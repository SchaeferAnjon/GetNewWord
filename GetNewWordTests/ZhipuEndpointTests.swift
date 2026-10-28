// 智谱的两个接口（ZhipuEndpoint）：默认先走通用接口；报欠费、套餐、模型权限这类错就换另一个接口，成功的那个记下来。
// 用一个假的智谱（URLProtocol）回话，不连真的智谱。

import Foundation
import Testing
@testable import GetNewWord

/// 假的智谱：按接口（通用 / Coding Plan）回话，记下每个请求的路径
final class FakeZhipu: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: String }

    nonisolated(unsafe) static var general = Reply(status: 200, body: FakeZhipu.ok)
    nonisolated(unsafe) static var coding = Reply(status: 200, body: FakeZhipu.ok)
    nonisolated(unsafe) static var paths: [String] = []

    static let ok = #"{"id":"t","choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"data":[{"id":"glm-5.3-flash"}]}"#
    static func error(_ code: String, _ message: String) -> String { #"{"error":{"code":"\#(code)","message":"\#(message)"}}"# }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.paths.append(path)
        let reply = path.hasPrefix("/api/coding/") ? Self.coding : Self.general
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeZhipu.self]
        return URLSession(configuration: config)
    }()
}

@MainActor
@Suite(.serialized)
final class ZhipuEndpointTests {
    let service = ZhipuService.shared
    let chat = "/api/paas/v4/chat/completions"
    let codingChat = "/api/coding/paas/v4/chat/completions"
    let arrears = FakeZhipu.Reply(status: 429, body: FakeZhipu.error("1113", "您的账户已欠费，请充值后重试"))

    init() {
        UserDefaults.standard.removeObject(forKey: ZhipuEndpoint.defaultsKey)
        FakeZhipu.general = FakeZhipu.Reply(status: 200, body: FakeZhipu.ok)
        FakeZhipu.coding = FakeZhipu.Reply(status: 200, body: FakeZhipu.ok)
        FakeZhipu.paths = []
        service.session = FakeZhipu.session
    }

    @Test func generalFirst() async throws {
        #expect(APIProvider.zhipu.baseURL == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(try await service.validateKey("k", provider: .zhipu))
        #expect(FakeZhipu.paths == [chat])
        #expect(ZhipuEndpoint.current == .general)
    }

    /// 只买了 Coding Plan 的 Key：通用接口报欠费，换到 Coding Plan 接口成功，以后直接用它
    @Test func arrearsSwitchesToCodingAndRemembers() async throws {
        FakeZhipu.general = arrears
        #expect(try await service.validateKey("k", provider: .zhipu))
        #expect(FakeZhipu.paths == [chat, codingChat])
        #expect(ZhipuEndpoint.current == .coding)
        #expect(APIProvider.zhipu.baseURL == "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")

        FakeZhipu.paths = []
        #expect(try await service.validateKey("k", provider: .zhipu))
        #expect(FakeZhipu.paths == [codingChat])
    }

    /// 通用接口说没有这个模型、Coding Plan 接口有：也换
    @Test func unknownModelSwitches() async throws {
        FakeZhipu.general = FakeZhipu.Reply(status: 400, body: FakeZhipu.error("1211", "模型不存在，请检查模型代码"))
        #expect(try await service.validateKey("k", provider: .zhipu))
        #expect(FakeZhipu.paths == [chat, codingChat])
        #expect(ZhipuEndpoint.current == .coding)
    }

    /// 记着 Coding Plan、套餐到期了：换回通用接口，记下通用接口
    @Test func expiredPlanSwitchesBack() async throws {
        ZhipuEndpoint.current = .coding
        FakeZhipu.coding = FakeZhipu.Reply(status: 429, body: FakeZhipu.error("1309", "您的 GLM Coding Plan 套餐已到期"))
        #expect(try await service.validateKey("k", provider: .zhipu))
        #expect(FakeZhipu.paths == [codingChat, chat])
        #expect(ZhipuEndpoint.current == .general)
    }

    /// 两个接口都不行：报第一个接口的错，记着的接口不变
    @Test func bothFailReportsTheFirst() async throws {
        FakeZhipu.general = arrears
        FakeZhipu.coding = FakeZhipu.Reply(status: 429, body: FakeZhipu.error("1311", "当前订阅套餐暂未开放 glm-5.3-flash 权限"))
        do {
            _ = try await service.validateKey("k", provider: .zhipu)
            Issue.record("应该报错")
        } catch let error as ZhipuServiceError {
            guard case .quotaExceeded(let message) = error else { Issue.record("报成了 \(error)"); return }
            #expect(message.contains("欠费"))
        }
        #expect(FakeZhipu.paths == [chat, codingChat])
        #expect(ZhipuEndpoint.current == .general)
    }

    /// Key 不对、限流、套餐用量到上限、内容审核、服务端出错：换接口也一样，不换
    @Test func otherErrorsStay() async throws {
        let replies = [
            FakeZhipu.Reply(status: 401, body: FakeZhipu.error("1000", "身份验证失败")),
            FakeZhipu.Reply(status: 429, body: FakeZhipu.error("1302", "您的账户已达到速率限制，请您控制请求频率")),
            FakeZhipu.Reply(status: 429, body: FakeZhipu.error("1308", "已达到 5 小时的使用上限")),
            FakeZhipu.Reply(status: 400, body: FakeZhipu.error("1301", "系统检测到输入或生成内容可能包含不安全或敏感内容")),
            FakeZhipu.Reply(status: 500, body: "Internal Server Error"),
        ]
        for reply in replies {
            FakeZhipu.general = reply
            FakeZhipu.paths = []
            _ = try? await service.validateKey("k", provider: .zhipu)
            #expect(FakeZhipu.paths == [chat], "HTTP \(reply.status) \(reply.body)")
        }
        #expect(ZhipuEndpoint.current == .general)
    }

    /// 别家的报错长得像也不换（只认智谱的地址）
    @Test func otherProvidersNeverSwitch() async throws {
        FakeZhipu.general = arrears
        _ = try? await service.validateKey("k", provider: .deepseek)
        #expect(FakeZhipu.paths == ["/chat/completions"])
    }

    /// 拉模型列表也走记下的接口
    @Test func modelListFollowsTheRememberedEndpoint() async throws {
        ZhipuEndpoint.current = .coding
        #expect(try await service.listModels(key: "k", provider: .zhipu) == ["glm-5.3-flash"])
        #expect(FakeZhipu.paths == ["/api/coding/paas/v4/models"])
    }

    /// 限流、模型忙、5xx 过几秒重发；欠费、套餐、用量上限重发也没用
    @Test func retryOnlyWhatCanRecover() {
        let body = { (code: String) in Data(FakeZhipu.error(code, "x").utf8) }
        #expect(ZhipuServiceError.isRetryable(status: 429, body: body("1302")))
        #expect(ZhipuServiceError.isRetryable(status: 429, body: body("1305")))
        #expect(ZhipuServiceError.isRetryable(status: 429, body: Data(#"{"error":{"message":"Rate limit reached"}}"#.utf8)))
        #expect(ZhipuServiceError.isRetryable(status: 503, body: Data()))
        #expect(!ZhipuServiceError.isRetryable(status: 429, body: body("1113")))
        #expect(!ZhipuServiceError.isRetryable(status: 429, body: body("1308")))
        #expect(!ZhipuServiceError.isRetryable(status: 429, body: body("1309")))
        #expect(!ZhipuServiceError.isRetryable(status: 400, body: body("1211")))
    }
}
