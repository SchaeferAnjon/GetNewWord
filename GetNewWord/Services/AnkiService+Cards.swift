// AnkiService+Cards.swift
// GetNewWord
//
// Anki 笔记类型：创建、样式和模板的升级、字段的补加、老卡字段的后台重写。
// 样式和模板的原文在 AnkiCardTemplates.swift。
//
// 两类改动要分开看：
// - 只改样式和模板文字：手机下次同步就换上，Anki 不要求单向同步。启动后核对一次，自动做。
// - 加字段（单词卡的 Fill、知识卡的 Question）和加卡片模板（语境填空）：Anki 会要求下一次同步选上传。
//   先由 AnkiUpgrade 问用户，点「继续」才做；点「以后再说」就一直用老样子，同步时只写已有的字段。

import Foundation
import SwiftData

extension AnkiService {
    // MARK: - 字段和模板名

    /// 单词卡 1.3.0 以前就有的字段：新模板用到的都在这里面
    static let baseWordFields = [
        "Front", "Back", "Phonetic", "Context", "ContextTranslation", "Analysis", "Screenshot",
        "Language", "Difficulty", "Audio", "Grammar"
    ]
    /// 单词卡现在的全部字段。Fill 不空才生成语境填空卡
    static let wordFields = baseWordFields + ["Fill"]
    static let baseSnippetFields = ["Title", "Content", "Source", "Domain", "Screenshot"]
    /// 知识卡现在的全部字段。Question 是正面的问题
    static let snippetFields = baseSnippetFields + ["Question"]

    /// 模板名不跟界面语言变，也不改（用户的牌组、统计里认的是它）
    static let fillTemplateName = "语境填空"
    private static let wordTemplateName = "正面"
    private static let snippetTemplateName = "知识"

    /// 老卡的字段要按新拼法重写时，这个开关为真；重写完才关
    static let refreshPendingKey = "ankiCardRefreshPending"

    private enum Kind { case word, snippet }

    // MARK: - 新建笔记类型

    /// 创建单词卡笔记类型：全部字段，「正面」和可选的「语境填空」两个卡片模板（Fill 为空就不生成后者）
    func createModel(labels: AnkiCardTemplates.Labels = .init()) async throws {
        let model: [String: Any] = [
            "modelName": modelName,
            "inOrderFields": Self.wordFields,
            "css": AnkiCardTemplates.css(labels),
            "isCloze": false,
            "cardTemplates": [
                ["Name": Self.wordTemplateName, "Front": AnkiCardTemplates.wordFront(labels), "Back": AnkiCardTemplates.wordBack(labels)],
                ["Name": Self.fillTemplateName, "Front": AnkiCardTemplates.fillFront(labels), "Back": AnkiCardTemplates.fillBack(labels)]
            ]
        ]
        try await sendVoid(action: "createModel", params: model)
    }

    func createSnippetModel(labels: AnkiCardTemplates.Labels = .init()) async throws {
        let model: [String: Any] = [
            "modelName": snippetModelName,
            "inOrderFields": Self.snippetFields,
            "css": AnkiCardTemplates.css(labels),
            "isCloze": false,
            "cardTemplates": [[
                "Name": Self.snippetTemplateName,
                "Front": AnkiCardTemplates.noteFront(labels, hasQuestion: true),
                "Back": AnkiCardTemplates.noteBack(labels, hasQuestion: true)
            ]]
        ]
        try await sendVoid(action: "createModel", params: model)
    }

    // MARK: - 核对和升级

    /// 确保单词卡笔记类型存在、字段齐全、样式是当前版本
    func ensureModelExists(labels: AnkiCardTemplates.Labels = .init()) async throws {
        let existing = try await modelNames()
        guard existing.contains(modelName) else {
            try await createModel(labels: labels)
            fieldCache.set(modelName, Set(Self.wordFields))
            return
        }
        try await upgradeModel(modelName, kind: .word, labels: labels)
    }

    /// 确保知识片段笔记类型存在、字段齐全、样式是当前版本
    func ensureSnippetModelExists(labels: AnkiCardTemplates.Labels = .init()) async throws {
        let existing = try await modelNames()
        guard existing.contains(snippetModelName) else {
            try await createSnippetModel(labels: labels)
            fieldCache.set(snippetModelName, Set(Self.snippetFields))
            return
        }
        try await upgradeModel(snippetModelName, kind: .snippet, labels: labels)
    }

    /// 两个笔记类型有哪个就核对哪个，没有的不新建（用户可能一直没存过知识片段）
    func ensureExistingModelsUpToDate(labels: AnkiCardTemplates.Labels = .init()) async throws {
        let existing = try await modelNames()
        if existing.contains(modelName) { try await ensureModelExists(labels: labels) }
        if existing.contains(snippetModelName) { try await ensureSnippetModelExists(labels: labels) }
    }

    /// 这次启动第一次保存时核对一次。Anki 没回话就下次再来
    @MainActor
    func checkCardsOnce() async {
        guard !cardsChecked else { return }
        do {
            try await ensureExistingModelsUpToDate()
            cardsChecked = true
        } catch {
            AppLog.log("[Anki] ✗ 核对卡片样式: \(error)")
        }
    }

    private func upgradeModel(_ model: String, kind: Kind, labels: AnkiCardTemplates.Labels) async throws {
        guard let names: [String] = try? await send(action: "modelFieldNames", params: ["modelName": model], as: [String].self), !names.isEmpty else {
            AppLog.log("[Anki] modelFieldNames 读取失败，跳过字段检查（避免误改模板触发全量同步）")
            return
        }
        var fields = Set(names)
        let required = kind == .word ? Self.wordFields : Self.snippetFields
        let missing = required.filter { !fields.contains($0) }
        if !missing.isEmpty {
            // 加字段会让 Anki 要求单向同步：问过用户、点了「继续」才做
            if await AnkiUpgrade.shared.allowStructureChange() {
                var count = names.count
                for field in missing {
                    try await sendVoid(action: "modelFieldAdd", params: ["modelName": model, "fieldName": field, "index": count])
                    fields.insert(field)
                    count += 1
                }
                UserDefaults.standard.set(true, forKey: Self.refreshPendingKey)
                AppLog.log("[Anki] 给 \(model) 加了字段 \(missing.joined(separator: ", "))")
            }
        }
        fieldCache.set(model, fields)
        await AnkiUpgrade.shared.report(model: model, complete: Set(required).isSubset(of: fields))
        // 样式和模板用到的字段都有了才换：缺 Grammar、Audio 的更老的笔记类型要等字段补上
        let base = kind == .word ? Self.baseWordFields : Self.baseSnippetFields
        guard Set(base).isSubset(of: fields) else { return }
        try await applyCardDesign(model, kind: kind, fields: fields, labels: labels)
    }

    /// 样式是旧版本、模板文字的语言和界面不一致、该有的卡片模板还没有：把样式和模板写成当前的
    private func applyCardDesign(_ model: String, kind: Kind, fields: Set<String>, labels: AnkiCardTemplates.Labels) async throws {
        guard let styling: [String: String] = try? await send(action: "modelStyling", params: ["modelName": model], as: [String: String].self),
              let templates: [String: [String: String]] = try? await send(action: "modelTemplates", params: ["modelName": model], as: [String: [String: String]].self),
              !templates.isEmpty else {
            AppLog.log("[Anki] \(model) 的样式或模板读取失败，这次不动")
            return
        }
        let css = styling["css"] ?? ""
        let mainName = templates.keys.sorted().first { $0 != Self.fillTemplateName } ?? (kind == .word ? Self.wordTemplateName : Self.snippetTemplateName)

        var wanted: [(name: String, front: String, back: String)] = []
        switch kind {
        case .word:
            wanted.append((mainName, AnkiCardTemplates.wordFront(labels), AnkiCardTemplates.wordBack(labels)))
            if fields.contains("Fill") {
                wanted.append((Self.fillTemplateName, AnkiCardTemplates.fillFront(labels), AnkiCardTemplates.fillBack(labels)))
            }
        case .snippet:
            let q = fields.contains("Question")
            wanted.append((mainName, AnkiCardTemplates.noteFront(labels, hasQuestion: q), AnkiCardTemplates.noteBack(labels, hasQuestion: q)))
        }

        let oldVersion = !AnkiCardTemplates.isCurrentVersion(css: css)
        let otherLanguage = !oldVersion && AnkiCardTemplates.labelLanguage(css: css) != labels.language
        let missingTemplate = wanted.contains { templates[$0.name] == nil }
        let questionChanged = kind == .snippet && (templates[mainName]?["Front"]?.contains("{{Question}}") ?? false) != fields.contains("Question")
        guard oldVersion || otherLanguage || missingTemplate || questionChanged else { return }

        try await sendVoid(action: "updateModelStyling", params: ["model": ["name": model, "css": AnkiCardTemplates.css(labels)]])
        var updates: [String: [String: String]] = [:]
        for t in wanted {
            if templates[t.name] != nil {
                updates[t.name] = ["Front": t.front, "Back": t.back]
            } else {
                try await sendVoid(action: "modelTemplateAdd", params: ["modelName": model, "template": ["Name": t.name, "Front": t.front, "Back": t.back]])
            }
        }
        if !updates.isEmpty {
            try await sendVoid(action: "updateModelTemplates", params: ["model": ["name": model, "templates": updates]])
        }
        if oldVersion { UserDefaults.standard.set(true, forKey: Self.refreshPendingKey) }
        AppLog.log("[Anki] \(model) 的样式和模板已更新到 v2（\(labels.language)）")
    }

    // MARK: - 用户点了「继续」

    /// 加字段和卡片模板、换样式、重写老卡。Anki 没开就下次保存时接着做（AnkiUpgrade 里的 approved 已经记下了）
    @MainActor
    func upgradeNow(context: ModelContext) async {
        cardsChecked = false
        guard await isAnkiRunning() else {
            AppLog.log("[Anki] 升级卡片：Anki 没开，等下次保存时做")
            return
        }
        await checkCardsOnce()
        await refreshSyncedNotesIfPending(context: context)
    }

    // MARK: - 老卡的字段按新拼法重写

    /// 升级后后台做一次：把已同步的词和片段的文字字段按新拼法重写（释义分词性、小标题去空格、要点成列表、Fill、Question）。
    /// 只发文字字段，不重传声音和截图；AnkiConnect 的 multi 每批 50 个。这是普通改动，不要求单向同步
    @MainActor
    func refreshSyncedNotesIfPending(context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: Self.refreshPendingKey) else { return }
        guard await refreshSyncedNotes(context: context) else { return }
        UserDefaults.standard.removeObject(forKey: Self.refreshPendingKey)
    }

    /// 返回是不是全部发完了（中途 Anki 断了返回 false，下次接着来）
    @MainActor
    @discardableResult
    func refreshSyncedNotes(context: ModelContext, textOnly fieldNames: Set<String>? = nil) async -> Bool {
        let words = (try? context.fetch(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.ankiNoteId != nil && $0.syncStatusRaw == "synced" }))) ?? []
        let snippets = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>(predicate: #Predicate { $0.ankiNoteId != nil && $0.syncStatusRaw == "synced" }))) ?? []
        var queued: [(id: Int, fields: [String: String])] = []
        for w in words {
            guard let id = w.ankiNoteId else { continue }
            queued.append((id, onlyKnownFields(wordTextFields(w), model: modelName)))
        }
        for s in snippets {
            guard let id = s.ankiNoteId else { continue }
            queued.append((id, onlyKnownFields(snippetTextFields(s), model: snippetModelName)))
        }
        if let fieldNames {
            queued = queued.map { ($0.id, $0.fields.filter { fieldNames.contains($0.key) }) }
        }
        queued = queued.filter { !$0.fields.isEmpty }
        guard !queued.isEmpty else { return true }

        var failed = 0
        for batch in stride(from: 0, to: queued.count, by: 50).map({ Array(queued[$0..<min($0 + 50, queued.count)]) }) {
            do {
                failed += try await sendMulti(updates: batch)
            } catch {
                AppLog.log("[Anki] ✗ 重写老卡字段中断：\(error)")
                return false
            }
            await Task.yield()
        }
        AppLog.log("[Anki] 重写了 \(queued.count) 张已同步的卡的字段（\(failed) 张失败）")
        return true
    }

    /// 一次发一批动作；返回其中失败的条数（卡在 Anki 里已被删掉这类，不算整批失败）
    private func sendMulti(updates: [(id: Int, fields: [String: String])]) async throws -> Int {
        let actions: [[String: Any]] = updates.map {
            ["action": "updateNoteFields", "params": ["note": ["id": $0.id, "fields": $0.fields] as [String: Any]]]
        }
        let results: [AnyCodable] = try await send(action: "multi", params: ["actions": actions], as: [AnyCodable].self)
        return results.filter { item in
            if let dict = item.value as? [String: Any], let error = dict["error"] as? String, !error.isEmpty { return true }
            return false
        }.count
    }

    // MARK: - 语境填空卡的设置

    /// 设置里改了「语境填空」的选项：已同步的词的 Fill 字段按新选项重写。笔记类型还没有 Fill 字段就请用户先升级
    @MainActor
    func applyFillChoice(context: ModelContext) async {
        guard await isAnkiRunning() else { return }
        if fieldCache.get(modelName)?.contains("Fill") != true {
            cardsChecked = false
            await checkCardsOnce()
        }
        guard fieldCache.get(modelName)?.contains("Fill") == true else { return }
        await refreshSyncedNotes(context: context, textOnly: ["Fill"])
    }

    /// 词卡右键「加一张语境填空卡」/「去掉语境填空卡」
    @MainActor
    func setFillCard(_ word: WordEntry, on: Bool, context: ModelContext) async {
        word.ankiFill = on
        try? context.save()
        guard let noteId = word.ankiNoteId, word.syncStatus == .synced, await isAnkiRunning() else { return }
        if fieldCache.get(modelName)?.contains("Fill") != true {
            cardsChecked = false
            await checkCardsOnce()
        }
        guard fieldCache.get(modelName)?.contains("Fill") == true else { return }
        try? await updateNoteFields(noteId: noteId, fields: ["Fill": Self.wantsFillCard(word) ? "1" : ""])
    }
}
