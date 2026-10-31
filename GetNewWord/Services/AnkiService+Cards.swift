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
    /// 语境填空的设置改了，但 Anki 没开或写入失败：已同步的词的 Fill 字段还没跟上。下次同步时补
    static let fillRefreshPendingKey = "ankiFillRefreshPending"
    /// 这些字段是 App 自己决定的，不是用户写的内容：重写时不比较，直接按现在的设置覆盖
    static let managedFields: Set<String> = ["Fill", "Language"]

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

    /// 确保单词卡笔记类型存在、字段齐全、样式是当前版本。
    /// 只有读不到笔记类型列表、建不起笔记类型才抛错；样式、模板、字段的升级失败只记日志，同步照常（1.3.0 也是这样）
    func ensureModelExists(labels: AnkiCardTemplates.Labels = .init()) async throws {
        try await upgradeGate.withLock {
            let existing = try await modelNames()
            guard existing.contains(modelName) else {
                try await createModel(labels: labels)
                fieldCache.set(modelName, Set(Self.wordFields))
                return
            }
            await upgradeModel(modelName, kind: .word, labels: labels)
        }
    }

    /// 确保知识片段笔记类型存在、字段齐全、样式是当前版本
    func ensureSnippetModelExists(labels: AnkiCardTemplates.Labels = .init()) async throws {
        try await upgradeGate.withLock {
            let existing = try await modelNames()
            guard existing.contains(snippetModelName) else {
                try await createSnippetModel(labels: labels)
                fieldCache.set(snippetModelName, Set(Self.snippetFields))
                return
            }
            await upgradeModel(snippetModelName, kind: .snippet, labels: labels)
        }
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

    /// 不抛错：升级中哪一步失败了，就停在那一步，字段缓存照实记下现在有哪些字段，同步用它过滤
    private func upgradeModel(_ model: String, kind: Kind, labels: AnkiCardTemplates.Labels) async {
        guard let names: [String] = try? await send(action: "modelFieldNames", params: ["modelName": model], as: [String].self), !names.isEmpty else {
            AppLog.log("[Anki] modelFieldNames 读取失败，跳过字段检查（避免误改模板触发全量同步）")
            return
        }
        var fields = Set(names)
        let required = kind == .word ? Self.wordFields : Self.snippetFields
        let missing = required.filter { !fields.contains($0) }
        var approved = await AnkiUpgrade.shared.approved
        if !missing.isEmpty {
            // 加字段会让 Anki 要求单向同步：问过用户、点了「继续」才做
            approved = await AnkiUpgrade.shared.allowStructureChange()
            if approved {
                var count = names.count
                var added: [String] = []
                for field in missing {
                    do {
                        try await sendVoid(action: "modelFieldAdd", params: ["modelName": model, "fieldName": field, "index": count])
                    } catch {
                        AppLog.log("[Anki] ✗ 给 \(model) 加字段 \(field) 失败，这次停在这里: \(error)")
                        break
                    }
                    fields.insert(field)
                    added.append(field)
                    count += 1
                }
                if !added.isEmpty {
                    UserDefaults.standard.set(true, forKey: Self.refreshPendingKey)
                    AppLog.log("[Anki] 给 \(model) 加了字段 \(added.joined(separator: ", "))")
                }
            }
        }
        fieldCache.set(model, fields)
        await AnkiUpgrade.shared.report(model: model, complete: Set(required).isSubset(of: fields))
        // 样式和模板用到的字段都有了才换：缺 Grammar、Audio 的更老的笔记类型要等字段补上
        let base = kind == .word ? Self.baseWordFields : Self.baseSnippetFields
        guard Set(base).isSubset(of: fields) else { return }
        do {
            try await applyCardDesign(model, kind: kind, fields: fields, labels: labels, mayAddTemplates: approved)
        } catch {
            AppLog.log("[Anki] ✗ 更新 \(model) 的样式或模板失败，卡片先保持现状，同步不受影响: \(error)")
        }
    }

    /// 样式是旧版本、模板文字的语言和界面不一致：把样式和模板写成当前的。
    /// 加卡片模板是改结构（Anki 会要求单向同步），只在用户点过「继续」的这次启动里做；平时发现语境填空模板不在了，
    /// 当成用户自己删的，不加回来
    private func applyCardDesign(_ model: String, kind: Kind, fields: Set<String>, labels: AnkiCardTemplates.Labels, mayAddTemplates: Bool) async throws {
        guard let styling: [String: String] = try? await send(action: "modelStyling", params: ["modelName": model], as: [String: String].self),
              let templates: [String: [String: String]] = try? await send(action: "modelTemplates", params: ["modelName": model], as: [String: [String: String]].self),
              !templates.isEmpty else {
            AppLog.log("[Anki] \(model) 的样式或模板读取失败，这次不动")
            return
        }
        let css = styling["css"] ?? ""
        // 主模板按名字认；用户自己加过别的卡片类型（比如反向卡）排在前面时不能当成主模板覆盖掉
        let mainDefault = kind == .word ? Self.wordTemplateName : Self.snippetTemplateName
        let mainName = templates[mainDefault] != nil ? mainDefault
            : (templates.keys.sorted().first { $0 != Self.fillTemplateName } ?? mainDefault)

        var wanted: [(name: String, front: String, back: String)] = []
        switch kind {
        case .word:
            wanted.append((mainName, AnkiCardTemplates.wordFront(labels), AnkiCardTemplates.wordBack(labels)))
            if fields.contains("Fill"), templates[Self.fillTemplateName] != nil || mayAddTemplates {
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
        // 样式换新版，或界面语言变了（卡上的「语言」字段跟着界面语言写）：已同步的卡的字段要跟上
        if oldVersion || otherLanguage { UserDefaults.standard.set(true, forKey: Self.refreshPendingKey) }
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

    /// 升级后后台做一次：把已同步的词和片段的文字字段按新拼法重写（释义分词性、小标题去空格、要点成列表、Fill、Question、语言名）。
    /// 只发文字字段，不重传声音和截图；AnkiConnect 的 multi 每批 50 个。这是普通改动，不要求单向同步
    @MainActor
    func refreshSyncedNotesIfPending(context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: Self.refreshPendingKey) else { return }
        guard await refreshSyncedNotes(context: context) else { return }
        UserDefaults.standard.removeObject(forKey: Self.refreshPendingKey)
    }

    /// 设置改了、但当时没写进 Anki 的 Fill 字段：这次补上
    @MainActor
    func refreshFillIfPending(context: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: Self.fillRefreshPendingKey),
              fieldCache.get(modelName)?.contains("Fill") == true else { return }
        guard await refreshSyncedNotes(context: context, textOnly: ["Fill"]) else { return }
        UserDefaults.standard.removeObject(forKey: Self.fillRefreshPendingKey)
    }

    /// 重写时每个字段怎么处理。Anki 里现在的内容和新拼法去掉标签、去掉空白后文字一样，就只是格式变了，换成新的；
    /// 文字不一样，是用户在 Anki 里改过的，留着不动。Anki 里是空的也写（新字段）。Fill、Language 由 App 决定，直接覆盖
    static func refreshableFields(new: [String: String], current: [String: String]) -> (send: [String: String], kept: Int) {
        func plain(_ s: String) -> String { stripHTML(s).filter { !$0.isWhitespace } }
        var send: [String: String] = [:]
        var kept = 0
        for (name, value) in new {
            guard let now = current[name], now != value else { continue }    // 笔记里没有这个字段，或者早已一样
            if managedFields.contains(name) || plain(now).isEmpty || plain(now) == plain(value) {
                send[name] = value
            } else {
                kept += 1
            }
        }
        return (send, kept)
    }

    private struct NoteFieldsLite: Codable {
        struct Value: Codable { let value: String }
        let noteId: Int?
        let fields: [String: Value]?
    }

    /// 返回是不是全部发完了（中途 Anki 断了返回 false，下次接着来）。
    /// 每 50 个一批：这一批的字段现拼、现读 Anki 里的当前值、现发，批与批之间让出主线程
    @MainActor
    @discardableResult
    func refreshSyncedNotes(context: ModelContext, textOnly fieldNames: Set<String>? = nil) async -> Bool {
        enum Item { case word(WordEntry), snippet(KnowledgeSnippet) }
        let words = (try? context.fetch(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.ankiNoteId != nil && $0.syncStatusRaw == "synced" }))) ?? []
        // 只改 Fill 时不用看片段
        let snippets = fieldNames == nil
            ? ((try? context.fetch(FetchDescriptor<KnowledgeSnippet>(predicate: #Predicate { $0.ankiNoteId != nil && $0.syncStatusRaw == "synced" }))) ?? [])
            : []
        var items: [(id: Int, item: Item)] = []
        for w in words { if let id = w.ankiNoteId { items.append((id, .word(w))) } }
        for s in snippets { if let id = s.ankiNoteId { items.append((id, .snippet(s))) } }
        guard !items.isEmpty else { return true }

        var sent = 0, kept = 0, failed = 0
        for start in stride(from: 0, to: items.count, by: 50) {
            let batch = Array(items[start..<min(start + 50, items.count)])
            var wanted: [Int: [String: String]] = [:]
            for (id, item) in batch {
                switch item {
                case .word(let w):
                    var fields = fieldNames == ["Fill"] ? ["Fill": Self.wantsFillCard(w) ? "1" : ""] : wordTextFields(w)
                    fields = onlyKnownFields(fields, model: modelName)
                    if let fieldNames { fields = fields.filter { fieldNames.contains($0.key) } }
                    wanted[id] = fields
                case .snippet(let s):
                    wanted[id] = onlyKnownFields(snippetTextFields(s), model: snippetModelName)
                }
            }
            let infos: [NoteFieldsLite]
            do {
                infos = try await send(action: "notesInfo", params: ["notes": batch.map(\.id)], as: [NoteFieldsLite].self)
            } catch {
                AppLog.log("[Anki] ✗ 重写老卡字段中断（读不到卡片内容）：\(error)")
                return false
            }
            guard infos.count == batch.count else {
                AppLog.log("[Anki] ✗ 重写老卡字段中断：问了 \(batch.count) 张，回了 \(infos.count) 张")
                return false
            }
            var updates: [(id: Int, fields: [String: String])] = []
            var fillOff: [Int] = [], fillOn: [Int] = []
            for (i, entry) in batch.enumerated() {
                // Anki 里已经删掉的卡（notesInfo 回空对象）不管
                guard let info = infos[i].fields, infos[i].noteId != nil else { continue }
                let current = info.mapValues(\.value)
                let (send, keptHere) = Self.refreshableFields(new: wanted[entry.id] ?? [:], current: current)
                kept += keptHere
                if !send.isEmpty { updates.append((entry.id, send)) }
                if let fill = send["Fill"] {
                    if fill.isEmpty { fillOff.append(entry.id) } else { fillOn.append(entry.id) }
                }
            }
            if !updates.isEmpty {
                do {
                    failed += try await sendMulti(updates: updates)
                    sent += updates.count
                } catch {
                    AppLog.log("[Anki] ✗ 重写老卡字段中断：\(error)")
                    return false
                }
            }
            await setFillCards(noteIds: fillOff, suspended: true)
            await setFillCards(noteIds: fillOn, suspended: false)
            await Task.yield()
        }
        AppLog.log("[Anki] 重写了 \(sent) 张已同步的卡的字段（\(failed) 张失败），\(kept) 个字段是你在 Anki 里改过的，没动")
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

    /// Fill 变空时 Anki 不会删掉已有的语境填空卡，它们会留在复习队列里显示「正面是空的」，所以暂停；Fill 回来时恢复
    func setFillCards(noteIds: [Int], suspended: Bool) async {
        guard !noteIds.isEmpty else { return }
        for start in stride(from: 0, to: noteIds.count, by: 50) {
            let ids = noteIds[start..<min(start + 50, noteIds.count)].map(String.init).joined(separator: ",")
            do {
                let cards: [Int] = try await send(action: "findCards",
                                                  params: ["query": "\"note:\(modelName)\" \"card:\(Self.fillTemplateName)\" nid:\(ids)"], as: [Int].self)
                guard !cards.isEmpty else { continue }
                try await sendVoid(action: suspended ? "suspend" : "unsuspend", params: ["cards": cards])
            } catch {
                AppLog.log("[Anki] ✗ \(suspended ? "暂停" : "恢复")语境填空卡失败: \(error)")
            }
        }
    }

    // MARK: - 语境填空卡的设置

    /// 设置里改了「语境填空」的选项：已同步的词的 Fill 字段按新选项重写。笔记类型还没有 Fill 字段就请用户先升级。
    /// Anki 没开或没写完，记一笔，下次同步时补
    @MainActor
    func applyFillChoice(context: ModelContext) async {
        guard await isAnkiRunning() else {
            UserDefaults.standard.set(true, forKey: Self.fillRefreshPendingKey)
            return
        }
        if fieldCache.get(modelName)?.contains("Fill") != true {
            cardsChecked = false
            await checkCardsOnce()
        }
        // 还没有 Fill 字段：升级询问已经挂起，点「继续」后整库重写时会带上 Fill
        guard fieldCache.get(modelName)?.contains("Fill") == true else { return }
        if await refreshSyncedNotes(context: context, textOnly: ["Fill"]) {
            UserDefaults.standard.removeObject(forKey: Self.fillRefreshPendingKey)
        } else {
            UserDefaults.standard.set(true, forKey: Self.fillRefreshPendingKey)
        }
    }

    /// 词卡右键「加一张语境填空卡」/「去掉语境填空卡」
    @MainActor
    func setFillCard(_ word: WordEntry, on: Bool, context: ModelContext) async {
        word.ankiFill = on
        try? context.save()
        guard let noteId = word.ankiNoteId, word.syncStatus == .synced else { return }
        guard await isAnkiRunning() else {
            UserDefaults.standard.set(true, forKey: Self.fillRefreshPendingKey)
            return
        }
        if fieldCache.get(modelName)?.contains("Fill") != true {
            cardsChecked = false
            await checkCardsOnce()
        }
        guard fieldCache.get(modelName)?.contains("Fill") == true else { return }
        let want = Self.wantsFillCard(word)
        do {
            try await updateNoteFields(noteId: noteId, fields: ["Fill": want ? "1" : ""])
            await setFillCards(noteIds: [noteId], suspended: !want)
        } catch {
            AppLog.log("[Anki] ✗ 写 Fill 失败 [\(word.word)]，下次同步补: \(error)")
            UserDefaults.standard.set(true, forKey: Self.fillRefreshPendingKey)
        }
    }
}

/// 一次只放一个人进去的异步锁。升级笔记类型是「读现状、再按现状补」，两处同时做会都读到旧状态、都去加字段和模板
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                if held { waiters.append(cont); return true }
                held = true
                return false
            }
            if !wait { cont.resume() }
        }
    }

    private func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty { held = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
