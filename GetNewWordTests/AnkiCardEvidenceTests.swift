// 交付用的图：只在设置了 TEST_RUNNER_GNW_EVIDENCE_OUT=<文件夹> 时才做事，平时（make test）直接通过。
// 1) 用应用自己的代码拼出一批笔记的字段、取出三种语言的模板和 CSS，写成 fixtures.json，
//    交给 Python 的官方 anki 包（真 Anki 的模板引擎）渲染出每张卡的 HTML，再用 Chrome 截图；
// 2) 把设置里新增的一行和升级询问用 SwiftUI 离屏画成 PNG（不开窗口）。

import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import GetNewWord

@MainActor
struct AnkiCardEvidenceTests {
    private var outDir: URL? {
        ProcessInfo.processInfo.environment["GNW_EVIDENCE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func makeWord(_ word: String, phonetic: String? = nil, language: Language, meaning: String, sense: String?, keyword: String?,
                          contexts: [(String, String)], usage: String, grammar: String? = nil, coll: String? = nil, ex: String? = nil, ety: String? = nil,
                          difficulty: Difficulty, lookups: Int = 1, in context: ModelContext) -> WordEntry {
        let w = WordEntry(word: word, phonetic: phonetic, language: language, meaning: meaning, contextMeaning: sense,
                          contextSentence: contexts.last?.0 ?? "", contextTranslation: contexts.last?.1 ?? "", analysisNote: usage, grammar: grammar,
                          collocationsText: coll, examplesText: ex, etymology: ety, difficulty: difficulty)
        w.translationKeyword = keyword
        w.lookupCount = lookups
        context.insert(w)
        for (i, c) in contexts.enumerated() {
            context.insert(WordContext(sentence: c.0, translation: c.1, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 86400)), word: w))
        }
        return w
    }

    @Test func exportCardFixtures() throws {
        guard let out = outDir else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let context = try makeLibrary()
        let anki = AnkiService.shared

        let nach = makeWord("Nachhaltigkeit", phonetic: "/ˈnaːxhaltɪçkaɪ̯t/", language: .german, meaning: "n. 可持续性；持久性；长远效果", sense: "可持续性", keyword: "可持续性",
                            contexts: [("Für viele Kunden ist Nachhaltigkeit inzwischen ein Kaufargument.", "如今对很多顾客来说，可持续性已经是买东西时会考虑的一点。"),
                                       ("Die Studie zeigt, dass die Nachhaltigkeit der Lieferketten deutlich zugenommen hat.", "研究表明，供应链的可持续性明显提高了。")],
                            usage: "多用在环保、经济和企业话题里；日常更常说形容词 nachhaltig（可持续的）。不可数，没有复数。", grammar: "die Nachhaltigkeit · 无复数",
                            coll: "ökologische Nachhaltigkeit —— 生态可持续性\nauf Nachhaltigkeit achten —— 注重可持续性",
                            ex: "Das Unternehmen setzt stark auf Nachhaltigkeit. —— 这家公司非常看重可持续性。",
                            ety: "nach（往后）+ halten（保持）→ nachhaltig（长久保持的）+ -keit（名词后缀）", difficulty: .b2, lookups: 4, in: context)
        let stem = makeWord("stem", phonetic: "/stem/", language: .english, meaning: "v. 源于；遏制 ｜ n. 茎；词干 ｜ adj. 干细胞的", sense: "源于", keyword: "源于",
                            contexts: [("These problems stem from a lack of trust between the two teams.", "这些问题源于两个团队之间缺乏信任。")],
                            usage: "stem from 表示问题、情绪的来源，后面接原因；作名词指植物的茎，也指词干。", grammar: nil,
                            coll: "stem from —— 源于\nstem the flow of —— 遏制……的流动", ex: "Her fear stems from a childhood accident. —— 她的恐惧源于童年的一次事故。",
                            ety: "古英语 stemn（树干）", difficulty: .b2, in: context)
        let gehen = makeWord("gehen", phonetic: "/ˈɡeːən/", language: .german, meaning: "v. 走；去；运转", sense: "走；去", keyword: "去",
                             contexts: [("Wir gingen nach dem Essen noch lange am Fluss entlang.", "吃完饭我们又沿着河走了很久。")],
                             usage: "最基本的动词之一，不规则变化。", grammar: "unregelmäßig · geht · ging · ist gegangen", difficulty: .a1, in: context)
        let solo = makeWord("Fernweh", phonetic: "/ˈfɛʁnˌveː/", language: .german, meaning: "n. 对远方的向往", sense: nil, keyword: nil, contexts: [],
                            usage: "与 Heimweh（思乡）相对。", grammar: "das Fernweh · 无复数", difficulty: .c1, in: context)

        let many = makeWord("stem", phonetic: "/stem/", language: .english, meaning: "v. 源于；遏制 ｜ n. 茎；词干", sense: "源于", keyword: "源于",
                            contexts: (1...8).map { ("Sentence \($0): these problems stem from trust issue \($0).", "第 \($0) 句：这些问题源于信任问题 \($0)。") },
                            usage: "stem from 表示来源。", difficulty: .b2, in: context)

        func wordFields(_ w: WordEntry, audio: String, shot: String) -> [String: String] {
            var f = anki.wordTextFields(w)
            f["Audio"] = audio
            f["Screenshot"] = shot
            return f
        }
        let nachFields = wordFields(nach, audio: "[sound:gnw_nach.mp3]", shot: "<img src=\"gnw_img_nach.png\">")
        var nachFill = nachFields
        nachFill["Fill"] = "1"
        // 1.3.0 写出来的老格式：释义一行带写死的蓝色，小标题带空格，语境是现成的 div
        var oldFormat = nachFields
        oldFormat["Back"] = "n. <b style=\"color:#5E6AD2\">可持续性</b>；持久性；长远效果"
        oldFormat["Analysis"] = nachFields["Analysis"]!
            .replacingOccurrences(of: ">用法<", with: ">用 法<").replacingOccurrences(of: ">搭配<", with: ">搭 配<").replacingOccurrences(of: ">例句<", with: ">例 句<")
        oldFormat["Fill"] = ""

        let kreis = KnowledgeSnippet(title: "进出环岛怎么打转向灯", content: "进环岛：不打灯。入口立着「让行」加环岛标志时，进的时候打灯反而违规。\n出环岛：在要出的那个口之前打右转灯，让后面和等着进来的车知道你要出去。\n环岛里的车先走，进去之前先让。",
                                     sourceContext: "Beim Einfahren in einen Kreisverkehr ist das Blinken unzulässig. Vor dem Ausfahren muss rechtzeitig rechts geblinkt werden.",
                                     domain: "交通规则", question: "在德国开进环岛要打转向灯吗？开出去呢？")
        var kreisFields = anki.snippetTextFields(kreis)
        kreisFields["Screenshot"] = "<img src=\"gnw_snip_kreis.png\">"
        var kreisOld: [String: String] = ["Title": kreis.title, "Content": kreis.content.replacingOccurrences(of: "\n", with: "<br>"), "Source": kreis.sourceContext,
                                          "Domain": "交通规则", "Screenshot": "<img src=\"gnw_snip_kreis.png\">"]
        kreisOld["Question"] = ""

        func languages() throws -> [String: Any] {
            var all: [String: Any] = [:]
            for code in ["zh-Hans", "en", "de"] {
                let l: AnkiCardTemplates.Labels
                if code == "zh-Hans" { l = AnkiCardTemplates.Labels() } else {
                    let path = try #require(Bundle.main.path(forResource: code, ofType: "lproj"))
                    l = AnkiCardTemplates.Labels(bundle: try #require(Bundle(path: path)))
                }
                all[code] = [
                    "css": AnkiCardTemplates.css(l),
                    "wordFront": AnkiCardTemplates.wordFront(l), "wordBack": AnkiCardTemplates.wordBack(l),
                    "fillFront": AnkiCardTemplates.fillFront(l), "fillBack": AnkiCardTemplates.fillBack(l),
                    "noteFront": AnkiCardTemplates.noteFront(l, hasQuestion: true), "noteBack": AnkiCardTemplates.noteBack(l, hasQuestion: true),
                    "noteFrontNoQ": AnkiCardTemplates.noteFront(l, hasQuestion: false), "noteBackNoQ": AnkiCardTemplates.noteBack(l, hasQuestion: false),
                ]
            }
            return all
        }
        let json: [String: Any] = [
            "wordFields": AnkiService.wordFields, "snippetFields": AnkiService.snippetFields, "languages": try languages(),
            "notes": [
                ["id": "nach", "kind": "word", "fields": nachFields],
                ["id": "stem", "kind": "word", "fields": wordFields(stem, audio: "[sound:gnw_stem.mp3]", shot: "")],
                ["id": "gehen", "kind": "word", "fields": wordFields(gehen, audio: "[sound:gnw_gehen.mp3]", shot: "")],
                ["id": "solo", "kind": "word", "fields": wordFields(solo, audio: "[sound:gnw_solo.mp3]", shot: "")],
                ["id": "fill", "kind": "word", "fields": nachFill],
                ["id": "many", "kind": "word", "fields": wordFields(many, audio: "[sound:gnw_stem.mp3]", shot: "")],
                ["id": "old", "kind": "word", "fields": oldFormat],
                ["id": "kreis", "kind": "snippet", "fields": kreisFields],
                ["id": "kreis-old", "kind": "snippet", "fields": kreisOld],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("fixtures.json"))
    }

    // MARK: - 界面离屏截图

    /// 按内容高度画：先把宽度定死、竖向按内容撑开，换行的文字才不会被裁掉
    private func snapshot<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: AnyView(view.environment(\.modelContext, try makeLibrary())
            .frame(width: width).fixedSize(horizontal: false, vertical: true)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)   // 不显示，只给 SwiftUI 一个宿主
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.frame.size = NSSize(width: width, height: max(host.fittingSize.height, 40))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func renderSettingsAndPrompt() throws {
        guard let out = outDir else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            AnkiService.FillMode.frequent.save()
            AnkiUpgrade.shared.report(model: "GetNewWord", complete: false)
            // 设置 › Anki 里新增的两块：升级入口（字段还没加时才有）和语境填空卡的选项
            let page = VStack(alignment: .leading, spacing: 16) {
                AnkiUpgradeRow()
                AnkiFillChoiceView()
            }
            .padding(20).background(Theme.bg)
            try snapshot(page, width: 560, dark: dark, to: out.appendingPathComponent("settings-anki-fill-\(tag).png"))
            try snapshot(AnkiUpgradePromptView(onContinue: {}, onLater: {}), width: 460, dark: dark, to: out.appendingPathComponent("upgrade-prompt-\(tag).png"))
        }
        UserDefaults.standard.removeObject(forKey: AnkiService.FillMode.key)
        AnkiUpgrade.shared.resetForTesting()
    }
}
