// MemberService.swift
// GetNewWord
//
// 会员（后台接口见 meetcaption-server 的 docs/multi-product.md §4）：不用注册账号，按这台 Mac 领免费试用
// （前 100 位新用户各 30 次查词）；之后订阅（月付、年付，刷卡自动续费），人民币另可一次买 1 个月 / 1 年（微信等，不自动续费）。
// 授权码能在另一台 Mac 上激活（一张最多 2 台）。会员模式下查词的 AI 请求发到我们的后台（OpenAI 兼容，带 X-Use-Id：
// 一次查词一个号），密钥只在服务器上。
// 这里只管和后台说话、记住设备令牌和最近一次状态；查词怎么发请求在 ZhipuService，界面在 PricingView、PlanCard。
// 后台地址：正式版 https://api.us-cloud.uk；开发版和单元测试只在设了 GETNEWWORD_API 时才连（开发版不占线上前 100 名的名额）。

import Foundation
import AppKit
import CryptoKit
import IOKit

// MARK: - 用法：会员 / 自带 Key

enum AIPlan: String, Sendable {
    case member, own

    static let key = "aiPlan"

    static var current: AIPlan {
        get { AIPlan(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .member }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 第一次启动新版时定一次：以前装的、填过 Key 的照旧自带 Key；新用户默认会员（欢迎引导里能改）
    static func settle(defaults: UserDefaults = .standard, hasAnyKey: () -> Bool) {
        guard defaults.string(forKey: key) == nil else { return }
        let existingUser = defaults.bool(forKey: "hasCompletedOnboarding") && hasAnyKey()
        defaults.set((existingUser ? AIPlan.own : .member).rawValue, forKey: key)
    }
}

// MARK: - 后台地址

enum MemberAPI {
    static let production = URL(string: "https://api.us-cloud.uk")!

    /// 正式版连线上后台；开发版和测试只在设了 GETNEWWORD_API 时连它（比如本机后台 http://127.0.0.1:8820）
    nonisolated static func base(environment: [String: String], isDev: Bool) -> URL? {
        if var raw = environment["GETNEWWORD_API"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            while raw.hasSuffix("/") { raw.removeLast() }
            return URL(string: raw)
        }
        return isDev ? nil : production
    }
}

// MARK: - 后台回的状态（GET /v1/getnewword/status）

struct MemberStatus: Codable, Equatable, Sendable {
    struct Trial: Codable, Equatable, Sendable {
        var granted = false
        var total = 0
        var used = 0
        var left = 0
    }
    struct Subscription: Codable, Equatable, Sendable {
        var status: String
        var plan: String?
        var currency: String?
        var amount: Int?
        var periodEnd: Double?
        var cancelAtPeriodEnd: Bool?
        var accessUntil: Double?
    }
    struct Pass: Codable, Equatable, Sendable {
        var plan: String?
        var currency: String?
        var amount: Int?
        var status: String?
        var startAt: Double?
        var until: Double?
    }
    struct Today: Codable, Equatable, Sendable {
        var limit: Int
        var used: Int
        var left: Int
        var resetAt: Double
    }
    struct Sync: Codable, Equatable, Sendable {
        var allowed: Bool
        var linked: Bool
        var email: String?
        var until: Double?
    }
    /// {"month": {"cny": 990, "usd": 199}, "year": {…}}，金额是分 / 美分
    typealias Prices = [String: [String: Int]]

    /// trial（还有试用）/ member（订阅或一次买在用）/ none
    var plan = "none"
    var code: String?
    var devices = 1
    var maxDevices = 2
    var trialOnly = true
    var trial = Trial()
    var subscription: Subscription?
    var pass: Pass?
    var memberUntil: Double?
    var autoRenew = false
    var expiring = false
    var today: Today?
    var canUse = true
    /// canUse 为 false 时：trial-used-up / trial-closed / sub-ended / payment-failed / daily-limit
    var reason: String?
    var prices: Prices?
    var passPrices: Prices?
    var sync: Sync?
    var now: Double = 0

    init() {}

    /// 缺字段补默认值：后台以后加减字段不让整个状态读不出来
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        func opt<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        plan = get(.plan, "none")
        code = opt(.code)
        devices = get(.devices, 1)
        maxDevices = get(.maxDevices, 2)
        trialOnly = get(.trialOnly, true)
        trial = get(.trial, Trial())
        subscription = opt(.subscription)
        pass = opt(.pass)
        memberUntil = opt(.memberUntil)
        autoRenew = get(.autoRenew, false)
        expiring = get(.expiring, false)
        today = opt(.today)
        canUse = get(.canUse, true)
        reason = opt(.reason)
        prices = opt(.prices)
        passPrices = opt(.passPrices)
        sync = opt(.sync)
        now = get(.now, 0)
    }

    var isMember: Bool { plan == "member" }

    static func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// 设备注册的回包：trial 是这次注册的结果（granted / existing / closed / ip-limit / daily-limit），次数明细在 trialUses
    static func registration(from data: Data) throws -> (token: String, trial: String, status: MemberStatus) {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { throw MemberError.badReply }
        let result = obj["trial"] as? String ?? ""
        obj["trial"] = obj["trialUses"]
        let status = try JSONDecoder().decode(MemberStatus.self, from: JSONSerialization.data(withJSONObject: obj))
        return (token, result, status)
    }
}

// MARK: - 出错

/// 后台的报错（{"error": {"code", "message"}}）和连不上。code 是 §4.0 的错误码，另有 network、unavailable、bad-reply
struct MemberError: LocalizedError, Equatable, Sendable {
    var code: String
    /// 后台给的原话（中文），只在不认识的错误码时显示
    var message = ""
    var status = 0
    var resetAt: Date?
    var retryAfter: Double?
    /// 下面三个是显示前按这台的状态补上的（MemberService.explain）：没领到试用的原因、一次买用到哪天、每天的上限是成本上限（次数其实还有）
    var miss: TrialMiss?
    var until: Date?
    var costCap = false

    static let network = MemberError(code: "network")
    static let unavailable = MemberError(code: "unavailable")
    static let badReply = MemberError(code: "bad-reply")

    static func from(status: Int, body: Data, headers: [AnyHashable: Any] = [:]) -> MemberError {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let retry = (headers["Retry-After"] as? String ?? headers["retry-after"] as? String).flatMap(Double.init)
        // 上游（DeepSeek）回 400 时，后台把上游的原文当 message 转过来：是 {"error":{"message":…}} 就只留里面那句
        var message = obj?["message"] as? String ?? ""
        if let inner = ZhipuErrorResponse.error(in: Data(message.utf8))?.message, !inner.isEmpty { message = inner }
        return MemberError(code: obj?["code"] as? String ?? "http", message: message,
                           status: status, resetAt: MemberStatus.date(obj?["resetAt"] as? Double), retryAfter: retry)
    }

    /// DeepSeek 的内容审核没过（400「Content Exists Risk」）
    var isContentRisk: Bool { code == "bad-request" && message.localizedCaseInsensitiveContains("content exists risk") }

    /// 等一会儿同一个用量号再发可能就好：上游暂时不可用、太频繁、后台 5xx
    var isRetryable: Bool {
        switch code {
        case "upstream", "rate", "too-fast": return true
        case "busy", "not-ready": return false
        default: return code == "http" && status >= 500
        }
    }

    /// 这几种说明额度变了，查一次状态让侧栏和会员页对上
    var changesStatus: Bool {
        ["trial-used-up", "trial-closed", "sub-ended", "payment-failed", "daily-limit"].contains(code)
    }

    var errorDescription: String? { MemberText.detail(self) }
}

// MARK: - 给人看的话（报错浮窗、会员页、侧栏卡片共用）

enum MemberText {
    static func title(_ e: MemberError) -> String {
        switch e.code {
        case "trial-used-up": return String(localized: "免费的 30 次用完了")
        case "trial-closed": return e.miss == .full ? String(localized: "免费名额已经发完了") : String(localized: "这台 Mac 没领到免费次数")
        case "sub-ended": return String(localized: "会员到期了")
        case "payment-failed": return String(localized: "续费没扣成")
        case "daily-limit": return e.costCap ? String(localized: "今天的用量到上限了") : String(localized: "今天的次数用完了")
        case "use-limit": return String(localized: "这个词查得太久了")
        case "use-expired": return String(localized: "这次查词过期了")
        case "busy": return String(localized: "会员 AI 今天太忙")
        case "upstream": return String(localized: "会员 AI 暂时连不上")
        case "rate", "too-fast": return String(localized: "查得太快了")
        case "network": return String(localized: "连不上会员服务器")
        case "unavailable": return String(localized: "开发版没连会员服务器")
        case "bad-code": return String(localized: "授权码不对")
        case "too-many-devices": return String(localized: "授权码已经用在 2 台电脑上")
        case "already-subscribed": return String(localized: "已经开了自动续费")
        case "pass-active": return String(localized: "一次买的会员还没到期")
        case "not-ready": return String(localized: "购买还没开通")
        case "portal-not-ready", "portal-upstream": return String(localized: "管理订阅暂时打不开")
        case "pay-upstream": return String(localized: "付款页暂时打不开")
        case "bad-request" where e.isContentRisk: return String(localized: "AI 不肯讲这段内容")
        default: return String(localized: "会员服务这次出错了")
        }
    }

    static func detail(_ e: MemberError) -> String {
        switch e.code {
        case "trial-used-up": return String(localized: "订阅会员接着用；也可以填自己的 AI Key，永久免费。")
        case "trial-closed":
            switch e.miss {
            case .full: return String(localized: "前 100 位新用户的免费次数已经发完，这台 Mac 没领到。订阅会员，或者填自己的 AI Key 免费用。")
            case .busy: return String(localized: "注册那天同一网络（或全站）领免费次数的人太多，这台 Mac 没领到。订阅会员，或者填自己的 AI Key 免费用。")
            default: return String(localized: "这台 Mac 注册时没领到免费次数。订阅会员，或者填自己的 AI Key 免费用。")
            }
        case "sub-ended": return String(localized: "续订或再买一段就能接着查；也可以填自己的 AI Key 免费用。")
        case "payment-failed": return String(localized: "上一期的续费没扣成。打开「管理订阅」换一张卡，换好马上恢复。")
        case "daily-limit":
            if e.costCap {
                if let reset = e.resetAt {
                    return String(localized: "今天用的 AI 量到上限了（框的内容很长时会比次数先到）。\(reset.formatted(date: .omitted, time: .shortened)) 恢复（你这里的时间）。")
                }
                return String(localized: "今天用的 AI 量到上限了（框的内容很长时会比次数先到）。北京时间早上 8 点恢复。")
            }
            if let reset = e.resetAt {
                return String(localized: "\(reset.formatted(date: .omitted, time: .shortened)) 恢复（你这里的时间），到时候再按一次就行。")
            }
            return String(localized: "北京时间早上 8 点恢复，到时候再按一次就行。")
        case "use-limit": return String(localized: "一次查词里请求太多了。关掉面板，重新框一次。")
        case "use-expired": return String(localized: "面板开得太久，重新框一次就好。")
        case "busy": return String(localized: "今天用的人太多，过一会儿再按一次。")
        case "upstream": return String(localized: "我们这边的 AI 服务暂时不通，不是你的问题。过一会儿再按一次。")
        case "rate", "too-fast": return String(localized: "等几秒再按。")
        case "network": return String(localized: "检查一下网络，再按一次快捷键。")
        case "unavailable": return String(localized: "开发版要设环境变量 GETNEWWORD_API 指到本机后台才连会员服务器；也可以先用自带 Key。")
        case "bad-code": return String(localized: "不是 GetNewWord 的授权码，核对一下再试（GW- 开头）。")
        case "too-many-devices": return String(localized: "一个授权码最多 2 台。先在另一台的「方案和价格」里点「解绑这台电脑」。")
        case "already-subscribed": return String(localized: "要改月付年付、取消或换卡，打开「管理订阅」。一次买要先在那里取消自动续费。")
        case "pass-active":
            if let until = e.until { return String(localized: "一次买的会员用到 \(MemberText.day(until))。到期前 3 天再开自动续费，接着用不断档。") }
            return e.message.isEmpty ? String(localized: "到期前 3 天再开自动续费，接着用不断档。") : e.message
        case "not-ready": return String(localized: "收款还没配好，过一阵再来；现在可以先用自带 Key。")
        case "portal-not-ready": return String(localized: "付款服务这边还没配好，过一阵再试。会员照常能用。")
        case "portal-upstream": return String(localized: "付款服务暂时连不上，过一会儿再试。会员照常能用。")
        case "pay-upstream": return String(localized: "付款服务暂时连不上，过一会儿再点一次。")
        case "bad-reply": return String(localized: "会员服务器回的内容读不懂，过一会儿再试。")
        case "bad-request" where e.isContentRisk: return String(localized: "这段内容没过 AI 服务商的内容审核，换一段再框。")
        default: return e.message.isEmpty ? String(localized: "过一会儿再试。（HTTP \(e.status)）") : e.message
        }
    }

    /// 金额（分）→ ¥9.9 / $1.99
    static func price(_ amount: Int, _ currency: String) -> String {
        let value = Double(amount) / 100
        let text = value == value.rounded() ? String(Int(value)) : String(format: currency == "usd" ? "%.2f" : "%.1f", value)
        return (currency == "usd" ? "$" : "¥") + text
    }

    static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
}

// MARK: - 现在是哪种状态（侧栏卡片、会员页用）

/// 没领到试用的原因：注册那次后台回的 trial（closed / ip-limit / daily-limit）
enum TrialMiss: Equatable, Sendable {
    /// 前 100 位的名额发完了
    case full
    /// 注册那天同一网络（ip-limit）或全站当天（daily-limit）领的人太多
    case busy
    /// 说不准：比如重新注册过，后台只回「老设备」
    case unknown

    static func of(_ trialResult: String?) -> TrialMiss {
        switch trialResult {
        case "closed": return .full
        case "ip-limit", "daily-limit": return .busy
        default: return .unknown
        }
    }
}

enum MemberState: Equatable {
    /// 开发版没设后台地址
    case unavailable
    /// 会员用法、还没向后台注册：第一次用会员查词、在引导里选着会员点「继续」、点订阅或输授权码时才注册领试用
    case notClaimed
    /// 还没有状态，正在连
    case connecting
    /// 还没有状态，也连不上
    case offline
    case trial(left: Int, total: Int)
    case trialUsedUp
    /// 没领到试用
    case trialClosed(TrialMiss)
    case member(until: Date?, autoRenew: Bool, expiring: Bool, pastDue: Bool, todayLeft: Int?, limit: Int?)
    case dailyLimit(reset: Date?)
    case paymentFailed
    case ended

    /// registered：这台已经向后台注册过（或正在注册）
    static func of(_ status: MemberStatus?, available: Bool, failed: Bool, trialResult: String?, registered: Bool = true, now: Date = Date()) -> MemberState {
        guard available else { return .unavailable }
        guard let s = status else { return !registered ? .notClaimed : failed ? .offline : .connecting }
        if s.isMember {
            let reset = MemberStatus.date(s.today?.resetAt)
            if s.reason == "daily-limit", (reset ?? .distantFuture) > now { return .dailyLimit(reset: reset) }
            // 自动续费的写下次扣款日（当期结束）；其余写用到哪天（含续费没扣成的宽限）
            let until = s.autoRenew ? MemberStatus.date(s.subscription?.periodEnd ?? s.memberUntil) : MemberStatus.date(s.memberUntil)
            return .member(until: until, autoRenew: s.autoRenew, expiring: s.expiring,
                           pastDue: s.subscription?.status == "past_due", todayLeft: s.today?.left, limit: s.today?.limit)
        }
        if s.plan == "trial", s.trial.left > 0 { return .trial(left: s.trial.left, total: s.trial.total) }
        switch s.reason {
        case "payment-failed": return .paymentFailed
        case "sub-ended": return .ended
        case "trial-closed": return .trialClosed(.of(trialResult))
        default: return s.trial.granted ? .trialUsedUp : .trialClosed(.of(trialResult))
        }
    }

    /// 能直接查词：还没领（第一次查词时领）、试用中、会员（含续费没扣成的宽限）
    var ready: Bool {
        switch self {
        case .notClaimed, .trial, .member: return true
        default: return false
        }
    }

    /// 现在能不能查词（后台最后说了算，这里只用来决定先不先拦下）
    var blocked: Bool {
        switch self {
        case .trialUsedUp, .trialClosed, .dailyLimit, .paymentFailed, .ended, .unavailable: return true
        default: return false
        }
    }

    /// 拦下时给报错浮窗的错误码
    var blockCode: String? {
        switch self {
        case .trialUsedUp: return "trial-used-up"
        case .trialClosed: return "trial-closed"
        case .dailyLimit: return "daily-limit"
        case .paymentFailed: return "payment-failed"
        case .ended: return "sub-ended"
        case .unavailable: return "unavailable"
        default: return nil
        }
    }
}

// MARK: - 设备标识

enum MemberDevice {
    /// sha256("getnewword:" + 硬件 UUID) 的十六进制：同一台 Mac 重装还是同一台，换不出新的试用；后台只存它的哈希
    nonisolated static func fingerprint(hardwareUUID: String) -> String {
        SHA256.hash(data: Data("getnewword:\(hardwareUUID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 这台 Mac 的 IOPlatformUUID；读不到返回 nil
    nonisolated static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 读不到硬件 UUID 时用存在本机的随机值（删了应用数据会换）
    @MainActor static func current(defaults: UserDefaults = .standard) -> String {
        if let uuid = hardwareUUID() { return fingerprint(hardwareUUID: uuid) }
        let key = "memberFallbackDevice"
        if let saved = defaults.string(forKey: key), saved.count == 64 { return saved }
        let random = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        defaults.set(random, forKey: key)
        return random
    }
}

// MARK: - 设备令牌放哪

/// 设备令牌（gwd_…）：正式用钥匙串，测试放内存。连哪个后台的令牌就只给哪个后台用（本机测试的令牌不会发给线上）
struct MemberTokenStore {
    var load: () -> String?
    var save: (String?) -> Void

    @MainActor static func keychain(api: URL?) -> MemberTokenStore {
        let account = "member_device"
        return MemberTokenStore(load: {
            guard let raw = KeychainManager.shared.load(key: account), let data = raw.data(using: .utf8),
                  let saved = try? JSONDecoder().decode([String: String].self, from: data),
                  saved["api"] == api?.absoluteString else { return nil }
            return saved["token"]
        }, save: { token in
            guard let token, let api,
                  let data = try? JSONEncoder().encode(["api": api.absoluteString, "token": token]) else {
                KeychainManager.shared.delete(key: account)
                return
            }
            KeychainManager.shared.save(key: account, value: String(decoding: data, as: UTF8.self))
        })
    }

    static func memory(_ initial: String? = nil) -> MemberTokenStore {
        final class Box: @unchecked Sendable { var token: String? }
        let box = Box()
        box.token = initial
        return MemberTokenStore(load: { box.token }, save: { box.token = $0 })
    }
}

// MARK: - 会员服务

/// 查词时 ZhipuService 要的东西：往哪发、带什么令牌、一次查词用哪个用量号、回来的次数记到哪
protocol MemberRoute: AnyObject, Sendable {
    func credentials() async throws -> MemberCredentials
    /// 令牌被后台拒了（401 bad-device）：重新注册；拿到新的返回 true
    func renewToken(_ used: String) async -> Bool
    /// 这次查词（runID）现在用的用量号：一般就是 runID；过了窗口换过号的用新的
    func useID(for run: UUID) async -> UUID
    /// 用量号过了窗口（409 use-expired）：这次查词以后都用一个新号（会再算一次）
    func renewUse(for run: UUID) async -> UUID
    /// 计量接口回来以后：返回头里的剩余次数记上；402 / 429 这类改了额度的查一次状态
    func noteResponse(headers: [String: String], error: MemberError?) async
}

extension HTTPURLResponse {
    /// 返回头转成 [String: String]（跨 actor 传）
    var stringHeaders: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in allHeaderFields { if let k = k as? String { out[k] = v as? String ?? "\(v)" } }
        return out
    }
}

struct MemberCredentials: Sendable {
    let chatURL: URL
    let token: String
}

@MainActor
final class MemberService: ObservableObject, MemberRoute {
    static let shared = MemberService(
        api: MemberAPI.base(environment: ProcessInfo.processInfo.environment, isDev: AppVariant.isDev || AppVariant.isUnitTesting),
        defaults: .standard
    )

    /// 开过的一次结账（付款页）
    struct Purchase: Equatable {
        let claim: String
        let mode: String
        let plan: String
        let currency: String
        let url: URL
        let started: Date
    }

    /// 绑定同步账号没成功：哪个 Supabase 用户、什么错、什么时候
    struct LinkFailure: Equatable {
        let user: String
        let error: MemberError
        let at: Date
    }

    @Published private(set) var status: MemberStatus?
    /// 最近一次没连上 / 出错；有旧状态时界面照样显示旧的，只多一句提示
    @Published private(set) var lastError: MemberError?
    /// 正在等付款（每 3 秒问一次）
    @Published private(set) var purchase: Purchase?
    /// 注册时的试用结果：granted / existing / closed / ip-limit / daily-limit
    @Published private(set) var trialResult: String?
    /// 刚付完款（会员页显示「付款成功」）
    @Published var justPaid = false
    /// 这台向后台注册过（钥匙串里有设备令牌）
    @Published private(set) var registered: Bool
    @Published private(set) var claiming = false
    /// 正在请后台打开同步 / 上次绑定没成功
    @Published private(set) var linking = false
    @Published private(set) var linkFailure: LinkFailure?
    /// 会员页上面那条提示：别处（查词报错浮窗的「管理订阅」）出的错带到会员页显示
    @Published var notice: MemberError?

    let api: URL?
    var isAvailable: Bool { api != nil }
    var state: MemberState {
        MemberState.of(status, available: isAvailable, failed: lastError != nil, trialResult: trialResult, registered: registered || claiming)
    }
    var isMember: Bool { status?.isMember == true }

    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let tokens: MemberTokenStore
    private let defaults: UserDefaults
    private let device: () -> String
    private let openURL: (URL) -> Void
    /// 会员模式（单元测试换掉，不读 UserDefaults）
    var memberMode: () -> Bool = { AIPlan.current == .member }
    /// 现在登录同步的账号（单元测试换掉）
    var syncSession: () -> SupabaseSession? = { SupabaseAuth.shared.session }
    var supabaseToken: () async throws -> String = { try await SupabaseAuth.shared.validAccessToken() }
    var pollInterval: Duration = .seconds(3)
    var pollLimit: TimeInterval = 30 * 60
    /// Stripe 的付款页开出来 1 小时内有效：这么久以内再点同一个方案，重新打开同一个付款页，不另开一单
    static let checkoutReuse: TimeInterval = 55 * 60
    /// 自动绑定同步账号失败后，这么久内不再自动试（点「重试」不受限）
    static let linkRetryAfter: TimeInterval = 10 * 60

    private var registering: Task<String, Error>?
    private var refreshing: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private(set) var checkedAt: Date?
    /// 刚打开过浏览器（结账、管理订阅）：回到前台时不节流，马上查一次
    private var backFromBrowser = false
    private var useAliases: [UUID: UUID] = [:]
    /// 最近开的付款页：点了「不等了」也留着，见 checkoutReuse
    private var lastCheckout: Purchase?
    private static let cacheKey = "memberCache"

    private struct Cache: Codable {
        var api: String
        var status: MemberStatus?
        var trialResult: String?
    }

    init(api: URL?, defaults: UserDefaults, tokens: MemberTokenStore? = nil,
         device: (() -> String)? = nil,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.api = api
        self.defaults = defaults
        let tokens = tokens ?? .keychain(api: api)
        self.tokens = tokens
        self.registered = api != nil && tokens.load() != nil
        self.device = device ?? { MemberDevice.current(defaults: defaults) }
        self.openURL = openURL
        self.send = send
        // 上次的状态先显示着（侧栏卡片一打开就有数），连上后台再换成新的
        if let api, let data = defaults.data(forKey: Self.cacheKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.api == api.absoluteString {
            status = cache.status
            trialResult = cache.trialResult
        }
    }

    private func storeToken(_ token: String?) {
        tokens.save(token)
        registered = token != nil
    }

    /// 应用启动时：会员用法、注册过的才查一次状态；回到前台再查（节流 60 秒）。没注册过的不在这里注册
    func start() {
        if memberMode() && registered { Task { await refresh() } }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appBecameActive() }
        }
    }

    private func appBecameActive() {
        let force = backFromBrowser
        backFromBrowser = false
        // 自带 Key 的不在回到前台时打后台；刚从付款页、门户回来的照样查（买了、退订了要马上对上）
        guard registered, memberMode() || force else { return }
        Task { await refresh(maxAge: force ? 0 : 60) }
    }

    // MARK: 设备注册、状态

    /// 注册这台、领试用，存下设备令牌；注册过直接返回令牌。同时来的几次合成一次。
    /// 只在人真要用会员时调：第一次用会员查词、引导里选会员点「继续」、点订阅、输授权码
    func ensureDevice() async throws -> String {
        if let token = tokens.load() { return token }
        if let task = registering { return try await task.value }
        let task = Task { () throws -> String in
            let data = try await self.request("POST", "v1/getnewword/device", body: [
                "device": self.device(), "platform": "darwin", "arch": Self.arch, "version": Self.version,
            ], auth: false)
            let r = try MemberStatus.registration(from: data)
            self.storeToken(r.token)
            // 重新注册（令牌丢了）后台只回 existing：留着第一次注册的结果，没领到试用时才说得出原因
            if r.trial != "existing" || self.trialResult == nil { self.trialResult = r.trial }
            self.lastError = nil
            self.checkedAt = Date()
            self.apply(r.status)
            AppLog.log("[Member] registered: trial \(r.trial), plan \(r.status.plan), left \(r.status.trial.left)")
            return r.token
        }
        registering = task
        claiming = true
        defer {
            registering = nil
            claiming = false
        }
        return try await task.value
    }

    /// 引导里选着会员点「继续」：注册、领试用。连不上只记下来（第一次查词时再领）
    func claimTrial() async {
        guard api != nil, !registered else { return }
        do {
            _ = try await ensureDevice()
        } catch {
            lastError = error as? MemberError ?? .network
            AppLog.log("[Member] claim trial failed: \(lastError?.code ?? "?")")
        }
    }

    /// 向后台要最新状态（别的电脑用掉了、退款、到期只有后台知道）。连不上就留着旧的。
    /// maxAge：有状态且上次查过不到这么久就不再查（回到前台、打开会员页时用，别每次切窗口都打后台）
    /// 没注册过的不查：查状态要先注册设备，不替还没用会员的人占试用名额
    func refresh(maxAge: TimeInterval = 0) async {
        guard api != nil, registered else { return }
        if let task = refreshing { return await task.value }
        if maxAge > 0, status != nil, let at = checkedAt, Date().timeIntervalSince(at) < maxAge { return }
        let task = Task {
            do {
                self.apply(try JSONDecoder().decode(MemberStatus.self, from: await self.request("GET", "v1/getnewword/status")))
                self.lastError = nil
            } catch {
                self.lastError = error as? MemberError ?? .network
                AppLog.log("[Member] status failed: \(self.lastError?.code ?? "?")")
            }
            self.checkedAt = Date()
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func apply(_ s: MemberStatus) {
        let before = status
        status = s
        if let api, let data = try? JSONEncoder().encode(Cache(api: api.absoluteString, status: s, trialResult: trialResult)) {
            defaults.set(data, forKey: Self.cacheKey)
        }
        if before?.plan != s.plan || before?.sync != s.sync {
            NotificationCenter.default.post(name: .memberStatusChanged, object: nil)
        }
        if s.isMember { linkSyncIfNeeded() }
    }

    /// 报错给人看之前，按这台的状态补上说清楚原因要的东西（没领到试用的原因、一次买用到哪天、是不是成本上限）
    func explain(_ e: MemberError) -> MemberError {
        var e = e
        switch e.code {
        case "trial-closed": e.miss = .of(trialResult)
        case "pass-active": e.until = MemberStatus.date(status?.memberUntil)
        // 后台每天的上限有两种：200 次用完、或这张授权当天的成本到顶。后者时状态里今天还剩好多次
        case "daily-limit": e.costCap = (status?.today?.left ?? 0) > 0
        default: break
        }
        return e
    }

    // MARK: 授权码

    func activate(code: String) async throws {
        apply(try JSONDecoder().decode(MemberStatus.self, from: await request("POST", "v1/getnewword/license/activate", body: ["code": code])))
        lastError = nil
        AppLog.log("[Member] activated a license code, plan \(status?.plan ?? "?")")
    }

    /// 这台退回自己的试用授权（剩几次就几次）
    func unbind() async throws {
        apply(try JSONDecoder().decode(MemberStatus.self, from: await request("POST", "v1/getnewword/license/unbind")))
        AppLog.log("[Member] unbound this Mac")
    }

    // MARK: 购买

    /// 开结账：mode sub（自动续费）/ pass（一次买，只有人民币）。浏览器打开付款页，之后每 3 秒问一次，最多等 30 分钟。
    /// 1 小时内点过同一个方案、还没付完的（比如点了「不等了」）：先问一次那单，没付就重新打开同一个付款页，不另开一单（免得两个都付了扣两份）
    func buy(plan: String, currency: String, mode: String) async throws {
        if let last = lastCheckout, last.plan == plan, last.mode == mode, last.currency == currency,
           Date().timeIntervalSince(last.started) < Self.checkoutReuse {
            switch await checkClaim(last.claim) {
            case "paid":
                return
            case "expired":
                break
            default:
                justPaid = false
                purchase = last
                backFromBrowser = true
                AppLog.log("[Member] checkout reopened \(mode) \(plan) \(currency)")
                openURL(last.url)
                startPolling(last.claim)
                return
            }
        }
        struct Checkout: Decodable { let url: String; let claim: String }
        let data: Data
        do {
            data = try await request("POST", "v1/getnewword/checkout", body: ["plan": plan, "currency": currency, "mode": mode])
        } catch var e as MemberError where e.code == "upstream" {
            e.code = "pay-upstream"   // 是付款服务连不上，不是会员 AI
            throw e
        }
        let r = try JSONDecoder().decode(Checkout.self, from: data)
        guard let url = URL(string: r.url) else { throw MemberError.badReply }
        justPaid = false
        let p = Purchase(claim: r.claim, mode: mode, plan: plan, currency: currency, url: url, started: Date())
        purchase = p
        lastCheckout = p
        backFromBrowser = true
        AppLog.log("[Member] checkout \(mode) \(plan) \(currency)")
        openURL(url)
        startPolling(r.claim)
    }

    /// 「不等了」：只是不再问，付款页留着，1 小时内再点同一个方案还打开它
    func cancelPurchase() {
        poll?.cancel()
        poll = nil
        purchase = nil
    }

    /// 问一次这单付了没有：付了就更新状态。回 paid / expired / pending，问不到回 nil
    private func checkClaim(_ claim: String) async -> String? {
        guard let data = try? await request("GET", "v1/getnewword/checkout/\(claim)"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = obj["status"] as? String
        switch result {
        case "paid":
            if let s = try? JSONDecoder().decode(MemberStatus.self, from: data) { apply(s) }
            lastError = nil
            checkedAt = Date()
            justPaid = true
            purchase = nil
            lastCheckout = nil
            AppLog.log("[Member] paid, plan \(status?.plan ?? "?")")
        case "expired":
            AppLog.log("[Member] checkout expired")
            if purchase?.claim == claim { purchase = nil }
            if lastCheckout?.claim == claim { lastCheckout = nil }
        default:
            break
        }
        return result
    }

    private func startPolling(_ claim: String) {
        poll?.cancel()
        poll = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.pollInterval)
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(started) > self.pollLimit { break }
                switch await self.checkClaim(claim) {
                case "paid", "expired":
                    self.poll = nil
                    return
                default:
                    continue   // 还没付，或网络抖一下：接着等
                }
            }
            self?.purchase = nil
            self?.poll = nil
        }
    }

    /// 管理订阅：打开 Stripe 的客户门户（取消、改月付年付、换卡、看发票）。回到前台时马上查一次状态
    func openPortal() async throws {
        struct Portal: Decodable { let url: String }
        let data: Data
        do {
            data = try await request("POST", "v1/getnewword/portal")
        } catch var e as MemberError where ["not-ready", "upstream"].contains(e.code) {
            e.code = "portal-" + e.code   // 门户打不开和「购买还没开通」「AI 连不上」不是一回事
            throw e
        }
        let r = try JSONDecoder().decode(Portal.self, from: data)
        guard let url = URL(string: r.url) else { throw MemberError.badReply }
        backFromBrowser = true
        openURL(url)
    }

    // MARK: 多台 Mac 同步（会员才有）

    /// 两个邮箱是不是同一个（不分大小写）；有一个不知道就算不是
    nonisolated static func sameEmail(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// 这次绑定失败只算现在登录的这个账号的
    var currentLinkFailure: MemberError? {
        guard let f = linkFailure, f.user == syncSession()?.userId else { return nil }
        return f.error
    }

    /// 会员登录着、这张授权还没绑同步账号：自动绑上（后台去 Supabase 打开这个账号的同步）。
    /// 已经绑了别的账号不自动换：两台 Mac 用同一个授权码、登不同的 Google 账号时会来回抢，要人在「账号与同步」里点了才换
    func linkSyncIfNeeded() {
        // status 里没有 sync：后台还没开同步资格（没配 Supabase），不用去绑
        guard let session = syncSession(), let s = status, s.isMember, let sync = s.sync, !sync.linked, !linking else { return }
        if let f = linkFailure, f.user == session.userId, Date().timeIntervalSince(f.at) < Self.linkRetryAfter { return }
        Task { await linkSync() }
    }

    /// 把这张授权的同步绑到现在登录的账号。已经绑了这个账号的再绑一次 = 请后台再推一次（不算换绑）。
    /// replacing：已经绑了别的账号，人点了「换成这个账号」才换
    func linkSync(replacing: Bool = false) async {
        guard api != nil, !linking, let session = syncSession(), let s = status, s.isMember, let sync = s.sync else { return }
        if sync.linked, !replacing, !Self.sameEmail(sync.email, session.email) { return }
        linking = true
        defer { linking = false }
        do {
            let token = try await supabaseToken()
            struct Linked: Decodable { let sync: MemberStatus.Sync }
            let r = try JSONDecoder().decode(Linked.self, from: await request("POST", "v1/getnewword/sync/link", body: ["supabaseToken": token]))
            linkFailure = nil
            if var s = status {
                s.sync = r.sync
                apply(s)
            }
            AppLog.log("[Member] sync linked, allowed \(r.sync.allowed)")
            NotificationCenter.default.post(name: .memberStatusChanged, object: nil)
        } catch {
            let e = error as? MemberError ?? (error is SupabaseAuthError ? MemberError(code: "bad-supabase-token") : .network)
            linkFailure = LinkFailure(user: session.userId, error: e, at: Date())
            AppLog.log("[Member] sync link failed: \(e.code)")
        }
    }

    // MARK: MemberRoute（查词时 ZhipuService 用）

    func credentials() async throws -> MemberCredentials {
        guard let api else { throw MemberError.unavailable }
        return MemberCredentials(chatURL: api.appendingPathComponent("v1/getnewword/chat/completions"), token: try await ensureDevice())
    }

    func renewToken(_ used: String) async -> Bool {
        if tokens.load() == used { storeToken(nil) }
        return (try? await ensureDevice()).map { $0 != used } ?? false
    }

    func useID(for run: UUID) async -> UUID { useAliases[run] ?? run }

    func renewUse(for run: UUID) async -> UUID {
        let fresh = UUID()
        useAliases[run] = fresh
        return fresh
    }

    func noteResponse(headers: [String: String], error: MemberError?) async {
        if let error {
            if error.changesStatus { await refresh() }
            return
        }
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard var s = status, let left = header("X-Uses-Left").flatMap(Int.init) else { return }
        switch header("X-Uses-Kind") {
        case "trial":
            s.trial.left = left
            s.trial.used = max(0, s.trial.total - left)
            if left <= 0, !s.isMember {
                s.plan = "none"
                s.canUse = false
                s.reason = s.trial.granted ? "trial-used-up" : "trial-closed"
            }
        case "sub":
            if var today = s.today {
                today.left = left
                today.used = max(0, today.limit - left)
                if let reset = header("X-Uses-Reset").flatMap(Double.init) { today.resetAt = reset }
                s.today = today
            }
            if left <= 0 {
                s.canUse = false
                s.reason = "daily-limit"
            } else if s.reason == "daily-limit" {
                // 过了 0 点的第一次查词：昨天记下的「用完了」清掉，不然重置时间换成今晚以后又显示用完
                s.canUse = true
                s.reason = nil
            }
        default: return
        }
        if s != status { apply(s) }
    }

    // MARK: 发请求

    private static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// 发一个会员接口的请求（20 秒超时）。设备令牌失效（401 bad-device）就重新注册一次再发：同一台 Mac 拿回原来的账
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = true, retry: Bool = true) async throws -> Data {
        guard let api else { throw MemberError.unavailable }
        let token = auth ? try await ensureDevice() : nil
        var req = URLRequest(url: api.appendingPathComponent(path), timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("GetNewWord/\(Self.version)", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(req)
        } catch {
            AppLog.log("[Member] \(method) \(path) failed: \((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))")
            throw MemberError.network
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        let error = MemberError.from(status: status, body: data, headers: http?.allHeaderFields ?? [:])
        if status == 401, error.code == "bad-device", auth, retry, let token {
            if tokens.load() == token { storeToken(nil) }
            return try await request(method, path, body: body, auth: auth, retry: false)
        }
        AppLog.log("[Member] \(method) \(path) → \(status) \(error.code)")
        throw error
    }
}

extension Notification.Name {
    /// 会员状态变了（成了会员、到期、同步资格变了）：同步服务据此重新判断要不要同步
    static let memberStatusChanged = Notification.Name("GetNewWord.memberStatusChanged")
}
