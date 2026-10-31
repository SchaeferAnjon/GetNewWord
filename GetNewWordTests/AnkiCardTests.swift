// Anki 卡片 v2（句子在前）：模板和字段、老卡升级、加字段前的询问、后台重写、语境填空、知识卡的问题。
// 用一个会记状态的假 Anki（笔记类型、字段、样式、模板），不连本机真开着的 Anki。
// 老格式和新格式的卡都要能恢复成同一份词库数据。

import Foundation
import SwiftData
import Testing
@testable import GetNewWord

/// 会记状态的假 Anki 集合：笔记类型的字段、CSS、模板，和每张卡的字段
final class FakeAnkiCollection: @unchecked Sendable {
    struct Model { var fields: [String]; var css: String; var templates: [String: [String: String]] }
    private let lock = NSLock()
    private var _models: [String: Model]
    private var _notes: [Int: [String: String]] = [:]

    init(models: [String: Model], notes: [Int: [String: String]] = [:]) { _models = models; _notes = notes }

    /// Anki 里原本就有的一张卡（老格式的字段）
    func seed(_ id: Int, _ fields: [String: String]) { lock.withLock { _notes[id] = fields } }

    var models: [String: Model] { lock.withLock { _models } }
    var notes: [Int: [String: String]] { lock.withLock { _notes } }

    func handle(_ call: FakeAnkiConnect.Call) -> Result<Any, FakeAnkiConnect.Failure> {
        lock.withLock {
            let name = call.params["modelName"] as? String ?? ""
            switch call.action {
            case "modelNames": return .success(Array(_models.keys))
            case "modelFieldNames": return .success(_models[name]?.fields ?? [])
            case "modelFieldAdd":
                _models[name]?.fields.append(call.params["fieldName"] as? String ?? "")
                return .success(NSNull())
            case "modelStyling": return .success(["css": _models[name]?.css ?? ""])
            case "modelTemplates": return .success(_models[name]?.templates ?? [:])
            case "updateModelStyling":
                let m = call.params["model"] as? [String: Any] ?? [:]
                _models[m["name"] as? String ?? ""]?.css = m["css"] as? String ?? ""
                return .success(NSNull())
            case "updateModelTemplates":
                let m = call.params["model"] as? [String: Any] ?? [:]
                for (t, v) in m["templates"] as? [String: [String: String]] ?? [:] { _models[m["name"] as? String ?? ""]?.templates[t] = v }
                return .success(NSNull())
            case "modelTemplateAdd":
                let t = call.params["template"] as? [String: String] ?? [:]
                _models[name]?.templates[t["Name"] ?? ""] = ["Front": t["Front"] ?? "", "Back": t["Back"] ?? ""]
                return .success(NSNull())
            case "createModel":
                let templates = (call.params["cardTemplates"] as? [[String: String]] ?? []).reduce(into: [String: [String: String]]()) {
                    $0[$1["Name"] ?? ""] = ["Front": $1["Front"] ?? "", "Back": $1["Back"] ?? ""]
                }
                _models[call.params["modelName"] as? String ?? ""] = Model(fields: call.params["inOrderFields"] as? [String] ?? [],
                                                                         css: call.params["css"] as? String ?? "", templates: templates)
                return .success(NSNull())
            case "updateNoteFields":
                let note = call.params["note"] as? [String: Any] ?? [:]
                let id = note["id"] as? Int ?? 0
                for (k, v) in note["fields"] as? [String: String] ?? [:] { _notes[id, default: [:]][k] = v }
                return .success(NSNull())
            case "notesInfo":
                // Anki 对不存在的卡回一个空对象
                let ids = call.params["notes"] as? [Int] ?? []
                return .success(ids.map { id -> [String: Any] in
                    guard let fields = _notes[id] else { return [:] }
                    return ["noteId": id, "tags": [String](), "cards": [Int](),
                            "fields": Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element.key, ["value": $0.element.value, "order": $0.offset]) })]
                })
            case "multi":
                var out: [Any] = []
                for a in call.params["actions"] as? [[String: Any]] ?? [] {
                    let inner = FakeAnkiConnect.Call(action: a["action"] as? String ?? "", params: a["params"] as? [String: Any] ?? [:])
                    // 递归会重复加锁：这里只支持 multi 里的 updateNoteFields
                    let note = inner.params["note"] as? [String: Any] ?? [:]
                    let id = note["id"] as? Int ?? 0
                    for (k, v) in note["fields"] as? [String: String] ?? [:] { _notes[id, default: [:]][k] = v }
                    out.append(NSNull())
                }
                return .success(out)
            default: return AnkiServiceTests.normalAnki(call)
            }
        }
    }
}

/// 1.3.0 的单词卡笔记类型：11 个字段，一个「正面」模板，老样式
private func legacyWordModel() -> FakeAnkiCollection.Model {
    .init(fields: AnkiService.baseWordFields,
          css: ".card {\n    font-family: \"SF Pro Display\";\n    text-align: center;\n}",
          templates: ["正面": ["Front": "<div style=\"font-size: 24px;\">{{Front}}</div>{{Grammar}}{{Audio}}",
                              "Back": "{{FrontSide}}<hr>{{Back}}{{Context}}{{Analysis}}{{Screenshot}}"]])
}

private func legacySnippetModel() -> FakeAnkiCollection.Model {
    .init(fields: AnkiService.baseSnippetFields,
          css: ".card { font-size: 16px; }",
          templates: ["知识": ["Front": "<div class=\"title\">{{Title}}</div>", "Back": "{{FrontSide}}<hr>{{Content}}"]])
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// 从 Anki 的 {{…}} 里取字段名
private func referencedFields(_ html: String) -> Set<String> {
    Set(html.matches(of: /\{\{[#^\/]?([A-Za-z]+)\}\}/).map { String($0.1) }).subtracting(["FrontSide"])
}

extension AnkiServiceTests {
    private var wordModel: String { AppVariant.ankiName }
    private var snippetModel: String { AppVariant.ankiName + " Snippet" }

    // MARK: - 模板和样式本身

    /// 模板里用到的每个字段，笔记类型里都有（少一个，Anki 就拒绝整个模板）；样式带版本号、深色、手机
    @Test func templatesOnlyUseExistingFields() {
        let l = AnkiCardTemplates.Labels()
        let word = Set(AnkiService.wordFields)
        for html in [AnkiCardTemplates.wordFront(l), AnkiCardTemplates.wordBack(l), AnkiCardTemplates.fillFront(l), AnkiCardTemplates.fillBack(l)] {
            #expect(referencedFields(html).subtracting(word).isEmpty, "\(referencedFields(html).subtracting(word))")
        }
        for q in [true, false] {
            let fields = Set(q ? AnkiService.snippetFields : AnkiService.baseSnippetFields)
            for html in [AnkiCardTemplates.noteFront(l, hasQuestion: q), AnkiCardTemplates.noteBack(l, hasQuestion: q)] {
                #expect(referencedFields(html).subtracting(fields).isEmpty, "\(referencedFields(html).subtracting(fields))")
            }
        }
        // 没有 Question 的老笔记类型：正面是标题，模板里一个 Question 都不能有
        #expect(!AnkiCardTemplates.noteFront(l, hasQuestion: false).contains("Question"))
        #expect(!AnkiCardTemplates.noteBack(l, hasQuestion: false).contains("Question"))
        // 填空卡整段包在 {{#Fill}} 里：Fill 为空就不生成卡，默认不会多出一倍卡
        #expect(AnkiCardTemplates.fillFront(l).hasPrefix("{{#Fill}}") && AnkiCardTemplates.fillFront(l).hasSuffix("{{/Fill}}"))

        let css = AnkiCardTemplates.css(l)
        #expect(css.hasPrefix("/* GetNewWord card · v2 */\n/* labels: "))
        #expect(AnkiCardTemplates.isCurrentVersion(css: css))
        #expect(AnkiCardTemplates.labelLanguage(css: css) == l.language)
        #expect(css.contains(".nightMode") && css.contains(".night_mode"))
        #expect(css.contains("@media (max-width: 520px)"))
        #expect(css.contains(":has("))
        #expect(!AnkiCardTemplates.isCurrentVersion(css: ".card { color: #333; }"))
        // 取景框、下划线、取景框里的首字母：pref 里「查的词用重点色」
        #expect(css.contains(".pairs .ctx .kw") && css.contains(".ctx-tr .kw") && css.contains(".fill.front .ctx .kw"))
    }

    /// 卡片上的固定文字按界面语言：英文、德文的 bundle 给出不同文字，CSS 第二行记着是哪种语言
    @Test func cardLabelsFollowInterfaceLanguage() throws {
        let zh = AnkiCardTemplates.Labels()
        #expect(zh.which == "这句里的" || zh.language != "zh-Hans")
        for code in ["en", "de"] {
            let path = try #require(Bundle.main.path(forResource: code, ofType: "lproj"))
            let l = AnkiCardTemplates.Labels(bundle: try #require(Bundle(path: path)))
            #expect(l.language == code)
            #expect(l.foldUsage != "用法和例句" && l.which != "这句里的" && l.foldShot != "当时的画面" && l.fillTag != "填空")
            let html = AnkiCardTemplates.wordBack(l) + AnkiCardTemplates.wordFront(l) + AnkiCardTemplates.fillBack(l) + AnkiCardTemplates.noteBack(l, hasQuestion: true)
            #expect(html.firstMatch(of: /[一-鿿]/) == nil, "\(code) 的模板里还有中文")
            #expect(AnkiCardTemplates.labelLanguage(css: AnkiCardTemplates.css(l)) == code)
        }
    }

    // MARK: - 字段拼法

    @Test func meaningGroupsByPartOfSpeech() {
        func word(_ meaning: String, _ sense: String?) -> WordEntry {
            WordEntry(word: "x", language: .english, meaning: meaning, contextMeaning: sense, contextSentence: "", contextTranslation: "", analysisNote: "")
        }
        // 词性一组一个 div，组之间是藏起来的 " ｜ "；这句里的义项是 <b>，不写死颜色
        let two = AnkiService.emphasizedMeaningHTML(word("v. 规定；开处方 ｜ n. 处方", "开处方"))
        #expect(two == "<div class=\"pos-group\"><span class=\"pos\">v.</span> 规定；<b>开处方</b></div><span class=\"sep\"> ｜ </span><div class=\"pos-group\"><span class=\"pos\">n.</span> 处方</div>")
        #expect(!two.contains("color"))
        // 没有词性前缀、没有语境义项、义项不在释义里：不出错，文字原样
        #expect(AnkiService.emphasizedMeaningHTML(word("汇合处；汇流", nil)) == "<div class=\"pos-group\">汇合处；汇流</div>")
        #expect(AnkiService.emphasizedMeaningHTML(word("n. 汇合处", "别的")) == "<div class=\"pos-group\"><span class=\"pos\">n.</span> 汇合处</div>")
        // 义项跨了词性组的老数据：整段里标出来，不拆
        #expect(AnkiService.emphasizedMeaningHTML(word("n. 甲 ｜ v. 乙", "甲 ｜ v. 乙")) == "n. <b>甲 ｜ v. 乙</b>")
    }

    @Test func snippetFields() {
        let s = KnowledgeSnippet(title: "进出环岛怎么打转向灯", content: "进环岛：不打灯。\n出环岛：打右转灯。\n环岛里的车先走。", sourceContext: "Beim Einfahren …", domain: "交通规则",
                                 question: " 在德国开进环岛要打转向灯吗？ ")
        let f = anki.snippetTextFields(s)
        #expect(f["Content"] == "<ul class=\"pts\"><li>进环岛：不打灯。</li><li>出环岛：打右转灯。</li><li>环岛里的车先走。</li></ul>")
        #expect(f["Question"] == "在德国开进环岛要打转向灯吗？")
        // 一行、或中间有空行的内容不做列表（空行做成列表会丢）
        #expect(anki.snippetTextFields(KnowledgeSnippet(title: "t", content: "单独一条", sourceContext: "", domain: "d"))["Content"] == "单独一条")
        #expect(anki.snippetTextFields(KnowledgeSnippet(title: "t", content: "甲\n\n乙", sourceContext: "", domain: "d"))["Content"] == "甲<br><br>乙")
        // 没有问题就不写这个键，免得清掉 Anki 里已有的
        #expect(anki.snippetTextFields(KnowledgeSnippet(title: "t", content: "c", sourceContext: "", domain: "d"))["Question"] == nil)
    }

    // MARK: - 老格式和新格式的卡恢复成同一份词库数据

    private struct RestoredWord: Equatable {
        var word, meaning, contextMeaning, phonetic, grammar, usage, coll, ex, ety: String
        var sentences: [String], translations: [String]
        var language: Language, difficulty: Difficulty
    }

    private func restoreWord(fields: [String: String]) async throws -> RestoredWord {
        let target = try makeLibrary()
        let model = wordModel
        FakeAnkiConnect.reply = { @Sendable call in
            let query = call.params["query"] as? String ?? ""
            switch call.action {
            case "findNotes" where query == "\"note:\(model)\"": return .success([1])
            case "findNotes": return .success([Int]())
            case "notesInfo":
                let info: [String: Any] = ["noteId": 1, "tags": [String](), "cards": [11],
                                           "fields": Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element.key, ["value": $0.element.value, "order": $0.offset]) })]
                return .success([info])
            default: return Self.normalAnki(call)
            }
        }
        #expect(await anki.restoreFromAnki(context: target) == 1)
        let w = try #require(try target.fetch(FetchDescriptor<WordEntry>()).first)
        let ctx = (w.contexts ?? []).sorted { $0.sentence < $1.sentence }
        return RestoredWord(word: w.word, meaning: w.meaning, contextMeaning: w.contextMeaning ?? "", phonetic: w.phonetic ?? "", grammar: w.grammar ?? "",
                            usage: w.analysisNote, coll: w.collocationsText ?? "", ex: w.examplesText ?? "", ety: w.etymology ?? "",
                            sentences: ctx.map(\.sentence), translations: ctx.map(\.translation), language: w.language, difficulty: w.difficulty)
    }

    /// 1.3.0 写出来的卡（释义一行带写死的蓝色、小标题带空格、语境是裸文字）、1.2.0 以前的卡（小标题没有 lbl-xxx）、
    /// 和这一版写出来的卡，恢复成同一份数据
    @Test func oldAndNewFormatRestoreTheSame() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        word.meaning = "n. 汇合处；汇流 ｜ v. 汇集"
        let new = anki.wordTextFields(word)
        #expect(new["Back"]?.contains("pos-group") == true)

        let oldCurrent: [String: String] = [
            "Front": "confluence",
            "Back": "n. <b style=\"color:#5E6AD2\">汇合处</b>；汇流 ｜ v. 汇集",
            "Phonetic": "/ˈkɒnfluəns/",
            "Context": "<div class=\"ctx\">The town sits at the <span class=\"kw\">confluence</span> of two rivers.</div>",
            "ContextTranslation": "<div class=\"ctx-tr\">小镇坐落在两条河的<span class=\"kw\">交汇处</span>。</div>",
            "Analysis": "<div class=\"lbl lbl-usage\">用 法</div><div class=\"usage\">多指河流交汇。</div>"
                + "<div class=\"lbl lbl-coll\">搭 配</div><div class=\"sec\"><div class=\"ctx\"><span class=\"kw\">at the confluence</span> of<div class=\"zh\">在……的交汇处</div></div></div>"
                + "<div class=\"lbl lbl-ex\">例 句</div><div class=\"sec\"><div class=\"ctx\">a <span class=\"kw\">confluence</span> of factors<div class=\"zh\">多种因素的汇合</div></div></div>"
                + "<div class=\"lbl lbl-ety\">词根词源</div><div class=\"sec\">con- 一起 + fluere 流</div>",
            "Language": "英语", "Difficulty": "C1", "Grammar": "", "Audio": "", "Screenshot": ""
        ]
        // 1.2.0 以前：小标题没有 lbl-xxx，语境和译文是裸文字
        var veryOld = oldCurrent
        veryOld["Context"] = "The town sits at the <span class=\"kw\">confluence</span> of two rivers."
        veryOld["ContextTranslation"] = "小镇坐落在两条河的<span class=\"kw\">交汇处</span>。"
        veryOld["Analysis"] = oldCurrent["Analysis"]!.replacingOccurrences(of: #" lbl-(usage|coll|ex|ety)"#, with: "", options: .regularExpression)

        var newFields = new
        newFields["Audio"] = ""; newFields["Screenshot"] = ""
        let fromNew = try await restoreWord(fields: newFields)
        let fromOld = try await restoreWord(fields: oldCurrent)
        let fromVeryOld = try await restoreWord(fields: veryOld)

        #expect(fromNew == fromOld)
        #expect(fromNew == fromVeryOld)
        #expect(fromNew.meaning == "n. 汇合处；汇流 ｜ v. 汇集")
        #expect(fromNew.contextMeaning == "汇合处")
        #expect(fromNew.sentences == ["The town sits at the confluence of two rivers."])
        #expect(fromNew.translations == ["小镇坐落在两条河的交汇处。"])
        #expect(fromNew.usage == "多指河流交汇。")
        #expect(fromNew.coll == "at the confluence of —— 在……的交汇处")
        #expect(fromNew.ex == "a confluence of factors —— 多种因素的汇合")
    }

    private struct RestoredSnippet: Equatable { var title, content, source, domain: String; var question: String? }

    private func restoreSnippet(fields: [String: String]) async throws -> RestoredSnippet {
        let target = try makeLibrary()
        let model = snippetModel
        FakeAnkiConnect.reply = { @Sendable call in
            let query = call.params["query"] as? String ?? ""
            switch call.action {
            case "findNotes" where query == "\"note:\(model)\"": return .success([2])
            case "findNotes": return .success([Int]())
            case "notesInfo":
                let info: [String: Any] = ["noteId": 2, "tags": [String](), "cards": [21],
                                           "fields": Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element.key, ["value": $0.element.value, "order": $0.offset]) })]
                return .success([info])
            default: return Self.normalAnki(call)
            }
        }
        #expect(await anki.restoreFromAnki(context: target) == 1)
        let s = try #require(try target.fetch(FetchDescriptor<KnowledgeSnippet>()).first)
        return RestoredSnippet(title: s.title, content: s.content, source: s.sourceContext, domain: s.domain, question: s.question)
    }

    /// 老知识卡（要点用 <br>，没有 Question 字段）和新的（编号列表，有 Question）恢复出同样的标题和要点；问题只有新卡有
    @Test func oldAndNewSnippetRestore() async throws {
        let s = KnowledgeSnippet(title: "进出环岛怎么打转向灯", content: "进环岛：不打灯。\n出环岛：打右转灯。\n环岛里的车先走。", sourceContext: "Beim Einfahren", domain: "交通规则",
                                 question: "在德国开进环岛要打转向灯吗？")
        var new = anki.snippetTextFields(s)
        new["Screenshot"] = ""
        let old: [String: String] = ["Title": s.title, "Content": "进环岛：不打灯。<br>出环岛：打右转灯。<br>环岛里的车先走。", "Source": "Beim Einfahren", "Domain": "交通规则", "Screenshot": ""]
        let fromNew = try await restoreSnippet(fields: new)
        let fromOld = try await restoreSnippet(fields: old)
        #expect(fromNew.content == "进环岛：不打灯。\n出环岛：打右转灯。\n环岛里的车先走。")
        #expect(fromNew.question == "在德国开进环岛要打转向灯吗？")
        #expect(fromOld.question == nil)
        var fromNewNoQuestion = fromNew; fromNewNoQuestion.question = nil
        #expect(fromNewNoQuestion == fromOld)
    }

    // MARK: - 新建、升级、询问

    /// 全新的 Anki：两个笔记类型直接建成 v2，字段齐全，不问用户
    @Test func freshAnkiGetsV2WithoutAsking() async throws {
        let anki = self.anki
        let fake = FakeAnkiCollection(models: [:])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        try await anki.ensureModelExists()
        try await anki.ensureSnippetModelExists()

        let word = try #require(fake.models[wordModel])
        #expect(word.fields == AnkiService.wordFields)
        #expect(Set(word.templates.keys) == ["正面", "语境填空"])
        #expect(AnkiCardTemplates.isCurrentVersion(css: word.css))
        let snippet = try #require(fake.models[snippetModel])
        #expect(snippet.fields == AnkiService.snippetFields)
        #expect(snippet.templates["知识"]?["Front"]?.contains("{{Question}}") == true)
        #expect(!AnkiUpgrade.shared.promptVisible)
        #expect(!AnkiUpgrade.shared.structurePending)
        #expect(UserDefaults.standard.bool(forKey: AnkiService.refreshPendingKey) == false)
    }

    /// 老 Anki、用户还没点继续：样式和模板换成 v2（不加字段），字段和填空模板不动，询问挂起；
    /// 同步只写笔记类型已有的字段，不会因为 Fill、Question 报错
    @Test func upgradeWithoutApprovalOnlyRestyles() async throws {
        let anki = self.anki
        let fake = FakeAnkiCollection(models: [wordModel: legacyWordModel(), snippetModel: legacySnippetModel()])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }

        try await anki.ensureExistingModelsUpToDate()

        #expect(FakeAnkiConnect.calls("modelFieldAdd").isEmpty)
        #expect(FakeAnkiConnect.calls("modelTemplateAdd").isEmpty)
        let word = try #require(fake.models[wordModel])
        #expect(word.fields == AnkiService.baseWordFields)
        #expect(AnkiCardTemplates.isCurrentVersion(css: word.css))
        #expect(word.templates["正面"]?["Front"]?.contains("gnw b word front") == true)
        #expect(word.templates["语境填空"] == nil)
        let snippet = try #require(fake.models[snippetModel])
        #expect(snippet.templates["知识"]?["Front"]?.contains("gnw b note front") == true)
        // 还没有 Question 字段：模板里不能提它
        #expect(snippet.templates["知识"]?["Front"]?.contains("Question") == false)
        #expect(AnkiUpgrade.shared.promptVisible)
        #expect(AnkiUpgrade.shared.structurePending)
        #expect(UserDefaults.standard.bool(forKey: AnkiService.refreshPendingKey))

        // 同步一个词和一个片段：只写已有的字段
        let context = try makeLibrary()
        let w = try sampleWord(in: context, withMedia: true)
        w.ankiNoteId = 42
        AnkiService.FillMode.all.save()
        try await anki.syncWord(w, context: context)
        let s = KnowledgeSnippet(title: "t", content: "a\nb", sourceContext: "s", domain: "d", question: "q?")
        s.ankiNoteId = 43
        context.insert(s)
        try await anki.syncSnippet(s, context: context)
        #expect(fake.notes[42]?["Fill"] == nil)
        #expect(fake.notes[42]?["Front"] == "confluence")
        #expect(fake.notes[43]?["Question"] == nil)
        #expect(fake.notes[43]?["Content"] == "<ul class=\"pts\"><li>a</li><li>b</li></ul>")
    }

    /// 点了「继续」：Fill、Question 一起加，加填空卡模板，知识卡模板换成有 Question 的；再核对一遍什么都不用改
    @Test func upgradeWithApprovalAddsFieldsTogether() async throws {
        let anki = self.anki
        let fake = FakeAnkiCollection(models: [wordModel: legacyWordModel(), snippetModel: legacySnippetModel()])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        AnkiUpgrade.shared.approved = true

        try await anki.ensureExistingModelsUpToDate()

        #expect(FakeAnkiConnect.calls("modelFieldAdd").compactMap { $0.params["fieldName"] as? String } == ["Fill", "Question"])
        let word = try #require(fake.models[wordModel])
        #expect(word.fields == AnkiService.wordFields)
        #expect(word.templates["语境填空"]?["Front"]?.hasPrefix("{{#Fill}}") == true)
        let snippet = try #require(fake.models[snippetModel])
        #expect(snippet.fields == AnkiService.snippetFields)
        #expect(snippet.templates["知识"]?["Front"]?.contains("{{Question}}") == true)
        #expect(snippet.templates["知识"]?["Back"]?.contains("{{#Question}}") == true)
        #expect(!AnkiUpgrade.shared.structurePending)

        // 第二次：已经是当前版本，一个写入的请求都不发
        FakeAnkiConnect.calls = []
        try await anki.ensureExistingModelsUpToDate()
        let writes = ["modelFieldAdd", "modelTemplateAdd", "updateModelStyling", "updateModelTemplates", "createModel"]
        #expect(FakeAnkiConnect.calls.filter { writes.contains($0.action) }.isEmpty)
    }

    /// 界面语言换了：模板文字重写成新语言的，不加字段、不要求单向同步，老卡也不用重写
    @Test func labelLanguageChangeRewritesTemplatesOnly() async throws {
        let anki = self.anki
        let fake = FakeAnkiCollection(models: [:])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        try await anki.ensureModelExists(labels: AnkiCardTemplates.Labels())
        UserDefaults.standard.removeObject(forKey: AnkiService.refreshPendingKey)
        FakeAnkiConnect.calls = []

        let path = try #require(Bundle.main.path(forResource: "de", ofType: "lproj"))
        let de = AnkiCardTemplates.Labels(bundle: try #require(Bundle(path: path)))
        try await anki.ensureModelExists(labels: de)

        #expect(FakeAnkiConnect.calls("modelFieldAdd").isEmpty)
        #expect(FakeAnkiConnect.calls("updateModelTemplates").count == 1)
        let word = try #require(fake.models[wordModel])
        #expect(AnkiCardTemplates.labelLanguage(css: word.css) == "de")
        #expect(word.templates["正面"]?["Back"]?.contains(de.foldUsage) == true)
        #expect(word.templates["语境填空"]?["Front"]?.contains(de.fillTag) == true)
        #expect(de.fillTag != "填空")
        // 卡上的「语言」字段跟着界面语言写：已同步的卡要补写一次（只写这一个字段，见 languageChangeRewritesOnlyLanguageField）
        #expect(UserDefaults.standard.bool(forKey: AnkiService.refreshPendingKey))
    }

    /// 样式、模板读不到（Anki 没回话）就不动，免得把用户的模板当成旧版本覆盖掉
    @Test func unreadableStylingLeavesModelAlone() async throws {
        let anki = self.anki
        let fake = FakeAnkiCollection(models: [wordModel: legacyWordModel()])
        FakeAnkiConnect.reply = { @Sendable call in
            call.action == "modelStyling" ? .failure(.init(message: "boom")) : fake.handle(call)
        }
        try await anki.ensureModelExists()
        #expect(FakeAnkiConnect.calls("updateModelStyling").isEmpty)
        #expect(FakeAnkiConnect.calls("updateModelTemplates").isEmpty)
    }

    // MARK: - 后台重写老卡

    /// 1.3.0 写进 Anki 的 syncedWords(…) 里那种词的字段：同样的文字，格式是老的
    private func oldFormatFields(_ i: Int) -> [String: String] {
        ["Front": "w\(i)", "Back": "n. <b style=\"color:#5E6AD2\">词\(i)</b>", "Phonetic": "", "Context": "A <span class=\"kw\">w\(i)</span> here.",
         "ContextTranslation": "这里有<span class=\"kw\">词\(i)</span>。", "Analysis": "<div class=\"lbl lbl-usage\">用 法</div><div class=\"usage\">用法</div>",
         "Language": "英语", "Difficulty": "B1", "Grammar": ""]
    }

    private func syncedWords(_ n: Int, in context: ModelContext) throws {
        for i in 1...n {
            let w = WordEntry(word: "w\(i)", language: .english, meaning: "n. 词\(i)", contextMeaning: "词\(i)", contextSentence: "A w\(i) here.", contextTranslation: "这里有词\(i)。",
                              analysisNote: "用法", ankiNoteId: 1000 + i, syncStatus: .synced)
            context.insert(w)
        }
        try context.save()
    }

    /// 已同步的词和片段按新拼法重写：每批 50 个 multi，只发文字字段，不带发音和截图
    @Test func refreshRewritesSyncedNotesInBatchesOf50() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        try syncedWords(120, in: context)
        let s = KnowledgeSnippet(title: "t", content: "a\nb", sourceContext: "s", domain: "d", syncStatus: .synced)
        s.ankiNoteId = 2001
        context.insert(s)
        try context.save()
        let fake = FakeAnkiCollection(models: [:])
        for i in 1...120 { fake.seed(1000 + i, oldFormatFields(i)) }
        fake.seed(2001, ["Title": "t", "Content": "a<br>b", "Source": "s", "Domain": "d"])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        UserDefaults.standard.set(true, forKey: AnkiService.refreshPendingKey)

        await anki.refreshSyncedNotesIfPending(context: context)

        let multis = FakeAnkiConnect.calls("multi")
        #expect(multis.map { ($0.params["actions"] as? [Any])?.count } == [50, 50, 21])
        let first = try #require((multis[0].params["actions"] as? [[String: Any]])?.first)
        #expect(first["action"] as? String == "updateNoteFields")
        let fields = try #require(((first["params"] as? [String: Any])?["note"] as? [String: Any])?["fields"] as? [String: String])
        #expect(fields["Audio"] == nil && fields["Screenshot"] == nil)
        #expect(fields["Back"]?.hasPrefix("<div class=\"pos-group\">") == true)
        #expect(fake.notes.count == 121)
        #expect(fake.notes[2001]?["Content"] == "<ul class=\"pts\"><li>a</li><li>b</li></ul>")
        #expect(FakeAnkiConnect.calls("notesInfo").count == 3)
        #expect(UserDefaults.standard.bool(forKey: AnkiService.refreshPendingKey) == false)
        // 没标记的时候一个请求也不发
        FakeAnkiConnect.calls = []
        await anki.refreshSyncedNotesIfPending(context: context)
        #expect(FakeAnkiConnect.calls.isEmpty)
    }

    /// 中途 Anki 断了：标记留着，下次接着重写
    @Test func refreshInterruptedKeepsMarker() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        try syncedWords(60, in: context)
        let seen = Counter()
        let fake = FakeAnkiCollection(models: [:])
        for i in 1...60 { fake.seed(1000 + i, oldFormatFields(i)) }
        FakeAnkiConnect.reply = { @Sendable call in
            guard call.action == "multi" else { return fake.handle(call) }
            return seen.next() == 1 ? .success([Any]()) : .failure(.init(message: "collection is not available"))
        }
        UserDefaults.standard.set(true, forKey: AnkiService.refreshPendingKey)
        await anki.refreshSyncedNotesIfPending(context: context)
        #expect(FakeAnkiConnect.calls("multi").count == 2)
        #expect(UserDefaults.standard.bool(forKey: AnkiService.refreshPendingKey))
    }

    // MARK: - 语境填空卡

    @Test func fillCardRules() throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        func want(_ mode: AnkiService.FillMode) -> Bool { AnkiService.wantsFillCard(word, mode: mode) }
        #expect(!want(.off))
        #expect(want(.all))
        word.lookupCount = 2
        #expect(!want(.frequent))
        word.lookupCount = 3
        #expect(want(.frequent))
        word.lookupCount = 1
        word.ankiFill = true
        #expect(want(.off))
        // 没有能挖的句子（词不在句子里、或根本没有语境）：任何设置下都不生成
        word.contexts?.forEach { $0.sentence = "Nothing relevant." }
        #expect(!want(.all))
        #expect(!AnkiService.hasFillSentence(word))
    }

    /// 笔记类型有 Fill 字段时 syncWord 按设置写 Fill；没有这个字段时不写
    @Test func syncWordWritesFill() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: true)
        word.ankiNoteId = 7
        let fake = FakeAnkiCollection(models: [:])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        try await anki.ensureModelExists()

        try await anki.syncWord(word, context: context)
        #expect(fake.notes[7]?["Fill"] == "")
        AnkiService.FillMode.frequent.save()
        word.lookupCount = 5
        try await anki.syncWord(word, context: context)
        #expect(fake.notes[7]?["Fill"] == "1")
    }

    /// 设置里改选项：已同步的词只重写 Fill 一个字段
    @Test func fillChoiceRewritesOnlyFill() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        try syncedWords(3, in: context)
        let fake = FakeAnkiCollection(models: [wordModel: legacyWordModel()])
        for i in 1...3 { fake.seed(1000 + i, ["Fill": ""]) }
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        AnkiUpgrade.shared.approved = true
        AnkiService.FillMode.all.save()

        await anki.applyFillChoice(context: context)

        #expect(fake.models[wordModel]?.fields.contains("Fill") == true)
        #expect(fake.notes[1001] == ["Fill": "1"])
        #expect(Set(fake.notes.keys) == [1001, 1002, 1003])
    }

    /// 词卡右键加一张填空卡：写本地标记，Anki 里只改这一张的 Fill
    @Test func contextMenuAddsFillCard() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        word.ankiNoteId = 9
        word.syncStatus = .synced
        let fake = FakeAnkiCollection(models: [:])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        try await anki.ensureModelExists()

        await anki.setFillCard(word, on: true, context: context)
        #expect(word.ankiFill)
        #expect(fake.notes[9] == ["Fill": "1"])
        #expect(FakeAnkiConnect.calls("unsuspend").count == 1)
        await anki.setFillCard(word, on: false, context: context)
        #expect(!word.ankiFill)
        #expect(fake.notes[9] == ["Fill": ""])
        // Fill 变空，Anki 不会删已有的语境填空卡：暂停它们，免得复习时出现「正面是空的」
        let suspend = try #require(FakeAnkiConnect.calls("suspend").first)
        #expect(suspend.params["cards"] as? [Int] == [11, 12])
        let query = try #require(FakeAnkiConnect.calls("findCards").last?.params["query"] as? String)
        #expect(query.contains("card:语境填空") && query.contains("nid:9"))
    }

    // MARK: - 知识卡的问题

    @Test func snippetQuestionRoundTripsThroughAnki() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        let fake = FakeAnkiCollection(models: [:])
        FakeAnkiConnect.reply = { @Sendable call in call.action == "addNote" ? .success(55) : fake.handle(call) }
        try await anki.ensureSnippetModelExists()
        let s = KnowledgeSnippet(title: "环岛", content: "不打灯\n出时打灯", sourceContext: "s", domain: "交通", question: "进环岛要打灯吗？")
        context.insert(s)
        try await anki.syncSnippet(s, context: context)

        let note = try #require(FakeAnkiConnect.calls("addNote").first?.params["note"] as? [String: Any])
        #expect(note["modelName"] as? String == snippetModel)
        let fields = try #require(note["fields"] as? [String: String])
        #expect(fields["Question"] == "进环岛要打灯吗？")
        #expect(fields["Content"] == "<ul class=\"pts\"><li>不打灯</li><li>出时打灯</li></ul>")
    }

    /// AI 回的片段带不带 question 都能解析；没给就是 nil（卡片正面用标题）
    @Test func snippetAnalysisQuestionIsOptional() throws {
        let with = #"{"words":[],"snippets":[{"title":"环岛","content":"a\nb","question":"进环岛要打灯吗？","sourceContext":"x","tags":[]}]}"#
        let without = #"{"words":[],"snippets":[{"title":"环岛","content":"a\nb","sourceContext":"x"}]}"#
        let a = try JSONDecoder().decode(WordAnalysisResult.self, from: Data(with.utf8))
        let b = try JSONDecoder().decode(WordAnalysisResult.self, from: Data(without.utf8))
        #expect(a.snippets.first?.question == "进环岛要打灯吗？")
        #expect(b.snippets.first?.question == nil)
        #expect(ZhipuService.shared.buildWordAnalysisPrompt(existingTags: [], categoryTree: "").contains("\"question\""))
    }

    /// 云端：question 列不参与内容哈希，所以云端有没有这一列，同步都不会来回改写；拉到的行没有这一列也能解码
    @Test func cloudRowQuestionDoesNotAffectHash() throws {
        let s = KnowledgeSnippet(title: "t", content: "c", sourceContext: "s", domain: "d", question: "q?")
        let withQ = CloudSyncService.row(s)
        var withoutQ = withQ; withoutQ.question = nil
        #expect(withQ.question == "q?")
        #expect(CloudSyncService.contentHash(withQ) == CloudSyncService.contentHash(withoutQ))

        let json = #"{"id":"a","title":"t","content":"c","source_context":"s","tags":[],"domain":"d","created_at":"2026-10-01T00:00:00Z","is_archived":false,"sync_status":"synced","related_word_ids":[]}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(SnippetRow.self, from: Data(json.utf8)).question == nil)
        let withColumn = json.replacingOccurrences(of: #""tags":[]"#, with: #""tags":[],"question":"q?""#)
        #expect(try decoder.decode(SnippetRow.self, from: Data(withColumn.utf8)).question == "q?")
        // 推送用的列清单里没有 question（没跑 SQL 的云端不认这一列）
        #expect(!SnippetRow.columns.contains("question"))
    }
}

extension AnkiService.FillMode {
    /// 测试里写设置
    func save() { UserDefaults.standard.set(rawValue, forKey: AnkiService.FillMode.key) }
}

// MARK: - 复审后补的情形

extension AnkiServiceTests {
    private var wm: String { AppVariant.ankiName }
    private var sm: String { AppVariant.ankiName + " Snippet" }

    private func legacyWord() -> FakeAnkiCollection.Model {
        .init(fields: AnkiService.baseWordFields, css: ".card { text-align: center; }",
              templates: ["正面": ["Front": "{{Front}}{{Grammar}}{{Audio}}", "Back": "{{FrontSide}}<hr>{{Back}}{{Context}}{{Analysis}}{{Screenshot}}"]])
    }

    /// 升级中样式、模板的任何一步失败，同步照样把新卡加进 Anki（1.3.0 也是这样）
    @Test func failedUpgradeNeverBlocksSync() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        let fake = FakeAnkiCollection(models: [wm: legacyWord()])
        FakeAnkiConnect.reply = { @Sendable call in
            ["modelTemplateAdd", "updateModelStyling", "updateModelTemplates", "modelFieldAdd"].contains(call.action)
                ? .failure(.init(message: "unsupported action")) : fake.handle(call)
        }
        AnkiUpgrade.shared.approved = true

        await anki.syncAllPendingWords([word], context: context)

        #expect(!FakeAnkiConnect.calls("addNote").isEmpty, "升级失败不能挡住同步")
        #expect(word.syncStatus == .synced)
        // 字段没加成：只写笔记类型已有的字段
        let note = try #require(FakeAnkiConnect.calls("addNote").first?.params["note"] as? [String: Any])
        let used = Set(try #require(note["fields"] as? [String: String]).keys)
        #expect(used.subtracting(AnkiService.baseWordFields).isEmpty)
        // 知识卡一样
        let snippetFake = FakeAnkiCollection(models: [sm: .init(fields: AnkiService.baseSnippetFields, css: "", templates: ["知识": ["Front": "{{Title}}", "Back": "{{Content}}"]])])
        FakeAnkiConnect.reply = { @Sendable call in
            call.action == "updateModelStyling" ? .failure(.init(message: "boom")) : snippetFake.handle(call)
        }
        try await anki.ensureSnippetModelExists()
    }

    /// 读不到笔记类型列表、建不起笔记类型，才是同步做不下去的错
    @Test func missingModelListStillThrows() async throws {
        let anki = self.anki
        FakeAnkiConnect.reply = { @Sendable call in call.action == "modelNames" ? .failure(.init(message: "boom")) : Self.normalAnki(call) }
        await #expect(throws: (any Error).self) { try await anki.ensureModelExists() }
    }

    /// 用户在 Anki 里删了「语境填空」卡片类型：平时核对不加回来（加模板会让 Anki 要求单向同步）；点过「继续」的那次启动里才加
    @Test func deletedFillTemplateIsNotReAdded() async throws {
        let anki = self.anki
        let css = AnkiCardTemplates.css(.init())
        let l = AnkiCardTemplates.Labels()
        let model = FakeAnkiCollection.Model(fields: AnkiService.wordFields, css: css,
                                             templates: ["正面": ["Front": AnkiCardTemplates.wordFront(l), "Back": AnkiCardTemplates.wordBack(l)]])
        let fake = FakeAnkiCollection(models: [wm: model])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }

        try await anki.ensureModelExists()
        #expect(FakeAnkiConnect.calls("modelTemplateAdd").isEmpty)
        #expect(FakeAnkiConnect.calls("updateModelStyling").isEmpty)
        #expect(fake.models[wm]?.templates["语境填空"] == nil)

        AnkiUpgrade.shared.approved = true
        try await anki.ensureModelExists()
        #expect(FakeAnkiConnect.calls("modelTemplateAdd").count == 1)
        #expect(fake.models[wm]?.templates["语境填空"] != nil)
    }

    /// 用户自己加过卡片类型（比如反向卡）：认「正面」当主模板，不把别的模板改成单词卡的
    @Test func ownTemplatesAreNotOverwritten() async throws {
        let anki = self.anki
        let model = FakeAnkiCollection.Model(fields: AnkiService.baseWordFields, css: ".card{}", templates: [
            "Card 2": ["Front": "{{Back}}", "Back": "{{Front}}"],
            "正面": ["Front": "old front", "Back": "old back"]
        ])
        let fake = FakeAnkiCollection(models: [wm: model])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        try await anki.ensureModelExists()
        #expect(fake.models[wm]?.templates["Card 2"]?["Front"] == "{{Back}}")
        #expect(fake.models[wm]?.templates["正面"]?["Front"]?.contains("gnw b word front") == true)
    }

    /// 两处同时升级（点「继续」、同步前的核对）：只加一次字段、一次模板
    @Test func concurrentUpgradesRunOneAtATime() async throws {
        let anki = self.anki
        let fake = FakeAnkiCollection(models: [wm: legacyWord()])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        AnkiUpgrade.shared.approved = true

        async let a: Void = anki.ensureModelExists()
        async let b: Void = anki.ensureModelExists()
        async let c: Void = anki.ensureModelExists()
        _ = try await (a, b, c)

        #expect(FakeAnkiConnect.calls("modelFieldAdd").count == 1)
        #expect(FakeAnkiConnect.calls("modelTemplateAdd").count == 1)
        #expect(fake.models[wm]?.fields.filter { $0 == "Fill" }.count == 1)
    }

    /// 填空卡显示的是最近的一句：只有更早的句子里有这个词，不生成
    @Test func fillCardNeedsWordInLatestSentence() throws {
        let context = try makeLibrary()
        let word = WordEntry(word: "go", language: .english, meaning: "v. 去", contextSentence: "She went home.", contextTranslation: "她回家了。", analysisNote: "")
        context.insert(word)
        let older = WordContext(sentence: "I go home.", translation: "我回家。", word: word)
        older.createdAt = Date(timeIntervalSinceNow: -100)
        let latest = WordContext(sentence: "She went home.", translation: "她回家了。", word: word)
        context.insert(older); context.insert(latest)
        try context.save()
        #expect(!AnkiService.hasFillSentence(word))
        #expect(!AnkiService.wantsFillCard(word, mode: .all))
        latest.sentence = "Let's go home."
        #expect(AnkiService.hasFillSentence(word))
        #expect(AnkiService.wantsFillCard(word, mode: .all))
    }

    /// 设置（所有词 / 查过 3 次以上）已经定了的词，右键菜单改不了
    @Test func settingForcesFillCard() throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        word.lookupCount = 1
        #expect(!AnkiService.settingForcesFillCard(word, mode: .off))
        #expect(AnkiService.settingForcesFillCard(word, mode: .all))
        #expect(!AnkiService.settingForcesFillCard(word, mode: .frequent))
        word.lookupCount = 3
        #expect(AnkiService.settingForcesFillCard(word, mode: .frequent))
    }

    /// 变形词整词标出来：stems 不是只标 stem
    @Test func highlightCoversWholeInflection() {
        #expect(AnkiService.hl("Her fear stems from the past.", word: "stem") == "Her fear <span class=\"kw\">stems</span> from the past.")
        #expect(AnkiService.hl("He is running.", word: "running") == "He is <span class=\"kw\">running</span>.")
        #expect(AnkiService.hl("She walked and walks.", word: "walk") == "She <span class=\"kw\">walked</span> and <span class=\"kw\">walks</span>.")
    }

    // MARK: 重写时保护用户改过的字段

    @Test func refreshKeepsFieldsEditedInAnki() {
        let new = ["Back": "<div class=\"pos-group\"><span class=\"pos\">n.</span> 词</div>", "Analysis": "<div class=\"lbl lbl-usage\">用法</div><div class=\"usage\">甲</div>",
                   "Language": "Deutsch", "Fill": "1", "Question": "问？", "Context": "<div class=\"ctx\">x</div>"]
        let current = ["Back": "n. 我自己改过的释义", "Analysis": "<div class=\"lbl lbl-usage\">用 法</div><div class=\"usage\">甲</div>",
                       "Language": "德语", "Fill": "", "Question": "", "Context": "<div class=\"ctx\">x</div>"]
        let (send, kept) = AnkiService.refreshableFields(new: new, current: current)
        #expect(kept == 1)
        #expect(send["Back"] == nil, "改过的释义留着")
        #expect(send["Analysis"] == new["Analysis"], "只是小标题去了空格，换成新格式")
        #expect(send["Language"] == "Deutsch" && send["Fill"] == "1", "语言名和填空开关由 App 定")
        #expect(send["Question"] == "问？", "Anki 里是空的，写")
        #expect(send["Context"] == nil, "早已一样，不用写")
        // 笔记类型里没有这个字段：不写
        #expect(AnkiService.refreshableFields(new: ["Fill": "1"], current: [:]).send.isEmpty)
    }

    @Test func refreshSendsOnlyUnchangedTextFormat() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        let w = WordEntry(word: "w1", language: .english, meaning: "n. 词1", contextMeaning: "词1", contextSentence: "A w1 here.", contextTranslation: "这里有词1。",
                          analysisNote: "用法", ankiNoteId: 5, syncStatus: .synced)
        context.insert(w)
        try context.save()
        let fake = FakeAnkiCollection(models: [:])
        var old = ["Front": "w1", "Back": "n. 我改过", "Context": "A <span class=\"kw\">w1</span> here."]
        old["Language"] = "德语"
        fake.seed(5, old)
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }

        #expect(await anki.refreshSyncedNotes(context: context))

        #expect(fake.notes[5]?["Back"] == "n. 我改过", "用户改过的释义不动")
        #expect(fake.notes[5]?["Language"] == w.language.displayName)
        #expect(fake.notes[5]?["Context"] == "<div class=\"ctx\">A <span class=\"kw\">w1</span> here.</div>", "只是格式不同，换成新格式")
    }

    /// 语境填空关掉：已有的填空卡暂停，不然复习时一张张显示「正面是空的」
    @Test func turningFillOffSuspendsCards() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        try syncedFillWords(2, in: context)
        let fake = FakeAnkiCollection(models: [wm: .init(fields: AnkiService.wordFields, css: AnkiCardTemplates.css(.init()), templates: ["正面": ["Front": "", "Back": ""], "语境填空": ["Front": "", "Back": ""]])])
        fake.seed(1001, ["Fill": "1"]); fake.seed(1002, ["Fill": ""])
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        try await anki.ensureModelExists()
        AnkiService.FillMode.off.save()

        await anki.applyFillChoice(context: context)

        #expect(fake.notes[1001]?["Fill"] == "")
        let suspend = FakeAnkiConnect.calls("suspend")
        #expect(suspend.count == 1)
        let query = FakeAnkiConnect.calls("findCards").last?.params["query"] as? String ?? ""
        #expect(query.contains("nid:1001") && !query.contains("1002"))
        #expect(FakeAnkiConnect.calls("unsuspend").isEmpty)

        AnkiService.FillMode.all.save()
        await anki.applyFillChoice(context: context)
        #expect(fake.notes[1001]?["Fill"] == "1" && fake.notes[1002]?["Fill"] == "1")
        #expect(FakeAnkiConnect.calls("unsuspend").count == 1)
    }

    private func syncedFillWords(_ n: Int, in context: ModelContext) throws {
        for i in 1...n {
            context.insert(WordEntry(word: "w\(i)", language: .english, meaning: "n. 词\(i)", contextMeaning: "词\(i)", contextSentence: "A w\(i) here.", contextTranslation: "这里有词\(i)。",
                                     analysisNote: "用法", ankiNoteId: 1000 + i, syncStatus: .synced))
        }
        try context.save()
    }

    /// Anki 没开时改了设置：记一笔，下次同步（Anki 开着）补写
    @Test func fillChangeWhileAnkiClosedIsRetried() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        try syncedFillWords(2, in: context)
        let fake = FakeAnkiCollection(models: [wm: .init(fields: AnkiService.wordFields, css: AnkiCardTemplates.css(.init()), templates: ["正面": ["Front": "", "Back": ""], "语境填空": ["Front": "", "Back": ""]])])
        fake.seed(1001, ["Fill": ""]); fake.seed(1002, ["Fill": ""])
        FakeAnkiConnect.reply = { @Sendable call in call.action == "version" ? .failure(.init(message: "closed")) : fake.handle(call) }
        AnkiService.FillMode.all.save()

        await anki.applyFillChoice(context: context)
        #expect(UserDefaults.standard.bool(forKey: AnkiService.fillRefreshPendingKey))
        #expect(fake.notes[1001]?["Fill"] == "")

        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }
        await anki.syncEverythingPending(context: context)
        #expect(fake.notes[1001]?["Fill"] == "1")
        #expect(!UserDefaults.standard.bool(forKey: AnkiService.fillRefreshPendingKey))
        UserDefaults.standard.removeObject(forKey: AnkiService.fillRefreshPendingKey)
    }

    /// 只改界面语言：已同步的卡只补写「语言」字段
    @Test func languageChangeRewritesOnlyLanguageField() async throws {
        let anki = self.anki
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        word.ankiNoteId = 77
        word.syncStatus = .synced
        let fake = FakeAnkiCollection(models: [:])
        var current = anki.wordTextFields(word)
        current["Language"] = "Zzz"
        fake.seed(77, current)
        FakeAnkiConnect.reply = { @Sendable call in fake.handle(call) }

        #expect(await anki.refreshSyncedNotes(context: context))
        let action = try #require((FakeAnkiConnect.calls("multi").first?.params["actions"] as? [[String: Any]])?.first)
        let fields = try #require(((action["params"] as? [String: Any])?["note"] as? [String: Any])?["fields"] as? [String: String])
        #expect(fields == ["Language": word.language.displayName])
    }

    // MARK: 语言名

    /// 卡上的「语言」按界面语言写；恢复词库时中文、英文、德文写法都认，1.3.0 写的中文名也认
    @Test func languageFieldFollowsInterfaceAndRestores() async throws {
        let context = try makeLibrary()
        let word = try sampleWord(in: context, withMedia: false)
        #expect(anki.wordTextFields(word)["Language"] == Language.english.displayName)
        for name in ["英语", "English", "Englisch", Language.english.displayName] {
            let restored = try await restoreLanguage(name)
            #expect(restored == .english, "\(name)")
        }
        #expect(try await restoreLanguage("Deutsch") == .german)
        #expect(try await restoreLanguage("德语") == .german)
        #expect(try await restoreLanguage("Klingon") == .other)
    }

    private func restoreLanguage(_ name: String) async throws -> Language {
        let target = try makeLibrary()
        let model = wm
        FakeAnkiConnect.reply = { @Sendable call in
            let query = call.params["query"] as? String ?? ""
            switch call.action {
            case "findNotes" where query == "\"note:\(model)\"": return .success([1])
            case "findNotes": return .success([Int]())
            case "notesInfo":
                let fields = ["Front": "w", "Back": "n. x", "Language": name, "Difficulty": "B1"]
                let info: [String: Any] = ["noteId": 1, "tags": [String](), "cards": [11],
                                           "fields": Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element.key, ["value": $0.element.value, "order": $0.offset]) })]
                return .success([info])
            default: return Self.normalAnki(call)
            }
        }
        _ = await anki.restoreFromAnki(context: target)
        return try #require(try target.fetch(FetchDescriptor<WordEntry>()).first).language
    }

    // MARK: 样式

    @Test func cssRules() {
        let l = AnkiCardTemplates.Labels()
        let css = AnkiCardTemplates.css(l)
        // 翻面不跳：正面不垂直居中
        #expect(!css.contains("min-height: 52vh") && !css.contains("justify-content: center"))
        #expect(css.contains("text-wrap: pretty"))
        // 每个词最多 40 句配对，第 8 句和第 40 句都有顺序规则
        #expect(css.contains(".ctxs .ctx:nth-child(8) { order: 15; }") && css.contains(".trs .ctx-tr:nth-child(40) { order: 80; }"))
        // 折叠提示只在非中文的手机上藏起来；根节点带语言类
        #expect(css.contains(".gnw:not(.lang-zh) details.fold > summary .hint { display: none; }"))
        #expect(AnkiCardTemplates.wordFront(l).contains("lang-\(l.language.prefix(2))"))
        #expect(AnkiCardTemplates.noteBack(l, hasQuestion: true).contains(l.langClass))
        #expect(l.langClass == (l.language == "zh-Hans" ? "lang-zh" : "lang-\(l.language)"))
    }

    // MARK: 云端

    @Test func cloudHashIncludesQuestionOnceColumnExists() {
        let s = KnowledgeSnippet(title: "t", content: "c", sourceContext: "s", domain: "d", question: "q?")
        let row = CloudSyncService.row(s)
        var noQuestion = row; noQuestion.question = nil
        #expect(CloudSyncService.contentHash(row) == CloudSyncService.contentHash(noQuestion))
        #expect(CloudSyncService.contentHash(row, withQuestion: true) != CloudSyncService.contentHash(noQuestion, withQuestion: true))
        // 没有问题的片段，跑 SQL 前后哈希一样：不会为了它们多推一次
        #expect(CloudSyncService.contentHash(noQuestion) == CloudSyncService.contentHash(noQuestion, withQuestion: true))
    }
}
