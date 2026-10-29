// 会员：后台的状态和报错读得对、该拦的拦、按钮文案跟着状态；设备注册、令牌失效重新注册、结账轮询、门户；
// 会员模式下查词发到后台、一次查词一个用量号、用量号过期换新号、试用用完直接报。全部用假的后台，不连网。

import Foundation
import Testing
@testable import GetNewWord

// MARK: - 后台回的东西

private let statusJSON = #"""
{"product":"getnewword","plan":"trial","code":null,"devices":1,"maxDevices":2,"trialOnly":true,
 "trial":{"granted":true,"total":30,"used":3,"left":27},"subscription":null,"pass":null,"memberUntil":null,
 "autoRenew":false,"expiring":false,"today":null,"canUse":true,"reason":null,
 "prices":{"month":{"cny":990,"usd":199},"year":{"cny":9900,"usd":1990}},"passPrices":{"month":{"cny":990},"year":{"cny":9900}},
 "sync":null,"now":1793232000000}
"""#

private func status(_ json: String) throws -> MemberStatus {
    try JSONDecoder().decode(MemberStatus.self, from: Data(json.utf8))
}

/// 后台状态的一份改写：plan、reason、试用剩几次、会员到哪天、今天的额度
private func makeStatus(plan: String, left: Int = 0, granted: Bool = true, reason: String? = nil, until: Date? = nil,
                        autoRenew: Bool = false, expiring: Bool = false, todayLeft: Int? = nil, resetAt: Date? = nil,
                        subscription: String? = nil) -> MemberStatus {
    var s = MemberStatus()
    s.plan = plan
    s.trial = .init(granted: granted, total: granted ? 30 : 0, used: granted ? 30 - left : 0, left: left)
    s.reason = reason
    s.canUse = reason == nil
    s.memberUntil = until.map { $0.timeIntervalSince1970 * 1000 }
    s.autoRenew = autoRenew
    s.expiring = expiring
    if let todayLeft {
        s.today = .init(limit: 200, used: 200 - todayLeft, left: todayLeft, resetAt: (resetAt ?? Date().addingTimeInterval(3600)).timeIntervalSince1970 * 1000)
    }
    if let subscription { s.subscription = .init(status: subscription, plan: "month", currency: "cny", amount: 990) }
    return s
}

@MainActor
struct MemberStatusTests {
    @Test func decodesTheServerShape() throws {
        let s = try status(statusJSON)
        #expect(s.plan == "trial")
        #expect(s.trial == .init(granted: true, total: 30, used: 3, left: 27))
        #expect(s.prices?["year"]?["usd"] == 1990)
        #expect(s.passPrices?["month"]?["cny"] == 990)
        #expect(s.passPrices?["month"]?["usd"] == nil)
        #expect(s.canUse && !s.isMember)
        #expect(s.code == nil && s.trialOnly && s.maxDevices == 2)
    }

    /// 后台少了字段、多了字段都照样读（缺的给默认值）
    @Test func toleratesMissingAndExtraFields() throws {
        let s = try status(#"{"plan":"member","memberUntil":1795824000000,"brandNew":{"x":1},"today":{"limit":200,"used":12,"left":188,"resetAt":1793318400000}}"#)
        #expect(s.isMember)
        #expect(s.today?.left == 188)
        #expect(s.trial == .init())
        #expect(s.canUse)
    }

    /// 注册的回包：trial 是这次注册的结果，次数明细在 trialUses
    @Test func registrationSplitsTrialResult() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(statusJSON.utf8)) as? [String: Any])
        obj["trialUses"] = obj["trial"]
        obj["trial"] = "granted"
        obj["token"] = "gwd_abc"
        let r = try MemberStatus.registration(from: JSONSerialization.data(withJSONObject: obj))
        #expect(r.token == "gwd_abc")
        #expect(r.trial == "granted")
        #expect(r.status.trial.left == 27)
        #expect(throws: MemberError.self) { try MemberStatus.registration(from: Data(#"{"trial":"closed"}"#.utf8)) }
    }

    @Test func states() {
        let later = Date().addingTimeInterval(20 * 86_400)
        func state(_ s: MemberStatus?, trialResult: String? = nil, available: Bool = true, failed: Bool = false) -> MemberState {
            MemberState.of(s, available: available, failed: failed, trialResult: trialResult)
        }
        #expect(state(nil, available: false) == .unavailable)
        #expect(state(nil) == .connecting)
        #expect(state(nil, failed: true) == .offline)
        #expect(state(makeStatus(plan: "trial", left: 27)) == .trial(left: 27, total: 30))
        #expect(state(makeStatus(plan: "none", reason: "trial-used-up")) == .trialUsedUp)
        // 名额发完：照实说；注册那天同网络 / 全站当天满了的另说
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed")) == .trialClosed(daily: false))
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "ip-limit") == .trialClosed(daily: true))
        #expect(state(makeStatus(plan: "none", reason: "sub-ended")) == .ended)
        #expect(state(makeStatus(plan: "none", reason: "payment-failed")) == .paymentFailed)
        let member = state(makeStatus(plan: "member", until: later, autoRenew: true, todayLeft: 188, subscription: "active"))
        guard case .member(let until, let autoRenew, _, let pastDue, let left, let limit) = member else {
            Issue.record("应为会员：\(member)")
            return
        }
        #expect(abs((until ?? .distantPast).timeIntervalSince(later)) < 1)
        #expect(autoRenew && !pastDue && left == 188 && limit == 200)
        #expect(!member.blocked)
        // 每天上限：没到重置时间拦下；过了 UTC 0 点（状态还没刷新）就不拦
        let reset = Date().addingTimeInterval(3600)
        #expect(state(makeStatus(plan: "member", reason: "daily-limit", until: later, todayLeft: 0, resetAt: reset)).blockCode == "daily-limit")
        #expect(!state(makeStatus(plan: "member", reason: "daily-limit", until: later, todayLeft: 0, resetAt: Date().addingTimeInterval(-60))).blocked)
        #expect(state(makeStatus(plan: "member", until: later, todayLeft: 3, subscription: "past_due")).blocked == false)
        for (s, code) in [(makeStatus(plan: "none", reason: "trial-used-up"), "trial-used-up"),
                          (makeStatus(plan: "none", granted: false, reason: "trial-closed"), "trial-closed"),
                          (makeStatus(plan: "none", reason: "sub-ended"), "sub-ended"),
                          (makeStatus(plan: "none", reason: "payment-failed"), "payment-failed")] {
            #expect(state(s).blocked && state(s).blockCode == code)
        }
    }

    /// 侧栏卡片：用完、欠费、快到期标黄；试用和今天剩几次写数字
    @Test func cardContent() {
        let later = Date().addingTimeInterval(20 * 86_400)
        let trial = PlanCard.memberContent(.trial(left: 27, total: 30))
        #expect(trial.count?.contains("27") == true && !trial.warn)
        #expect(PlanCard.memberContent(.trialUsedUp).warn)
        #expect(PlanCard.memberContent(.trialClosed(daily: false)).warn)
        #expect(PlanCard.memberContent(.paymentFailed).warn)
        #expect(PlanCard.memberContent(.ended).warn)
        #expect(PlanCard.memberContent(.dailyLimit(reset: later)).warn)
        let member = PlanCard.memberContent(.member(until: later, autoRenew: true, expiring: false, pastDue: false, todayLeft: 188, limit: 200))
        #expect(!member.warn && member.count?.contains("188") == true)
        #expect(PlanCard.memberContent(.member(until: later, autoRenew: false, expiring: true, pastDue: false, todayLeft: 5, limit: 200)).warn)
        #expect(PlanCard.memberContent(.member(until: later, autoRenew: true, expiring: false, pastDue: true, todayLeft: 5, limit: 200)).warn)
    }
}

struct MemberErrorTests {
    @Test func readsCodeMessageAndReset() {
        let body = #"{"error":{"code":"daily-limit","message":"今天的 200 次用完了","resetAt":1793318400000}}"#
        let e = MemberError.from(status: 429, body: Data(body.utf8), headers: ["Retry-After": "120"])
        #expect(e.code == "daily-limit")
        #expect(e.message == "今天的 200 次用完了")
        #expect(e.status == 429)
        #expect(e.resetAt == Date(timeIntervalSince1970: 1_793_318_400))
        #expect(e.retryAfter == 120)
        #expect(e.changesStatus && !e.isRetryable)
        // 恢复时间按这台电脑的时区写出来
        #expect(MemberText.detail(e).contains(Date(timeIntervalSince1970: 1_793_318_400).formatted(date: .omitted, time: .shortened)))
        #expect(MemberError.from(status: 502, body: Data("<html>".utf8)).code == "http")
    }

    @Test func whatToRetry() {
        #expect(MemberError(code: "upstream", status: 503).isRetryable)
        #expect(MemberError(code: "rate", status: 429).isRetryable)
        #expect(MemberError(code: "http", status: 502).isRetryable)
        #expect(!MemberError(code: "busy", status: 503).isRetryable)
        #expect(!MemberError(code: "trial-used-up", status: 402).isRetryable)
        #expect(!MemberError(code: "use-limit", status: 429).isRetryable)
    }

    /// 每个错误码都有自己的话，不认识的才用后台原话；会员报错不说「Key 不对」
    @Test func everyCodeHasWords() {
        let codes = ["trial-used-up", "trial-closed", "sub-ended", "payment-failed", "daily-limit", "use-limit", "use-expired",
                     "busy", "upstream", "rate", "network", "unavailable", "bad-code", "too-many-devices", "already-subscribed",
                     "pass-active", "not-ready"]
        let generic = MemberText.title(MemberError(code: "zzz"))
        for code in codes {
            let e = MemberError(code: code, message: "后台原话")
            #expect(MemberText.title(e) != generic, "\(code)")
            #expect(!MemberText.detail(e).isEmpty && MemberText.detail(e) != "后台原话", "\(code)")
        }
        #expect(MemberText.detail(MemberError(code: "zzz", message: "后台原话")) == "后台原话")
        #expect(caseName(LookupFailure.from(ZhipuServiceError.member(MemberError(code: "trial-used-up")))) == "member")
        #expect(caseName(LookupFailure.from(MemberError.network)) == "member")
        #expect(!LookupFailure.member(MemberError(code: "trial-used-up")).autoDismiss)
    }

    @Test func prices() {
        #expect(MemberText.price(990, "cny") == "¥9.9")
        #expect(MemberText.price(9900, "cny") == "¥99")
        #expect(MemberText.price(199, "usd") == "$1.99")
        #expect(MemberText.price(1990, "usd") == "$19.90")
    }
}

struct MemberSetupTests {
    @Test func planDefaults() throws {
        let suite = "GetNewWordTests.plan.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        // 新装：默认会员
        AIPlan.settle(defaults: d) { true }
        #expect(d.string(forKey: AIPlan.key) == "member")
        // 以前走完引导、填过 Key 的：照旧自带 Key
        d.removeObject(forKey: AIPlan.key)
        d.set(true, forKey: "hasCompletedOnboarding")
        AIPlan.settle(defaults: d) { true }
        #expect(d.string(forKey: AIPlan.key) == "own")
        // 走完引导但没填 Key：会员
        d.removeObject(forKey: AIPlan.key)
        AIPlan.settle(defaults: d) { false }
        #expect(d.string(forKey: AIPlan.key) == "member")
        // 定过了就不再改
        AIPlan.settle(defaults: d) { true }
        #expect(d.string(forKey: AIPlan.key) == "member")
    }

    @Test func deviceFingerprint() {
        let fp = MemberDevice.fingerprint(hardwareUUID: "00000000-0000-4000-8000-000000000001")
        #expect(fp == "d34ba5e98abf2e2ded6584e8ae2e0a478afb45de665fb58178356675cea84389")
        let mine = MemberDevice.hardwareUUID()
        #expect(mine != nil)
        #expect(MemberDevice.fingerprint(hardwareUUID: mine ?? "") .count == 64)
    }

    @Test func apiBase() {
        #expect(MemberAPI.base(environment: [:], isDev: false)?.absoluteString == "https://api.us-cloud.uk")
        #expect(MemberAPI.base(environment: [:], isDev: true) == nil)
        #expect(MemberAPI.base(environment: ["GETNEWWORD_API": "http://127.0.0.1:8820/"], isDev: true)?.absoluteString == "http://127.0.0.1:8820")
    }

    /// 跑测试的进程（开发版）不连线上后台：没设 GETNEWWORD_API 时 shared 没有地址
    @MainActor @Test func testsDontTalkToProduction() {
        if ProcessInfo.processInfo.environment["GETNEWWORD_API"] == nil {
            #expect(MemberService.shared.api == nil)
            #expect(!ZhipuService.shared.memberAvailable)
        }
    }

    @Test func syncAccessReplies() {
        #expect(SyncAccess.from(status: 200, body: Data("true".utf8)) == .allowed)
        #expect(SyncAccess.from(status: 200, body: Data("false".utf8)) == .denied)
        // Supabase 上还没加 sync_allowed()：会员限制还没上线，照旧同步
        #expect(SyncAccess.from(status: 404, body: Data(#"{"code":"PGRST202"}"#.utf8)) == .allowed)
        #expect(SyncAccess.from(status: 500, body: Data()) == .unknown)
        #expect(SyncAccess.from(status: 401, body: Data()) == .unknown)
        #expect(SyncAccess.isRLSDenial(status: 403, body: Data()))
        #expect(SyncAccess.isRLSDenial(status: 401, body: Data(#"{"code":"42501","message":"new row violates row-level security policy"}"#.utf8)))
        #expect(!SyncAccess.isRLSDenial(status: 400, body: Data(#"{"code":"PGRST100"}"#.utf8)))
    }
}

// MARK: - 假的会员后台（MemberService 用）

/// 记下每个请求，按路径回话；回话可以按次序排好（同一个路径第 n 次回第 n 个）
final class FakeMemberServer: @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    private let lock = NSLock()
    private var queues: [String: [Reply]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ method: String, _ path: String, _ replies: Reply...) {
        lock.withLock { queues["\(method) \(path)", default: []] += replies }
    }

    var paths: [String] { lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } } }

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        let reply: Reply = lock.withLock {
            requests.append(request)
            guard var q = queues[key], !q.isEmpty else { return Reply(status: 404, body: #"{"error":{"code":"not-found","message":"假后台没配"}}"#) }
            let r = q.count > 1 ? q.removeFirst() : q[0]
            queues[key] = q
            return r
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(reply.body.utf8), http)
    }
}

private func registration(token: String = "gwd_one", trial: String = "granted", left: Int = 30) -> String {
    #"{"token":"\#(token)","trial":"\#(trial)","trialUses":{"granted":true,"total":30,"used":\#(30 - left),"left":\#(left)},"plan":"trial","canUse":true}"#
}
private func trialStatus(left: Int) -> String {
    #"{"plan":"\#(left > 0 ? "trial" : "none")","trial":{"granted":true,"total":30,"used":\#(30 - left),"left":\#(left)},"canUse":\#(left > 0),"reason":\#(left > 0 ? "null" : "\"trial-used-up\""),"prices":{"month":{"cny":990,"usd":199},"year":{"cny":9900,"usd":1990}}}"#
}
private let memberStatusBody = #"{"plan":"member","code":"GW-AAAA-BBBB-CCCC","trialOnly":false,"trial":{"granted":true,"total":30,"used":3,"left":27},"subscription":{"status":"active","plan":"month","currency":"cny","amount":990,"periodEnd":1795824000000,"cancelAtPeriodEnd":false,"accessUntil":1795910400000},"memberUntil":1795910400000,"autoRenew":true,"today":{"limit":200,"used":0,"left":200,"resetAt":1793318400000},"canUse":true}"#

@MainActor
@Suite(.serialized)
struct MemberServiceTests {
    let server = FakeMemberServer()
    let defaults: UserDefaults
    let suite = "GetNewWordTests.member.\(UUID().uuidString)"
    var opened: [URL] { openedBox.urls }
    let openedBox = OpenedURLs()

    final class OpenedURLs: @unchecked Sendable { var urls: [URL] = [] }

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    private func make(api: URL? = URL(string: "http://127.0.0.1:9"), token: String? = nil, member: Bool = true) -> MemberService {
        let server = server
        let box = openedBox
        let m = MemberService(api: api, defaults: defaults, tokens: .memory(token), device: { String(repeating: "ab", count: 32) },
                              openURL: { box.urls.append($0) }, send: { try server.handle($0) })
        m.memberMode = { member }
        m.pollInterval = .milliseconds(10)
        return m
    }

    @Test func firstRefreshRegistersThenAsksStatus() async throws {
        server.on("POST", "/v1/getnewword/device", .init(status: 200, body: registration()))
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: trialStatus(left: 30)))
        let m = make()
        await m.refresh()
        #expect(server.paths == ["POST /v1/getnewword/device", "GET /v1/getnewword/status"])
        let register = server.requests[0]
        #expect(register.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: register.httpBody ?? Data()) as? [String: String])
        #expect(body["device"] == String(repeating: "ab", count: 32))
        #expect(body["platform"] == "darwin")
        #expect(["arm64", "x64"].contains(body["arch"]))
        #expect(server.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer gwd_one")
        #expect(server.requests[1].timeoutInterval == 20)
        #expect(m.trialResult == "granted")
        #expect(m.state == .trial(left: 30, total: 30))

        // 60 秒内回到前台不再问；不节流的再问一次，不重新注册
        await m.refresh(maxAge: 60)
        #expect(server.requests.count == 2)
        await m.refresh()
        #expect(server.paths.last == "GET /v1/getnewword/status")
        #expect(server.paths.filter { $0.hasSuffix("/device") }.count == 1)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 上次的状态存着：重开应用先显示上次的（连哪个后台的存哪个后台的）
    @Test func remembersLastStatus() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: trialStatus(left: 12)))
        await make(token: "gwd_one").refresh()
        #expect(make(token: "gwd_one").status?.trial.left == 12)
        #expect(make(api: URL(string: "http://127.0.0.1:10"), token: "gwd_one").status == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 令牌失效（后台重置、换了电脑的备份）：重新注册一次再发，同一台拿回原来的账
    @Test func badDeviceRegistersAgain() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 401, body: #"{"error":{"code":"bad-device","message":"设备令牌无效"}}"#),
                  .init(status: 200, body: trialStatus(left: 20)))
        server.on("POST", "/v1/getnewword/device", .init(status: 200, body: registration(token: "gwd_two", trial: "existing", left: 20)))
        let m = make(token: "gwd_old")
        await m.refresh()
        #expect(server.paths == ["GET /v1/getnewword/status", "POST /v1/getnewword/device", "GET /v1/getnewword/status"])
        #expect(server.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer gwd_two")
        #expect(m.state == .trial(left: 20, total: 30))
        #expect(m.lastError == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 自带 Key、没注册过的：不去后台注册（不替没选会员的人占名额）；开发版没地址时什么都不发
    @Test func ownKeyAndDevBuildsStayQuiet() async throws {
        await make(member: false).refresh()
        #expect(server.requests.isEmpty)
        let dev = make(api: nil)
        await dev.refresh()
        #expect(server.requests.isEmpty)
        #expect(dev.state == .unavailable)
        await #expect(throws: MemberError.unavailable) { _ = try await dev.credentials() }
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func offlineKeepsOldStatus() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: trialStatus(left: 9)))
        let m = make(token: "gwd_one")
        await m.refresh()
        let failing = MemberService(api: URL(string: "http://127.0.0.1:9"), defaults: defaults, tokens: .memory("gwd_one"),
                                    send: { _ in throw URLError(.notConnectedToInternet) })
        failing.memberMode = { true }
        await failing.refresh()
        #expect(failing.lastError == .network)
        #expect(failing.state == .trial(left: 9, total: 30))
        defaults.removePersistentDomain(forName: suite)
    }

    /// 结账：浏览器打开付款页，每隔一会儿问一次，付完马上是会员
    @Test func buyPollsUntilPaid() async throws {
        server.on("POST", "/v1/getnewword/checkout", .init(status: 200, body: #"{"url":"https://checkout.stripe.test/cs_1","claim":"gwc_1"}"#))
        server.on("GET", "/v1/getnewword/checkout/gwc_1", .init(status: 200, body: #"{"status":"pending"}"#),
                  .init(status: 200, body: #"{"status":"pending"}"#),
                  .init(status: 200, body: #"{"status":"paid",\#(memberStatusBody.dropFirst())"#))
        let m = make(token: "gwd_one")
        try await m.buy(plan: "year", currency: "usd", mode: "sub")
        #expect(opened == [URL(string: "https://checkout.stripe.test/cs_1")!])
        #expect(m.purchase?.claim == "gwc_1")
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests[0].httpBody ?? Data()) as? [String: String])
        #expect(body == ["plan": "year", "currency": "usd", "mode": "sub"])
        for _ in 0..<200 where m.purchase != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.purchase == nil)
        #expect(m.justPaid)
        #expect(m.isMember)
        #expect(m.status?.code == "GW-AAAA-BBBB-CCCC")
        #expect(server.paths.filter { $0.hasSuffix("/checkout/gwc_1") }.count == 3)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func buyExpiredStops() async throws {
        server.on("POST", "/v1/getnewword/checkout", .init(status: 200, body: #"{"url":"https://checkout.stripe.test/cs_2","claim":"gwc_2"}"#))
        server.on("GET", "/v1/getnewword/checkout/gwc_2", .init(status: 200, body: #"{"status":"expired"}"#))
        let m = make(token: "gwd_one")
        try await m.buy(plan: "month", currency: "cny", mode: "pass")
        for _ in 0..<200 where m.purchase != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.purchase == nil && !m.justPaid)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 已经在自动续费：后台回 409，原样报出来让会员页给「管理订阅」
    @Test func buyAlreadySubscribed() async throws {
        server.on("POST", "/v1/getnewword/checkout", .init(status: 409, body: #"{"error":{"code":"already-subscribed","message":"已经是会员了"}}"#))
        let m = make(token: "gwd_one")
        await #expect(throws: MemberError(code: "already-subscribed", message: "已经是会员了", status: 409)) {
            try await m.buy(plan: "month", currency: "cny", mode: "sub")
        }
        #expect(opened.isEmpty && m.purchase == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func portalOpensBrowser() async throws {
        server.on("POST", "/v1/getnewword/portal", .init(status: 200, body: #"{"url":"https://billing.stripe.test/p/1"}"#))
        let m = make(token: "gwd_one")
        try await m.openPortal()
        #expect(opened == [URL(string: "https://billing.stripe.test/p/1")!])
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func activateAndUnbind() async throws {
        server.on("POST", "/v1/getnewword/license/activate", .init(status: 404, body: #"{"error":{"code":"bad-code","message":"不是 GetNewWord 的授权码"}}"#),
                  .init(status: 200, body: memberStatusBody))
        server.on("POST", "/v1/getnewword/license/unbind", .init(status: 200, body: trialStatus(left: 27)))
        let m = make(token: "gwd_one")
        await #expect(throws: MemberError.self) { try await m.activate(code: "AF-1234-5678-ABCD") }
        try await m.activate(code: "gw-aaaa-bbbb-cccc")
        #expect(m.isMember)
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests[1].httpBody ?? Data()) as? [String: String])
        #expect(body["code"] == "gw-aaaa-bbbb-cccc")
        try await m.unbind()
        #expect(m.state == .trial(left: 27, total: 30))
        defaults.removePersistentDomain(forName: suite)
    }

    /// 查词的返回头带剩余次数：侧栏马上跟着变；用到 0 就是用完了
    @Test func usageHeadersUpdateCounts() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: trialStatus(left: 2)))
        let m = make(token: "gwd_one")
        await m.refresh()
        await m.noteResponse(headers: ["x-uses-kind": "trial", "X-Uses-Left": "1", "X-Use-Charged": "1"], error: nil)
        #expect(m.state == .trial(left: 1, total: 30))
        await m.noteResponse(headers: ["X-Uses-Kind": "trial", "X-Uses-Left": "0"], error: nil)
        #expect(m.state == .trialUsedUp)
        #expect(m.state.blockCode == "trial-used-up")
        // 后台说试用用完了：查一次状态对齐
        let before = server.requests.count
        await m.noteResponse(headers: [:], error: MemberError(code: "trial-used-up", status: 402))
        #expect(server.requests.count == before + 1)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func useAliases() async {
        let m = make(token: "gwd_one")
        let run = UUID()
        #expect(await m.useID(for: run) == run)
        let fresh = await m.renewUse(for: run)
        #expect(fresh != run)
        #expect(await m.useID(for: run) == fresh)
        defaults.removePersistentDomain(forName: suite)
    }
}

// MARK: - 会员模式下的查词请求（ZhipuService）

/// 假的会员后台的 chat 接口：记下请求头和请求体，按次序回话
final class FakeMemberChat: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: String; var headers: [String: String] = [:] }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var seen: [(headers: [String: String], body: [String: Any])] = []
    static let lock = NSLock()

    static let ok = Reply(status: 200, body: #"{"id":"t","choices":[{"index":0,"message":{"role":"assistant","content":"{\"words\":[{\"word\":\"Nachhaltigkeit\",\"language\":\"de\",\"meaning\":\"n. 可持续性\",\"contextSentence\":\"s\",\"contextTranslation\":\"t\",\"difficulty\":\"b2\",\"tags\":[]}],\"snippets\":[]}"},"finish_reason":"stop"}]}"#,
                          headers: ["X-Use-Charged": "1", "X-Uses-Kind": "trial", "X-Uses-Left": "26"])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
        }
        let reply: Reply = Self.lock.withLock {
            Self.seen.append((request.allHTTPHeaderFields ?? [:], (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]))
            return Self.replies.isEmpty ? Self.ok : Self.replies.removeFirst()
        }
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeMemberChat.self]
        return URLSession(configuration: config)
    }()
}

/// 假的 MemberRoute：固定令牌，记下换号、换令牌、回来的返回头
final class FakeRoute: MemberRoute, @unchecked Sendable {
    private let lock = NSLock()
    var token = "gwd_one"
    var aliases: [UUID: UUID] = [:]
    var renewedUses = 0
    var renewedTokens = 0
    var notes: [(headers: [String: String], error: MemberError?)] = []

    func credentials() async throws -> MemberCredentials {
        lock.withLock { MemberCredentials(chatURL: URL(string: "http://127.0.0.1:9/v1/getnewword/chat/completions")!, token: token) }
    }
    func renewToken(_ used: String) async -> Bool {
        lock.withLock { renewedTokens += 1; token = "gwd_two"; return true }
    }
    func useID(for run: UUID) async -> UUID { lock.withLock { aliases[run] ?? run } }
    func renewUse(for run: UUID) async -> UUID {
        lock.withLock { renewedUses += 1; let u = UUID(); aliases[run] = u; return u }
    }
    func noteResponse(headers: [String: String], error: MemberError?) async {
        lock.withLock { notes.append((headers, error)) }
    }
}

@Suite(.serialized)
final class MemberChatTests {
    let service = ZhipuService()
    let route = FakeRoute()
    let lookup = TextLookup(target: "Nachhaltigkeit", context: "Die Nachhaltigkeit der Lieferketten hat zugenommen.", language: "de", isWord: true, scene: .hover)

    init() {
        FakeMemberChat.replies = []
        FakeMemberChat.seen = []
        service.session = FakeMemberChat.session
        service.memberMode = { true }
        service.memberOverride = route
        service.memberAvailable = true
    }

    private func useIDs() -> [String] { FakeMemberChat.seen.map { $0.headers["X-Use-Id"] ?? "" } }

    /// 发到后台、带设备令牌和这次查词的用量号；模型和思考由后台定，不发；要 JSON
    @Test func requestGoesToOurServer() async throws {
        #expect(service.isConfigured)
        let run = UUID()
        let result = try await service.analyzeText(lookup, useID: run)
        #expect(result.words.first?.word == "Nachhaltigkeit")
        let sent = try #require(FakeMemberChat.seen.first)
        #expect(sent.headers["Authorization"] == "Bearer gwd_one")
        #expect(sent.headers["X-Use-Id"] == run.uuidString.lowercased())
        #expect(sent.body["model"] as? String == "deepseek-flash")
        #expect(sent.body["thinking"] == nil)
        #expect(sent.body["reasoning_effort"] == nil)
        #expect((sent.body["response_format"] as? [String: String])?["type"] == "json_object")
        #expect((sent.body["max_tokens"] as? Int ?? 0) <= 8192)
        // 返回头交给会员服务记剩余次数
        #expect(route.notes.last?.headers["X-Uses-Left"] == "26")
        #expect(route.notes.last?.error == nil)
    }

    /// 一次查词的几个请求（主分析、补全）用同一个号
    @Test func oneLookupOneUseID() async throws {
        let run = UUID()
        _ = try await service.analyzeText(lookup, useID: run)
        FakeMemberChat.replies = [.init(status: 200, body: #"{"id":"e","choices":[{"index":0,"message":{"role":"assistant","content":"{\"usage\":\"u\"}"},"finish_reason":"stop"}]}"#)]
        _ = try await service.enrichWord(word: "Nachhaltigkeit", language: "de", useID: run)
        #expect(Set(useIDs()) == [run.uuidString.lowercased()])
        #expect(useIDs().count == 2)
    }

    /// 用量号过了窗口：换一个新号再发一次，这次查词以后都用新号
    @Test func expiredUseIDGetsNewOne() async throws {
        let run = UUID()
        FakeMemberChat.replies = [.init(status: 409, body: #"{"error":{"code":"use-expired","message":"过了重试的时间"}}"#), FakeMemberChat.ok]
        _ = try await service.analyzeText(lookup, useID: run)
        let ids = useIDs()
        #expect(ids.count == 2 && ids[0] == run.uuidString.lowercased() && ids[1] != ids[0])
        #expect(route.renewedUses == 1)
    }

    /// 试用用完：不重试，直接报会员的错，并让会员状态跟着更新；面板上是会员的说法
    @Test func trialUsedUpIsReported() async throws {
        FakeMemberChat.replies = [.init(status: 402, body: #"{"error":{"code":"trial-used-up","message":"30 次查词的免费试用用完了"}}"#)]
        do {
            _ = try await service.analyzeText(lookup, useID: UUID())
            Issue.record("应该报错")
        } catch ZhipuServiceError.member(let e) {
            #expect(e.code == "trial-used-up" && e.status == 402)
        }
        #expect(FakeMemberChat.seen.count == 1)
        #expect(route.notes.last?.error?.code == "trial-used-up")
    }

    @Test func dailyLimitCarriesResetTime() async throws {
        FakeMemberChat.replies = [.init(status: 429, body: #"{"error":{"code":"daily-limit","message":"今天的 200 次用完了","resetAt":1793318400000}}"#, headers: ["Retry-After": "3600"])]
        do {
            _ = try await service.analyzeText(lookup, useID: UUID())
            Issue.record("应该报错")
        } catch ZhipuServiceError.member(let e) {
            #expect(e.code == "daily-limit" && e.resetAt == Date(timeIntervalSince1970: 1_793_318_400))
        }
        #expect(FakeMemberChat.seen.count == 1)
    }

    /// 上游暂时不可用：同一个号重试（后台只算一次），好了就用好的那次
    @Test func upstreamRetriesWithSameUseID() async throws {
        let run = UUID()
        FakeMemberChat.replies = [.init(status: 503, body: #"{"error":{"code":"upstream","message":"会员 AI 服务暂时不可用"}}"#, headers: ["Retry-After": "0"]), FakeMemberChat.ok]
        _ = try await service.analyzeText(lookup, useID: run)
        #expect(useIDs() == [run.uuidString.lowercased(), run.uuidString.lowercased()])
    }

    /// 令牌被拒：重新注册拿新令牌，再发一次
    @Test func badDeviceRenewsToken() async throws {
        FakeMemberChat.replies = [.init(status: 401, body: #"{"error":{"code":"bad-device","message":"设备令牌无效"}}"#), FakeMemberChat.ok]
        _ = try await service.analyzeText(lookup, useID: UUID())
        #expect(FakeMemberChat.seen.map { $0.headers["Authorization"] ?? "" } == ["Bearer gwd_one", "Bearer gwd_two"])
        #expect(route.renewedTokens == 1)
    }

    /// 语法拆解（流式）也走会员通道、带同一个号
    @Test func grammarStreamUsesMemberRoute() async throws {
        let run = UUID()
        FakeMemberChat.replies = [.init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"## 主干\"}}]}\n\ndata: [DONE]\n\n")]
        final class Pieces: @unchecked Sendable { var text = "" }
        let pieces = Pieces()
        try await service.streamGrammarBreakdown(sentence: "Die Studie zeigt …", word: "zeigt", language: "de", useID: run) { pieces.text += $0 }
        #expect(pieces.text == "## 主干")
        let sent = try #require(FakeMemberChat.seen.first)
        #expect(sent.headers["X-Use-Id"] == run.uuidString.lowercased())
        #expect(sent.body["stream"] as? Bool == true)
        #expect(sent.body["response_format"] == nil)
    }
}
