// AnkiService.swift
// GetNewWord
//
// Anki 集成服务：封装 AnkiConnect HTTP API，提供牌组管理、笔记 CRUD、
// 单词同步及内容臃肿治理功能

import Foundation
import SwiftData

// MARK: - AnkiError

enum AnkiError: LocalizedError {
    case notRunning
    case apiError(String)
    case networkError(Error)
    case invalidResponse
    case modelNotFound
    case deckCreationFailed

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return String(localized: "Anki 未运行，请先启动 Anki")
        case .apiError(let msg):
            return String(localized: "Anki API 错误：\(msg)")
        case .networkError(let err):
            return String(localized: "网络错误：\(err.localizedDescription)")
        case .invalidResponse:
            return String(localized: "Anki 返回了无效的响应数据")
        case .modelNotFound:
            return String(localized: "未找到 GetNewWord 卡片模板")
        case .deckCreationFailed:
            return String(localized: "牌组创建失败")
        }
    }
}

// MARK: - 字段缓存

final class AnkiFieldCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String: Set<String>] = [:]

    func get(_ model: String) -> Set<String>? { lock.withLock { fields[model] } }
    func set(_ model: String, _ names: Set<String>) { lock.withLock { fields[model] = names } }
    func reset() { lock.withLock { fields = [:] } }
}

// MARK: - AnkiService

final class AnkiService: @unchecked Sendable {
    static let shared = AnkiService()

    #if DEBUG
    /// 开发版量卡顿时可以指到假的 AnkiConnect（GNW_ANKI_URL），不碰本机真开着的 Anki
    private let baseURL = ProcessInfo.processInfo.environment["GNW_ANKI_URL"] ?? "http://127.0.0.1:8765"
    #else
    private let baseURL = "http://127.0.0.1:8765"
    #endif
    /// 单元测试换成假的 AnkiConnect，不碰本机真开着的 Anki
    var session = URLSession.shared
    let modelName = AppVariant.ankiName
    private let rootDeckName = AppVariant.ankiName

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let jsonDecoder = JSONDecoder()

    /// 每个笔记类型现在有哪些字段（ensure 时读到的）。用户选了「以后再说」、字段还没加的时候，同步只写已有的字段
    let fieldCache = AnkiFieldCache()
    /// 这次启动是不是已经核对过卡片样式和字段（核对一次就够，不用每次保存都问 Anki）
    @MainActor var cardsChecked = false

    private init() {}

    /// 只留下笔记类型里有的字段；还不知道笔记类型有什么字段时原样返回
    func onlyKnownFields(_ fields: [String: String], model: String) -> [String: String] {
        guard let known = fieldCache.get(model), !known.isEmpty else { return fields }
        return fields.filter { known.contains($0.key) }
    }

    // MARK: - 底层通信

    /// 发送 AnkiConnect 请求并解码响应
    func send<T: Codable>(action: String, params: [String: Any]? = nil, as type: T.Type) async throws -> T {
        let request = AnkiConnectRequest(action: action, params: params)
        let body = try jsonEncoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AnkiError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnkiError.invalidResponse
        }

        let ankiResponse = try jsonDecoder.decode(AnkiConnectResponse<T>.self, from: data)

        if let error = ankiResponse.error, !error.isEmpty {
            throw AnkiError.apiError(error)
        }

        guard let result = ankiResponse.result else {
            throw AnkiError.invalidResponse
        }

        return result
    }

    /// 发送无返回值的请求（result 可能为 null）
    func sendVoid(action: String, params: [String: Any]? = nil) async throws {
        let request = AnkiConnectRequest(action: action, params: params)
        let body = try jsonEncoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AnkiError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnkiError.invalidResponse
        }

        // result 可能是 null / bool / 数字 / 对象（createDeck 返回 id，createModel 返回模型），一律宽松解码
        let ankiResponse = try jsonDecoder.decode(AnkiConnectResponse<AnyCodable>.self, from: data)
        if let error = ankiResponse.error, !error.isEmpty {
            AppLog.log("[Anki] \(action) error: \(error)")
            throw AnkiError.apiError(error)
        }
    }

    // MARK: - Connection

    /// 检查 Anki 是否正在运行
    func isAnkiRunning() async -> Bool {
        do {
            let _: Int = try await send(action: "version", as: Int.self)
            return true
        } catch {
            return false
        }
    }

    /// 获取 Anki 版本
    func version() async throws -> Int {
        try await send(action: "version", as: Int.self)
    }

    // MARK: - Deck Management

    /// 获取所有牌组名称（排除 Default 空牌组）
    func deckNames() async throws -> [String] {
        let names: [String] = try await send(action: "deckNames", as: [String].self)
        return names.filter { $0 != "Default" }
    }

    /// 创建牌组
    func createDeck(name: String) async throws {
        try await sendVoid(action: "createDeck", params: ["deck": name])
    }

    /// 确保牌组存在（不存在则创建）
    func ensureDeckExists(name: String) async throws {
        let existing = try await deckNames()
        if !existing.contains(name) {
            try await createDeck(name: name)
        }
    }

    // MARK: - Note Management

    /// 添加笔记（卡片），返回笔记 ID
    func addNote(
        deckName: String,
        modelName: String,
        fields: [String: String],
        tags: [String]
    ) async throws -> Int {
        let note: [String: Any] = [
            "deckName": deckName,
            "modelName": modelName,
            "fields": fields,
            "tags": tags,
            "options": [
                "allowDuplicate": false,
                "duplicateScope": "deck",
                "duplicateScopeOptions": [
                    "deckName": deckName,
                    "checkChildren": true
                ]
            ] as [String: Any]
        ]
        let noteId: Int = try await send(action: "addNote", params: ["note": note], as: Int.self)
        return noteId
    }

    /// 更新笔记字段
    func updateNoteFields(noteId: Int, fields: [String: String]) async throws {
        let note: [String: Any] = [
            "id": noteId,
            "fields": fields
        ]
        try await sendVoid(action: "updateNoteFields", params: ["note": note])
    }

    /// 关键词高亮：大小写不敏感匹配整词 + ≥4 字符共同前缀的词形变化，包 <span class="kw">
    static func hl(_ text: String, word: String) -> String {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, w.count >= 2 else { return text }
        var pattern = NSRegularExpression.escapedPattern(for: w)
        if w.count >= 4 {
            let stem = NSRegularExpression.escapedPattern(for: String(w.prefix(max(4, w.count - 2))))
            pattern = "\(pattern)|\(stem)[\\p{L}]*"
        }
        guard let re = try? NSRegularExpression(pattern: "(\(pattern))", options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<span class=\"kw\">$1</span>")
    }

    /// 中文译文里高亮语境义项（面板/卡片的译文高亮同源）；整串没命中就拆子义项
    static func hlSense(_ text: String, sense: String?, keyword: String? = nil) -> String {
        if let k = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty, text.contains(k) {
            return text.replacingOccurrences(of: k, with: "<span class=\"kw\">\(k)</span>")
        }
        guard let s = sense?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !text.isEmpty else { return text }
        if text.contains(s) {
            return text.replacingOccurrences(of: s, with: "<span class=\"kw\">\(s)</span>")
        }
        var out = text
        for p in s.components(separatedBy: CharacterSet(charactersIn: "，,、；;／/ ")) {
            let t = p.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, out.contains(t), !out.contains("<span class=\"kw\">\(t)") else { continue }
            out = out.replacingOccurrences(of: t, with: "<span class=\"kw\">\(t)</span>")
        }
        return out
    }

    /// Back 字段：整个义项列表，按词性一组一个 <div class="pos-group">，组之间放藏起来的 " ｜ "，这句里的义项包 <b>。
    /// 去掉标签后文字和 word.meaning 一字不差（词性后面的空格也原样保留），恢复词库时 stripHTML 能原样还原
    static func emphasizedMeaningHTML(_ word: WordEntry) -> String {
        let separator = " ｜ "
        let groups = word.meaning.components(separatedBy: separator)
        let sense = word.contextMeaning.flatMap { $0.isEmpty ? nil : $0 }
        var boldAt: Int?
        if let sense {
            boldAt = groups.firstIndex { $0.contains(sense) }
            if boldAt == nil, word.meaning.contains(sense) {
                // 义项跨了词性组（写法很怪的老数据）：不分组，整段里标出来
                return word.meaning.replacingOccurrences(of: sense, with: "<b>\(sense)</b>")
            }
        }
        let html = groups.enumerated().map { i, group -> String in
            var text = group
            if let sense, i == boldAt, let r = text.range(of: sense) {
                text.replaceSubrange(r, with: "<b>\(sense)</b>")
            }
            if let m = text.firstMatch(of: /^([A-Za-z]{1,8}\.(?:[\/&][A-Za-z]{1,8}\.)*)(\s*)/) {
                text = "<span class=\"pos\">\(m.1)</span>\(m.2)" + text[m.range.upperBound...]
            }
            return "<div class=\"pos-group\">\(text)</div>"
        }
        return html.joined(separator: "<span class=\"sep\">\(separator)</span>")
    }

    /// 卡片背面「AI 解释」的四段。小标题按界面语言写（中英德）；class 里带上是哪一段（lbl-usage 等），
    /// 从 Anki 恢复时认 class，不认文字。1.2.0 以前的卡只有 class="lbl" 和中文小标题，按 legacyLabel 认
    enum AnalysisSection: String, CaseIterable {
        case usage, coll, ex, ety

        var label: String {
            switch self {
            case .usage: return String(localized: "用法")
            case .coll: return String(localized: "搭配")
            case .ex: return String(localized: "例句")
            case .ety: return String(localized: "词根词源")
            }
        }

        var legacyLabel: String {
            switch self {
            case .usage: return "用法"
            case .coll: return "搭配"
            case .ex: return "例句"
            case .ety: return "词根词源"
            }
        }

        var labelHTML: String { "<div class=\"lbl lbl-\(rawValue)\">\(label)</div>" }
    }

    /// 卡片背面的「AI 解释」：用法 + 搭配 + 例句 + 词根词源
    static func composeAnalysisHTML(_ word: WordEntry) -> String {
        var parts: [String] = []
        func line(_ raw: String) -> String {
            // "原句 —— 中文" 拆两行：外语行高亮关键词，中文行灰色小字
            let comps = raw.components(separatedBy: "——")
            let foreign = Self.hl(comps[0].trimmingCharacters(in: .whitespaces), word: word.word)
            if comps.count > 1 {
                let zh = comps.dropFirst().joined(separator: "——").trimmingCharacters(in: .whitespaces)
                return "<div class=\"ctx\">\(foreign)<div class=\"zh\">\(zh)</div></div>"
            }
            return "<div class=\"ctx\">\(foreign)</div>"
        }
        if !word.analysisNote.isEmpty {
            parts.append("\(AnalysisSection.usage.labelHTML)<div class=\"usage\">\(hl(word.analysisNote, word: word.word))</div>")
        }
        if let c = word.collocationsText, !c.isEmpty {
            parts.append("\(AnalysisSection.coll.labelHTML)<div class=\"sec\">\(c.components(separatedBy: "\n").map(line).joined())</div>")
        }
        if let ex = word.examplesText, !ex.isEmpty {
            parts.append("\(AnalysisSection.ex.labelHTML)<div class=\"sec\">\(ex.components(separatedBy: "\n").map(line).joined())</div>")
        }
        if let e = word.etymology, !e.isEmpty {
            parts.append("\(AnalysisSection.ety.labelHTML)<div class=\"sec\">\(e)</div>")
        }
        return parts.joined(separator: "")
    }

    /// 按 noteId 批量删卡（Anki 没开就静默跳过）。
    /// 注意：调用方必须在删除本地实体**之前**取好 noteId——SwiftData 对象删除后属性不可再读。
    @MainActor
    func deleteAnkiNotes(ids: [Int]) async {
        guard !ids.isEmpty else { return }
        guard await isAnkiRunning() else { AppLog.log("[Anki] not running, cannot delete \(ids.count) notes"); return }
        try? await deleteNotes(noteIds: ids)
        AppLog.log("[Anki] deleted \(ids.count) note(s)")
    }

    /// 删除片段对应的 Anki 卡：有 noteId 用 noteId，老数据回退按标题查
    @MainActor
    func deleteAnkiNote(forSnippet noteId: Int?, title: String) async {
        if let noteId {
            await deleteAnkiNotes(ids: [noteId])
        } else {
            await deleteAnkiNote(forSnippetTitle: title)
        }
    }

    /// 删除某条知识片段在 Anki 里的卡（按标题查）
    @MainActor
    func deleteAnkiNote(forSnippetTitle title: String) async {
        guard await isAnkiRunning() else { return }
        let clean = title.replacingOccurrences(of: "\"", with: "")
        if let notes = try? await findNotes(query: "\"note:\(snippetModelName)\" \"Title:\(clean)\""), !notes.isEmpty {
            try? await deleteNotes(noteIds: notes)
            AppLog.log("[Anki] deleted \(notes.count) snippet note(s) titled '\(title)'")
        }
    }

    /// 把一条笔记的所有卡片移动到指定牌组（分类改名/移动后保持 Anki 牌组对齐）
    func moveNote(_ noteId: Int, toDeck deck: String) async throws {
        let cards: [Int] = try await send(action: "findCards", params: ["query": "nid:\(noteId)"], as: [Int].self)
        guard !cards.isEmpty else { return }
        try await sendVoid(action: "changeDeck", params: ["cards": cards, "deck": deck])
    }

    /// 删除笔记
    func deleteNotes(noteIds: [Int]) async throws {
        try await sendVoid(action: "deleteNotes", params: ["notes": noteIds])
    }

    /// 暂停卡片（从复习中移除）
    func suspendCards(cardIds: [Int]) async throws {
        try await sendVoid(action: "suspend", params: ["cards": cardIds])
    }

    /// 恢复卡片
    func unsuspendCards(cardIds: [Int]) async throws {
        try await sendVoid(action: "unsuspend", params: ["cards": cardIds])
    }

    // MARK: - Card Queries

    /// 查找笔记 ID
    func findNotes(query: String) async throws -> [Int] {
        try await send(action: "findNotes", params: ["query": query], as: [Int].self)
    }

    /// 获取笔记信息
    func notesInfo(notes: [Int]) async throws -> [AnkiNoteInfo] {
        try await send(action: "notesInfo", params: ["notes": notes], as: [AnkiNoteInfo].self)
    }

    /// 获取牌组中的卡片数量
    func cardCount(query: String) async throws -> Int {
        // cardCount 可能返回 Int 或 String，统一处理
        let request = AnkiConnectRequest(action: "cardNames", params: ["query": query])
        let body = try jsonEncoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, _) = try await session.data(for: urlRequest)
        let response = try jsonDecoder.decode(AnkiConnectResponse<[String]>.self, from: data)
        return response.result?.count ?? 0
    }

    /// 获取今日复习数
    func getReviewsToday() async throws -> Int {
        // 返回格式为 [[timestamp, ...], ...] 的数组，取总数
        let request = AnkiConnectRequest(action: "getReviewsToday")
        let body = try jsonEncoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, _) = try await session.data(for: urlRequest)
        let response = try jsonDecoder.decode(AnkiConnectResponse<[[Int]]>.self, from: data)
        guard let result = response.result else { return 0 }
        return result.reduce(0) { $0 + $1.count }
    }

    // MARK: - Model Management

    /// 获取所有模型名称
    func modelNames() async throws -> [String] {
        try await send(action: "modelNames", as: [String].self)
    }

    // MARK: - Media

    /// 存储媒体文件到 Anki（data 为 base64 编码字符串）
    func storeMedia(filename: String, data: String) async throws -> String {
        // AnkiConnect 的动作名是 storeMediaFile，返回存储后的文件名字符串（之前写成 storeMedia + 字典解码，截图/音频从未上传成功）
        let stored: String = try await send(
            action: "storeMediaFile",
            params: ["filename": filename, "data": data],
            as: String.self
        )
        return stored
    }

    // MARK: - Sync Management

    /// 同步所有待同步的单词
    @MainActor
    func syncAllPendingWords(_ words: [WordEntry], context: ModelContext) async {
        AppLog.log("[Anki] sync start: \(words.count) pending")
        // 确保模板和牌组结构就绪
        do {
            try await ensureModelExists()
            try await initializeDeckStructure()
        } catch {
            AppLog.log("[Anki] ✗ 初始化失败: \(error)")
            return
        }

        for word in words {
            do {
                try await syncWord(word, context: context)
            } catch {
                AppLog.log("[Anki] ✗ 同步失败 [\(word.word)]: \(error)")
            }
        }
    }

    // MARK: - 字段拼法

    /// 语境填空卡的开关：设置里选「不加 / 查过 3 次以上的词 / 所有词」，词卡右键还能单独加
    enum FillMode: String, CaseIterable, Identifiable {
        case off, frequent, all
        static let key = "ankiFillMode"
        /// 「查过 3 次以上」的 3
        static let frequentThreshold = 3
        var id: String { rawValue }
        static var current: FillMode {
            FillMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off
        }
    }

    /// 有没有一句里面真套着这个词的语境（填空卡要把它挖掉，没有就没得挖）
    static func hasFillSentence(_ word: WordEntry) -> Bool { contextHTML(word).contains("class=\"kw\"") }

    /// 这个词要不要生成语境填空卡：得有能挖的句子，再看设置和词卡右键
    static func wantsFillCard(_ word: WordEntry, mode: FillMode = .current) -> Bool {
        guard hasFillSentence(word) else { return false }
        if word.ankiFill { return true }
        switch mode {
        case .off: return false
        case .frequent: return word.lookupCount >= FillMode.frequentThreshold
        case .all: return true
        }
    }

    /// Context：每次遇到的句子一句一个 <div class="ctx">，词用 span.kw 标出来；最后一句是最近的
    static func contextHTML(_ word: WordEntry) -> String {
        let contexts = word.sortedContexts
        if contexts.isEmpty {
            let sentence = word.contextSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? "" : "<div class=\"ctx\">\(hl(word.contextSentence, word: word.word))</div>"
        }
        return contexts.map { "<div class=\"ctx\">\(hl($0.sentence, word: word.word))</div>" }.joined()
    }

    /// ContextTranslation：和 Context 一句对一句
    static func translationHTML(_ word: WordEntry) -> String {
        let contexts = word.sortedContexts
        func tr(_ t: String) -> String { "<div class=\"ctx-tr\">\(hlSense(t, sense: word.contextMeaning, keyword: word.translationKeyword))</div>" }
        if contexts.isEmpty {
            return word.contextTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : tr(word.contextTranslation)
        }
        return contexts.map { tr($0.translation) }.joined()
    }

    /// 单词卡的文字字段（不含发音和截图，那两个要上传媒体文件）。Fill 只在笔记类型有这个字段时才会被留下
    func wordTextFields(_ word: WordEntry) -> [String: String] {
        [
            "Front": word.word,
            "Back": Self.emphasizedMeaningHTML(word),
            "Phonetic": word.phonetic ?? "",
            "Context": Self.contextHTML(word),
            "ContextTranslation": Self.translationHTML(word),
            "Analysis": Self.composeAnalysisHTML(word),
            "Language": word.language.chineseName,
            "Difficulty": word.difficulty.displayName,
            "Grammar": word.grammar ?? "",
            "Fill": Self.wantsFillCard(word) ? "1" : ""
        ]
    }

    /// 知识卡的文字字段。要点有两行以上就写成编号列表（<ul class="pts">）；Question 还没有（老片段、AI 没出）就不写，免得清掉 Anki 里已有的
    func snippetTextFields(_ s: KnowledgeSnippet) -> [String: String] {
        let lines = s.content.components(separatedBy: "\n")
        let asList = lines.count > 1 && lines.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var fields = [
            "Title": s.title,
            "Content": asList ? "<ul class=\"pts\">" + lines.map { "<li>\($0)</li>" }.joined() + "</ul>"
                              : s.content.replacingOccurrences(of: "\n", with: "<br>"),
            "Source": s.sourceContext,
            "Domain": s.category?.name ?? (s.domain.isEmpty ? "未分组" : s.domain)
        ]
        if let q = s.question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { fields["Question"] = q }
        return fields
    }

    /// 同步单个单词到 Anki
    @MainActor
    func syncWord(_ word: WordEntry, context: ModelContext) async throws {
        let deckName = deckNameForWord(word)

        // 确保目标牌组存在
        do {
            try await ensureDeckExists(name: deckName)
        } catch {
            // 尝试创建父牌组
            let parts = deckName.split(separator: "::")
            if parts.count > 1 {
                let parentDeck = String(parts[0])
                try? await ensureDeckExists(name: parentDeck)
                try await ensureDeckExists(name: deckName)
            }
        }

        // 构造字段（文字部分，和升级时后台重写老卡用同一份）
        var fields = wordTextFields(word)
        fields["Screenshot"] = ""
        fields["Audio"] = ""

        // 发音：优先已缓存/下载的真人 mp3，没有就现下；上传到 Anki 媒体库，正面自动播放
        var audioPath = word.audioPath
        if audioPath == nil || !FileManager.default.fileExists(atPath: audioPath!) {
            audioPath = await AudioService.shared.generateAudioFile(for: word.word, language: word.language)
            if let audioPath { word.audioPath = audioPath }
        }
        if let audioPath, let audioData = FileManager.default.contents(atPath: audioPath) {
            let ext = (audioPath as NSString).pathExtension
            // gnw_ 前缀：旧 getnewword_ 名字在 AnkiWeb 清单里成了"幽灵条目"（有记录无文件、checksum 相同永不重传），换名换血
            let filename = "gnw_\(word.id.uuidString.lowercased()).\(ext)"
            if (try? await storeMedia(filename: filename, data: audioData.base64EncodedString())) != nil {
                fields["Audio"] = "[sound:\(filename)]"
            }
        }

        // 处理截图
        if let screenshotPath = word.screenshotPath,
           FileManager.default.fileExists(atPath: screenshotPath) {
            let screenshotData = FileManager.default.contents(atPath: screenshotPath)
            if let data = screenshotData {
                let base64 = data.base64EncodedString()
                let filename = "gnw_img_\(word.id.uuidString.lowercased()).png"
                _ = try? await storeMedia(filename: filename, data: base64)
                fields["Screenshot"] = "<img src=\"\(filename)\">"
            }
        }

        // 没拿到本地音频/截图：把键去掉，updateNoteFields 不会动 Anki 卡上已有的内容
        if fields["Audio"] == "" { fields.removeValue(forKey: "Audio") }
        if fields["Screenshot"] == "" { fields.removeValue(forKey: "Screenshot") }
        // 笔记类型还没加的字段（用户选了「以后再说」）不写，不然 AnkiConnect 整张卡都加不进去
        fields = onlyKnownFields(fields, model: modelName)

        // 构造标签
        // 不再把应用内标签带进 Anki，只保留来源与语言标记
        let tags = ["GetNewWord", "lang:\(word.language.rawValue)"]

        // 添加或更新笔记
        if let existingNoteId = word.ankiNoteId {
            // 更新已有笔记（分组改了 → 牌组跟着搬）
            do {
                try await updateNoteFields(noteId: existingNoteId, fields: fields)
                try? await moveNote(existingNoteId, toDeck: deckName)
                word.syncStatus = .synced
            } catch {
                word.syncStatus = .syncFailed
                throw error
            }
        } else {
            // 创建新笔记
            do {
                let noteId = try await addNote(
                    deckName: deckName,
                    modelName: modelName,
                    fields: fields,
                    tags: tags
                )
                word.ankiNoteId = noteId
                word.syncStatus = .synced
                AppLog.log("[Anki] ✓ added '\(word.word)' → \(deckName) (note \(noteId))")
            } catch {
                // Anki 说重复：卡其实已经在了（本地卡号丢过，如被旧版云同步覆盖）→ 认领那张卡并更新，不算失败
                if "\(error)".contains("duplicate"),
                   let existing = try? await findNotes(query: "\"note:\(modelName)\" \"Front:\(word.word.replacingOccurrences(of: "\"", with: ""))\"").first {
                    do {
                        try await updateNoteFields(noteId: existing, fields: fields)
                        try? await moveNote(existing, toDeck: deckName)
                        word.ankiNoteId = existing
                        word.syncStatus = .synced
                        AppLog.log("[Anki] ✓ adopted existing note for '\(word.word)' (note \(existing))")
                    } catch {
                        word.syncStatus = .syncFailed
                        throw error
                    }
                } else {
                    word.syncStatus = .syncFailed
                    throw error
                }
            }
        }

        // 持久化状态变更
        try? context.save()
    }

    // MARK: - 知识片段同步

    let snippetModelName = AppVariant.ankiName + " Snippet"

    func deckNameForSnippet(_ s: KnowledgeSnippet) -> String {
        if let cat = s.category {
            if let parent = cat.parent { return "\(parent.name)::\(cat.name)" }
            return cat.name
        }
        return "知识片段::其他"
    }

    @MainActor
    func syncSnippet(_ s: KnowledgeSnippet, context: ModelContext) async throws {
        let deckName = deckNameForSnippet(s)
        try? await ensureDeckExists(name: deckName)
        var fields = snippetTextFields(s)
        fields["Screenshot"] = ""
        if let path = s.screenshotPath, let data = FileManager.default.contents(atPath: path) {
            let filename = "gnw_snip_\(s.id.uuidString.lowercased()).png"
            if (try? await storeMedia(filename: filename, data: data.base64EncodedString())) != nil {
                fields["Screenshot"] = "<img src=\"\(filename)\">"
            }
        }
        fields = onlyKnownFields(fields, model: snippetModelName)
        // 优先用已存的 noteId；老数据没有就按 Title 查一次并回填
        var noteId = s.ankiNoteId
        if noteId == nil {
            let found = (try? await findNotes(query: "\"note:\(snippetModelName)\" \"Title:\(s.title.replacingOccurrences(of: "\"", with: ""))\"")) ?? []
            noteId = found.first
        }
        if let noteId {
            try await updateNoteFields(noteId: noteId, fields: fields)
            try? await moveNote(noteId, toDeck: deckName)   // 分组改了 → 牌组跟着搬
            s.ankiNoteId = noteId
        } else {
            let newId = try await addNote(deckName: deckName, modelName: snippetModelName, fields: fields, tags: ["GetNewWord", "snippet"] + s.tags.map { $0.replacingOccurrences(of: " ", with: "_") })
            s.ankiNoteId = newId
            AppLog.log("[Anki] ✓ added snippet '\(s.title)' → \(deckName) (note \(newId))")
        }
        s.syncStatus = .synced
        try? context.save()
    }

    /// 反向同步：Anki 里已被删掉的卡（notesInfo 返回空对象），本地单词也删掉，保持两端一致
    private struct NoteInfoLite: Codable { let noteId: Int? }
    /// 要看全部同步过的词：只要卡号，在后台另开一个 ModelContext 读。以前在主线程把这些词全取成对象，
    /// 2000 个词时卡 0.2–0.3 秒，查完词 Anki 一开着就同步，正好卡在用户读卡、点关面板的时候
    @MainActor
    func pruneDeletedNotes(context: ModelContext) async {
        let container = context.container
        let ids = await Task.detached(priority: .utility) { () -> [Int] in
            var d = FetchDescriptor<WordEntry>(predicate: #Predicate { $0.ankiNoteId != nil })
            d.propertiesToFetch = [\.ankiNoteId]
            return ((try? ModelContext(container).fetch(d)) ?? []).compactMap(\.ankiNoteId)
        }.value
        guard !ids.isEmpty else { return }
        guard let infos: [NoteInfoLite] = try? await send(action: "notesInfo", params: ["notes": ids], as: [NoteInfoLite].self),
              infos.count == ids.count else { return }
        // 熔断：绝大多数本地卡都在 Anki 中不存在 = 换库/换配置/新账号，绝不能当成用户删卡
        let missingCount = infos.filter { $0.noteId == nil }.count
        if missingCount > 2 && missingCount * 5 >= ids.count * 4 {
            AppLog.log("[Anki] 熔断：\(missingCount)/\(ids.count) 本地卡在 Anki 中不存在，疑似换库，跳过反向清理")
            return
        }
        CloudSyncService.shared.confirmAnkiNotes(infos.compactMap { $0.noteId })
        var removed = 0
        for (i, info) in infos.enumerated() where info.noteId == nil {
            // 从另一台电脑同步来、本机 Anki 还没经 AnkiWeb 拿到的卡：不是用户删卡
            guard !CloudSyncService.shared.isUnconfirmedAnkiNote(ids[i]) else { continue }
            // 按卡号在主线程的词库里重新取：等 Anki 回话的这段时间里用户可能已经删了这个词并存了盘，
            // 拿后台读到的对象 ID 去取会拿到已失效的对象，一读属性就崩
            let noteId: Int? = ids[i]
            for w in (try? context.fetch(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.ankiNoteId == noteId }))) ?? [] {
                AppLog.log("[Anki] '\(w.word)' deleted in Anki → remove locally")
                context.delete(w)
                removed += 1
            }
        }
        if removed > 0 { try? context.save() }
    }

    /// 反向同步（片段）：先给老数据回填 noteId，再检查 Anki 里已删的卡并同步删除本地
    @MainActor
    func pruneDeletedSnippets(context: ModelContext) async {
        // 老数据回填：已同步但没存 noteId 的片段，按标题查一次补上
        let legacy = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>(predicate: #Predicate { $0.ankiNoteId == nil && $0.syncStatusRaw == "synced" }))) ?? []
        for s in legacy {
            let clean = s.title.replacingOccurrences(of: "\"", with: "")
            if let found = try? await findNotes(query: "\"note:\(snippetModelName)\" \"Title:\(clean)\""), let nid = found.first {
                s.ankiNoteId = nid
            }
        }
        if !legacy.isEmpty { try? context.save() }

        let snippets = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>(predicate: #Predicate { $0.ankiNoteId != nil }))) ?? []
        guard !snippets.isEmpty else { return }
        let ids = snippets.compactMap { $0.ankiNoteId }
        guard let infos: [NoteInfoLite] = try? await send(action: "notesInfo", params: ["notes": ids], as: [NoteInfoLite].self),
              infos.count == ids.count else { return }
        // 熔断：绝大多数本地卡都在 Anki 中不存在 = 换库/换配置/新账号，绝不能当成用户删卡
        let missingCount = infos.filter { $0.noteId == nil }.count
        if missingCount > 2 && missingCount * 5 >= ids.count * 4 {
            AppLog.log("[Anki] 熔断：\(missingCount)/\(ids.count) 本地卡在 Anki 中不存在，疑似换库，跳过反向清理")
            return
        }
        CloudSyncService.shared.confirmAnkiNotes(infos.compactMap { $0.noteId })
        var removed = 0
        for (i, info) in infos.enumerated() where info.noteId == nil {
            guard !CloudSyncService.shared.isUnconfirmedAnkiNote(ids[i]) else { continue }
            if let s = snippets.first(where: { $0.ankiNoteId == ids[i] }) {
                AppLog.log("[Anki] 片段 '\(s.title)' deleted in Anki → remove locally")
                context.delete(s)
                removed += 1
            }
        }
        if removed > 0 { try? context.save() }
    }

    /// 保存后自动调用：Anki 没开就静默跳过；同步所有未同步的单词和知识片段
    @MainActor
    func syncEverythingPending(context: ModelContext) async {
        guard await isAnkiRunning() else {
            AppLog.log("[Anki] not running, skip auto sync")
            return
        }
        await checkCardsOnce()                         // 卡片样式、字段：这次启动核对一次，老的升到 v2
        await pruneDeletedNotes(context: context)      // Anki 里删掉的单词卡 → 本地也删
        await pruneDeletedSnippets(context: context)   // Anki 里删掉的片段卡 → 本地也删
        // 失败过的也一起重试（失败很快；重复卡会被认领而自愈）
        let words = (try? context.fetch(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.syncStatusRaw == "not_synced" || $0.syncStatusRaw == "sync_failed" }))) ?? []
        let snippets = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>(predicate: #Predicate { $0.syncStatusRaw == "not_synced" }))) ?? []
        if !words.isEmpty { await syncAllPendingWords(words, context: context) }
        if !snippets.isEmpty {
            do {
                try await ensureSnippetModelExists()
                for s in snippets {
                    do { try await syncSnippet(s, context: context) } catch {
                        s.syncStatus = .syncFailed
                        AppLog.log("[Anki] ✗ snippet '\(s.title)': \(error)")
                    }
                }
            } catch {
                AppLog.log("[Anki] ✗ snippet model: \(error)")
            }
        }
        await refreshSyncedNotesIfPending(context: context)   // 升级到 v2 以后，把已同步的老卡的字段按新拼法重写一遍
        // 推完新卡后立即触发 Anki 的正常同步（增量合并；手机端复习记录一并合并，减少两端分叉窗口）
        if !words.isEmpty || !snippets.isEmpty {
            do {
                try await sendVoid(action: "sync")
                AppLog.log("[Anki] triggered AnkiWeb sync")
            } catch {
                AppLog.log("[Anki] ✗ AnkiWeb sync trigger: \(error)")
            }
        }
    }

    // MARK: - 灾难恢复：从 Anki 反向导入词库

    private static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")
        t = t.replacingOccurrences(of: "\\[sound:[^\\]]*\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 取 <div class="cls">…</div> 的内容列表（内容里没有嵌套 div 时适用）
    private static func divContents(_ html: String, cls: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<div class=\"\(cls)\">(.*?)</div>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            stripHTML(ns.substring(with: $0.range(at: 1)))
        }
    }

    /// Analysis HTML → 用法/搭配/例句/词根词源
    static func parseAnalysisHTML(_ html: String) -> (usage: String?, coll: String?, ex: String?, ety: String?) {
        var usage: String?, coll: String?, ex: String?, ety: String?
        // 新卡 <div class="lbl lbl-usage">Usage</div>，1.2.0 以前的旧卡 <div class="lbl">用 法</div>
        for part in html.components(separatedBy: "<div class=\"lbl").dropFirst() {
            guard let open = part.range(of: "\">"), let r = part.range(of: "</div>", range: open.upperBound..<part.endIndex) else { continue }
            let cls = part[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            let label = String(part[open.upperBound..<r.lowerBound]).replacingOccurrences(of: " ", with: "")
            let body = String(part[r.upperBound...])
            let section = AnalysisSection.allCases.first { "lbl-\($0.rawValue)" == cls }
                ?? AnalysisSection.allCases.first { cls.isEmpty && $0.legacyLabel == label }
            func lines(_ b: String) -> String {
                b.components(separatedBy: "<div class=\"ctx\">").dropFirst().map { entry -> String in
                    let sub = entry.components(separatedBy: "<div class=\"zh\">")
                    let foreign = stripHTML(sub[0])
                    let zh = sub.count > 1 ? stripHTML(sub[1]) : ""
                    return zh.isEmpty ? foreign : "\(foreign) —— \(zh)"
                }.joined(separator: "\n")
            }
            switch section {
            case .usage: usage = stripHTML(body)
            case .coll: coll = lines(body)
            case .ex: ex = lines(body)
            case .ety: ety = stripHTML(body)
            case nil: break
            }
        }
        return (usage, coll, ex, ety)
    }

    /// 卡片上的「语言」：现在写中文名；1.2.0 的开发版按界面语言写过 English、Deutsch 这类名字，也认
    private static func languageFromDisplay(_ name: String) -> Language {
        Language.allCases.first { $0.chineseName == name || $0.displayName == name } ?? .other
    }

    /// 从 Anki 反向导入：把 Anki 里 GetNewWord 的卡还原成本地词条/片段。
    /// 幂等：本地已有同 noteId 或同词（word|语言）的条目跳过。返回恢复条数。
    @MainActor
    func restoreFromAnki(context: ModelContext) async -> Int {
        guard await isAnkiRunning() else { return 0 }
        let localWords = (try? context.fetch(FetchDescriptor<WordEntry>())) ?? []
        let localNoteIds = Set(localWords.compactMap { $0.ankiNoteId })
        var localKeys = Set(localWords.map { $0.dedupeKey })
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []

        // note → 牌组叶子名（恢复分组归属）
        var noteDeckLeaf: [Int: String] = [:]
        if let decks = try? await deckNames() {
            for d in decks {
                let leaf = d.components(separatedBy: "::").last ?? d
                for m in [modelName, snippetModelName] {
                    if let dn = try? await findNotes(query: "\"deck:\(d)\" \"note:\(m)\"") {
                        for id in dn { noteDeckLeaf[id] = leaf }
                    }
                }
            }
        }
        var cats = categories
        func category(leaf: String?, forWords: Bool) -> Category? {
            guard let leaf, !leaf.isEmpty else { return nil }
            if let c = cats.first(where: { $0.name == leaf && $0.parent != nil }) { return c }
            // Anki 牌组存在而本地分类没有 → 自动重建（恢复用户的分组结构）
            let parentName = forWords ? "语言学习" : "知识片段"
            guard leaf != parentName, let parent = cats.first(where: { $0.name == parentName && $0.parent == nil }) else { return nil }
            let c = Category(name: leaf, icon: forWords ? "character.book.closed" : "folder", colorHex: "#4A90D9")
            c.parent = parent
            context.insert(c)
            cats.append(c)
            AppLog.log("[Recovery] recreated category \u{300C}\(parentName) > \(leaf)\u{300D}")
            return c
        }

        var restored = 0
        // ---- 单词 ----
        if let ids = try? await findNotes(query: "\"note:\(modelName)\""), !ids.isEmpty,
           let infos = try? await notesInfo(notes: ids) {
            for info in infos {
                guard !localNoteIds.contains(info.noteId) else { continue }
                func f(_ k: String) -> String { info.fields[k]?.value ?? "" }
                let word = Self.stripHTML(f("Front"))
                guard !word.isEmpty else { continue }
                let language = Self.languageFromDisplay(f("Language"))
                let key = "\(word.lowercased())|\(language.rawValue)"
                guard !localKeys.contains(key) else { continue }
                localKeys.insert(key)

                let back = f("Back")
                var contextMeaning: String? = nil
                if let re = try? NSRegularExpression(pattern: "<b[^>]*>(.*?)</b>"),
                   let m = re.firstMatch(in: back, range: NSRange(back.startIndex..., in: back)),
                   let r = Range(m.range(at: 1), in: back) {
                    contextMeaning = Self.stripHTML(String(back[r]))
                }
                let ctxHTML = f("Context")
                var sentences = Self.divContents(ctxHTML, cls: "ctx")
                if sentences.isEmpty { let s = Self.stripHTML(ctxHTML); if !s.isEmpty { sentences = [s] } }
                var translations = Self.divContents(f("ContextTranslation"), cls: "ctx-tr")
                if translations.isEmpty { let t = Self.stripHTML(f("ContextTranslation")); if !t.isEmpty { translations = [t] } }
                let a = Self.parseAnalysisHTML(f("Analysis"))

                let entry = WordEntry(
                    word: word,
                    phonetic: Self.stripHTML(f("Phonetic")).isEmpty ? nil : Self.stripHTML(f("Phonetic")),
                    language: language,
                    meaning: Self.stripHTML(back),
                    contextMeaning: contextMeaning,
                    contextSentence: sentences.first ?? "",
                    contextTranslation: translations.first ?? "",
                    analysisNote: a.usage ?? "",
                    grammar: Self.stripHTML(f("Grammar")).isEmpty ? nil : Self.stripHTML(f("Grammar")),
                    collocationsText: a.coll,
                    examplesText: a.ex,
                    etymology: a.ety,
                    difficulty: Difficulty(rawValue: f("Difficulty").lowercased()) ?? .b1,
                    ankiNoteId: info.noteId,
                    syncStatus: .synced,
                    category: category(leaf: noteDeckLeaf[info.noteId], forWords: true)
                )
                context.insert(entry)
                for (i, s) in sentences.enumerated() {
                    let ctx = WordContext(sentence: s, translation: i < translations.count ? translations[i] : "", word: entry)
                    context.insert(ctx)
                }
                restored += 1
            }
        }
        // ---- 知识片段 ----
        let localSnippets = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>())) ?? []
        let localSnippetIds = Set(localSnippets.compactMap { $0.ankiNoteId })
        var localTitles = Set(localSnippets.map { $0.title })
        if let ids = try? await findNotes(query: "\"note:\(snippetModelName)\""), !ids.isEmpty,
           let infos = try? await notesInfo(notes: ids) {
            for info in infos {
                guard !localSnippetIds.contains(info.noteId) else { continue }
                func f(_ k: String) -> String { info.fields[k]?.value ?? "" }
                let title = Self.stripHTML(f("Title"))
                guard !title.isEmpty, !localTitles.contains(title) else { continue }
                localTitles.insert(title)
                let question = Self.stripHTML(f("Question"))
                let s = KnowledgeSnippet(
                    title: title,
                    content: Self.stripHTML(f("Content")),
                    sourceContext: Self.stripHTML(f("Source")),
                    domain: Self.stripHTML(f("Domain")),
                    question: question.isEmpty ? nil : question,
                    syncStatus: .synced,
                    category: category(leaf: noteDeckLeaf[info.noteId], forWords: false) ?? category(leaf: Self.stripHTML(f("Domain")), forWords: false)
                )
                s.ankiNoteId = info.noteId
                context.insert(s)
                restored += 1
            }
        }
        try? context.save()
        AppLog.log("[Recovery] restored \(restored) items from Anki")
        return restored
    }

    // MARK: - Deck Structure

    /// 获取单词对应的牌组路径（使用 :: 分隔层级）
    /// 牌组 = 左侧分类树路径（如 "语言学习::英语"、"知识片段::健身"）；没归类时按语言兜底
    func deckNameForWord(_ word: WordEntry) -> String {
        if let cat = word.category {
            if let parent = cat.parent { return "\(parent.name)::\(cat.name)" }
            return cat.name
        }
        return "语言学习::\(word.language.chineseName)"
    }

    /// 牌组结构完全跟随应用内分类树，按需在同步时创建；这里只确保 AnkiConnect 可达
    func initializeDeckStructure() async throws {
        _ = try await deckNames()
    }
}

// MARK: - 内容臃肿治理

extension AnkiService {

    /// 获取臃肿治理建议
    func getDeclutterSuggestions(words: [WordEntry], context: ModelContext) -> DeclutterSuggestions {
        let now = Date()
        let calendar = Calendar.current

        let archivable = words.filter { word in
            guard word.reviewCount >= 5, !word.isArchived else { return false }
            let daysSinceReview = calendar.dateComponents([.day], from: word.createdAt, to: now).day ?? 0
            return daysSinceReview > 30
        }

        var mergeablePairs: [DeclutterSuggestions.WordPair] = []
        let nonArchived = words.filter { !$0.isArchived }
        let meaningGroups = Dictionary(grouping: nonArchived, by: { $0.meaning.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        for (_, group) in meaningGroups where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    mergeablePairs.append(DeclutterSuggestions.WordPair(
                        first: group[i],
                        second: group[j]
                    ))
                }
            }
        }

        let removable = words.filter { word in
            !word.isArchived &&
            word.difficulty == .a1 &&
            word.reviewCount >= 3
        }

        let totalCards = words.filter { !$0.isArchived }.count
        let suggestedReduction = archivable.count + removable.count

        return DeclutterSuggestions(
            archivableWords: archivable,
            mergeablePairs: mergeablePairs,
            removableWords: removable,
            totalCards: totalCards,
            suggestedReduction: suggestedReduction,
            context: context
        )
    }

    /// 自动归档已掌握的旧卡片
    func autoArchiveOldCards(words: [WordEntry], context: ModelContext) async throws {
        let now = Date()
        let calendar = Calendar.current

        let toArchive = words.filter { word in
            guard !word.isArchived, word.reviewCount >= 5 else { return false }
            let daysSinceCreation = calendar.dateComponents([.day], from: word.createdAt, to: now).day ?? 0
            return daysSinceCreation > 30
        }

        guard !toArchive.isEmpty else { return }

        // 在 Anki 中暂停这些卡片
        let noteIds = toArchive.compactMap { $0.ankiNoteId }
        if !noteIds.isEmpty {
            // 分批处理，每批最多 50 个
            for batch in noteIds.chunked(into: 50) {
                // 先获取卡片 ID
                let noteIdStrings = batch.map { "nid:\($0)" }
                let query = noteIdStrings.joined(separator: " or ")
                if let cardIds = try? await findNotes(query: query) as [Int], !cardIds.isEmpty {
                    try? await suspendCards(cardIds: cardIds)
                }
            }
        }

        // 本地标记为已归档
        for word in toArchive {
            word.isArchived = true
            word.syncStatus = .archived
        }

        try? context.save()
    }

    /// 精简模式：降低已掌握单词的复习频率（通过 Anki 暂停卡片实现）
    func applyDeclineMode(words: [WordEntry]) async throws {
        let masteredWords = words.filter { word in
            !word.isArchived && word.reviewCount >= 5
        }

        guard !masteredWords.isEmpty else { return }

        let noteIds = masteredWords.compactMap { $0.ankiNoteId }
        guard !noteIds.isEmpty else { return }

        // 分批暂停
        for batch in noteIds.chunked(into: 50) {
            let queries = batch.map { "nid:\($0)" }
            let query = queries.joined(separator: " or ")
            if let cardIds = try? await findNotes(query: query) as [Int], !cardIds.isEmpty {
                try? await suspendCards(cardIds: cardIds)
            }
        }
    }
}

// MARK: - Array Chunked Helper

private extension Array {
    /// 将数组按指定大小分块
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
