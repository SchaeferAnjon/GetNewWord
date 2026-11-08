// AnkiService+Unify.swift
// GetNewWord
//
// 往 Anki 里加卡的统一规范（DESIGN.md「往 Anki 里加卡」，方向 B「按内容分」）：
// - 单词进「语言学习::<语言>」，软件里语言下面再分的类写成标签「分类::<名字>」，不再建牌组
// - 知识片段进「知识」，分类写成标签「主题::<名字>」；新片段写进三个软件共用的「学习卡 · 问答」，老片段留在 GetNewWord Snippet
// - 每张卡带「来自::GetNewWord」；两个顶层牌组按 id 记，你在 Anki 里改了名，跟着你改的名字走
// - 升级后第一次连上 Anki：已经在 Anki 里的卡搬进新牌组、补上标签，空了的老分类牌组删掉（只删自己建的、空的）

import Foundation
import SwiftData

/// 两个顶层牌组现在叫什么（按 id 从 Anki 读回来）
final class AnkiDeckRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var language = AnkiService.languageRootDefault
    private var knowledge = AnkiService.knowledgeRootDefault

    var languageRoot: String { lock.withLock { language } }
    var knowledgeRoot: String { lock.withLock { knowledge } }
    func set(language: String, knowledge: String) { lock.withLock { self.language = language; self.knowledge = knowledge } }
}

extension AnkiService {
    static let languageRootDefault = "语言学习"
    static let knowledgeRootDefault = "知识"
    static let languageDeckIDKey = "ankiLanguageDeckID"
    static let knowledgeDeckIDKey = "ankiKnowledgeDeckID"
    /// 升级到统一规范以后，已经在 Anki 里的卡搬过牌组、补过标签了
    static let unifyMigratedKey = "ankiUnifyMigrated"
    static let fromTag = "来自::GetNewWord"
    /// 知识片段写进「学习卡 · 问答」时 ID 字段的前缀
    static let snippetIDPrefix = "gnw-snip-"

    // MARK: - 顶层牌组

    func deckNamesAndIds() async throws -> [String: Int] {
        try await send(action: "deckNamesAndIds", as: [String: Int].self)
    }

    /// 两个顶层牌组：记着 id 的按 id 找现在的名字；没记或删了，按默认名字找，没有就建，记下 id
    func resolveDeckRoots() async throws {
        let decks = try await deckNamesAndIds()
        func resolve(_ key: String, _ fallback: String) async throws -> String {
            let stored = UserDefaults.standard.object(forKey: key) as? Int
            if let stored, let name = decks.first(where: { $0.value == stored })?.key { return name }
            if let id = decks[fallback] {
                UserDefaults.standard.set(id, forKey: key)
                return fallback
            }
            let id: Int = try await send(action: "createDeck", params: ["deck": fallback], as: Int.self)
            UserDefaults.standard.set(id, forKey: key)
            return fallback
        }
        let language = try await resolve(Self.languageDeckIDKey, Self.languageRootDefault)
        let knowledge = try await resolve(Self.knowledgeDeckIDKey, Self.knowledgeRootDefault)
        deckRoots.set(language: language, knowledge: knowledge)
    }

    // MARK: - 标签

    /// 单词：来自::GetNewWord、lang:de；词归在语言下面再分的类（不是语言本身）时加「分类::<名字>」
    func wordTags(_ word: WordEntry) -> [String] {
        var tags = ["GetNewWord", Self.fromTag, "lang:\(word.language.rawValue)"]
        if let cat = word.category, cat.parent != nil, !Language.allCases.contains(where: { $0.knownNames.contains(cat.name) }) {
            tags.append("分类::" + Self.tagSafe(cat.name))
        }
        return tags
    }

    /// 知识片段：来自::GetNewWord、主题::<分类>，加上片段自己的标签
    func snippetTags(_ s: KnowledgeSnippet) -> [String] {
        var tags = ["GetNewWord", Self.fromTag, "snippet"]
        if let topic = snippetTopic(s) { tags.append("主题::" + Self.tagSafe(topic)) }
        return tags + s.tags.map(Self.tagSafe).filter { !$0.isEmpty }
    }

    /// 片段的主题：它的分类（不是「知识片段」这个根）；没归类就用 AI 给的领域
    func snippetTopic(_ s: KnowledgeSnippet) -> String? {
        if let cat = s.category, cat.parent != nil { return cat.name }
        let domain = s.domain.trimmingCharacters(in: .whitespaces)
        return domain.isEmpty ? nil : domain
    }

    static func tagSafe(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }

    /// 卡上现有的「分类::」「主题::」标签和应有的不一样：去掉旧的、补上新的（用户在 Anki 里加的别的标签不动）
    func reconcileTags(noteId: Int, wanted: [String]) async {
        guard let info = (try? await notesInfo(notes: [noteId]))?.first else { return }
        let managed = info.tags.filter { $0.hasPrefix("分类::") || $0.hasPrefix("主题::") }
        let stale = managed.filter { !wanted.contains($0) }
        let missing = wanted.filter { !info.tags.contains($0) }
        if !stale.isEmpty { try? await sendVoid(action: "removeTags", params: ["notes": [noteId], "tags": stale.joined(separator: " ")]) }
        if !missing.isEmpty { try? await sendVoid(action: "addTags", params: ["notes": [noteId], "tags": missing.joined(separator: " ")]) }
    }

    // MARK: - 知识片段写进「学习卡 · 问答」

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 九个字段：答案是几条要点时写 <ol>（纸上是编号方块）；查的时候那一屏收进「当时的画面」
    func studyCardFields(_ s: KnowledgeSnippet, image: String) -> [String: String] {
        let lines = s.content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let answer = lines.count > 1 ? "<ol>" + lines.map { "<li>\(Self.escape($0))</li>" }.joined() + "</ol>"
            : Self.escape(s.content.trimmingCharacters(in: .whitespacesAndNewlines))
        let question = s.question?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? s.title
        let label = "GetNewWord" + (snippetTopic(s).map { " · " + Category.displayName($0) } ?? "")
        return [
            "Question": Self.escape(question),
            "Answer": answer,
            "More": "",
            "Quote": Self.escape(s.sourceContext).replacingOccurrences(of: "\n", with: "<br>"),
            "Image": image,
            "Label": Self.escape(label),
            "Source": Self.escape("\(s.title) · \(Self.dayFormatter.string(from: s.createdAt))"),
            "Link": "",
            "ID": Self.snippetIDPrefix + s.id.uuidString.lowercased(),
        ]
    }

    /// 「学习卡 · 问答」缺了就建；Anki 里的版本旧了才换模板和样式（只往新的换）。
    /// 同名的不是我们的（字段对不上）就用「学习卡 · 问答 2」；你在 Anki 里改过模板的不动（GetNewWord 是自动送的，没人点按钮，不弹窗问）
    func ensureStudyCardModel() async throws -> String {
        let names = try await modelNames()
        for name in [StudyCard.name, StudyCard.otherName] {
            guard names.contains(name) else {
                let model: [String: Any] = [
                    "modelName": name, "inOrderFields": StudyCard.fields, "css": StudyCard.css, "isCloze": false,
                    "cardTemplates": [["Name": StudyCard.templateName, "Front": StudyCard.front, "Back": StudyCard.back]],
                ]
                try await sendVoid(action: "createModel", params: model)
                return name
            }
            let fields = try await send(action: "modelFieldNames", params: ["modelName": name], as: [String].self)
            guard fields == StudyCard.fields else { continue }
            let styling = try await send(action: "modelStyling", params: ["modelName": name], as: [String: String].self)
            if let v = StudyCard.version(ofCSS: styling["css"] ?? ""), v < StudyCard.version {
                try await sendVoid(action: "updateModelStyling", params: ["model": ["name": name, "css": StudyCard.css]])
                try await sendVoid(action: "updateModelTemplates", params: ["model": ["name": name, "templates": [StudyCard.templateName: ["Front": StudyCard.front, "Back": StudyCard.back]]]])
            }
            return name
        }
        throw AnkiError.deckCreationFailed
    }

    // MARK: - 升级后搬一次

    /// 已经在 Anki 里的单词和片段：搬进新牌组、补上标签；搬完删掉空了的老分类牌组。只做一次，失败了下次再来
    @MainActor
    func migrateToUnifiedDecksIfNeeded(context: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: Self.unifyMigratedKey) else { return }
        let words = (try? context.fetch(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.ankiNoteId != nil }))) ?? []
        let snippets = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>(predicate: #Predicate { $0.ankiNoteId != nil }))) ?? []
        var oldDecks = Set<String>()
        var groups: [String: [(noteId: Int, tags: [String])]] = [:]
        for w in words {
            if let cat = w.category { oldDecks.insert(cat.parent.map { "\($0.name)::\(cat.name)" } ?? cat.name) }
            groups[deckNameForWord(w), default: []].append((w.ankiNoteId!, wordTags(w)))
        }
        for s in snippets {
            if let cat = s.category { oldDecks.insert(cat.parent.map { "\($0.name)::\(cat.name)" } ?? cat.name) }
            groups[deckNameForSnippet(s), default: []].append((s.ankiNoteId!, snippetTags(s)))
        }
        oldDecks.insert("知识片段::其他")
        oldDecks.insert("知识片段")
        do {
            for (deck, notes) in groups {
                try await ensureDeckExists(name: deck)
                for chunk in stride(from: 0, to: notes.count, by: 200).map({ Array(notes[$0..<min($0 + 200, notes.count)]) }) {
                    let infos = try await notesInfo(notes: chunk.map(\.noteId))
                    let cards = infos.flatMap(\.cards)
                    if !cards.isEmpty { try await sendVoid(action: "changeDeck", params: ["cards": cards, "deck": deck]) }
                    for note in chunk { await reconcileTags(noteId: note.noteId, wanted: note.tags) }
                }
            }
            let targets = Set(groups.keys)
            var removed: [String] = []
            for deck in oldDecks.subtracting(targets).sorted(by: { $0.count > $1.count }) {
                guard (try? await deckNames())?.contains(deck) == true else { continue }
                // 只删空的：里面（含子牌组）一张卡都没有才删
                guard try await cardCount(query: "\"deck:\(deck)\"") == 0 else { continue }
                try await sendVoid(action: "deleteDecks", params: ["decks": [deck], "cardsToo": true])
                removed.append(deck)
            }
            UserDefaults.standard.set(true, forKey: Self.unifyMigratedKey)
            AppLog.log("[Anki] 统一牌组：搬了 \(words.count) 个词、\(snippets.count) 个片段，删了空牌组 \(removed)")
        } catch {
            AppLog.log("[Anki] ✗ 统一牌组没搬完，下次再来: \(error)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
