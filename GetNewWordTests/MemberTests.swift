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

    /// 后台 2026-10-29 加的 trialResult、limitBy、resetAt：读得到；旧后台没有也照样读
    @Test func decodesLimitFields() throws {
        let s = try status(#"{"plan":"trial","trial":{"granted":false,"total":0,"used":0,"left":0},"canUse":false,"reason":"daily-limit","limitBy":"cost","resetAt":1793318400000,"trialResult":"ip-limit"}"#)
        #expect(s.limitBy == "cost" && s.resetAt == 1_793_318_400_000 && s.trialResult == "ip-limit")
        let old = try status(statusJSON)
        #expect(old.limitBy == nil && old.resetAt == nil && old.trialResult == nil)
    }

    /// 状态里的 trialResult 比本机记的准（本机的可能是重新注册后的 existing）；成本上限过了重置时刻就不算
    @Test func statesUseServerTrialResultAndCostCap() {
        var s = makeStatus(plan: "none", granted: false, reason: "trial-closed")
        s.trialResult = "closed"
        #expect(MemberState.of(s, available: true, failed: false, trialResult: "existing") == .trialClosed(.full))
        var c = makeStatus(plan: "trial", left: 10)
        c.reason = "daily-limit"
        c.canUse = false
        c.limitBy = "cost"
        c.resetAt = Date().addingTimeInterval(600).timeIntervalSince1970 * 1000
        #expect(MemberState.of(c, available: true, failed: false, trialResult: nil).blockCode == "daily-limit")
        c.resetAt = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000
        #expect(MemberState.of(c, available: true, failed: false, trialResult: nil) == .trial(left: 10, total: 30))
    }

    @Test func newErrorCodesHaveTitles() {
        #expect(MemberText.title(MemberError(code: "re-register-limit", message: "这台电脑 24 小时里重新注册超过 5 次了，约 3 小时后再试")) == String(localized: "这台 Mac 重新注册太多次了"))
        #expect(MemberText.detail(MemberError(code: "re-register-limit", message: "这台电脑 24 小时里重新注册超过 5 次了，约 3 小时后再试")).contains("约 3 小时"))
        #expect(MemberText.title(MemberError(code: "payment-pending", message: "x")) == String(localized: "上一笔付款还在确认"))
    }

    @Test func states() {
        let later = Date().addingTimeInterval(20 * 86_400)
        func state(_ s: MemberStatus?, trialResult: String? = nil, available: Bool = true, failed: Bool = false, registered: Bool = true) -> MemberState {
            MemberState.of(s, available: available, failed: failed, trialResult: trialResult, registered: registered)
        }
        #expect(state(nil, available: false) == .unavailable)
        #expect(state(nil) == .connecting)
        #expect(state(nil, failed: true) == .offline)
        // 还没注册：第一次查词时领，连不上过也一样（到时候再领）
        #expect(state(nil, registered: false) == .notClaimed)
        #expect(state(nil, failed: true, registered: false) == .notClaimed)
        #expect(MemberState.notClaimed.ready && !MemberState.notClaimed.blocked)
        #expect(state(makeStatus(plan: "trial", left: 27)) == .trial(left: 27, total: 30))
        #expect(state(makeStatus(plan: "none", reason: "trial-used-up")) == .trialUsedUp)
        // 没领到试用：名额发完、注册那天同网络 / 全站当天满了、说不准（重新注册过）各说各的
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "closed") == .trialClosed(.full))
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "ip-limit") == .trialClosed(.busy))
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "daily-limit") == .trialClosed(.busy))
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed")) == .trialClosed(.unknown))
        #expect(state(makeStatus(plan: "none", granted: false, reason: "trial-closed"), trialResult: "existing") == .trialClosed(.unknown))
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

    /// 自动续费的写下次扣款日（当期结束），不是带 1 天宽限的会员到期
    @Test func autoRenewShowsPeriodEnd() {
        let periodEnd = Date().addingTimeInterval(30 * 86_400)
        var s = makeStatus(plan: "member", until: periodEnd.addingTimeInterval(86_400), autoRenew: true, todayLeft: 200, subscription: "active")
        s.subscription?.periodEnd = periodEnd.timeIntervalSince1970 * 1000
        guard case .member(let until, _, _, _, _, _) = MemberState.of(s, available: true, failed: false, trialResult: nil) else {
            Issue.record("应为会员")
            return
        }
        #expect(abs((until ?? .distantPast).timeIntervalSince(periodEnd)) < 1)
        // 不自动续费（一次买、点了到期取消）写用到哪天
        s.autoRenew = false
        guard case .member(let until2, _, _, _, _, _) = MemberState.of(s, available: true, failed: false, trialResult: nil) else { return }
        #expect(abs((until2 ?? .distantPast).timeIntervalSince(periodEnd.addingTimeInterval(86_400))) < 1)
    }

    /// 侧栏卡片：用完、欠费、快到期标黄；试用和今天剩几次写数字
    @Test func cardContent() {
        let later = Date().addingTimeInterval(20 * 86_400)
        let trial = PlanCard.memberContent(.trial(left: 27, total: 30))
        #expect(trial.count?.contains("27") == true && !trial.warn)
        #expect(PlanCard.memberContent(.trialUsedUp).warn)
        #expect(PlanCard.memberContent(.trialClosed(.full)).warn)
        #expect(PlanCard.memberContent(.trialClosed(.busy)).detail != PlanCard.memberContent(.trialClosed(.full)).detail)
        #expect(!PlanCard.memberContent(.notClaimed).warn && PlanCard.memberContent(.notClaimed).count == nil)
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
                     "not-ready", "portal-not-ready", "portal-upstream", "pay-upstream"]
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

    /// DeepSeek 回 400（内容审核没过之类）：后台转来的是上游原文，只留里面那句；内容审核换成白话
    @Test func upstreamRejectionIsReadable() {
        let raw = #"{"error":{"code":"bad-request","message":"{\"error\":{\"message\":\"Content Exists Risk\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"invalid_request_error\"}}"}}"#
        let e = MemberError.from(status: 400, body: Data(raw.utf8))
        #expect(e.code == "bad-request" && e.message == "Content Exists Risk")
        #expect(e.isContentRisk)
        #expect(!MemberText.detail(e).contains("{") && !MemberText.detail(e).contains("Risk"))
        #expect(MemberText.title(e) != MemberText.title(MemberError(code: "bad-request")))
        let other = MemberError.from(status: 400, body: Data(#"{"error":{"code":"bad-request","message":"{\"error\":{\"message\":\"Invalid max_tokens value\"}}"}}"#.utf8))
        #expect(MemberText.detail(other) == "Invalid max_tokens value")
        #expect(MemberError.from(status: 400, body: Data(#"{"error":{"code":"bad-json","message":"请求体不是 JSON"}}"#.utf8)).message == "请求体不是 JSON")
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

/// 会员的状态：今天剩几次、什么原因、几点重置；sync 是同步绑定（nil = 后台没开同步资格）
private func memberBody(todayLeft: Int = 200, reason: String? = nil, resetAt: Date = Date().addingTimeInterval(3600), sync: String? = nil) -> String {
    let reset = Int(resetAt.timeIntervalSince1970 * 1000)
    return #"{"plan":"member","code":"GW-AAAA-BBBB-CCCC","trialOnly":false,"trial":{"granted":true,"total":30,"used":3,"left":27},"subscription":{"status":"active","plan":"month","currency":"cny","amount":990,"periodEnd":1795824000000,"cancelAtPeriodEnd":false,"accessUntil":1795910400000},"memberUntil":1795910400000,"autoRenew":true,"today":{"limit":200,"used":\#(200 - todayLeft),"left":\#(todayLeft),"resetAt":\#(reset)},"canUse":\#(reason == nil),"reason":\#(reason.map { "\"\($0)\"" } ?? "null"),"sync":\#(sync ?? "null")}"#
}

private let sessionB = SupabaseSession(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, userId: "user-b", email: "b@example.com")

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

    /// 没注册过的：查状态、启动、回到前台都不注册（不替还没用会员的人占名额）；领试用时才注册一次
    @Test func registersOnlyWhenClaimed() async throws {
        server.on("POST", "/v1/getnewword/device", .init(status: 200, body: registration()))
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: trialStatus(left: 30)))
        let m = make()
        m.start()
        await m.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.requests.isEmpty)
        #expect(m.state == .notClaimed && !m.registered)

        await m.claimTrial()
        #expect(server.paths == ["POST /v1/getnewword/device"])
        let register = server.requests[0]
        #expect(register.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: register.httpBody ?? Data()) as? [String: String])
        #expect(body["device"] == String(repeating: "ab", count: 32))
        #expect(body["platform"] == "darwin")
        #expect(["arm64", "x64"].contains(body["arch"]))
        #expect(m.registered && m.trialResult == "granted")
        #expect(m.state == .trial(left: 30, total: 30))

        // 注册过以后：查状态带令牌，不再注册；60 秒内回到前台不再问
        await m.refresh()
        #expect(server.paths.last == "GET /v1/getnewword/status")
        #expect(server.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer gwd_one")
        #expect(server.requests[1].timeoutInterval == 20)
        await m.refresh(maxAge: 60)
        #expect(server.requests.count == 2)
        await m.claimTrial()
        #expect(server.paths.filter { $0.hasSuffix("/device") }.count == 1)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 第一次用会员查词时注册（查词要令牌）
    @Test func firstLookupRegisters() async throws {
        server.on("POST", "/v1/getnewword/device", .init(status: 200, body: registration(token: "gwd_new")))
        let m = make()
        let c = try await m.credentials()
        #expect(c.token == "gwd_new")
        #expect(server.paths == ["POST /v1/getnewword/device"])
        defaults.removePersistentDomain(forName: suite)
    }

    /// 自带 Key 但注册过的（以前用过会员）：启动时不查；会员用法、注册过的启动时查一次
    @Test func startOnlyAsksForMembers() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: trialStatus(left: 5)))
        make(token: "gwd_one", member: false).start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.requests.isEmpty)
        let m = make(token: "gwd_one")
        m.start()
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.paths == ["GET /v1/getnewword/status"])
        defaults.removePersistentDomain(forName: suite)
    }

    /// 没领到试用时，原因按第一次注册的结果说；令牌丢了重新注册（后台回 existing）也不忘
    @Test func trialMissSurvivesReRegistering() async throws {
        server.on("POST", "/v1/getnewword/device",
                  .init(status: 200, body: #"{"token":"gwd_one","trial":"ip-limit","trialUses":{"granted":false,"total":0,"used":0,"left":0},"plan":"none","canUse":false,"reason":"trial-closed"}"#),
                  .init(status: 200, body: #"{"token":"gwd_two","trial":"existing","trialUses":{"granted":false,"total":0,"used":0,"left":0},"plan":"none","canUse":false,"reason":"trial-closed"}"#))
        let m = make()
        await m.claimTrial()
        #expect(m.state == .trialClosed(.busy))
        #expect(await m.renewToken("gwd_one"))
        #expect(m.trialResult == "ip-limit")
        #expect(m.state == .trialClosed(.busy))
        let e = m.explain(MemberError(code: "trial-closed", message: "免费试用名额已经发完了。", status: 402))
        #expect(e.miss == .busy)
        #expect(MemberText.detail(e) != MemberText.detail(MemberError(code: "trial-closed", miss: .full)))
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
        let own = make(member: false)
        own.start()
        await own.refresh()
        try await Task.sleep(for: .milliseconds(50))
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

    /// 上一个付款页其实付好了（后台回 409 already-paid）：问一次状态，是会员就当付款成功，不报错、不开新页
    @Test func buyAlreadyPaidCountsAsPaid() async throws {
        server.on("POST", "/v1/getnewword/checkout", .init(status: 409, body: #"{"error":{"code":"already-paid","message":"上一个付款页已经付好了，会员已经开通，不用再付"}}"#))
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: memberStatusBody))
        let m = make(token: "gwd_one")
        try await m.buy(plan: "year", currency: "cny", mode: "sub")
        #expect(m.justPaid && m.isMember)
        #expect(opened.isEmpty && m.purchase == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 后台 /status 带了 trialResult：按后台记的原因说，本机没记下（比如钥匙串清过、重装）也说得出
    @Test func serverTrialResultExplainsMiss() async throws {
        server.on("GET", "/v1/getnewword/status",
                  .init(status: 200, body: #"{"plan":"none","trial":{"granted":false,"total":0,"used":0,"left":0},"canUse":false,"reason":"trial-closed","trialResult":"closed"}"#))
        let m = make(token: "gwd_one")
        await m.refresh()
        #expect(m.trialResult == nil)
        #expect(m.state == .trialClosed(.full))
        #expect(m.explain(MemberError(code: "trial-closed", status: 402)).miss == .full)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 成本上限进了 /status（limitBy cost）：试用的也拦，说成「今天的用量到上限了」；次数用完的说成次数用完
    @Test func costCapFromStatus() async throws {
        let reset = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        server.on("GET", "/v1/getnewword/status",
                  .init(status: 200, body: #"{"plan":"trial","trial":{"granted":true,"total":30,"used":5,"left":25},"canUse":false,"reason":"daily-limit","limitBy":"cost","resetAt":\#(reset)}"#))
        let m = make(token: "gwd_one")
        await m.refresh()
        guard case .dailyLimit(let at) = m.state else { Issue.record("试用的成本上限也要拦：\(m.state)"); return }
        #expect(at.map { Int($0.timeIntervalSince1970 * 1000) } == reset)
        #expect(m.state.blocked && m.state.blockCode == "daily-limit")
        let e = m.explain(MemberError(code: "daily-limit", status: 429))
        #expect(e.costCap)
        #expect(MemberText.title(e) == String(localized: "今天的用量到上限了"))
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func usesLimitIsNotCostCap() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: memberBody(todayLeft: 0, reason: "daily-limit")
            .replacingOccurrences(of: #""reason":"daily-limit""#, with: #""reason":"daily-limit","limitBy":"uses""#)))
        let m = make(token: "gwd_one")
        await m.refresh()
        let e = m.explain(MemberError(code: "daily-limit", status: 429))
        #expect(!e.costCap)
        #expect(MemberText.title(e) == String(localized: "今天的次数用完了"))
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

    /// 「不等了」以后再点同一个方案：1 小时内重新打开同一个付款页、接着等，不另开一单（免得两个都付了扣两份）
    @Test func cancelledCheckoutIsReopened() async throws {
        server.on("POST", "/v1/getnewword/checkout", .init(status: 200, body: #"{"url":"https://checkout.stripe.test/cs_3","claim":"gwc_3"}"#),
                  .init(status: 200, body: #"{"url":"https://checkout.stripe.test/cs_4","claim":"gwc_4"}"#))
        server.on("GET", "/v1/getnewword/checkout/gwc_3", .init(status: 200, body: #"{"status":"pending"}"#))
        let m = make(token: "gwd_one")
        m.pollInterval = .seconds(60)   // 这个测试不等轮询
        let cs3 = URL(string: "https://checkout.stripe.test/cs_3")!
        try await m.buy(plan: "month", currency: "cny", mode: "sub")
        m.cancelPurchase()
        #expect(m.purchase == nil)
        try await m.buy(plan: "month", currency: "cny", mode: "sub")
        #expect(server.paths.filter { $0 == "POST /v1/getnewword/checkout" }.count == 1)
        #expect(server.paths.contains("GET /v1/getnewword/checkout/gwc_3"))
        #expect(opened == [cs3, cs3])
        #expect(m.purchase?.claim == "gwc_3")
        // 换成年付是另一单
        m.cancelPurchase()
        try await m.buy(plan: "year", currency: "cny", mode: "sub")
        #expect(server.paths.filter { $0 == "POST /v1/getnewword/checkout" }.count == 2)
        #expect(opened.last == URL(string: "https://checkout.stripe.test/cs_4")!)
        m.cancelPurchase()
        defaults.removePersistentDomain(forName: suite)
    }

    /// 「不等了」以后在浏览器里付了：再点同一个方案时先问一次那单，付了就直接是会员，不再开付款页；过期了就另开一单
    @Test func reopenChecksTheOldCheckoutFirst() async throws {
        server.on("POST", "/v1/getnewword/checkout", .init(status: 200, body: #"{"url":"https://checkout.stripe.test/cs_5","claim":"gwc_5"}"#),
                  .init(status: 200, body: #"{"url":"https://checkout.stripe.test/cs_6","claim":"gwc_6"}"#))
        server.on("GET", "/v1/getnewword/checkout/gwc_5", .init(status: 200, body: #"{"status":"paid",\#(memberStatusBody.dropFirst())"#))
        server.on("GET", "/v1/getnewword/checkout/gwc_6", .init(status: 200, body: #"{"status":"expired"}"#))
        let m = make(token: "gwd_one")
        m.pollInterval = .seconds(60)
        try await m.buy(plan: "year", currency: "usd", mode: "sub")
        m.cancelPurchase()
        try await m.buy(plan: "year", currency: "usd", mode: "sub")
        #expect(opened.count == 1)
        #expect(m.justPaid && m.isMember && m.purchase == nil)

        try await m.buy(plan: "month", currency: "cny", mode: "pass")
        m.cancelPurchase()
        try await m.buy(plan: "month", currency: "cny", mode: "pass")   // cs_6 过期了：另开一单（假后台第二次还回 cs_6）
        #expect(server.paths.filter { $0 == "POST /v1/getnewword/checkout" }.count == 3)
        m.cancelPurchase()
        defaults.removePersistentDomain(forName: suite)
    }

    /// 门户、付款页打不开说的是付款服务，不是「购买还没开通」「会员 AI 连不上」
    @Test func portalAndCheckoutErrorsSayWhatBroke() async throws {
        server.on("POST", "/v1/getnewword/portal", .init(status: 503, body: #"{"error":{"code":"not-ready","message":"门户还没配好"}}"#))
        server.on("POST", "/v1/getnewword/checkout", .init(status: 503, body: #"{"error":{"code":"upstream","message":"付款服务暂时连不上，稍后再试"}}"#))
        let m = make(token: "gwd_one")
        await #expect(throws: MemberError(code: "portal-not-ready", message: "门户还没配好", status: 503)) { try await m.openPortal() }
        await #expect(throws: MemberError(code: "pay-upstream", message: "付款服务暂时连不上，稍后再试", status: 503)) {
            try await m.buy(plan: "month", currency: "cny", mode: "sub")
        }
        #expect(MemberText.title(MemberError(code: "portal-not-ready")) != MemberText.title(MemberError(code: "not-ready")))
        #expect(MemberText.title(MemberError(code: "pay-upstream")) != MemberText.title(MemberError(code: "upstream")))
        #expect(opened.isEmpty && m.purchase == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 报错前补上原因：成本上限（次数还有）不说成次数用完；一次买还没到期写到期日
    @Test func explainFillsTheRealReason() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: memberBody(todayLeft: 150)))
        let m = make(token: "gwd_one")
        await m.refresh()
        let reset = Date().addingTimeInterval(3600)
        let cap = m.explain(MemberError(code: "daily-limit", message: "今天的用量到上限了，北京时间早上 8 点重置", status: 429, resetAt: reset))
        #expect(cap.costCap)
        #expect(MemberText.title(cap) != MemberText.title(MemberError(code: "daily-limit")))
        #expect(MemberText.detail(cap).contains(reset.formatted(date: .omitted, time: .shortened)))
        let until = Date(timeIntervalSince1970: 1_795_910_400)
        let pass = m.explain(MemberError(code: "pass-active", message: "一次买的会员用到2026年11月28日（北京时间）", status: 409))
        #expect(pass.until == until)
        #expect(MemberText.detail(pass).contains(MemberText.day(until)))
        // 没有到期日时用后台原话（写了到期日）
        #expect(MemberText.detail(MemberError(code: "pass-active", message: "一次买的会员用到2026年11月28日")) == "一次买的会员用到2026年11月28日")
        // 今天真的用完了（剩 0）：是次数用完
        await m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "0"], error: nil)
        #expect(!m.explain(MemberError(code: "daily-limit", status: 429)).costCap)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 昨天用满了、今天第一次查词成功：「用完了」清掉，侧栏不再说用完；用到 0 才记用完
    @Test func newDayClearsDailyLimit() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: memberBody(todayLeft: 0, reason: "daily-limit", resetAt: Date().addingTimeInterval(-60))))
        let m = make(token: "gwd_one")
        await m.refresh()
        let tonight = Date().addingTimeInterval(20 * 3600)
        let tonightMs = String(Int(tonight.timeIntervalSince1970 * 1000))
        await m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "199", "X-Uses-Reset": tonightMs], error: nil)
        guard case .member(_, _, _, _, let left, _) = m.state else {
            Issue.record("应为会员：\(m.state)")
            return
        }
        #expect(left == 199)
        #expect(m.status?.reason == nil && m.status?.canUse == true)
        await m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "0", "X-Uses-Reset": tonightMs], error: nil)
        guard case .dailyLimit(let reset) = m.state else {
            Issue.record("应为今天用完：\(m.state)")
            return
        }
        #expect(abs((reset ?? .distantPast).timeIntervalSince(tonight)) < 1)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 同步绑定：绑了别的账号不自动换（两台 Mac 同一个授权码、登不同 Google 账号时不来回抢），点了「换成这个账号」才换
    @Test func linkedElsewhereNeedsAClick() async throws {
        server.on("GET", "/v1/getnewword/status",
                  .init(status: 200, body: memberBody(sync: #"{"allowed":true,"linked":true,"email":"a@example.com","until":1795910400000}"#)))
        server.on("POST", "/v1/getnewword/sync/link", .init(status: 200, body: #"{"sync":{"allowed":true,"linked":true,"email":"b@example.com","until":1795910400000}}"#))
        let m = make(token: "gwd_one")
        m.syncSession = { sessionB }
        m.supabaseToken = { "sb-token-b" }
        await m.refresh()
        await m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "150"], error: nil)   // 每次查词后状态都会更新
        try await Task.sleep(for: .milliseconds(50))
        await m.linkSync()   // 登录后的那一次也不换
        #expect(!server.paths.contains("POST /v1/getnewword/sync/link"))
        await m.linkSync(replacing: true)
        #expect(server.paths.filter { $0.hasSuffix("/sync/link") }.count == 1)
        let body = try #require(try JSONSerialization.jsonObject(with: server.requests.last?.httpBody ?? Data()) as? [String: String])
        #expect(body["supabaseToken"] == "sb-token-b")
        #expect(m.status?.sync?.email == "b@example.com")
        // 绑的就是这个账号：再绑一次只是请后台再推（不算换绑）
        await m.linkSync()
        #expect(server.paths.filter { $0.hasSuffix("/sync/link") }.count == 2)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 没绑过的会员自动绑一次；失败了记下原因，10 分钟内不再每次拿到状态都去试
    @Test func unlinkedMemberLinksOnceAndBacksOff() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: memberBody(sync: #"{"allowed":true,"linked":false,"email":null,"until":null}"#)))
        server.on("POST", "/v1/getnewword/sync/link", .init(status: 409, body: #"{"error":{"code":"link-limit","message":"30 天里换绑 Google 账号太多次了"}}"#))
        let m = make(token: "gwd_one")
        m.syncSession = { sessionB }
        m.supabaseToken = { "sb-token-b" }
        await m.refresh()
        for _ in 0..<100 where m.linkFailure == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.currentLinkFailure?.code == "link-limit")
        await m.refresh()
        await m.noteResponse(headers: ["X-Uses-Kind": "sub", "X-Uses-Left": "150"], error: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.paths.filter { $0.hasSuffix("/sync/link") }.count == 1)
        // 换了登录的账号：上一个账号的失败不算
        m.syncSession = { SupabaseSession(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, userId: "user-c", email: "c@example.com") }
        #expect(m.currentLinkFailure == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 不是会员、后台没开同步资格：不去绑
    @Test func noLinkWithoutMembershipOrServerSupport() async throws {
        server.on("GET", "/v1/getnewword/status", .init(status: 200, body: memberBody()), .init(status: 200, body: trialStatus(left: 5)))
        let m = make(token: "gwd_one")
        m.syncSession = { sessionB }
        m.supabaseToken = { "sb-token-b" }
        await m.refresh()      // 会员，但 sync 是 null
        await m.linkSync()
        await m.refresh()      // 试用
        await m.linkSync()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!server.paths.contains("POST /v1/getnewword/sync/link"))
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

// MARK: - 账号与同步：不让同步时写什么

struct SyncNoticeTests {
    /// 付了钱的不引去「开通会员」：后台没开同步、绑的是别的账号、正在打开、绑定出错各说各的
    @Test func paidMembersAreNotSentToBuy() {
        let linkedA = MemberStatus.Sync(allowed: true, linked: true, email: "a@example.com", until: nil)
        let limit = MemberError(code: "link-limit", status: 409)
        #expect(SyncNotice.of(isMember: false, sync: linkedA, sessionEmail: "a@example.com", linkError: nil) == .notMember)
        #expect(SyncNotice.of(isMember: true, sync: nil, sessionEmail: "a@example.com", linkError: nil) == .notReady)
        #expect(SyncNotice.of(isMember: true, sync: linkedA, sessionEmail: "A@Example.com", linkError: nil) == .opening)
        #expect(SyncNotice.of(isMember: true, sync: .init(allowed: true, linked: false), sessionEmail: "b@example.com", linkError: nil) == .opening)
        #expect(SyncNotice.of(isMember: true, sync: linkedA, sessionEmail: "b@example.com", linkError: nil) == .linkedElsewhere("a@example.com"))
        #expect(SyncNotice.of(isMember: true, sync: linkedA, sessionEmail: "b@example.com", linkError: limit) == .failed(limit))
        #expect(SyncNotice.of(isMember: true, sync: linkedA, sessionEmail: "a@example.com", linkError: MemberError(code: "not-ready", status: 503)) == .notReady)
        let all: [SyncNotice] = [.notMember, .notReady, .linkedElsewhere("a@example.com"), .opening, .failed(limit),
                                 .failed(MemberError(code: "bad-supabase-token", status: 401)), .failed(.network)]
        #expect(Set(all.map(\.title)).count == all.count)
        #expect(Set(all.map(\.detail)).count == all.count)
        // 别人的邮箱只露头一个字
        #expect(SyncNotice.linkedElsewhere("someone@example.com").title.contains("s…@example.com"))
        #expect(!SyncNotice.linkedElsewhere("someone@example.com").title.contains("someone"))
        #expect(SyncNotice.masked("no-at-sign") == "no-at-sign")
    }

    /// Supabase 不让同步、会员后台说能：只在没绑过、或绑的就是这个账号时请后台再推；绑的是别的账号不动
    @Test func cloudAsksPushAgainOnlyForThisAccount() {
        #expect(CloudSyncService.shouldAskPushAgain(link: .init(allowed: true, linked: false), email: "b@example.com"))
        #expect(CloudSyncService.shouldAskPushAgain(link: .init(allowed: true, linked: true, email: "B@example.com"), email: "b@example.com"))
        #expect(!CloudSyncService.shouldAskPushAgain(link: .init(allowed: true, linked: true, email: "a@example.com"), email: "b@example.com"))
        #expect(!CloudSyncService.shouldAskPushAgain(link: .init(allowed: true, linked: true, email: nil), email: "b@example.com"))
    }

    /// 标删除的 PATCH 回改到了几行：RLS 拦了时是 0 行、不报错
    @Test func tombstoneReplies() {
        #expect(CloudSyncService.updatedRows(Data("[]".utf8)) == 0)
        #expect(CloudSyncService.updatedRows(Data(#"[{"id":"0b2c"}]"#.utf8)) == 1)
        #expect(CloudSyncService.updatedRows(Data()) == nil)
    }
}
