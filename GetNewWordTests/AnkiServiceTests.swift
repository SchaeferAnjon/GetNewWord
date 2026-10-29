// Anki 卡片：字段名和笔记类型对得上、发音截图走 storeMediaFile、卡片能原样恢复回词库。
// 用一个假的 AnkiConnect（URLProtocol）回话，不连本机真开着的 Anki。

import Foundation
import SwiftData
import Testing
@testable import GetNewWord

/// 假的 AnkiConnect：记下每个请求，按 action 回话
final class FakeAnkiConnect: URLProtocol, @unchecked Sendable {
    struct Call { let action: String; let params: [String: Any] }
    /// AnkiConnect 回的 error 原话
    struct Failure: Error { let message: String }

    /// 返回 .success(result) 当 result，.failure 当 AnkiConnect 的 error。
    /// 在 URL 加载线程上调：必须是 @Sendable，不能继承测试的 MainActor（否则 dispatch_assert_queue 崩）
    nonisolated(unsafe) static var reply: @Sendable (Call) -> Result<Any, Failure> = { _ in .success(NSNull()) }
    nonisolated(unsafe) static var calls: [Call] = []

    static func calls(_ action: String) -> [Call] { calls.filter { $0.action == action } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let call = Call(action: json["action"] as? String ?? "", params: json["params"] as? [String: Any] ?? [:])
        Self.calls.append(call)
        let payload: [String: Any]
        switch Self.reply(call) {
        case .success(let result): payload = ["result": result, "error": NSNull()]
        case .failure(let failure): payload = ["result": NSNull(), "error": failure.message]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    /// 只认这个假服务的 URLSession
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeAnkiConnect.self]
        return URLSession(configuration: config)
    }()
}

@MainActor
@Suite(.serialized)
final class AnkiServiceTests {
    let anki = AnkiService.shared
    let files: URL

    init() throws {
        files = try makeTempDirectory()
        FakeAnkiConnect.calls = []
        FakeAnkiConnect.reply = Self.normalAnki
        anki.session = FakeAnkiConnect.session
    }

    deinit {
        try? FileManager.default.removeItem(at: files)
    }

    /// 一个正常开着的 Anki：牌组都在，加卡返回新卡号
    nonisolated static func normalAnki(_ call: FakeAnkiConnect.Call) -> Result<Any, FakeAnkiConnect.Failure> {
        switch call.action {
        case "version": return .success(6)
        case "deckNames": return .success(["Default", "语言学习", "语言学习::英语", "语言学习::法语"])
        case "storeMediaFile": return .success(call.params["filename"] ?? "")
        case "addNote": return .success(1_700_000_000_001)
        case "findCards": return .success([11, 12])
        case "findNotes": return .success([Int]())
        case "modelNames": return .success(["Basic"])
        default: return .success(NSNull())
        }
    }

    private func sampleWord(in context: ModelContext, withMedia: Bool) throws -> WordEntry {
        let parent = Category(name: "语言学习")
        let english = Category(name: "英语", parent: parent)
        let word = WordEntry(word: "confluence", phonetic: "/ˈkɒnfluəns/", language: .english, meaning: "n. 汇合处；汇流",
                             contextMeaning: "汇合处", contextSentence: "The town sits at the confluence of two rivers.",
                             contextTranslation: "小镇坐落在两条河的交汇处。", analysisNote: "多指河流交汇。",
                             grammar: "", collocationsText: "at the confluence of —— 在……的交汇处",
                             examplesText: "a confluence of factors —— 多种因素的汇合", etymology: "con- 一起 + fluere 流",
                             difficulty: .c1, category: english)
        word.translationKeyword = "交汇处"
        if withMedia {
            let audio = files.appendingPathComponent("confluence.mp3")
            let shot = files.appendingPathComponent("shot.png")
            try Data("ID3 fake mp3".utf8).write(to: audio)
            try Data("fake png".utf8).write(to: shot)
            word.audioPath = audio.path
            word.screenshotPath = shot.path
        }
        context.insert(parent)
        context.insert(english)
        context.insert(word)
        context.insert(WordContext(sentence: word.contextSentence, translation: word.contextTranslation, word: word))
        try context.save()
        return word
    }

    @Test func newWordCard() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: true)
        try await anki.syncWord(word, context: context)

        let id = word.id.uuidString.lowercased()
        let media = FakeAnkiConnect.calls("storeMediaFile")
        #expect(media.map { $0.params["filename"] as? String } == ["gnw_\(id).mp3", "gnw_img_\(id).png"])
        #expect(media.first?.params["data"] as? String == Data("ID3 fake mp3".utf8).base64EncodedString())

        let add = try #require(FakeAnkiConnect.calls("addNote").first)
        let note = try #require(add.params["note"] as? [String: Any])
        #expect(note["deckName"] as? String == "语言学习::英语")
        #expect(note["modelName"] as? String == AppVariant.ankiName)
        #expect(note["tags"] as? [String] == ["GetNewWord", "lang:en"])
        #expect((note["options"] as? [String: Any])?["allowDuplicate"] as? Bool == false)
        let fields = try #require(note["fields"] as? [String: String])
        #expect(fields["Front"] == "confluence")
        #expect(fields["Back"] == "n. <b style=\"color:#5E6AD2\">汇合处</b>；汇流")
        #expect(fields["Context"] == "<div class=\"ctx\">The town sits at the <span class=\"kw\">confluence</span> of two rivers.</div>")
        #expect(fields["ContextTranslation"] == "<div class=\"ctx-tr\">小镇坐落在两条河的<span class=\"kw\">交汇处</span>。</div>")
        #expect(fields["Audio"] == "[sound:gnw_\(id).mp3]")
        #expect(fields["Screenshot"] == "<img src=\"gnw_img_\(id).png\">")
        #expect(fields["Difficulty"] == "C1")
        #expect(fields["Analysis"]?.contains("<div class=\"lbl lbl-coll\">\(String(localized: "搭 配"))</div>") == true)

        #expect(word.ankiNoteId == 1_700_000_000_001)
        #expect(word.syncStatus == .synced)
    }

    /// 卡片用到的字段，笔记类型里都有（少一个 AnkiConnect 就整张卡加不进去）
    @Test func fieldsMatchNoteType() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: true)
        FakeAnkiConnect.reply = { @Sendable call in
            call.action == "modelNames" ? .success([String]()) : Self.normalAnki(call)
        }
        try await anki.ensureModelExists()
        try await anki.syncWord(word, context: context)

        let model = try #require(FakeAnkiConnect.calls("createModel").first)
        #expect(model.params["modelName"] as? String == AppVariant.ankiName)
        let modelFields = Set(try #require(model.params["inOrderFields"] as? [String]))
        let note = try #require(FakeAnkiConnect.calls("addNote").first?.params["note"] as? [String: Any])
        let used = Set(try #require(note["fields"] as? [String: String]).keys)
        #expect(used.subtracting(modelFields).isEmpty, "笔记类型里没有：\(used.subtracting(modelFields))")
        // 模板里引用的字段也都存在
        let templates = try #require(model.params["cardTemplates"] as? [[String: String]])
        let html = templates.flatMap { [$0["Front"] ?? "", $0["Back"] ?? ""] }.joined()
        let referenced = Set(html.matches(of: /\{\{([A-Za-z]+)\}\}/).map { String($0.1) }).subtracting(["FrontSide"])
        #expect(referenced.subtracting(modelFields).isEmpty, "模板引用了不存在的字段：\(referenced.subtracting(modelFields))")
    }

    /// 已有卡：只更新字段并挪牌组；没传上去的发音、截图不带空值，免得清掉 Anki 卡上已有的
    @Test func existingCardKeepsMediaWhenUploadFails() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: true)
        word.screenshotPath = nil
        word.ankiNoteId = 42
        FakeAnkiConnect.reply = { @Sendable call in
            call.action == "storeMediaFile" ? .failure(.init(message: "disk full")) : Self.normalAnki(call)
        }
        try await anki.syncWord(word, context: context)

        #expect(FakeAnkiConnect.calls("addNote").isEmpty)
        let update = try #require(FakeAnkiConnect.calls("updateNoteFields").first?.params["note"] as? [String: Any])
        #expect(update["id"] as? Int == 42)
        let fields = try #require(update["fields"] as? [String: String])
        #expect(fields["Audio"] == nil)
        #expect(fields["Screenshot"] == nil)
        #expect(fields["Front"] == "confluence")
        let move = try #require(FakeAnkiConnect.calls("changeDeck").first)
        #expect(move.params["deck"] as? String == "语言学习::英语")
        #expect(move.params["cards"] as? [Int] == [11, 12])
        #expect(word.syncStatus == .synced)
    }

    /// Anki 说重复（本地丢过卡号）：认领那张卡并更新，不算失败
    @Test func duplicateAdoptsExistingCard() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: true)
        FakeAnkiConnect.reply = { @Sendable call in
            switch call.action {
            case "addNote": return .failure(.init(message: "cannot create note because it is a duplicate"))
            case "findNotes": return .success([777])
            default: return Self.normalAnki(call)
            }
        }
        try await anki.syncWord(word, context: context)

        let query = try #require(FakeAnkiConnect.calls("findNotes").first?.params["query"] as? String)
        #expect(query == "\"note:\(AppVariant.ankiName)\" \"Front:confluence\"")
        #expect((FakeAnkiConnect.calls("updateNoteFields").first?.params["note"] as? [String: Any])?["id"] as? Int == 777)
        #expect(word.ankiNoteId == 777)
        #expect(word.syncStatus == .synced)
    }

    @Test func otherAddErrorMarksFailed() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: true)
        FakeAnkiConnect.reply = { @Sendable call in
            call.action == "addNote" ? .failure(.init(message: "model was not found")) : Self.normalAnki(call)
        }
        await #expect(throws: AnkiError.self) { try await self.anki.syncWord(word, context: context) }
        #expect(word.syncStatus == .syncFailed)
        #expect(word.ankiNoteId == nil)
    }

    /// AnkiConnect 的动作名是 storeMediaFile，回的是存下的文件名
    @Test func storeMedia() async throws {
        let stored = try await anki.storeMedia(filename: "gnw_x.mp3", data: "QUJD")
        #expect(stored == "gnw_x.mp3")
        let call = try #require(FakeAnkiConnect.calls.first)
        #expect(call.action == "storeMediaFile")
        #expect(call.params["filename"] as? String == "gnw_x.mp3")
        #expect(call.params["data"] as? String == "QUJD")
    }

    /// 没归类的词按语言进牌组，牌组名用存的中文名，不跟界面语言变（不然换了界面语言卡就分到两个牌组）
    @Test func uncategorizedDeckIsStable() async throws {
        let context = try makeLibrary()
        let word = WordEntry(word: "rendez-vous", language: .french, meaning: "n. 约会", contextSentence: "Un rendez-vous.",
                             contextTranslation: "一个约会。", analysisNote: "")
        context.insert(word)
        #expect(anki.deckNameForWord(word) == "语言学习::法语")
    }

    /// 卡片同步上去再从 Anki 恢复（灾难恢复），词、语境、讲解都回得来
    @Test func cardRestoresIntoLibrary() async throws {
        let source = try makeLibrary()
        let word = try sampleWord(in: source, withMedia: true)
        try await anki.syncWord(word, context: source)
        let fields = try #require((FakeAnkiConnect.calls("addNote").first?.params["note"] as? [String: Any])?["fields"] as? [String: String])

        let target = try makeLibrary()
        let parent = Category(name: "语言学习")
        target.insert(parent)
        target.insert(Category(name: "英语", parent: parent))
        try target.save()
        let model = AppVariant.ankiName
        FakeAnkiConnect.reply = { @Sendable call in
            let query = call.params["query"] as? String ?? ""
            switch call.action {
            case "findNotes" where query.contains("Snippet"): return .success([Int]())
            case "findNotes" where query.contains("deck:语言学习::英语") || query == "\"note:\(model)\"": return .success([1])
            case "findNotes": return .success([Int]())
            case "notesInfo":
                let info: [String: Any] = [
                    "noteId": 1, "tags": ["GetNewWord"], "cards": [11],
                    "fields": Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element.key, ["value": $0.element.value, "order": $0.offset]) }),
                ]
                return .success([info])
            default: return Self.normalAnki(call)
            }
        }
        #expect(await anki.restoreFromAnki(context: target) == 1)

        let restored = try #require(try target.fetch(FetchDescriptor<WordEntry>()).first)
        #expect(restored.word == "confluence")
        #expect(restored.language == .english)
        #expect(restored.meaning == "n. 汇合处；汇流")
        #expect(restored.contextMeaning == "汇合处")
        #expect(restored.phonetic == "/ˈkɒnfluəns/")
        #expect(restored.difficulty == .c1)
        #expect(restored.ankiNoteId == 1)
        #expect(restored.category?.name == "英语")
        #expect(restored.contexts?.map(\.sentence) == ["The town sits at the confluence of two rivers."])
        #expect(restored.contexts?.map(\.translation) == ["小镇坐落在两条河的交汇处。"])
        #expect(restored.analysisNote == "多指河流交汇。")
        #expect(restored.collocationsText == "at the confluence of —— 在……的交汇处")
        #expect(restored.examplesText == "a confluence of factors —— 多种因素的汇合")
        #expect(restored.etymology == "con- 一起 + fluere 流")
    }

    /// 背面四段的小标题按界面语言写，恢复时认 class；1.2.0 以前的卡只有中文小标题，也认得
    @Test func analysisSectionsParseInAnyLanguage() {
        let english = "<div class=\"lbl lbl-usage\">Usage</div><div class=\"usage\">Mostly rivers.</div>"
            + "<div class=\"lbl lbl-coll\">Collocations</div><div class=\"sec\"><div class=\"ctx\">at the confluence<div class=\"zh\">在交汇处</div></div></div>"
            + "<div class=\"lbl lbl-ex\">Beispiele</div><div class=\"sec\"><div class=\"ctx\">a confluence of factors</div></div>"
            + "<div class=\"lbl lbl-ety\">Herkunft</div><div class=\"sec\">con- + fluere</div>"
        let a = AnkiService.parseAnalysisHTML(english)
        #expect(a.usage == "Mostly rivers.")
        #expect(a.coll == "at the confluence —— 在交汇处")
        #expect(a.ex == "a confluence of factors")
        #expect(a.ety == "con- + fluere")

        let legacy = "<div class=\"lbl\">用 法</div><div class=\"usage\">多指河流交汇。</div>"
            + "<div class=\"lbl\">例 句</div><div class=\"sec\"><div class=\"ctx\">a confluence of factors<div class=\"zh\">多种因素的汇合</div></div></div>"
            + "<div class=\"lbl\">词根词源</div><div class=\"sec\">con- 一起 + fluere 流</div>"
        let b = AnkiService.parseAnalysisHTML(legacy)
        #expect(b.usage == "多指河流交汇。")
        #expect(b.coll == nil)
        #expect(b.ex == "a confluence of factors —— 多种因素的汇合")
        #expect(b.ety == "con- 一起 + fluere 流")
    }

    /// Anki 里删掉的卡（notesInfo 回空对象）：本地只删那一个词；卡号在后台读，删的时候按 id 拿回主线程这边的对象
    @Test func deletedInAnkiRemovedLocally() async throws {
        let context = try makeLibrary()
        for i in 1...4 {
            context.insert(WordEntry(word: "w\(i)", language: .english, meaning: "m", contextSentence: "", contextTranslation: "",
                                     analysisNote: "", ankiNoteId: 100 + i, syncStatus: .synced))
        }
        context.insert(WordEntry(word: "local", language: .english, meaning: "m", contextSentence: "", contextTranslation: "", analysisNote: ""))
        try context.save()
        FakeAnkiConnect.reply = { @Sendable call in
            guard call.action == "notesInfo" else { return Self.normalAnki(call) }
            let ids = call.params["notes"] as? [Int] ?? []
            return .success(ids.map { $0 == 102 ? [String: Any]() : ["noteId": $0] })
        }
        await anki.pruneDeletedNotes(context: context)
        #expect(Set(FakeAnkiConnect.calls("notesInfo").first?.params["notes"] as? [Int] ?? []) == [101, 102, 103, 104])
        #expect(try context.fetch(FetchDescriptor<WordEntry>()).map(\.word).sorted() == ["local", "w1", "w3", "w4"])
    }

    /// 后台读完卡号、等 Anki 回 notesInfo 的时候，用户在主窗口删了一个已同步的词并存了盘（App 也删了它在 Anki 的卡）：
    /// 以前拿后台读到的对象 ID 去取，取到已失效的对象，一读卡号就崩
    @Test func wordDeletedLocallyWhileAskingAnki() async throws {
        let context = try makeLibrary()
        for i in 1...4 {
            context.insert(WordEntry(word: "w\(i)", language: .english, meaning: "m", contextSentence: "", contextTranslation: "",
                                     analysisNote: "", ankiNoteId: 100 + i, syncStatus: .synced))
        }
        try context.save()
        FakeAnkiConnect.reply = { @Sendable call in
            guard call.action == "notesInfo" else { return Self.normalAnki(call) }
            Thread.sleep(forTimeInterval: 0.4)
            let ids = call.params["notes"] as? [Int] ?? []
            return .success(ids.map { $0 == 102 ? [String: Any]() : ["noteId": $0] })
        }
        let deleter = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(150))
            let w = try #require(try context.fetch(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.word == "w2" })).first)
            context.delete(w)
            try context.save()
        }
        await anki.pruneDeletedNotes(context: context)
        try await deleter.value
        #expect(try context.fetch(FetchDescriptor<WordEntry>()).map(\.word).sorted() == ["w1", "w3", "w4"])
    }

    @Test func highlight() {
        #expect(AnkiService.hl("Running runs ran", word: "running") == "<span class=\"kw\">Running</span> runs ran")
        #expect(AnkiService.hl("Die Vorfahrt achten", word: "Vorfahrt") == "Die <span class=\"kw\">Vorfahrt</span> achten")
        #expect(AnkiService.hl("a b", word: "a") == "a b")
        #expect(AnkiService.hl("(x+y)", word: "x+y") == "(<span class=\"kw\">x+y</span>)")
        #expect(AnkiService.hlSense("逼得不少小店关了门", sense: "驱使；迫使", keyword: "逼得") == "<span class=\"kw\">逼得</span>不少小店关了门")
        #expect(AnkiService.hlSense("他们被迫离开", sense: "驱使；迫使") == "他们被迫离开")
        #expect(AnkiService.hlSense("小镇在交汇处", sense: "汇合处，交汇处") == "小镇在<span class=\"kw\">交汇处</span>")
    }
}
