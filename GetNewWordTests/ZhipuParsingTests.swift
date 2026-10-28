// 解析 AI 的回答（ZhipuService.parseAnalysis）和服务商报错的归类（ZhipuServiceError.from、LookupFailure.from）

import Foundation
import Testing
@testable import GetNewWord

/// 拼一个 chat/completions 的返回
private func response(content: String?, finish: String? = "stop") throws -> ZhipuResponse {
    var message: [String: Any] = ["role": "assistant"]
    if let content { message["content"] = content }
    let body: [String: Any] = [
        "id": "chatcmpl-test",
        "choices": [["index": 0, "message": message, "finish_reason": finish.map { $0 as Any } ?? NSNull()]],
        "usage": ["prompt_tokens": 900, "completion_tokens": 120, "total_tokens": 1020],
    ]
    return try JSONDecoder().decode(ZhipuResponse.self, from: JSONSerialization.data(withJSONObject: body))
}

private let fullWord = """
{"words":[{"word":"confluence","phonetic":"/ˈkɒnfluəns/","language":"en","meaning":"n. 汇合处；汇流","contextMeaning":"汇合处",
"contextSentence":"The town sits at the confluence of two rivers.","contextTranslation":"小镇坐落在两条河的交汇处。",
"translationKeyword":"交汇处","grammar":"","difficulty":"c1","tags":[],"category":"英语","suggestedCategory":null}],"snippets":[]}
"""

struct ParseAnalysisTests {
    let service = ZhipuService.shared

    @Test func plainJSON() throws {
        let result = try service.parseAnalysis(response(content: fullWord))
        let w = try #require(result.words.first)
        #expect(result.words.count == 1)
        #expect(w.word == "confluence")
        #expect(w.contextMeaning == "汇合处")
        #expect(w.translationKeyword == "交汇处")
        #expect(w.category == "英语")
        #expect(w.suggestedCategory == nil)
        #expect(result.snippets.isEmpty)
    }

    @Test func fencedWithChatter() throws {
        let content = "好的，下面是结果：\n```json\n\(fullWord)\n```\n希望有帮助。"
        let result = try service.parseAnalysis(response(content: content))
        #expect(result.words.first?.word == "confluence")
    }

    /// DeepSeek 偶尔省略空数组和可选字段：补默认值，不算坏数据（wiki pit-getnewword-deepseek-52-2）
    @Test func missingOptionalFields() throws {
        let content = #"{"words":[{"word":"Vorfahrt","language":"de","meaning":"n. 优先通行权","contextSentence":"Achten Sie auf die Vorfahrt.","contextTranslation":"注意让行。"}]}"#
        let w = try #require(try service.parseAnalysis(response(content: content)).words.first)
        #expect(w.word == "Vorfahrt")
        #expect(w.tags == [])
        #expect(w.difficulty == "B1")
        #expect(w.phonetic == nil)
        #expect(w.examples == nil)
    }

    @Test func wrongTypeFallsBackToDefault() throws {
        let content = #"{"words":[{"word":"run","language":"en","meaning":"v. 跑","contextSentence":"Run!","contextTranslation":"跑！","tags":"none","difficulty":2}],"snippets":null}"#
        let w = try #require(try service.parseAnalysis(response(content: content)).words.first)
        #expect(w.tags == [])
        #expect(w.difficulty == "B1")
    }

    @Test func trailingCommas() throws {
        let content = #"{"words":[{"word":"run","language":"en","meaning":"v. 跑","contextSentence":"Run!","contextTranslation":"跑！","tags":[],},],"snippets":[],}"#
        #expect(try service.parseAnalysis(response(content: content)).words.first?.word == "run")
    }

    /// 模型偶尔把对象包进数组：[{words…}, {answer…}]
    @Test func objectInsideArray() throws {
        let content = "[\(fullWord), {\"answer\": \"done\"}]"
        #expect(try service.parseAnalysis(response(content: content)).words.first?.word == "confluence")
    }

    @Test func snippet() throws {
        let content = #"{"words":[],"snippets":[{"title":"右侧优先","content":"没有标志的路口，右边来的车先走。","sourceContext":"rechts vor links","domain":"驾驶"}]}"#
        let s = try #require(try service.parseAnalysis(response(content: content)).snippets.first)
        #expect(s.title == "右侧优先")
        #expect(s.tags == [])
        #expect(s.category == nil)
    }

    /// finish_reason=length：内容写到一半，报「被截断」，不当成格式错
    @Test func truncatedHalfJSON() {
        let half = String(fullWord.prefix(120))
        #expect(thrownCase { _ = try service.parseAnalysis(response(content: half, finish: "length")) } == "truncated")
    }

    @Test func truncatedEmpty() {
        #expect(thrownCase { _ = try service.parseAnalysis(response(content: "  ", finish: "length")) } == "truncated")
    }

    /// 思考模型把预算用在 reasoning 上，content 为 null
    @Test func emptyContent() {
        let e = error(of: { _ = try service.parseAnalysis(response(content: nil, finish: "stop")) })
        guard case ZhipuServiceError.emptyResponse(let reason)? = e else {
            Issue.record("应为 emptyResponse，实际 \(String(describing: e))")
            return
        }
        #expect(reason == "stop")
    }

    @Test func notJSON() {
        #expect(thrownCase { _ = try service.parseAnalysis(response(content: "抱歉，我看不清图里的字。")) } == "responseParsingFailed")
    }

    @Test func noChoices() throws {
        let r = try JSONDecoder().decode(ZhipuResponse.self, from: Data(#"{"id":"x","choices":[]}"#.utf8))
        #expect(thrownCase { _ = try service.parseAnalysis(r) } == "invalidResponse")
    }

    @Test func reasoningContentAndUsage() throws {
        let json = #"{"id":"x","choices":[{"message":{"role":"assistant","content":"{}","reasoning_content":"想一想"},"finish_reason":"stop"}],"usage":{"completion_tokens":7}}"#
        let r = try JSONDecoder().decode(ZhipuResponse.self, from: Data(json.utf8))
        #expect(r.choices.first?.message.reasoningContent == "想一想")
        #expect(r.usage?.completionTokens == 7)
        #expect(r.usage?.promptTokens == nil)
    }

    @Test func extractJSON() {
        #expect(service.extractJSON(from: "```json\n{\"word\":\"a\"}\n```") == #"{"word":"a"}"#)
        #expect(service.extractJSON(from: "```\n{\"word\":\"a\"}\n```") == #"{"word":"a"}"#)
        #expect(service.extractJSON(from: "前面 {\"word\":\"a\"} 后面") == #"{"word":"a"}"#)
        #expect(service.extractJSON(from: "没有") == "没有")
    }
}

/// 跑一段会抛错的代码，返回抛出的错（没抛返回 nil）
private func error(of body: () throws -> Void) -> Error? {
    do { try body(); return nil } catch { return error }
}

/// 抛出的错是哪一种；没抛返回「没报错」
private func thrownCase(_ body: () throws -> Void) -> String {
    error(of: body).map(caseName) ?? "没报错"
}

struct ProviderErrorTests {
    private func classify(_ status: Int, _ body: String) -> ZhipuServiceError {
        ZhipuServiceError.from(status: status, body: Data(body.utf8))
    }

    private func message(_ e: ZhipuServiceError) -> String? {
        switch e {
        case .apiError(let m), .unauthorized(let m), .quotaExceeded(let m), .modelNotFound(let m): return m
        default: return nil
        }
    }

    @Test func byStatus() {
        let body = #"{"error":{"message":"nope"}}"#
        #expect(caseName(classify(401, body)) == "unauthorized")
        #expect(caseName(classify(403, body)) == "unauthorized")
        #expect(caseName(classify(402, body)) == "quotaExceeded")
        #expect(caseName(classify(429, body)) == "quotaExceeded")
        #expect(caseName(classify(404, body)) == "modelNotFound")
        #expect(caseName(classify(400, body)) == "apiError")
        #expect(message(classify(400, body)) == "nope")
    }

    /// DeepSeek 模型名写错是 400，原话里写着 you passed
    @Test func deepSeekWrongModel() {
        let body = #"{"error":{"message":"The supported API model names are deepseek-chat or deepseek-reasoner, but you passed deepseek-v9.","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#
        #expect(caseName(classify(400, body)) == "modelNotFound")
    }

    @Test func zhipuCodes() {
        #expect(caseName(classify(400, #"{"error":{"code":"1211","message":"模型不存在，请检查模型代码。"}}"#)) == "modelNotFound")
        #expect(caseName(classify(400, #"{"error":{"code":"1113","message":"您的账户已欠费，请充值后重试。"}}"#)) == "quotaExceeded")
        #expect(caseName(classify(400, #"{"error":{"code":"1301","message":"系统检测到输入或生成内容可能包含不安全或敏感内容"}}"#)) == "apiError")
    }

    @Test func openAICodes() {
        #expect(caseName(classify(400, #"{"error":{"code":"model_not_found","message":"The model `gpt-9` does not exist"}}"#)) == "modelNotFound")
        #expect(caseName(classify(400, #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#)) == "quotaExceeded")
        #expect(caseName(classify(400, #"{"error":{"message":"Insufficient Balance"}}"#)) == "quotaExceeded")
    }

    /// Gemini 的兼容接口把报错包在数组里，code 是数字；Key 不对是 400
    @Test func geminiArrayBody() {
        // 2026-10-28 拿假 Key 真请求一次得到的 body
        let badKey = "[{\n  \"error\": {\n    \"code\": 400,\n    \"message\": \"Please pass a valid API key\",\n    \"status\": \"INVALID_ARGUMENT\"\n  }\n}\n]\n"
        #expect(caseName(classify(400, badKey)) == "unauthorized")
        #expect(message(classify(400, badKey)) == "Please pass a valid API key")
        #expect(caseName(classify(400, #"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key."}}]"#)) == "unauthorized")
        let other = #"[{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}]"#
        #expect(message(classify(400, other)) == "Request contains an invalid argument.")
        let busy = #"[{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}]"#
        #expect(caseName(classify(429, busy)) == "quotaExceeded")
    }

    @Test func bodyNotJSON() {
        let e = classify(502, "<html>Bad Gateway</html>")
        #expect(caseName(e) == "apiError")
        #expect(message(e) == "HTTP 502")
    }

    @Test func descriptionNamesTheProvider() {
        let ai = APIProvider.current.displayName
        #expect(classify(401, #"{"error":{"message":"bad"}}"#).errorDescription?.contains(ai) == true)
        #expect(ZhipuServiceError.truncated.errorDescription?.contains(ai) == true)
    }
}

/// 报错浮窗按哪一类给说法和按钮
struct LookupFailureTests {
    @Test func fromServiceErrors() {
        let cases: [(Error, String)] = [
            (ZhipuServiceError.apiKeyNotConfigured, "noKey"),
            (ZhipuServiceError.unauthorized("x"), "badKey"),
            (ZhipuServiceError.quotaExceeded("x"), "quota"),
            (ZhipuServiceError.modelNotFound("x"), "model"),
            (ZhipuServiceError.truncated, "truncated"),
            (ZhipuServiceError.responseParsingFailed, "unreadable"),
            (ZhipuServiceError.invalidResponse, "unreadable"),
            (ZhipuServiceError.emptyResponse(finishReason: nil), "unreadable"),
            (ZhipuServiceError.apiError("x"), "service"),
            (ZhipuServiceError.networkError(URLError(.timedOut)), "timeout"),
            (ZhipuServiceError.networkError(URLError(.notConnectedToInternet)), "network"),
            (ZhipuServiceError.incompleteSetup("先填接口地址"), "other"),
            (CocoaError(.fileNoSuchFile), "other"),
        ]
        for (error, expected) in cases {
            #expect(caseName(LookupFailure.from(error)) == expected, "\(error)")
        }
    }

    @Test func modelCarriesCurrentModelName() {
        guard case .model(let name) = LookupFailure.from(ZhipuServiceError.modelNotFound("x")) else {
            Issue.record("应为 .model")
            return
        }
        #expect(name == APIProvider.current.model)
    }

    @Test func serviceKeepsProviderWords() {
        guard case .service(let m) = LookupFailure.from(ZhipuServiceError.apiError("Content blocked")) else {
            Issue.record("应为 .service")
            return
        }
        #expect(m == "Content blocked")
    }

    /// 只有「没认出词」自己消失，要用户处理的一直留着
    @Test func onlyNoWordDismissesItself() {
        #expect(LookupFailure.noWord.autoDismiss)
        for f: LookupFailure in [.noKey, .badKey, .timeout, .quota, .truncated, .unreadable, .service("x"), .model("m")] {
            #expect(!f.autoDismiss, "\(f)")
        }
    }
}
