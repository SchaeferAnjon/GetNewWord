// SupabaseAuth.swift
// GetNewWord
//
// 共用账号登录：Supabase Auth 的 Google OAuth（PKCE），手写 REST，不引 SDK。
// 流程：/auth/v1/authorize → ASWebAuthenticationSession 接 getnewword://auth-callback?code=… →
// POST /auth/v1/token?grant_type=pkce 换 session；过期前用 refresh_token 续期。会话存 Keychain。
// 后台看板事件：新登录报「登录」，已登录时启动/回到前台每天报一次「打开」（public.track_event）。

import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

struct SupabaseSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var email: String?
}

enum SupabaseAuthError: LocalizedError {
    case notSignedIn
    case callback(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return String(localized: "未登录")
        case .callback(let msg): return String(localized: "登录失败：\(msg)")
        case .http(let code, let body): return String(localized: "账号服务 HTTP \(code)：\(body)")
        }
    }
}

@MainActor
final class SupabaseAuth: NSObject, ObservableObject {
    static let shared = SupabaseAuth()

    static let callbackScheme = "getnewword"
    static let redirectURL = "getnewword://auth-callback"
    private static let keychainKey = "supabase_session"

    @Published private(set) var session: SupabaseSession?
    @Published private(set) var isSigningIn = false

    private var webSession: ASWebAuthenticationSession?
    private var refreshTask: Task<SupabaseSession, Error>?

    private override init() {
        super.init()
        if let raw = KeychainManager.shared.load(key: Self.keychainKey), let data = raw.data(using: .utf8) {
            session = try? JSONDecoder().decode(SupabaseSession.self, from: data)
        }
    }

    // MARK: - 登录 / 登出

    func signInWithGoogle() async throws {
        let verifier = Self.randomURLSafeString(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: Self.redirectURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]

        isSigningIn = true
        defer { isSigningIn = false; webSession = nil }
        NSApp.activate(ignoringOtherApps: true)
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            // 回调在 SafariLaunchAgent 的 XPC 队列上执行：闭包必须显式 @Sendable（非 MainActor 隔离），
            // 否则 Swift 6 会插入主线程断言，登录完成瞬间 dispatch_assert_queue 崩溃（crash 2026-09-14-191857）
            let completion: @Sendable (URL?, Error?) -> Void = { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.cancelled)) }
            }
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: Self.callbackScheme, completionHandler: completion)
            s.presentationContextProvider = self
            webSession = s
            if !s.start() { cont.resume(throwing: SupabaseAuthError.callback(String(localized: "无法打开登录窗口"))) }
        }

        // 成功：?code=…；失败：?error=…&error_description=…（也可能在 fragment 里）
        var params: [String: String] = [:]
        for part in [URLComponents(url: callback, resolvingAgainstBaseURL: false)?.query, callback.fragment] {
            var c = URLComponents(); c.query = part
            for item in c.queryItems ?? [] { params[item.name] = item.value ?? "" }
        }
        guard let code = params["code"], !code.isEmpty else {
            throw SupabaseAuthError.callback(params["error_description"] ?? params["error"] ?? String(localized: "回调里没有授权码"))
        }
        let s = try await tokenRequest(grantType: "pkce", body: ["auth_code": code, "code_verifier": verifier])
        store(s)
        AppLog.log("[Auth] signed in (user \(s.userId.prefix(8))…)")   // 日志会被附进反馈邮件：不记邮箱
    }

    func signOut() async {
        if let token = session?.accessToken {
            var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("auth/v1/logout"))
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        store(nil)
        AppLog.log("[Auth] signed out")
    }

    // MARK: - Token

    /// 返回有效的 access token；过期前 60 秒自动刷新。refresh token 失效时清掉会话。
    func validAccessToken() async throws -> String {
        guard let current = session else { throw SupabaseAuthError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let task = refreshTask { return try await task.value.accessToken }
        let task = Task { try await tokenRequest(grantType: "refresh_token", body: ["refresh_token": current.refreshToken]) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let s = try await task.value
            store(s)
            return s.accessToken
        } catch SupabaseAuthError.http(let code, let body) where code == 400 || code == 401 {
            AppLog.log("[Auth] refresh rejected (\(code)), signing out: \(body)")
            store(nil)
            throw SupabaseAuthError.notSignedIn
        }
    }

    private func tokenRequest(grantType: String, body: [String: String]) async throws -> SupabaseSession {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw SupabaseAuthError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        struct TokenResponse: Decodable {
            struct User: Decodable { var id: String; var email: String? }
            var access_token: String
            var refresh_token: String
            var expires_in: Double
            var user: User
        }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return SupabaseSession(accessToken: t.access_token, refreshToken: t.refresh_token,
                               expiresAt: Date().addingTimeInterval(t.expires_in),
                               userId: t.user.id, email: t.user.email)
    }

    private func store(_ s: SupabaseSession?) {
        session = s
        if let s, let data = try? JSONEncoder().encode(s) {
            KeychainManager.shared.save(key: Self.keychainKey, value: String(decoding: data, as: UTF8.self))
        } else {
            KeychainManager.shared.delete(key: Self.keychainKey)
        }
    }

    private static func randomURLSafeString(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64URLEncoded()
    }
}

extension SupabaseAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeKey } ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
