// UsagePing.swift
// GetNewWord
//
// 每天匿名报到一次（照会议字幕的 src/main/usagePing.js）：我们会给前 100 位用户免费额度，所以要统计有多少人在用。
// 要用户先同意（UsageConsent：没问过 | yes | no），只有 yes 才发，没问过和不同意都不发。
// 新用户在欢迎引导里问；1.2.0 以前装的、和引导里没答那一步的人，打开主窗口时问一次（UsageConsentSheet）；
// 设置 › 更新与关于 › 匿名使用统计 随时能改。
// POST https://api.us-cloud.uk/v1/ping，不带 Authorization，body 只有 id（第一次启动时随机生成的 UUID，不是硬件号）、
// version、platform（darwin）、arch（arm64 | x64）、plan（member | own）、lang（界面语言）、product（getnewword）。
// 不发查的词、词库、截图、Key、名字和邮箱。
// 同一个本地日期只报一次：id 和报过的日期存在数据目录的 usage-ping.json。启动 5 秒后看一次，之后每小时看一眼
// （开着跨过午夜第二天也报）；失败（断网、4xx、5xx、10 秒超时）只记日志，这一天不算报过，下一个小时再试。
// 开发版、单元测试、--selftest 不报；设了 GETNEWWORD_API（比如本机假服务器 http://127.0.0.1:8790）才报，发到 <它>/v1/ping。

import Foundation

enum UsageConsent: String {
    case unasked = "", yes, no

    static let key = "usageConsent"

    static var current: UsageConsent {
        UsageConsent(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .unasked
    }

    /// 引导那一步、主窗口的询问、设置里的开关都走这里
    @MainActor static func answer(_ agree: Bool) {
        UserDefaults.standard.set(agree ? yes.rawValue : no.rawValue, forKey: key)
        AppLog.log("[Ping] consent: \(agree ? "yes" : "no")")
        // 刚同意：今天还没报过的现在就报，不等下一个小时
        if agree { Task { _ = await UsagePing.shared.tick() } }
    }
}

@MainActor
final class UsagePing {
    struct Body: Codable, Equatable {
        let id: String
        let version: String
        let platform: String
        let arch: String
        let plan: String
        let lang: String
        let product: String
    }

    enum Outcome: Equatable { case off, done, sent, failed }

    private struct State: Codable {
        var id: String?
        var day: String?
    }

    static let shared = UsagePing(
        file: AppVariant.supportDirectory.appendingPathComponent("usage-ping.json"),
        endpoint: endpoint(environment: ProcessInfo.processInfo.environment, isDev: AppVariant.isDev || AppVariant.isUnitTesting),
        enabled: { UsageConsent.current == .yes }
    )

    /// 正式版发到会员服务器；开发版和测试只在设了 GETNEWWORD_API 时发到它
    nonisolated static func endpoint(environment: [String: String], isDev: Bool) -> URL? {
        if let base = environment["GETNEWWORD_API"], !base.isEmpty {
            return URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base)?.appendingPathComponent("v1/ping")
        }
        return isDev ? nil : URL(string: "https://api.us-cloud.uk/v1/ping")
    }

    nonisolated private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        return URLSession(configuration: c)
    }()

    let file: URL
    let endpoint: URL?
    private let enabled: () -> Bool
    private let now: () -> Date
    private let send: @Sendable (URLRequest) async throws -> Int
    private var loop: Task<Void, Never>?
    private var busy: Task<Outcome, Never>?

    init(file: URL, endpoint: URL?, enabled: @escaping () -> Bool, now: @escaping () -> Date = Date.init,
         send: @escaping @Sendable (URLRequest) async throws -> Int = { request in
             let (_, response) = try await UsagePing.session.data(for: request)
             return (response as? HTTPURLResponse)?.statusCode ?? 0
         }) {
        self.file = file
        self.endpoint = endpoint
        self.enabled = enabled
        self.now = now
        self.send = send
    }

    /// 应用启动时调：记下这次安装的随机编号；能报的话 5 秒后看一次，之后每小时看一眼
    func start() {
        _ = installID()
        guard endpoint != nil else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                _ = await self?.tick()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// 看一眼：同意了、今天还没报过就报。同时来的几次合成一次
    func tick() async -> Outcome {
        if let busy { return await busy.value }
        let task = Task { await run() }
        busy = task
        let outcome = await task.value
        busy = nil
        return outcome
    }

    /// 本地日期 2026-10-28（不用 UTC：东八区早上 8 点前还算前一天）
    nonisolated static func localDay(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 这次报到发的内容；version、plan、lang 每次现取（升级、改界面语言之后跟着变）
    func body(id: String) -> Body {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let lang = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        return Body(
            id: id,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            platform: "darwin",
            arch: arch,
            plan: AIPlan.current == .member ? "member" : "own",
            lang: lang.hasPrefix("zh") ? "zh" : lang,
            product: "getnewword"
        )
    }

    private func run() async -> Outcome {
        guard let endpoint, enabled() else { return .off }
        var state = read()
        let day = Self.localDay(now())
        if state.day == day { return .done }
        let id = installID()
        state.id = id
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GetNewWord", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(body(id: id))
        do {
            let status = try await send(request)
            guard (200..<300).contains(status) else {
                AppLog.log("[Ping] HTTP \(status)")
                return .failed
            }
        } catch {
            AppLog.log("[Ping] failed: \((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))")
            return .failed
        }
        state.day = day
        write(state)
        AppLog.log("[Ping] sent for \(day)")
        return .sent
    }

    /// 这次安装的随机编号：第一次启动时生成，存在 usage-ping.json，删了应用数据才会换
    private func installID() -> String {
        var state = read()
        if let id = state.id, UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        state.id = id
        write(state)
        return id
    }

    private func read() -> State {
        guard let data = try? Data(contentsOf: file) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    private func write(_ state: State) {
        do {
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch {
            AppLog.log("[Ping] can't write \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
