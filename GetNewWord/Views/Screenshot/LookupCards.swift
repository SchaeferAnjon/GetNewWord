// LookupCards.swift
// GetNewWord
//
// 查词面板的内容（design/panels）：两种样式共用一份展示数据和同一套部件。
// - 跟词浮签（B）：先只给这句里的意思和整句译文，点「展开讲解」再用页签看释义、用法、例句、构词、语法
// - 讲义卡（A）：一整张卡分层摆全：这句话 → 释义（这句里的义项整行高亮）→ 用法 → 搭配和例句 → 构词和来历
// 设置 → 翻译与学习 里选，浮签还能设成默认展开。

import SwiftUI

// MARK: - 样式

enum LookupPanelStyle: String, CaseIterable, Identifiable {
    case tag, tagExpanded, lecture

    static let key = "lookupPanelStyle"
    static var current: LookupPanelStyle {
        LookupPanelStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .tag
    }

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .tag: return "跟词浮签"
        case .tagExpanded: return "浮签，默认展开"
        case .lecture: return "讲义卡"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .tag: return "先只给这句里的意思和整句译文，想细看再展开"
        case .tagExpanded: return "一出来就带页签：释义、用法、例句、构词、语法"
        case .lecture: return "一整张卡，所有内容分层摆全"
        }
    }

    /// 弹出时面板的大小：浮签收起时矮，展开和讲义卡高
    func panelSize(expanded: Bool) -> NSSize {
        switch self {
        case .lecture: return NSSize(width: 480, height: 640)
        case .tag, .tagExpanded: return expanded ? NSSize(width: 440, height: 520) : NSSize(width: 400, height: 250)
        }
    }
}

// MARK: - 展示数据：新查的和词库直出的都转成它

struct LookupWord {
    var word: String
    var phonetic: String?
    var language: Language
    var difficulty: Difficulty?
    var grammar: String?
    var meaning: String
    var contextMeaning: String?
    var sentence: String
    var translation: String
    var translationKeyword: String?
    var usage: String?
    var collocations: [String]?
    var examples: [String]?
    var etymology: String?
    var lookupCount: Int
    /// 用法、例句、构词还在第二次请求里生成
    var extrasPending: Bool

    init(analysis w: WordAnalysis, enrichment e: WordEnrichment?, lookupCount: Int, enriching: Bool) {
        word = w.word
        phonetic = w.phonetic
        language = Language(rawValue: w.language.lowercased()) ?? .other
        difficulty = Difficulty(rawValue: w.difficulty.lowercased())
        grammar = w.grammar
        meaning = e?.meaning ?? w.meaning
        contextMeaning = w.contextMeaning
        sentence = w.contextSentence
        translation = w.contextTranslation
        translationKeyword = w.translationKeyword
        usage = e?.usage ?? w.analysisNote
        collocations = e?.collocations
        examples = e?.examples ?? w.examples
        etymology = e?.etymology ?? w.etymology
        self.lookupCount = lookupCount
        extrasPending = enriching || (e == nil && w.examples == nil)
    }

    init(entry: WordEntry, enrichment e: WordEnrichment?, lookupCount: Int) {
        word = entry.word
        phonetic = entry.phonetic
        language = entry.language
        difficulty = entry.difficulty
        grammar = entry.grammar
        meaning = entry.meaning
        contextMeaning = entry.contextMeaning
        let ctx = entry.sortedContexts.last
        sentence = ctx?.sentence ?? entry.contextSentence
        translation = ctx?.translation ?? entry.contextTranslation
        translationKeyword = entry.translationKeyword
        usage = e?.usage ?? (entry.analysisNote.isEmpty ? nil : entry.analysisNote)
        collocations = e?.collocations ?? entry.collocationsText?.components(separatedBy: "\n").filter { !$0.isEmpty }
        examples = e?.examples ?? entry.examplesText?.components(separatedBy: "\n").filter { !$0.isEmpty }
        etymology = e?.etymology ?? entry.etymology
        self.lookupCount = lookupCount
        extrasPending = false
    }

    /// 这句里的意思：浮签上的大字。模型给的义项为准，没有就取释义第一项
    var senseHere: String {
        if let c = contextMeaning?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        return MeaningGroups.parse(meaning).first?.senses.first ?? meaning
    }

    /// 这句里那个义项的词性（v. / n. …）
    var posHere: String? {
        MeaningGroups.parse(meaning).first { $0.senses.contains { contextMeaning.map($0.contains) ?? false } }?.pos
    }
}

/// 释义「v. 规定；开处方 ｜ n. 处方」拆成按词性的组
enum MeaningGroups {
    struct Group: Hashable { let pos: String?; let senses: [String] }

    static func parse(_ meaning: String) -> [Group] {
        meaning.components(separatedBy: CharacterSet(charactersIn: "｜|")).compactMap { raw in
            var text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            var pos: String?
            if let r = text.range(of: #"^[a-zA-Z]+\.(\s*/\s*[a-zA-Z]+\.)?\s*"#, options: .regularExpression) {
                pos = text[r].trimmingCharacters(in: .whitespaces)
                text = String(text[r.upperBound...])
            }
            let senses = text.components(separatedBy: CharacterSet(charactersIn: "；;")).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return Group(pos: pos, senses: senses)
        }
    }
}

// MARK: - 共用部件

/// 词头：原形、朗读；下一行音标、词性和变化、等级、查过几次
struct LookupHead: View {
    let w: LookupWord
    var big: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(w.word).font(.system(size: big, weight: .bold)).textSelection(.enabled)
                Button {
                    AudioService.shared.speak(w.word, language: w.language)
                } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain).focusable(false).focusEffectDisabled().help("朗读")
                Spacer(minLength: 0)
                if w.lookupCount > 1 {
                    Text("查过 \(w.lookupCount) 次").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
                if let d = w.difficulty { Chip(text: d.displayName, tone: .custom(Theme.levelColor(d))) }
            }
            HStack(spacing: 8) {
                if let p = w.phonetic, !p.isEmpty {
                    Text(TextHighlighter.ipa(p)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text2)
                }
                if let g = w.grammar, !g.isEmpty {
                    Text(g).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2).lineLimit(2)
                }
            }
        }
    }
}

/// 小节：小号灰标题 + 内容
struct LookupSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「这句话」：原句（被查的词高亮）+ 整句译文（对应的词标出来）；右上角拆语法
struct SentenceBlock: View {
    let w: LookupWord
    var grammar: GrammarBreakdownState?
    var canBreakDown = true
    var onBreakDown: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("这句话").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                Spacer()
                if let onBreakDown {
                    Button(action: onBreakDown) {
                        HStack(spacing: 4) {
                            if grammar?.streaming == true { ProgressView().controlSize(.mini) }
                            Text(grammar == nil ? "拆语法" : "重新拆")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canBreakDown || grammar?.streaming == true)
                    .help("把这句话的语法从头到尾拆开讲一遍")
                }
            }
            Text(TextHighlighter.highlight(w.word, in: w.sentence))
                .font(.system(size: 14.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !w.translation.isEmpty {
                Text(TextHighlighter.emphasizeTranslation(w.translationKeyword, sense: w.contextMeaning, in: w.translation))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let grammar {
                GrammarBreakdownSection(state: grammar).padding(.top, 4)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 释义：按词性分组、编号；这句里用到的义项整行高亮，标「这句里」
struct MeaningList: View {
    let w: LookupWord

    var body: some View {
        let groups = MeaningGroups.parse(w.meaning)
        let here = w.contextMeaning?.trimmingCharacters(in: .whitespaces) ?? ""
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(g.pos ?? "·").font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text3).frame(width: 34, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(g.senses.enumerated()), id: \.offset) { i, sense in
                            let isHere = !here.isEmpty && (sense == here || here.contains(sense) || sense.contains(here))
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(i + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3)
                                Text(sense).font(.system(size: 14, weight: isHere ? .semibold : .regular))
                                    .foregroundStyle(isHere ? Theme.accent : Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                if isHere {
                                    Text("这句里").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(.horizontal, isHere ? 6 : 0)
                            .padding(.vertical, isHere ? 3 : 0)
                            .background(isHere ? Theme.accentSoft.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
    }
}

/// 用法、搭配、例句、构词和来历；还在生成时显示一行占位
struct LookupExtras: View {
    let w: LookupWord
    var showUsage = true
    var showExamples = true
    var showEtymology = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showUsage, let u = w.usage, !u.isEmpty {
                LookupSection(title: "用法") {
                    Text(TextHighlighter.highlight(w.word, in: u)).font(.system(size: 13.5)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showExamples, let c = w.collocations, !c.isEmpty {
                LookupSection(title: "搭配") {
                    VStack(alignment: .leading, spacing: 6) { ForEach(c, id: \.self) { exampleView($0, word: w.word) } }
                }
            }
            if showExamples, let ex = w.examples, !ex.isEmpty {
                LookupSection(title: "例句") {
                    VStack(alignment: .leading, spacing: 6) { ForEach(ex, id: \.self) { exampleView($0, word: w.word) } }
                }
            }
            if showEtymology, let e = w.etymology, !e.isEmpty {
                LookupSection(title: "构词和来历") {
                    Text(e).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if w.extrasPending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("用法 · 例句 · 词根词源 生成中…").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
        }
    }
}

/// 加载占位：每块先占好位置，内容来了不跳
struct LookupSkeleton: View {
    let headWord: String?
    var lines = 4
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headWord {
                Text(headWord).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text2)
            } else {
                bar(160, 24)
            }
            ForEach(0..<lines, id: \.self) { i in bar(i == 0 ? 220 : CGFloat(320 - i * 40), 12) }
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }

    private func bar(_ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Theme.selected).frame(width: w, height: h)
    }
}

// MARK: - 讲义卡（A）

struct LectureCard: View {
    let w: LookupWord
    var grammar: GrammarBreakdownState?
    var canBreakDown = true
    var onBreakDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LookupHead(w: w)
            if !w.sentence.isEmpty {
                SentenceBlock(w: w, grammar: grammar, canBreakDown: canBreakDown, onBreakDown: onBreakDown)
            }
            LookupSection(title: "释义") { MeaningList(w: w) }
            LookupExtras(w: w)
        }
    }
}

// MARK: - 跟词浮签（B）

struct FloatingTag: View {
    let w: LookupWord
    @Binding var expanded: Bool
    var grammar: GrammarBreakdownState?
    var canBreakDown = true
    var onBreakDown: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case meaning, usage, examples, etymology, grammar
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .meaning: return "释义"
            case .usage: return "用法"
            case .examples: return "例句"
            case .etymology: return "构词"
            case .grammar: return "语法"
            }
        }
    }
    @State private var tab: Tab = .meaning

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(w.word).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                if let p = w.phonetic, !p.isEmpty {
                    Text(TextHighlighter.ipa(p)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3)
                }
                Button {
                    AudioService.shared.speak(w.word, language: w.language)
                } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain).focusable(false).focusEffectDisabled().help("朗读")
                Spacer(minLength: 0)
                if let d = w.difficulty { Chip(text: d.displayName, tone: .custom(Theme.levelColor(d))) }
            }
            // 这句里的意思：大字
            Text(w.senseHere)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let pos = w.posHere {
                Text(pos + (w.grammar.map { "  " + $0 } ?? "")).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            if !w.translation.isEmpty {
                Text(TextHighlighter.emphasizeTranslation(w.translationKeyword, sense: w.contextMeaning, in: w.translation))
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                tabs
            }
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { t in
                    Button {
                        tab = t
                        if t == .grammar, grammar == nil { onBreakDown() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(t.title)
                            if pending(t) { Circle().fill(Theme.accent).frame(width: 4, height: 4) }
                        }
                        .font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Theme.text : Theme.text2)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(tab == t ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(t == .grammar && !canBreakDown)
                }
            }
            Hairline()
            Group {
                switch tab {
                case .meaning: MeaningList(w: w)
                case .usage: LookupExtras(w: w, showExamples: false, showEtymology: false)
                case .examples: LookupExtras(w: w, showUsage: false, showEtymology: false)
                case .etymology: LookupExtras(w: w, showUsage: false, showExamples: false)
                case .grammar:
                    if let grammar { GrammarBreakdownSection(state: grammar) }
                    else { Text("等语境句出来后可用").font(.system(size: 12.5)).foregroundStyle(Theme.text3) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    /// 页签名后的小点：这个页签的内容还在生成
    private func pending(_ t: Tab) -> Bool {
        switch t {
        case .usage, .examples, .etymology: return w.extrasPending
        case .grammar: return grammar?.streaming == true
        case .meaning: return false
        }
    }
}

// MARK: - 知识片段

struct SnippetLookupCard: View {
    let snippet: SnippetAnalysis
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snippet.title).font(.system(size: compact ? 16 : 19, weight: .semibold)).textSelection(.enabled)
            Text(snippet.content)
                .font(.system(size: 13.5)).lineSpacing(3)
                .lineLimit(compact ? 3 : nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !compact, !snippet.sourceContext.isEmpty {
                LookupSection(title: "出自这句") {
                    Text(snippet.sourceContext).font(.system(size: 12.5)).italic().foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
