// ZhipuService.swift
// GetNewWord
//
// 智谱 BigModel API 服务层
// 封装 GLM-5.3-Flash 模型的多模态分析调用

import Foundation
import AppKit

// MARK: - API 请求/响应模型

/// 消息内容枚举，支持文本和图片两种类型
enum ZhipuContent: Codable, Sendable {
    case text(String)
    case imageUrl(String)

    private struct TextContent: Codable {
        let type: String
        let text: String
    }

    private struct ImageContent: Codable {
        let type: String
        let imageUrl: ImageURL

        struct ImageURL: Codable {
            let url: String
        }

        /// 必须映射为 `image_url`：默认会编码成 `imageUrl`，服务端直接 HTTP 500「内部错误」
        /// ——这就是应用从第一天起图片就没被正确发出去的原因
        enum CodingKeys: String, CodingKey {
            case type
            case imageUrl = "image_url"
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let string):
            var container = encoder.singleValueContainer()
            try container.encode(TextContent(type: "text", text: string))
        case .imageUrl(let url):
            var container = encoder.singleValueContainer()
            try container.encode(ImageContent(type: "image_url", imageUrl: .init(url: url)))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // 尝试解析为图片类型
        if let imageContent = try? container.decode(ImageContent.self),
           imageContent.type == "image_url" {
            self = .imageUrl(imageContent.imageUrl.url)
            return
        }
        // 尝试解析为文本类型
        if let textContent = try? container.decode(TextContent.self),
           textContent.type == "text" {
            self = .text(textContent.text)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法解析 ZhipuContent"
        )
    }
}

/// API 消息
struct ZhipuMessage: Codable, Sendable {
    let role: String
    let content: [ZhipuContent]
}

/// API 请求体
struct ZhipuRequest: Codable, Sendable {
    let model: String
    let messages: [ZhipuMessage]
    /// OpenAI 推理模型、Claude、Kimi 只接受默认温度，传了会 400 → nil 不发送
    let temperature: Double?
    let maxTokens: Int?
    /// OpenAI GPT-5 之后的模型拒收 max_tokens，只认这个
    let maxCompletionTokens: Int?
    /// OpenAI / Gemini 的思考强度（low / minimal），取词不需要深度思考
    let reasoningEffort: String?
    /// GLM-5.x 默认开启「思考」，多模态分析时 reasoning 动辄 60–120 秒且会耗尽 max_tokens
    /// （completion_tokens 含 reasoning_tokens），导致超时或 content 为空。截图取词不需要思考，显式关闭。
    /// DeepSeek 不支持该参数（nil = 不发送）。
    let thinking: ThinkingConfig?
    /// 强制 JSON 输出，避免模型夹带 markdown / 解释文字
    let responseFormat: ResponseFormat?
    /// SSE 流式输出（语法拆解这类长文本边生成边显示）；nil = 不发送
    let stream: Bool?

    struct ThinkingConfig: Codable, Sendable {
        let type: String
        static let disabled = ThinkingConfig(type: "disabled")
    }

    struct ResponseFormat: Codable, Sendable {
        let type: String
        static let jsonObject = ResponseFormat(type: "json_object")
    }

    /// 按提供商的接口差异组装请求体：哪些字段发、用哪个字段名
    init(provider p: APIProvider, messages: [ZhipuMessage], temperature: Double, maxTokens: Int,
         thinking: ThinkingConfig?, jsonOutput: Bool = false, stream: Bool? = nil) {
        self.model = p.model
        self.messages = messages
        self.temperature = p.acceptsTemperature ? temperature : nil
        self.maxTokens = p.usesMaxCompletionTokens ? nil : maxTokens
        self.maxCompletionTokens = p.usesMaxCompletionTokens ? maxTokens : nil
        self.reasoningEffort = p.reasoningEffort
        self.thinking = thinking
        self.responseFormat = jsonOutput && p.supportsJSONMode ? .jsonObject : nil
        self.stream = stream
    }

    /// 会员通道：发到我们的后台，模型、思考由后台定（deepseek-flash、关思考），这里只给内容、输出上限和要不要 JSON
    init(memberMessages messages: [ZhipuMessage], temperature: Double, maxTokens: Int, jsonOutput: Bool = false, stream: Bool? = nil) {
        self.model = "deepseek-flash"
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.maxCompletionTokens = nil
        self.reasoningEffort = nil
        self.thinking = nil
        self.responseFormat = jsonOutput ? .jsonObject : nil
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, thinking, stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffort = "reasoning_effort"
        case responseFormat = "response_format"
    }
}

/// API 响应体
struct ZhipuResponse: Codable, Sendable {
    let id: String
    let choices: [ZhipuChoice]
    let usage: ZhipuUsage?
}

struct ZhipuChoice: Codable, Sendable {
    let message: ZhipuResponseMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

struct ZhipuResponseMessage: Codable, Sendable {
    let role: String
    /// 思考模型在 max_tokens 被 reasoning 耗尽时 content 可能为 null/空
    let content: String?
    let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case reasoningContent = "reasoning_content"
    }
}

struct ZhipuUsage: Codable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// API 错误响应：{"error": {"code": "…", "message": "…"}}。
/// Gemini 的兼容接口包在数组里、code 是数字：[{"error": {"code": 400, "message": "…", "status": "INVALID_ARGUMENT"}}]
struct ZhipuErrorResponse: Codable, Sendable {
    let error: ZhipuError?

    struct ZhipuError: Codable, Sendable {
        let code: String?
        let message: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? (try? c.decodeIfPresent(Int.self, forKey: .code)).map(String.init)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
        }
    }

    /// 读出报错 body 里的 error；不是 JSON 或认不出格式时为 nil
    static func error(in body: Data) -> ZhipuError? {
        let decoder = JSONDecoder()
        return (try? decoder.decode(Self.self, from: body))?.error ?? (try? decoder.decode([Self].self, from: body))?.first?.error
    }
}

// MARK: - 分析结果模型

/// 单词与知识片段的分析结果
struct WordAnalysisResult: Codable, Sendable {
    let words: [WordAnalysis]
    let snippets: [SnippetAnalysis]

    init(words: [WordAnalysis] = [], snippets: [SnippetAnalysis] = []) {
        self.words = words
        self.snippets = snippets
    }
}

/// 单词分析
struct WordAnalysis: Codable, Sendable {
    let word: String
    let phonetic: String?
    let language: String
    let meaning: String
    /// 当前语境对应的义项（meaning 里的原文子串，用于高亮）
    let contextMeaning: String?
    let contextSentence: String
    let contextTranslation: String
    /// 目标词在译文中对应的字词（模型逐字摘抄，用于译文精确高亮）
    let translationKeyword: String?
    /// 用法已挪到二段式补全；一段可能不返回
    let analysisNote: String?
    /// 语法信息（德语：词性+复数 / 可分与三态 / 比较级；其他语言可为空）
    let grammar: String?
    /// 例句（1–2 条，"原句 —— 中文"格式）
    let examples: [String]?
    /// 助记（谐音/联想/构词拆解，1 句）
    let mnemonic: String?
    /// 词根词源（一条里讲完词根 + 来源）
    let etymology: String?
    let difficulty: String
    /// 从现有标签库中选出的标签（0–2 个）
    let tags: [String]
    /// 模型从现有分类体系里选定的分类（叶子名，如 "英语"）；体系里没有合适的则为 nil
    let category: String?
    /// 体系里没有合适分类时，模型建议新建的分类名（需用户确认）
    let suggestedCategory: String?
}

// MARK: - 宽松解码
// 不同模型对「可省略字段」的理解不一样：GLM 总是把 tags/snippets 这类空数组写出来，DeepSeek 偶尔直接省略，
// 合成的 Codable 遇到缺字段就整体失败（面板报「响应解析失败」）。这里缺什么补默认值，只有连词头都没有才算坏数据。

private extension KeyedDecodingContainer {
    /// 缺失 / null / 类型不对 → 默认值
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
    func lenientOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension WordAnalysisResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(words: c.lenient(.words, []), snippets: c.lenient(.snippets, []))
    }
}

extension WordAnalysis {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            word: try c.decode(String.self, forKey: .word),
            phonetic: c.lenientOptional(.phonetic),
            language: c.lenient(.language, "en"),
            meaning: c.lenient(.meaning, ""),
            contextMeaning: c.lenientOptional(.contextMeaning),
            contextSentence: c.lenient(.contextSentence, ""),
            contextTranslation: c.lenient(.contextTranslation, ""),
            translationKeyword: c.lenientOptional(.translationKeyword),
            analysisNote: c.lenientOptional(.analysisNote),
            grammar: c.lenientOptional(.grammar),
            examples: c.lenientOptional(.examples),
            mnemonic: c.lenientOptional(.mnemonic),
            etymology: c.lenientOptional(.etymology),
            difficulty: c.lenient(.difficulty, "B1"),
            tags: c.lenient(.tags, []),
            category: c.lenientOptional(.category),
            suggestedCategory: c.lenientOptional(.suggestedCategory)
        )
    }
}

extension SnippetAnalysis {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            content: c.lenient(.content, ""),
            sourceContext: c.lenient(.sourceContext, ""),
            domain: c.lenientOptional(.domain),
            tags: c.lenient(.tags, []),
            category: c.lenientOptional(.category),
            suggestedCategory: c.lenientOptional(.suggestedCategory)
        )
    }
}

/// 二段式补充内容
struct WordEnrichment: Codable, Sendable {
    let meaning: String?
    let usage: String?
    let collocations: [String]?
    let examples: [String]?
    let etymology: String?
}

/// 知识片段分析
struct SnippetAnalysis: Codable, Sendable {
    let title: String
    let content: String
    let sourceContext: String
    let domain: String?
    let tags: [String]
    let category: String?
    let suggestedCategory: String?
}

// MARK: - 错误类型

enum ZhipuServiceError: LocalizedError {
    case apiKeyNotConfigured
    case imageEncodingFailed
    case networkError(Error)
    /// 没归进下面几类的 HTTP 错误，带服务商的原话
    case apiError(String)
    /// 401 / 403：Key 不对或没权限
    case unauthorized(String)
    /// 402 / 429（重试完仍是），或报错写着余额不足：额度用完、欠费、请求太密
    case quotaExceeded(String)
    /// 404，或报错写着模型不存在：模型名不对
    case modelNotFound(String)
    /// finish_reason=length：回复没写完就停了
    case truncated
    case responseParsingFailed
    case invalidResponse
    case emptyResponse(finishReason: String?)
    /// 自定义服务商还没填全（地址、模型名）
    case incompleteSetup(String)
    /// 会员通道的报错（试用用完、每天上限、欠费……），按后台的错误码说
    case member(MemberError)

    /// 把服务商的 HTTP 报错归类：状态码优先，再看错误码和原话里的关键词
    static func from(status: Int, body: Data) -> ZhipuServiceError {
        let error = ZhipuErrorResponse.error(in: body)
        let message = error?.message ?? "HTTP \(status)"
        let code = error?.code?.lowercased() ?? ""
        let text = message.lowercased()
        // Gemini 的 Key 不对是 400「Please pass a valid API key」（老一点的说法是「API key not valid」）
        if text.contains("valid api key") || text.contains("api key not valid") { return .unauthorized(message) }
        switch status {
        case 401, 403: return .unauthorized(message)
        case 402, 429: return .quotaExceeded(message)
        case 404: return .modelNotFound(message)
        default:
            // 智谱 1211、OpenAI model_not_found、DeepSeek 400「The supported API model names are …, but you passed …」
            let modelHints = ["not exist", "not found", "no such model", "invalid model", "unknown model", "you passed"]
            if code == "1211" || code == "model_not_found" || text.contains("模型不存在")
                || (text.contains("model") && modelHints.contains(where: text.contains)) {
                return .modelNotFound(message)
            }
            // 智谱 1113 余额不足、OpenAI insufficient_quota
            if code == "1113" || code == "insufficient_quota" || text.contains("余额不足") || text.contains("insufficient balance") {
                return .quotaExceeded(message)
            }
            return .apiError(message)
        }
    }

    /// 过几秒重发可能就好：5xx，和不是欠费、套餐、用量上限的 429（限流、模型忙）
    static func isRetryable(status: Int, body: Data) -> Bool {
        if (500...599).contains(status) { return true }
        guard status == 429 else { return false }
        let code = ZhipuErrorResponse.error(in: body)?.code ?? ""
        return !ZhipuEndpoint.switchCodes.contains(code) && !ZhipuEndpoint.usageCapCodes.contains(code)
    }

    var errorDescription: String? {
        let ai = AIPlan.current == .member ? ZhipuService.memberName : APIProvider.current.displayName
        switch self {
        case .apiKeyNotConfigured: return String(localized: "还没填 \(ai) 的 Key：到「设置 › AI 服务」填好再查。")
        case .imageEncodingFailed: return String(localized: "截图没能转成图片，再框一次试试。")
        case .networkError(let error): return String(localized: "连不上 \(ai)：\(error.localizedDescription)")
        case .apiError(let message): return String(localized: "\(ai) 报错：\(message)")
        case .unauthorized(let message): return String(localized: "\(ai) 不认这个 Key：\(message)")
        case .quotaExceeded(let message): return String(localized: "\(ai) 的额度用完了：\(message)")
        case .modelNotFound(let message): return String(localized: "\(ai) 找不到这个模型：\(message)")
        case .truncated: return String(localized: "\(ai) 的回复没写完就停了。")
        case .responseParsingFailed: return String(localized: "\(ai) 回的内容格式不对，没读出释义。")
        case .invalidResponse: return String(localized: "\(ai) 的回应不完整，没法读。")
        case .emptyResponse(let reason): return String(localized: "\(ai) 这次什么都没回（finish_reason=\(reason ?? "-")）。")
        case .incompleteSetup(let message): return message
        case .member(let e): return MemberText.detail(e)
        }
    }
}

// MARK: - 模型提供商

/// 截图分析可选的 AI。除智谱外都走 OpenAI 兼容的 chat/completions，差异集中在下面几个开关里。
/// 推荐模型核对于 2026-10，用户可在设置里改成别的模型名。
enum APIProvider: String, CaseIterable, Identifiable {
    case zhipu, deepseek, qwen, kimi, doubao, openai, gemini, claude, openrouter, custom
    var id: String { rawValue }

    /// 国内可直连的排前面一组，其余归「海外与其他」
    var isDomestic: Bool { [.zhipu, .deepseek, .qwen, .kimi, .doubao].contains(self) }

    var displayName: String {
        switch self {
        case .zhipu: return String(localized: "智谱 GLM")
        case .deepseek: return "DeepSeek"
        case .qwen: return String(localized: "通义千问")
        case .kimi: return "Kimi"
        case .doubao: return String(localized: "豆包")
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .openrouter: return "OpenRouter"
        case .custom: return String(localized: "自定义")
        }
    }

    /// 一句话特点，选 AI 时显示
    var blurb: String {
        switch self {
        case .zhipu: return String(localized: "国内直连，速度快")
        case .deepseek: return String(localized: "便宜，中文好")
        case .qwen: return String(localized: "阿里云百炼")
        case .kimi: return String(localized: "月之暗面")
        case .doubao: return String(localized: "火山方舟")
        case .openai, .gemini, .claude: return String(localized: "需要海外网络")
        case .openrouter: return String(localized: "一个 Key 用多家模型")
        case .custom: return String(localized: "任何 OpenAI 兼容接口")
        }
    }

    /// Assets 里的官方图标；自定义没有图标，用 SF Symbol
    var logoAsset: String? { self == .custom ? nil : "Provider-\(rawValue)" }

    var keyPage: URL? {
        switch self {
        case .zhipu: return URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .qwen: return URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")
        case .kimi: return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .doubao: return URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .custom: return nil
        }
    }

    var defaultModel: String {
        switch self {
        case .zhipu: return "glm-5.3-flash"
        case .deepseek: return "deepseek-v4-flash-vision-exp"
        case .qwen: return "qwen3-vl-plus"
        case .kimi: return "kimi-k3"
        case .doubao: return "doubao-seed-1-6-251015"
        case .openai: return "gpt-6-luna"
        case .gemini: return "gemini-3.8-flash"
        case .claude: return "claude-haiku-5-5"
        case .openrouter: return "openai/gpt-6-luna"
        case .custom: return ""
        }
    }

    /// 用户在设置里改过的模型名优先
    var model: String {
        let custom = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        return custom.isEmpty ? defaultModel : custom
    }
    var modelDefaultsKey: String { "model.\(rawValue)" }

    static let customBaseURLKey = "customBaseURL"

    var baseURL: String {
        switch self {
        case .zhipu: return ZhipuEndpoint.current.root + "/chat/completions"
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .kimi: return "https://api.moonshot.cn/v1/chat/completions"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .custom:
            // 用户填的是 …/v1 这类根地址，补上 chat/completions
            var base = (UserDefaults.standard.string(forKey: Self.customBaseURLKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            return base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        }
    }

    /// 智谱、DeepSeek 沿用老的 Keychain 条目，已填的 Key 不丢
    var keychainKey: String { "\(rawValue)_api_key" }

    /// 模型列表接口：各家都是把 chat/completions 换成 models（Claude 落到原生 /v1/models）
    var modelsURL: String {
        baseURL.replacingOccurrences(of: "/chat/completions", with: "/models")
    }

    /// 自定义必须填地址和模型才能用
    var isReady: Bool { isReadyForListing && !model.isEmpty }

    /// 拉模型列表只要地址
    var isReadyForListing: Bool { self != .custom || URL(string: baseURL)?.host != nil }

    // MARK: 接口差异

    enum ThinkingControl { case none, toggle, level }

    /// 智谱有等级；DeepSeek、豆包只有开关；其余家不在设置里露出思考选项
    var thinkingControl: ThinkingControl {
        switch self {
        case .zhipu: return .level
        case .deepseek, .doubao: return .toggle
        default: return .none
        }
    }

    /// 按设置生成思考配置（默认关闭）：智谱支持等级 low/high/max；DeepSeek、豆包只有开/关
    var thinkingConfig: ZhipuRequest.ThinkingConfig? {
        guard thinkingControl != .none else { return nil }
        let d = UserDefaults.standard
        guard d.bool(forKey: "thinkingEnabled") else { return .disabled }
        guard thinkingControl == .level else { return ZhipuRequest.ThinkingConfig(type: "enabled") }
        return ZhipuRequest.ThinkingConfig(type: d.string(forKey: "thinkingLevel") ?? "low")   // low / high / max
    }

    /// 关不掉思考的两家压到最低档：Gemini 3 Flash 最低是 minimal；OpenAI 各模型都认 low
    var reasoningEffort: String? {
        switch self {
        case .openai: return "low"
        case .gemini: return "minimal"
        default: return nil
        }
    }

    /// OpenAI 推理模型只认默认温度；Claude 新模型传低于 1 的温度报 400；Kimi 官方建议不传
    var acceptsTemperature: Bool { ![.openai, .claude, .kimi].contains(self) }

    var usesMaxCompletionTokens: Bool { self == .openai }

    /// 文档写明支持 json_object 的才发；其余靠 extractJSON 从文本里抠
    var supportsJSONMode: Bool { [.zhipu, .deepseek, .kimi, .openai, .openrouter].contains(self) }

    static var current: APIProvider {
        APIProvider(rawValue: UserDefaults.standard.string(forKey: "apiProvider") ?? "zhipu") ?? .zhipu
    }
}

// MARK: - 智谱的两个接口

/// 智谱的同一个 Key 有两个接口：通用接口扣账户余额，GLM Coding Plan 接口扣编程套餐的额度。只充了余额的调套餐接口会报
/// 套餐不可用，只买了套餐的调通用接口会报欠费，哪个能用要试了才知道。默认先走通用接口；报的是欠费、套餐或模型权限这类
/// 换个接口可能就好的错，就把同一个请求发到另一个接口，那边成功了就记下它，以后直接用。
enum ZhipuEndpoint: String {
    case general, coding

    static let defaultsKey = "zhipuEndpoint"

    var root: String {
        switch self {
        case .general: return "https://open.bigmodel.cn/api/paas/v4"
        case .coding: return "https://open.bigmodel.cn/api/coding/paas/v4"
        }
    }

    var other: ZhipuEndpoint { self == .general ? .coding : .general }

    /// 上次用通了的那个；没记过就是通用接口
    static var current: ZhipuEndpoint {
        get { ZhipuEndpoint(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 智谱的错误码（https://docs.bigmodel.cn/cn/faq/api-code ，2026-10 核对）里换个接口可能就好的：欠费 1113，
    /// 模型不存在 1211，无权访问 1220，套餐到期 1309，套餐没开放这个模型 1311，企业套餐失效 1314，Key 只能用于企业编程套餐 1315。
    /// 套餐用量到了上限（1308、1310、1316 到 1321）不换：几小时后就重置，换到通用接口会悄悄扣余额。
    static let switchCodes: Set<String> = ["1113", "1211", "1220", "1309", "1311", "1314", "1315"]
    /// 套餐用量上限：到点重置，几秒后重试也没用
    static let usageCapCodes: Set<String> = ["1308", "1310", "1316", "1317", "1318", "1319", "1320", "1321"]

    /// 发往智谱某个接口的请求，改发到另一个接口；不是发往智谱的返回 nil
    static func alternative(to request: URLRequest) -> (request: URLRequest, endpoint: ZhipuEndpoint)? {
        guard let url = request.url?.absoluteString,
              let from = [ZhipuEndpoint.coding, .general].first(where: { url.hasPrefix($0.root + "/") }) else { return nil }
        var switched = request
        switched.url = URL(string: from.other.root + url.dropFirst(from.root.count))
        return (switched, from.other)
    }

    static func shouldSwitch(status: Int, body: Data) -> Bool {
        guard !(200...299).contains(status), let code = ZhipuErrorResponse.error(in: body)?.code else { return false }
        return switchCodes.contains(code)
    }
}

// MARK: - ZhipuService

class ZhipuService: @unchecked Sendable {
    static let shared = ZhipuService()

    private var provider: APIProvider { .current }
    private let maxRetryCount = 2
    private let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000] // 2s, 5s (nanoseconds)
    /// 一次调用（含全部重试）的总预算。单次超时再长也不会超过它，
    /// 免得「超时放宽 + 重试 2 次」把最坏等待叠成两三分钟。
    private let overallBudget: TimeInterval = 75

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()

    /// 专用 URLSession：GLM-5.3-Flash 带思考的多模态分析经常超过 60 秒，
    /// 默认的 URLSession.shared（timeoutIntervalForRequest = 60s）会导致请求超时失败。
    /// 这里放宽到请求 5 分钟、资源 10 分钟。单元测试换成假服务。
    var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300   // 请求超时 5 分钟
        config.timeoutIntervalForResource = 600  // 资源超时 10 分钟
        return URLSession(configuration: config)
    }()

    // MARK: - 会员通道

    /// 会员模式：查词发到我们的后台，不用 Key。单元测试换成假的
    var memberMode: @Sendable () -> Bool = { AIPlan.current == .member }
    /// 会员的凭据、用量号、剩余次数；nil = MemberService.shared。单元测试换成假的
    var memberOverride: (any MemberRoute)?
    /// 后台地址有没有（开发版没设 GETNEWWORD_API 时没有）
    var memberAvailable = MemberAPI.base(environment: ProcessInfo.processInfo.environment,
                                         isDev: AppVariant.isDev || AppVariant.isUnitTesting) != nil

    static var memberName: String { String(localized: "GetNewWord 会员") }

    private func memberRoute() async -> any MemberRoute {
        if let memberOverride { return memberOverride }
        return await MainActor.run { MemberService.shared }
    }

    // MARK: - API Key 管理

    /// 当前提供商的 API Key
    var apiKey: String? {
        get { key(for: provider) }
        set { setKey(newValue, for: provider) }
    }

    func key(for p: APIProvider) -> String? {
        #if DEBUG
        if let key = DemoMode.key { return key }
        #endif
        return KeychainManager.shared.load(key: p.keychainKey)
    }

    func setKey(_ value: String?, for p: APIProvider) {
        if let value, !value.isEmpty {
            _ = KeychainManager.shared.save(key: p.keychainKey, value: value)
        } else {
            _ = KeychainManager.shared.delete(key: p.keychainKey)
        }
    }

    /// 能不能查词：会员模式看有没有后台地址，自带 Key 看当前服务商填没填 Key
    var isConfigured: Bool {
        memberMode() ? memberAvailable : key(for: provider) != nil && provider.isReady
    }

    /// 当前用的 AI 的名字（错误提示用）
    var currentProviderName: String { memberMode() ? Self.memberName : provider.displayName }

    // MARK: - 公开方法

    /// 分析截图，返回单词和知识片段
    /// - Parameters:
    ///   - image: 截图图片
    ///   - customPrompt: 自定义提示词，为 nil 时使用默认单词分析 Prompt
    /// - Returns: 分析结果
    func analyzeScreenshot(_ image: NSImage, existingTags: [String] = [], categoryTree: String = "", customPrompt: String? = nil,
                           useID: UUID? = nil) async throws -> WordAnalysisResult {
        guard isConfigured else {
            throw ZhipuServiceError.apiKeyNotConfigured
        }

        guard let dataURL = ImageEncoder.toCompressedDataURL(image) else {
            throw ZhipuServiceError.imageEncodingFailed
        }

        let prompt = customPrompt ?? buildWordAnalysisPrompt(existingTags: existingTags, categoryTree: categoryTree)

        let message = ZhipuMessage(
            role: "user",
            content: [
                .imageUrl(dataURL),
                .text(prompt)
            ]
        )

        // 不开思考时 p50≈4.5s、p90≈10s，但服务端偶尔会拖到 20–56s 才回；30s 砍掉的多半是这种「慢但活着」的请求，
        // 重发同一张图只会再撞一次。给 50s，总时长由 overallBudget 兜。开思考可能真的慢，放宽
        let thinkingOn = !memberMode() && (provider.thinkingConfig?.type ?? "disabled") != "disabled"
        let response = try await sendRequest(messages: [message], timeout: thinkingOn ? 120 : 50, useID: useID)
        return try parseAnalysis(response)
    }

    /// 文字版取词（指词 / 框选都用）：已知目标文字和它周围的屏幕文字，不发图，纯文字请求比识图快得多
    func analyzeText(_ text: TextLookup, existingTags: [String] = [], categoryTree: String = "", useID: UUID? = nil) async throws -> WordAnalysisResult {
        guard isConfigured else {
            throw ZhipuServiceError.apiKeyNotConfigured
        }
        let source = "本地 OCR 识别，可能有轻微误差，行尾可能把句子截断"
        let scene: String
        switch text.scene {
        case .hover:
            scene = """
            这是外语学习查词场景：用户用鼠标指着屏幕上的一个词。下文说的「红框内」就是目标词「\(text.target)」，「红框外的上下文」就是下面这段屏幕文字（\(source)）：
            <<<
            \(text.context)
            >>>
            目标是单词，按查词处理（只填 words）；若它在上下文里是某个固定短语的一部分，word 仍只给这个词的词典形式。
            """
        case .region:
            scene = """
            这是外语学习取词场景：用户在屏幕上框选了一段文字。下文说的「红框内」就是框选的文字「\(text.target)」，「红框外的上下文」就是下面这段屏幕文字（\(source)；框选文字也在其中）：
            <<<
            \(text.context)
            >>>
            """
        }
        let prompt = buildWordAnalysisPrompt(existingTags: existingTags, categoryTree: categoryTree, scene: scene)
        let thinkingOn = !memberMode() && (provider.thinkingConfig?.type ?? "disabled") != "disabled"
        let response = try await sendRequest(messages: [ZhipuMessage(role: "user", content: [.text(prompt)])], timeout: thinkingOn ? 120 : 50, useID: useID)
        return try parseAnalysis(response)
    }

    /// 取出主分析的 JSON。finish_reason=length 时内容不全：空的或解析不了都按「被截断」报，不当成格式错
    func parseAnalysis(_ response: ZhipuResponse) throws -> WordAnalysisResult {
        guard let choice = response.choices.first else {
            throw ZhipuServiceError.invalidResponse
        }
        let truncated = choice.finishReason == "length"
        guard let content = choice.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // content 为空：通常是输出被截断，或模型只输出了 reasoning
            throw truncated ? ZhipuServiceError.truncated : ZhipuServiceError.emptyResponse(finishReason: choice.finishReason)
        }
        do {
            return try parseAnalysisResult(from: content)
        } catch {
            throw truncated ? ZhipuServiceError.truncated : error
        }
    }

    /// 验证当前提供商的 API Key
    func validateAPIKey() async throws -> Bool {
        guard let key = apiKey, !key.isEmpty else {
            throw ZhipuServiceError.apiKeyNotConfigured
        }
        return try await validateKey(key, provider: provider)
    }

    /// 验证任意提供商的 Key（设置页用）
    func validateKey(_ key: String, provider p: APIProvider) async throws -> Bool {
        guard p.isReady else { throw ZhipuServiceError.incompleteSetup(String(localized: "先填接口地址和模型名")) }
        let message = ZhipuMessage(
            role: "user",
            content: [.text("Hi")]
        )

        // 有些模型思考关不掉，5 个 token 可能连思考都不够，给宽一点；只看状态码，不看内容
        let request = ZhipuRequest(
            provider: p,
            messages: [message],
            temperature: 0.1,
            maxTokens: 16,
            thinking: p.thinkingControl == .none ? nil : .disabled
        )

        let requestData = try JSONEncoder().encode(request)
        var urlRequest = buildURLRequest(provider: p)
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = requestData

        let (data, httpResponse) = try await perform(urlRequest)

        if httpResponse.statusCode == 401 {
            return false
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ZhipuServiceError.from(status: httpResponse.statusCode, body: data)
        }

        return true
    }

    /// 拉取这家现有的模型，供设置页挑选。
    /// 接口标了输入模态的（DeepSeek、OpenRouter）只留能看图的；没标的按名字去掉嵌入、语音、生图这类不能聊天的
    func listModels(key: String, provider p: APIProvider) async throws -> [String] {
        guard p.isReadyForListing else { throw ZhipuServiceError.incompleteSetup(String(localized: "先填接口地址")) }
        var request = URLRequest(url: URL(string: p.modelsURL)!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if p == .claude {
            // 原生 /v1/models 认 x-api-key
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let (data, http) = try await perform(request)
        guard (200...299).contains(http.statusCode) else {
            throw ZhipuServiceError.from(status: http.statusCode, body: data)
        }
        let list = try jsonDecoder.decode(ModelList.self, from: data)
        let ids = list.data.compactMap { m -> String? in
            let modalities = m.input_modalities ?? m.architecture?.input_modalities
            if let modalities, !modalities.contains("image") { return nil }
            let id = m.id.hasPrefix("models/") ? String(m.id.dropFirst(7)) : m.id   // Gemini 带 models/ 前缀
            let lower = id.lowercased()
            return Self.nonChatMarkers.contains(where: lower.contains) ? nil : id
        }
        AppLog.log("[Zhipu] models \(p.rawValue): \(list.data.count) → \(ids.count)")
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedDescending }   // 新版本号排前面
    }

    private static let nonChatMarkers = ["embed", "tts", "whisper", "transcribe", "dall-e", "moderation", "realtime",
                                         "audio", "image", "imagen", "veo", "sora", "search", "rerank", "babbage", "davinci"]

    private struct ModelList: Decodable {
        struct Model: Decodable {
            struct Architecture: Decodable { let input_modalities: [String]? }
            let id: String
            let input_modalities: [String]?
            let architecture: Architecture?
        }
        let data: [Model]
    }

    // MARK: - 私有方法

    /// 发送 API 请求，含重试机制
    /// - timeout: 单次请求超时（秒）。服务端偶尔会几十秒不回包，砍太早等于把本来会成功的请求掐死
    ///   （实测成功样本 p95=12.6s、p99=21.7s、最慢 56s），所以单次超时给宽，
    ///   由 `deadline` 兜住总时长。
    /// - deadline: 整个调用（含重试）的截止时刻，首次调用时按 `overallBudget` 生成
    private func sendRequest(messages: [ZhipuMessage], maxTokens: Int = 8192, timeout: TimeInterval = 60, useID: UUID? = nil,
                             retryCount: Int = 0, deadline: Date? = nil) async throws -> ZhipuResponse {
        if memberMode() {
            return try await sendMemberRequest(messages: messages, maxTokens: maxTokens, timeout: timeout, run: useID ?? UUID())
        }
        guard let key = apiKey, !key.isEmpty else {
            throw ZhipuServiceError.apiKeyNotConfigured
        }

        // 单次超时比总预算还长（如带思考的分析给 120s）时，预算跟着放宽，别把它反过来砍短
        let deadline = deadline ?? Date().addingTimeInterval(max(overallBudget, timeout + 15))

        let p = provider
        let request = ZhipuRequest(
            provider: p,
            messages: messages,
            temperature: 0.3,
            maxTokens: maxTokens,
            thinking: p.thinkingConfig,
            jsonOutput: true
        )

        let requestData = try JSONEncoder().encode(request)
        var urlRequest = buildURLRequest()
        // 单次超时不超过剩余预算；预算见底时不再新开请求
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 3 else {
            AppLog.log("[Zhipu] ✗ 总预算耗尽，放弃重试")
            throw ZhipuServiceError.networkError(URLError(.timedOut))
        }
        urlRequest.timeoutInterval = min(timeout, remaining)
        urlRequest.httpBody = requestData

        let startedAt = Date()
        AppLog.log("[Zhipu] → POST \(p.baseURL) model=\(p.model) body=\(requestData.count / 1024)KB thinking=\(request.thinking?.type ?? "n/a") retry=\(retryCount) timeout=\(Int(urlRequest.timeoutInterval))s")

        do {
            let (data, httpResponse) = try await perform(urlRequest)
            let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
            AppLog.log("[Zhipu] ← HTTP \(httpResponse.statusCode) after \(elapsed), \(data.count / 1024)KB")

            // 处理 HTTP 错误
            guard (200...299).contains(httpResponse.statusCode) else {
                if ZhipuServiceError.isRetryable(status: httpResponse.statusCode, body: data) && retryCount < maxRetryCount {
                    // 服务端给了 Retry-After 就听它的，否则用默认退避
                    let retryAfter = (httpResponse.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                    return try await retryAfterDelay(messages: messages, maxTokens: maxTokens, timeout: timeout, retryCount: retryCount, deadline: deadline, overrideDelay: retryAfter)
                }
                AppLog.log("[Zhipu] ✗ API error: \(String(data: data.prefix(500), encoding: .utf8) ?? "")")
                throw ZhipuServiceError.from(status: httpResponse.statusCode, body: data)
            }

            // 解析响应
            do {
                let apiResponse = try jsonDecoder.decode(ZhipuResponse.self, from: data)
                let choice = apiResponse.choices.first
                AppLog.log("[Zhipu] ✓ finish=\(choice?.finishReason ?? "nil") content=\(choice?.message.content?.count ?? 0)ch reasoning=\(choice?.message.reasoningContent?.count ?? 0)ch usage=\(apiResponse.usage?.completionTokens ?? -1)")
                return apiResponse
            } catch {
                AppLog.log("[Zhipu] ✗ decode failed: \(error) raw=\(String(data: data.prefix(500), encoding: .utf8) ?? "")")
                throw ZhipuServiceError.responseParsingFailed
            }

        } catch let error as ZhipuServiceError {
            AppLog.log("[Zhipu] ✗ \(error)")
            // 网络错误时进行重试
            if case .networkError = error, retryCount < maxRetryCount {
                return try await retryAfterDelay(messages: messages, maxTokens: maxTokens, timeout: timeout, retryCount: retryCount, deadline: deadline)
            }
            throw error
        } catch let error as URLError {
            AppLog.log("[Zhipu] ✗ URLError \(error.code.rawValue) \(error.localizedDescription) after \(String(format: "%.1fs", Date().timeIntervalSince(startedAt)))")
            // 用户取消（Esc 关面板）：不重试，直接抛出
            if error.code == .cancelled { throw ZhipuServiceError.networkError(error) }
            // URLSession 网络错误，进行重试
            if retryCount < maxRetryCount {
                return try await retryAfterDelay(messages: messages, maxTokens: maxTokens, timeout: timeout, retryCount: retryCount, deadline: deadline)
            }
            throw ZhipuServiceError.networkError(error)
        } catch {
            if error is CancellationError { throw ZhipuServiceError.networkError(error) }
            if retryCount < maxRetryCount {
                return try await retryAfterDelay(messages: messages, maxTokens: maxTokens, timeout: timeout, retryCount: retryCount, deadline: deadline)
            }
            throw ZhipuServiceError.networkError(error)
        }
    }

    /// 会员通道：发到我们的后台，带设备令牌和这次查词的用量号（重试也用同一个号，后台只算一次）。
    /// 令牌失效（401 bad-device）重新注册一次；用量号过了窗口（409 use-expired）换新号再发一次（会再算一次）；
    /// 上游暂时不可用、太频繁按退避重试；试用用完、每天上限这类直接报，并让会员状态跟着更新
    private func sendMemberRequest(messages: [ZhipuMessage], maxTokens: Int, timeout: TimeInterval, run: UUID) async throws -> ZhipuResponse {
        let route = await memberRoute()
        let deadline = Date().addingTimeInterval(max(overallBudget, timeout + 15))
        let body = try JSONEncoder().encode(ZhipuRequest(memberMessages: messages, temperature: 0.3, maxTokens: maxTokens, jsonOutput: true))
        var retries = 0, renewedToken = false, renewedUse = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 3 else {
                AppLog.log("[Member] ✗ 总预算耗尽，放弃重试")
                throw ZhipuServiceError.networkError(URLError(.timedOut))
            }
            let (built, token) = try await memberURLRequest(route, run: run, timeout: min(timeout, remaining))
            var request = built
            request.httpBody = body
            let startedAt = Date()
            AppLog.log("[Member] → POST chat body=\(body.count / 1024)KB retry=\(retries) timeout=\(Int(request.timeoutInterval))s")
            let data: Data, http: HTTPURLResponse
            do {
                let (d, response) = try await session.data(for: request)
                guard let h = response as? HTTPURLResponse else { throw ZhipuServiceError.invalidResponse }
                (data, http) = (d, h)
            } catch let error as ZhipuServiceError {
                throw error
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                AppLog.log("[Member] ✗ \(cancelled ? "cancelled" : "network \((error as? URLError)?.code.rawValue ?? 0)") after \(String(format: "%.1fs", Date().timeIntervalSince(startedAt)))")
                if !cancelled, retries < maxRetryCount {
                    try await backoff(retries)
                    retries += 1
                    continue
                }
                // 超时照旧说「迟迟没回应」；连不上说是我们的会员服务器连不上（不是你的 Key）
                if cancelled || (error as? URLError)?.code == .timedOut { throw ZhipuServiceError.networkError(error) }
                throw ZhipuServiceError.member(.network)
            }
            AppLog.log("[Member] ← HTTP \(http.statusCode) after \(String(format: "%.1fs", Date().timeIntervalSince(startedAt))), \(data.count / 1024)KB")
            if (200...299).contains(http.statusCode) {
                await route.noteResponse(headers: http.stringHeaders, error: nil)
                do {
                    return try jsonDecoder.decode(ZhipuResponse.self, from: data)
                } catch {
                    AppLog.log("[Member] ✗ decode failed: \(error) raw=\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
                    throw ZhipuServiceError.responseParsingFailed
                }
            }
            let error = MemberError.from(status: http.statusCode, body: data, headers: http.allHeaderFields)
            AppLog.log("[Member] ✗ \(http.statusCode) \(error.code)")
            if http.statusCode == 401, error.code == "bad-device", !renewedToken, await route.renewToken(token) {
                renewedToken = true
                continue
            }
            if error.code == "use-expired", !renewedUse {
                _ = await route.renewUse(for: run)
                renewedUse = true
                continue
            }
            if error.isRetryable, retries < maxRetryCount {
                try await backoff(retries, after: error.retryAfter)
                retries += 1
                continue
            }
            await route.noteResponse(headers: http.stringHeaders, error: error)
            throw ZhipuServiceError.member(error)
        }
    }

    /// 会员通道的一个请求：地址、设备令牌、这次查词的用量号。回请求和用的令牌（令牌被拒时拿它去换）
    private func memberURLRequest(_ route: any MemberRoute, run: UUID, timeout: TimeInterval) async throws -> (URLRequest, String) {
        let credentials: MemberCredentials
        do {
            credentials = try await route.credentials()
        } catch let error as MemberError {
            throw ZhipuServiceError.member(error)
        }
        var request = URLRequest(url: credentials.chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(await route.useID(for: run).uuidString.lowercased(), forHTTPHeaderField: "X-Use-Id")
        return (request, credentials.token)
    }

    private func backoff(_ retry: Int, after: TimeInterval? = nil) async throws {
        NotificationCenter.default.post(name: .zhipuRetrying, object: nil, userInfo: ["retry": retry + 1])
        let delay = after.map { min($0, 10) } ?? Double(retryDelays[min(retry, retryDelays.count - 1)]) / 1_000_000_000
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// 等待退避后重试；先广播一次，面板据此把副标题换成「正在重试」
    private func retryAfterDelay(messages: [ZhipuMessage], maxTokens: Int, timeout: TimeInterval, retryCount: Int, deadline: Date, overrideDelay: TimeInterval? = nil) async throws -> ZhipuResponse {
        NotificationCenter.default.post(name: .zhipuRetrying, object: nil, userInfo: ["retry": retryCount + 1])
        let delay = overrideDelay.map { min($0, 10) } ?? Double(retryDelays[retryCount]) / 1_000_000_000
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return try await sendRequest(messages: messages, maxTokens: maxTokens, timeout: timeout, retryCount: retryCount + 1, deadline: deadline)
    }

    /// 发一次请求。发往智谱的报了换个接口可能就好的错（ZhipuEndpoint.shouldSwitch），同一个请求发到另一个接口：
    /// 那边成功就记下它、用它的回答；那边也不行（或连不上）就还是报第一个接口的错。
    /// 语法拆解的流式请求不走这里：它总在一次查词之后，接口已经定下了。
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ZhipuServiceError.invalidResponse }
        guard ZhipuEndpoint.shouldSwitch(status: http.statusCode, body: data),
              let alt = ZhipuEndpoint.alternative(to: request) else { return (data, http) }
        let code = ZhipuErrorResponse.error(in: data)?.code ?? ""
        AppLog.log("[Zhipu] \(alt.endpoint.other.rawValue) 接口报 \(code)，换 \(alt.endpoint.rawValue) 接口再发一次")
        if let reply = try? await session.data(for: alt.request), let other = reply.1 as? HTTPURLResponse {
            if (200...299).contains(other.statusCode) {
                ZhipuEndpoint.current = alt.endpoint
                AppLog.log("[Zhipu] ✓ \(alt.endpoint.rawValue) 接口可以用，以后先用它")
                return (reply.0, other)
            }
            AppLog.log("[Zhipu] ✗ \(alt.endpoint.rawValue) 接口也不行：HTTP \(other.statusCode) \(String(data: reply.0.prefix(300), encoding: .utf8) ?? "")")
        }
        return (data, http)
    }

    /// 构建 URL 请求
    private func buildURLRequest(provider p: APIProvider? = nil) -> URLRequest {
        let prov = p ?? provider
        var request = URLRequest(url: URL(string: prov.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = key(for: prov) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if prov == .openrouter {
            request.setValue("GetNewWord", forHTTPHeaderField: "X-Title")   // OpenRouter 后台按应用名统计
        }
        // 与专用 session 的超时配置保持一致（请求 5 分钟）
        request.timeoutInterval = 300
        return request
    }

    /// 构建单词分析 Prompt
    /// - Parameter scene: 场景说明；nil = 截图红框（默认），指词查词时换成「目标词 + OCR 语境文字」
    private func buildWordAnalysisPrompt(existingTags: [String], categoryTree: String, scene: String? = nil) -> String {
        return """
        ## 分类体系规则（重要）
        用户维护了一个固定的分类体系，每个条目必须归入体系里的一个叶子分类，避免体系越来越乱。
        当前分类体系：
        \(categoryTree.isEmpty ? "（空）" : categoryTree)
        - 单词只能归入「语言学习」下的分类（按语言），知识片段只能归入「知识片段」下的分类（按领域）。
        - `category` 只能填体系里**已有**的叶子分类名（原样照抄，如 "英语"、"健身"）。
        - 只有当体系里确实没有合适的分类时，`category` 给 null，并把建议的新分类名放进 `suggestedCategory`（中文，2–4 字，如 "驾驶"、"法律"）；用户会确认是否新建。
        - 不要用同义词绕过已有分类（例如已有「健身」就不要建议「运动」「workout」）。

        ## 标签
        - 不使用标签：`tags` 一律返回 []（分组一律用分类体系表达）。

        """ + (scene ?? "这是一张屏幕截图，是外语学习取词场景。图中**红色方框**是用户圈选的目标（通常是 1 个单词或短语），红框外的内容是它的上下文。") + """


        ## 首先判定红框内容的类型（二选一，不要两者都给）
        - 红框内是**一个单词或短语**（大致 ≤5 个词）→ 这是查词：只填 words（就 1 个词条），snippets 给 []。
        - 红框内是**一整句话或一段话**（一条规则、一个知识点）→ 这是记知识：只填 snippets（整理成 1 条），words 给 []。段落里的个别生词不要单独立词条。

        请完成以下任务：
        1. 查词时只分析**红框内**的那个词/短语（不要解释红框外的词），红框外只作语境。
        2. 对每个单词提供：
           - 单词原文（词典形式，如动词原形、名词单数；**不要带冠词**——德语名词写 "Vorfahrt" 而不是 "die Vorfahrt"，冠词放进 grammar）。红框里是**短语**时，word 必须是**完整短语**的词典形式（保留全部单词，只把中心词还原原形，如 "Traffic confluences" → "traffic confluence"），**绝不能只取中心词**
           - 音标（国际音标）
           - 语言（de=德语, en=英语, fr=法语等）
           - meaning：该词**常见的 2–4 个义项**，**按词性分组**：每组以词性缩写开头（v. / n. / adj. / adv. / prep.），组内义项用"；"分隔，多个词性之间用 " ｜ " 分隔，如 "v. 规定；开处方 ｜ n. 处方"；只有一个词性也要标前缀（如 "adj. 无阻碍的；畅通的"）。当前语境的词性组放最前
           - contextMeaning：当前语境对应的那个义项（**不带词性前缀**，必须与 meaning 里该义项的写法**逐字一致**，用于高亮）
           - contextSentence：红框所在的**完整原文句子**（从红框外的上下文里补全，不要截断）
           - contextTranslation：该句子的中文翻译，按下方「译文要求」写。目标词怎么译以整句通顺为准，**不必照搬 contextMeaning 的字面**——义项是词典释义，译文是给人读的句子（如 contextMeaning 是"驱使；迫使"，译文里可以是"逼得"）
           - translationKeyword：**译文写好之后**，从译文里逐字摘出对应目标词的那几个字（必须是译文的连续子串，如下方例句译文里对应 along with 的是"加上"）；意译后目标词融进整句、拆不出对应的字就给 ""。**一致性**：译文表达的必须是 contextMeaning 这个义项（措辞可以不同）；意思对不上时改 contextMeaning，不要为了凑字面把译文改生硬
           - grammar：**德语必填**——名词给「冠词 + 单数, 复数」如 "der Fahrer, die Fahrer"；动词给「可分/不可分 · 第三人称现在时 · 过去式 · 过去分词（助动词）」如 "trennbar · hält an · hielt an · hat angehalten"；形容词给比较级/最高级。英语等其他语言：不规则变化才填，否则 ""。
           - 难度等级（a1/a2/b1/b2/c1/c2）
        3. 译文要求（contextTranslation）：像中文母语的译者那样译，读起来不像翻译。
           - 先吃透整句意思，再按中文语序和说法重新组织；可以调语序、拆句，把名词化结构改成动词。
           - 避免翻译腔：不滥用"被""进行""一个""它们""当……的时候"和成串的"的"；along with、including、such as 这类连接词按中文习惯处理（"和""及其""比如"），不硬译成"连同""包括……在内"。
           - 按文体定语气：字幕、推文、聊天用口语；美食、生活类用中文里本来的叫法（口感的 chewy 是"有嚼劲"，菜单上的 side 是"配菜"）；技术文档、报错信息用该领域的通行译法（string literal 是"字符串字面量"）；俚语和梗译出实际意思。
           - 不增不减：不加原文没有的信息，不漏原文的意思；原文明显断在半句时（如结尾是 and、the、to）才在译文结尾用"……"，意思完整的不加。
           - 例：The new policy, along with rising costs, has driven many small shops out of business.
             ✗ 新政策连同不断上涨的成本，已经把许多小商店驱赶出了生意。
             ✓ 新政策加上成本不断上涨，已经逼得不少小店关了门。
        4. 固定搭配：红框里的词和紧挨着的词组成固定搭配或术语时（如 compound interest「复利」、take off「起飞」），word 仍是红框里的词，但 contextMeaning 写它在这个搭配里的意思（如「复利的」），usage 第一句先点出这个搭配和它的意思，translationKeyword 摘译文里对应整个搭配的词（如「复利」）。translationKeyword 要摘完整的词，不要只摘一个字（「复利」而不是「复」）。
        5. snippets：仅当第一步判定为"记知识"时填写（交通规则、健身要点、医学常识、题目要点等），整理成 1 条，此时 words 必须是 []。**words 和 snippets 永远二选一，绝不能同时给**——记知识时段落里的生词也不要立词条。
        6. 保持简洁，不要输出多余字段。

        请严格以 JSON 格式返回，格式如下：
        {
          "words": [
            {
              "word": "单词",
              "phonetic": "音标",
              "language": "de",
              "meaning": "义项1；义项2；义项3",
              "contextMeaning": "义项1",
              "contextSentence": "原文句子",
              "contextTranslation": "中文翻译",
              "translationKeyword": "译文中对应目标词的那几个字",
              "grammar": "der Fahrer, die Fahrer",
              "difficulty": "b1",
              "tags": [],
              "category": "体系里已有的叶子分类名，或 null",
              "suggestedCategory": "仅当 category 为 null 时给建议的新分类名，否则 null"
            }
          ],
          "snippets": [
            {
              "title": "知识标题",
              "content": "结构化知识内容",
              "sourceContext": "原始上下文",
              "tags": [],
              "category": "体系里已有的叶子分类名，或 null",
              "suggestedCategory": null
            }
          ]
        }

        只返回 JSON，不要有其他内容。
        """ + Self.targetLanguageRule(fields: "meaning、contextMeaning、contextTranslation、translationKeyword、snippets 的 title 和 content")
    }

    /// 目标语言不是简体中文时，追加在提示词末尾，覆盖上文「中文」的要求（上文的译文规则照样适用于目标语言）
    static func targetLanguageRule(fields: String) -> String {
        let t = TargetLanguage.current
        guard t != .zhHans else { return "" }
        return """


        ## 输出语言（覆盖上文所有「中文」「简体中文」的要求）
        \(fields) 一律用\(t.promptName)写，像\(t.promptName)母语者写的，不要翻译腔；上文的中文例子只说明要求，不要照抄成中文。
        如果目标词本身就是\(t.promptName)，释义用\(t.promptName)写单语词典式解释，contextTranslation 用更浅白的\(t.promptName)把整句改写一遍（不要原样照抄原句）。分类名照抄体系里已有的写法；suggestedCategory 用\(t.promptName)。
        """
    }

    // MARK: - 极速识词（先出词头 + 发音）

    struct QuickWord: Codable, Sendable {
        let word: String
        let language: String
    }

    /// 只认红框里的词（输出 ~15 token，2 秒级）：面板词头和发音靠它先出
    func quickExtract(_ image: NSImage, useID: UUID? = nil) async throws -> QuickWord {
        guard let dataURL = ImageEncoder.toCompressedDataURL(image, maxDimension: 1000, quality: 0.75) else {
            throw ZhipuServiceError.imageEncodingFailed
        }
        let prompt = """
        图中红框是用户圈选的目标。先判断类型，再只返回 JSON：
        - 红框内是一个单词或短语（大致 ≤5 个词）→ {"word": "词典形式（名词不带冠词；短语保留完整，只把中心词还原原形，如 "Traffic confluences" → "traffic confluence"，不要只取中心词）", "language": "en/de/fr/es/ja/ko/zh"}
        - 红框内是一整句话/一段话/一道题（知识点）→ {"word": "", "language": ""}
        """
        let message = ZhipuMessage(role: "user", content: [.imageUrl(dataURL), .text(prompt)])
        // 256：给完整 JSON 留余量（V4 会把少量内部框架计入输出预算，100 会被截断）
        // 15s 太紧：26 次超时里 12 次卡在 15.0–15.2s，而同期成功样本 p99=21.7s、最慢 56s，
        // 等于把本来会回来的请求掐死再重传整张图。给 35s，总时长由 overallBudget 兜
        let response = try await sendRequest(messages: [message], maxTokens: 256, timeout: 35, useID: useID)
        guard let content = response.choices.first?.message.content,
              let data = extractJSON(from: content).data(using: .utf8),
              let q = try? jsonDecoder.decode(QuickWord.self, from: data) else {
            throw ZhipuServiceError.responseParsingFailed
        }
        return q
    }

    // MARK: - 语法分解（SSE 流式，边生成边显示）

    /// 流式 chunk 的最小解码结构：只取 choices[0].delta.content
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]
    }

    /// 把语境整句完全拆解（主干 → 各成分 → 词形/时态 → 直译对照）。
    /// 纯文本 Markdown、SSE 流式：每到一段就回调 `onDelta`，面板把它拼在「释义」上方。
    /// 不走 `sendRequest` 的 JSON/重试逻辑：流式失败直接抛出，由调用方提示。
    func streamGrammarBreakdown(sentence: String, word: String, language: String, useID: UUID? = nil,
                                onDelta: @escaping @Sendable (String) -> Void) async throws {
        let member = memberMode()
        if !member { guard let key = apiKey, !key.isEmpty else { throw ZhipuServiceError.apiKeyNotConfigured } }
        let prompt = """
        请把下面这句话的语法**完全拆解**，面向正在学这门语言的中文使用者。
        句子：\(sentence)
        语言代码：\(language)；用户刚查的词：\(word)

        要求（用简体中文，Markdown，直接开始，不要任何开场白或总结）：
        1. **主干**：一行写出句子主干（主语 / 谓语 / 宾语或表语），用 `**原文片段**` 标出每个成分。
        2. **成分逐个拆**：按原句顺序，每个成分一行：`**原文片段**` → 它是什么（从句 / 不定式 / 分词短语 / 介词短语 / 状语…）→ 修饰谁、在句中做什么。从句要再拆到内部主谓宾。
        3. **动词与形态**：时态、语态、语气；德语标出格（Nominativ/Akkusativ/Dativ/Genitiv）、性数、动词位置（V2 / 句尾）、可分动词；法语/西语标出时态与性数配合；日语标出助词与活用形。
        4. **难点**：1–3 条最容易看错的地方（省略、倒装、指代、固定搭配）。
        5. **直译对照**：按原句语序逐段对照的中文，用 " / " 分隔各段；最后一行给通顺译文。
        每节用二级标题（`## 主干` `## 成分` `## 动词与形态` `## 难点` `## 直译对照`），总长控制在 350 字以内。
        """ + Self.targetLanguageRule(fields: "全部讲解、二级标题、直译对照和通顺译文")
        let p = provider
        let messages = [ZhipuMessage(role: "user", content: [.text(prompt)])]
        let body = try JSONEncoder().encode(member
            ? ZhipuRequest(memberMessages: messages, temperature: 0.3, maxTokens: 2048, stream: true)
            : ZhipuRequest(provider: p, messages: messages, temperature: 0.3, maxTokens: 2048, thinking: p.thinkingConfig, stream: true))
        let startedAt = Date()
        let route: (any MemberRoute)? = member ? await memberRoute() : nil
        let run = useID ?? UUID()
        var renewedToken = false, renewedUse = false
        var opened: URLSession.AsyncBytes?
        while opened == nil {
            var urlRequest: URLRequest
            var token = ""
            if let route {
                (urlRequest, token) = try await memberURLRequest(route, run: run, timeout: 90)
            } else {
                urlRequest = buildURLRequest()
                urlRequest.timeoutInterval = 90
            }
            urlRequest.httpBody = body
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            AppLog.log("[Zhipu] → POST(stream) \(urlRequest.url?.absoluteString ?? "") model=\(member ? "member" : p.model) grammar for '\(word)' (\(sentence.prefix(60)))")
            let (stream, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ZhipuServiceError.invalidResponse }
            if (200...299).contains(http.statusCode) {
                if let route { await route.noteResponse(headers: http.stringHeaders, error: nil) }
                opened = stream
                continue
            }
            var text = ""
            for try await line in stream.lines { text += line; if text.count > 800 { break } }
            AppLog.log("[Zhipu] ✗ stream HTTP \(http.statusCode): \(text.prefix(300))")
            guard let route else { throw ZhipuServiceError.from(status: http.statusCode, body: Data(text.utf8)) }
            let error = MemberError.from(status: http.statusCode, body: Data(text.utf8), headers: http.allHeaderFields)
            if error.code == "bad-device", !renewedToken, await route.renewToken(token) { renewedToken = true; continue }
            if error.code == "use-expired", !renewedUse { _ = await route.renewUse(for: run); renewedUse = true; continue }
            await route.noteResponse(headers: http.stringHeaders, error: error)
            throw ZhipuServiceError.member(error)
        }
        guard let bytes = opened else { throw ZhipuServiceError.invalidResponse }

        var total = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? jsonDecoder.decode(StreamChunk.self, from: data),
                  let piece = chunk.choices.first?.delta?.content, !piece.isEmpty else { continue }
            total += piece.count
            onDelta(piece)
        }
        AppLog.log("[Zhipu] ✓ stream done \(total)ch after \(String(format: "%.1fs", Date().timeIntervalSince(startedAt)))")
        if total == 0 { throw ZhipuServiceError.invalidResponse }
    }

    // MARK: - 二段式：例句/助记/词根词源（纯文本请求，不带图，快）

    func enrichWord(word: String, language: String, meaning: String = "", sentence: String = "", useID: UUID? = nil) async throws -> WordEnrichment {
        let prompt = """
        为这个外语单词生成学习辅助内容。
        单词：\(word)（语言代码 \(language)）\(meaning.isEmpty ? "" : "\n释义：\(meaning)")\(sentence.isEmpty ? "" : "\n语境句：\(sentence)")

        只返回 JSON：
        {
          "meaning": "释义按词性分组重写：每组以词性缩写开头（v. / n. / adj. / adv. / prep.），组内义项用"；"分隔，组间用 " ｜ " 分隔，如 "v. 规定；开处方 ｜ n. 处方"。**保留上面给出释义的原义项措辞**，只做分组加前缀，不增删义项；没给释义才自己生成 2–4 个义项",
          "usage": "用法分析（易错点、语气，2 句以内；搭配放 collocations 里）",
          "collocations": ["常用搭配 —— 中文", "第二条 —— 中文", "第三条 —— 中文"],
          "examples": ["新造的外语例句 —— 中文翻译", "第二条 —— 中文翻译"],
          "etymology": "词根词源（词根含义 + 来源，1–2 句；太简单的词给 \"\"）"
        }
        例句不要重复语境句，贴近日常或驾考场景。有语境句时，usage 先讲它在语境句里的用法；它在语境句里是固定搭配的一部分（如 compound interest）就先点出这个搭配，collocations 第一条放这个搭配，别先讲和语境无关的义项。
        """ + Self.targetLanguageRule(fields: "meaning、usage、etymology，以及 collocations 和 examples 里 —— 后面的译文")
        let response = try await sendRequest(messages: [ZhipuMessage(role: "user", content: [.text(prompt)])], useID: useID)
        guard let content = response.choices.first?.message.content,
              let data = extractJSON(from: content).data(using: .utf8),
              let enrichment = try? jsonDecoder.decode(WordEnrichment.self, from: data) else {
            throw ZhipuServiceError.responseParsingFailed
        }
        return enrichment
    }

    /// 解析模型返回的分析结果
    /// - Parameter content: 模型返回的文本内容
    /// - Returns: 解析后的分析结果
    private func parseAnalysisResult(from content: String) throws -> WordAnalysisResult {
        // 策略 1：直接解析
        if let data = content.data(using: .utf8),
           let result = try? jsonDecoder.decode(WordAnalysisResult.self, from: data) {
            return result
        }

        // 策略 2：从 markdown 代码块中提取 JSON
        let jsonContent = extractJSON(from: content)

        if let data = jsonContent.data(using: .utf8),
           let result = try? jsonDecoder.decode(WordAnalysisResult.self, from: data) {
            return result
        }

        // 策略 3：尝试修复常见的 JSON 格式问题
        let cleaned = cleanJSON(jsonContent)
        if let data = cleaned.data(using: .utf8),
           let result = try? jsonDecoder.decode(WordAnalysisResult.self, from: data) {
            return result
        }

        // 策略 4：模型偶尔把对象包进数组返回（[{words:…}, {answer:…}]）——逐元素找能解出来的那个
        for candidate in [content, jsonContent, cleaned] {
            guard let data = candidate.data(using: .utf8),
                  let anyArr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { continue }
            for el in anyArr {
                if let elData = try? JSONSerialization.data(withJSONObject: el),
                   let result = try? jsonDecoder.decode(WordAnalysisResult.self, from: elData),
                   !(result.words.isEmpty && result.snippets.isEmpty) {
                    return result
                }
            }
        }

        // 记下真正的解码错误和完整内容，下次不用再猜是缺了哪个字段
        let reason: String = {
            guard let data = content.data(using: .utf8) else { return "not utf8" }
            do { _ = try jsonDecoder.decode(WordAnalysisResult.self, from: data); return "?" } catch { return "\(error)" }
        }()
        AppLog.log("[Zhipu] ✗ JSON parse failed: \(reason.prefix(300)) | content: \(String(content.prefix(1500)))")
        throw ZhipuServiceError.responseParsingFailed
    }

    /// 从文本中提取 JSON 内容（处理 markdown 代码块包裹的情况）
    func extractJSON(from text: String) -> String {
        // 匹配 ```json ... ``` 或 ``` ... ```
        let patterns = [
            "```json\\s*\\n([\\s\\S]*?)\\n\\s*```",
            "```\\s*\\n([\\s\\S]*?)\\n\\s*```"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
               let match = regex.firstMatch(
                   in: text,
                   range: NSRange(text.startIndex..., in: text)
               ),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }

        // 尝试找到第一个 { 和最后一个 } 之间的内容
        if let firstBrace = text.firstIndex(of: "{"),
           let lastBrace = text.lastIndex(of: "}") {
            return String(text[firstBrace...lastBrace])
        }

        return text
    }

    /// 清理 JSON 字符串中的常见问题
    private func cleanJSON(_ json: String) -> String {
        var cleaned = json.trimmingCharacters(in: .whitespacesAndNewlines)

        // 移除尾随逗号（在 } 或 ] 前的逗号）
        cleaned = cleaned.replacingOccurrences(
            of: ",\\s*([}\\]])",
            with: "$1",
            options: .regularExpression
        )

        return cleaned
    }
}


extension Notification.Name {
    /// 请求超时/失败后即将重试（userInfo["retry"] = 第几次）
    static let zhipuRetrying = Notification.Name("GetNewWord.zhipuRetrying")
}
