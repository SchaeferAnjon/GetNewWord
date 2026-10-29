// AnalysisResultPanel.swift
// GetNewWord
//
// 查词结果浮动面板（design/panels）：样式由设置决定——经典卡片（默认，1.1.7 那版，ClassicCard.swift）、
// 跟词浮签（可默认展开）或讲义卡（LookupCards.swift）。经典卡片把这次认出的词和知识片段都列出来，另外两种只讲第一个。
// 框选会自动存，指词查词默认只查、点「存进词库」才存。

import SwiftUI
import SwiftData
import AppKit

// MARK: - 主面板

struct AnalysisResultPanel: View {
    @ObservedObject var viewModel: AnalysisViewModel
    /// 面板由 NSPanel 承载，拿不到 SwiftUI 环境里的 modelContext，显式传入（新建分类时用）
    let modelContext: ModelContext
    let onSave: () -> Void
    let onDismiss: () -> Void
    var onTogglePin: (Bool) -> Void = { _ in }
    var startPinned: Bool = false
    /// 浮签展开 / 收起时让窗口跟着变大变小
    var onResize: (NSSize) -> Void = { _ in }
    @State private var pinned = false
    @State private var expanded = false
    @AppStorage(LookupPanelStyle.key) private var style: LookupPanelStyle = .classic

    private var isLecture: Bool { style == .lecture }
    private var isClassic: Bool { style == .classic }
    /// 状态条在顶上、底栏只放撤销 / 存进词库（经典卡片和讲义卡）
    private var hasStatusBar: Bool { style.hasStatusBar }

    var body: some View {
        VStack(spacing: 0) {
            if hasStatusBar {
                statusBar
                Hairline()
            }
            ScrollView {
                Group { if isClassic { classicContent } else { content } }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 语法拆解流式增长时整列一起动：下面的内容平滑下移，不留空隙
                    .animation(.easeOut(duration: 0.18), value: viewModel.grammarText)
            }
            // 这次什么都没新存时底栏没东西可放（没有撤销），整条不要
            if !hasStatusBar || !viewModel.savedNothingNew {
                Hairline()
                footer
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        // 面板是 key window，系统会给第一个可聚焦控件套蓝色焦点环——整体禁用（对全部子视图生效）
        .focusEffectDisabled()
        .background {
            // 浮签半透明但底色留得很实：深色视频和白色 PDF 上字都清楚。经典卡片和讲义卡不透明：
            // 毛玻璃每帧都要窗口服务器把后面（常常是在播的视频）重新模糊一遍，配置低的 Mac 上滑动会跟着掉帧
            if hasStatusBar { Theme.elevated } else { ZStack { VisualEffectBackground(); Theme.elevated.opacity(0.82) } }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // 描边不接收鼠标，否则面板四边按下被它吃掉，拖边缘改不了大小
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 0.5).allowsHitTesting(false))
        .appAppearance()
        .onAppear {
            pinned = startPinned
            expanded = style != .tag
        }
    }

    // MARK: 内容

    private var word: LookupWord? {
        if let w0 = viewModel.analysisResult?.analysis.words.first, !viewModel.removedWords.contains(0) {
            return LookupWord(analysis: w0, enrichment: viewModel.enrichments[0],
                              lookupCount: viewModel.lookupCountValue(viewModel.savedWords[0]),
                              enriching: viewModel.enrichingIndices.contains(0))
        }
        if viewModel.analysisResult == nil, let hit = viewModel.cachedHit {
            return LookupWord(entry: hit, enrichment: viewModel.enrichments[0], lookupCount: viewModel.lookupCountValue(hit))
        }
        return nil
    }

    private var snippet: SnippetAnalysis? {
        guard let s = viewModel.analysisResult?.analysis.snippets.first, !viewModel.removedSnippets.contains(0) else { return nil }
        return s
    }

    @ViewBuilder private var content: some View {
        if let w = word {
            VStack(alignment: .leading, spacing: 16) {
                if isLecture {
                    LectureCard(w: w, grammar: viewModel.grammarState, canBreakDown: viewModel.grammarSentence != nil,
                                onBreakDown: viewModel.breakDownGrammar)
                } else {
                    FloatingTag(w: w, expanded: $expanded, grammar: viewModel.grammarState,
                                canBreakDown: viewModel.grammarSentence != nil, onBreakDown: viewModel.breakDownGrammar)
                }
                // 什么都没新存时状态条已经说了，卡片里不再重复
                if viewModel.skippedAsDuplicate.contains(0), !viewModel.savedNothingNew {
                    Label("这个词已在词库里，且语境几乎相同，本次未重复添加", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                if viewModel.analysisResult != nil, isLecture || expanded { wordCategoryRow() }
            }
        } else if let s = snippet {
            VStack(alignment: .leading, spacing: 16) {
                SnippetLookupCard(snippet: s, compact: !isLecture && !expanded)
                if isLecture || expanded { snippetCategoryRow(s) }
            }
        } else if isEmptyResult {
            VStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 26)).foregroundStyle(Theme.text3)
                Text("未识别到单词或知识片段").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            LookupSkeleton(headWord: viewModel.quickWord?.word, lines: isLecture ? 6 : 3)
        }
    }

    /// 经典卡片：1.1.7 的排法，单词一张张列下来，知识片段跟在后面
    @ViewBuilder private var classicContent: some View {
        VStack(spacing: 0) {
            // 主分析还没回来：词库直出或骨架（词头由极速识词先填）
            if viewModel.analysisResult == nil {
                if let hit = viewModel.cachedHit {
                    ClassicCachedCard(entry: hit, enrichment: viewModel.enrichments[0],
                                      lookupCount: viewModel.lookupCountValue(hit), grammar: viewModel.grammarState)
                } else {
                    ClassicSkeletonCard(quickWord: viewModel.quickWord, meaning: viewModel.enrichments[0]?.meaning)
                }
            }
            if let words = viewModel.analysisResult?.analysis.words, !words.isEmpty {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    if !viewModel.removedWords.contains(index) {
                        ClassicWordCard(
                            word: word,
                            isSelected: viewModel.selectedIndices.contains(index),
                            // 只有一部分词是老词时才在那张卡上提一句；全是老词时状态条说
                            skippedAsDuplicate: viewModel.skippedAsDuplicate.contains(index) && !viewModel.savedNothingNew,
                            showCheckbox: !viewModel.autoSaved,
                            onToggle: { viewModel.toggleWordSelection(index) },
                            categoryPicker: { wordCategoryRow(index) },
                            // 这次没存进去的老词没有「从这次保存中撤掉」可言
                            onRemove: viewModel.autoSaved && !viewModel.skippedAsDuplicate.contains(index)
                                ? { viewModel.removeSavedWord(index) } : nil,
                            enrichment: viewModel.enrichments[index],
                            screenshot: PanelPerf.hidesScreenshot ? nil : viewModel.analysisResult?.screenshot,
                            lookupCount: viewModel.lookupCountValue(viewModel.savedWords[index]),
                            grammar: index == 0 ? viewModel.grammarState : nil
                        )
                    }
                }
            }
            if let snippets = viewModel.analysisResult?.analysis.snippets, !snippets.isEmpty {
                Divider().padding(.vertical, 4)
                HStack {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                    Text("知识片段").font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                ForEach(Array(snippets.enumerated()), id: \.offset) { index, snippet in
                    if !viewModel.removedSnippets.contains(index) {
                        ClassicSnippetCard(snippet: snippet,
                                           onRemove: viewModel.autoSaved ? { viewModel.removeSavedSnippet(index) } : nil) {
                            snippetCategoryRow(snippet, index: index)
                        }
                    }
                }
            }
            if isEmptyResult {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("未识别到单词或知识片段").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }

    private func wordCategoryRow(_ index: Int = 0) -> CategoryAssignRow {
        let words = viewModel.analysisResult?.analysis.words ?? []
        let w = words.indices.contains(index) ? words[index] : nil
        return CategoryAssignRow(
            viewModel: viewModel, forWords: true,
            modelCategory: w?.category, suggested: w?.suggestedCategory,
            selection: Binding(get: { viewModel.chosenWordCategory[index] },
                               set: { viewModel.chosenWordCategory[index] = $0; viewModel.applyCategoryChange(forWord: index) }),
            modelContext: modelContext)
    }

    private func snippetCategoryRow(_ s: SnippetAnalysis, index: Int = 0) -> CategoryAssignRow {
        CategoryAssignRow(
            viewModel: viewModel, forWords: false,
            modelCategory: s.category, suggested: s.suggestedCategory,
            selection: Binding(get: { viewModel.chosenSnippetCategory[index] },
                               set: { viewModel.chosenSnippetCategory[index] = $0; viewModel.applyCategoryChange(forSnippet: index) }),
            modelContext: modelContext)
    }

    private var isEmptyResult: Bool {
        // 识别中（result 尚为 nil）显示占位，不算"空结果"
        guard let result = viewModel.analysisResult else { return false }
        return result.analysis.words.isEmpty && result.analysis.snippets.isEmpty
    }

    // MARK: 状态

    /// 一句话说现在怎样，分两截：前一截是状态（正在认词 / 已存进 德语 / 已在词库里 / 只查看），后一截是补充（Anki 稍后同步…）。
    /// 放不下时整截去掉补充，状态那截总是完整显示
    private var status: (main: String, more: String?) {
        if let hint = viewModel.netHint { return (hint, nil) }
        guard viewModel.analysisResult != nil else {
            if viewModel.cachedHit != nil { return (String(localized: "词库直出"), String(localized: "正在核对语境…")) }
            return (viewModel.quickWord != nil ? String(localized: "正在讲解…") : String(localized: "正在认词…"), nil)
        }
        if viewModel.savedNothingNew { return (String(localized: "已在词库里"), String(localized: "语境相同，没再存")) }
        if viewModel.autoSaved {
            let cat = (viewModel.savedWords[0]?.category ?? viewModel.savedSnippets[0]?.category)?.displayName
            let main = cat.map { String(localized: "已存进 \($0)") } ?? String(localized: "已存进词库")
            // 浮签底栏窄，只说存到哪；顶上有状态条的再补一句同步
            return (main, hasStatusBar ? String(localized: "Anki 稍后同步") : nil)
        }
        return (String(localized: "只查看，没存"), nil)
    }

    /// 状态那一行：整句放得下就整句，放不下只留状态那截（鼠标停上去看整句）
    private func statusLine(size: CGFloat, color: Color, showPin: Bool) -> some View {
        let s = status
        let main = showPin && pinned ? String(localized: "已钉住") + " · " + s.main : s.main
        let full = s.more.map { main + " · " + $0 } ?? main
        return ViewThatFits(in: .horizontal) {
            Text(full).fixedSize()
            Text(main).lineLimit(1)
        }
        .font(.system(size: size))
        .foregroundStyle(viewModel.netHint != nil ? Theme.warn : color)
        .help(full)
    }

    // MARK: 讲义卡顶上的状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image).renderingMode(.template).foregroundStyle(Theme.text2)
            if viewModel.analysisResult == nil { ProgressView().controlSize(.mini) }
            statusLine(size: 13, color: Theme.text2, showPin: true)
            Spacer(minLength: 8)
            if isClassic { breakDownButton }
            toolIcons
            closeButton
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.surface)
    }

    /// 经典卡片的「分解语法」：把语境整句拆开讲，流式插在释义上方
    private var breakDownButton: some View {
        Button(action: viewModel.breakDownGrammar) {
            HStack(spacing: 4) {
                if viewModel.grammarStreaming { ProgressView().controlSize(.mini) }
                else { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                Text("分解语法")
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .fixedSize()   // 按钮字不截；窄了先让状态那行去掉补充
        .disabled(viewModel.grammarSentence == nil || viewModel.grammarStreaming)
        .help(viewModel.grammarSentence == nil ? String(localized: "等语境句出来后可用") : String(localized: "把这句话的语法从头到尾拆开讲一遍"))
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 8) {
            if hasStatusBar {
                Spacer()
            } else {
                if viewModel.analysisResult == nil { ProgressView().controlSize(.mini) }
                statusLine(size: 11.5, color: Theme.text3, showPin: false)
                Spacer(minLength: 4)
            }
            if viewModel.autoSaved {
                if !viewModel.savedNothingNew {
                    Button("撤销") { viewModel.undoAutoSave() }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("删掉这次保存的内容")
                }
            } else if viewModel.analysisResult != nil, !isEmptyResult {
                Button("存进词库") { onSave() }.buttonStyle(PrimaryButtonStyle())
                    // 经典卡片能勾掉单词：一个都没勾、也没有知识片段时没东西可存
                    .disabled(isClassic && viewModel.selectedIndices.isEmpty && (viewModel.analysisResult?.analysis.snippets.isEmpty ?? true))
            }
            if !hasStatusBar {
                pinButton
                if word != nil || snippet != nil {
                    Button(expanded ? "收起" : "展开讲解") { setExpanded(!expanded) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                closeButton
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func setExpanded(_ e: Bool) {
        withAnimation(.easeOut(duration: 0.18)) { expanded = e }
        onResize(style.panelSize(expanded: e))
    }

    // MARK: 小图标：钉住、在主窗口打开、找图

    private var pinButton: some View {
        iconButton(pinned ? "pin.fill" : "pin", tint: pinned ? Theme.accent : Theme.text2,
                   help: pinned ? String(localized: "已钉住：点面板外不会关闭（Esc 或 ✕ 可关闭）") : String(localized: "钉在桌面上")) {
            pinned.toggle()
            onTogglePin(pinned)
        }
    }

    /// 状态条上的：钉住、在主窗口打开、找图（浮签底栏窄，只留钉住）
    private var toolIcons: some View {
        HStack(spacing: 2) {
            pinButton
            iconButton("macwindow", help: String(localized: "打开主窗口")) { MainWindowOpener.open() }
            iconButton("photo.on.rectangle.angled", help: String(localized: "找图：看看这是什么东西")) { searchImages() }
        }
    }

    private var closeButton: some View {
        iconButton("xmark", help: String(localized: "关闭"), action: onDismiss)
    }

    private func iconButton(_ symbol: String, tint: Color = Theme.text2, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).focusEffectDisabled().help(help)
    }

    /// 找图：多义词消歧，搜「词 + 当前语境义项」（如 "bulb 球茎"），不是裸词
    private func searchImages() {
        let first = viewModel.analysisResult?.analysis.words.first
        guard let w = first?.word ?? viewModel.quickWord?.word else { return }
        let sense = (first?.contextMeaning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = sense.isEmpty ? w : "\(w) \(sense)"
        if let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?tbm=isch&q=\(q)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 浮签的毛玻璃底
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 语法分解小节（流式）

/// 面板卡片读取的语法拆解快照（ViewModel 的三个 @Published 打包）
struct GrammarBreakdownState: Equatable {
    var text: String
    var streaming: Bool
    var error: String?
}

/// 「分解语法」小节：小灰标题 + 流式 Markdown；每来一段就长高，把释义及以下内容平滑推下去。
/// 讲解里引到查的那个词（和它的变形）也标紫
struct GrammarBreakdownSection: View {
    let state: GrammarBreakdownState
    let word: String
    let language: Language

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle(String(localized: "语法分解"))
                if state.streaming {
                    ProgressView().controlSize(.mini)
                }
            }
            if let err = state.error, state.text.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.text.isEmpty {
                Text("正在拆解这句话…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(Self.blocks(state.text).enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radiusLg))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).stroke(Theme.accent.opacity(0.18), lineWidth: 0.5))
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block { case heading(String), line(String) }

    /// 按行切：`## ` 开头当小标题，其余按行渲染（行内 Markdown：**加粗** / `代码`）
    private static func blocks(_ text: String) -> [Block] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("#") {
                let t = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : .heading(t)
            }
            return .line(line)
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let t):
            Text(t)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 6)
        case .line(let l):
            Text(TextHighlighter.mark(word, in: Self.inline(l), language: language))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 行内 Markdown → AttributedString；解析失败就原样显示（流式中途 ** 未闭合也不会闪）
    private static func inline(_ s: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

// MARK: - AI 解释小节

@ViewBuilder
func sectionTitle(_ t: String) -> some View {
    Text(t)
        .font(.system(size: 10, weight: .semibold))
        .tracking(Theme.sectionTracking)
        .foregroundStyle(Theme.text3)
}

/// 扁平小节：小灰标题 + 正文，无底色盒子
@ViewBuilder
func aiSection(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        sectionTitle(title)
        Text(body)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

/// 例句一条："外语原句 —— 中文"拆两行：原句斜体、查的词标紫，译文灰色小字
@ViewBuilder
func exampleView(_ line: String, word: String, language: Language) -> some View {
    let parts = line.components(separatedBy: "——")
    let foreign = parts.first?.trimmingCharacters(in: .whitespaces) ?? line
    let chinese = parts.count > 1 ? parts.dropFirst().joined(separator: "——").trimmingCharacters(in: .whitespaces) : nil
    VStack(alignment: .leading, spacing: 2) {
        Text(TextHighlighter.highlight(word, in: foreign, language: language))
            .font(.system(size: 13.5))
            .italic()
            .fixedSize(horizontal: false, vertical: true)
        if let chinese, !chinese.isEmpty {
            Text(chinese)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 分类归属行

/// 每个条目下方的「归入体系」行：
/// - 模型选中了体系里已有的分类 → 直接预选，用户可改
/// - 模型建议新建分类 → 显示建议，用户点「新建」或从现有分类里挑一个
/// - 都没有 → 提示用户选择（不选则按语言自动归类）
struct CategoryAssignRow: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let forWords: Bool
    let modelCategory: String?
    let suggested: String?
    @Binding var selection: UUID?
    let modelContext: ModelContext

    private var options: [Category] { viewModel.leafCategories(forWords: forWords) }
    private var selectedName: String { viewModel.category(id: selection)?.name ?? "" }

    @State private var showNewGroup = false
    @State private var newGroupName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("归入")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Menu 代替 Picker：底部可以放「新建分组…」
                Menu {
                    Button("未选择") { selection = nil }
                    ForEach(options, id: \.id) { cat in
                        Button {
                            selection = cat.id
                        } label: {
                            if selection == cat.id {
                                Label("\(cat.parent?.displayName ?? "") › \(cat.displayName)", systemImage: "checkmark")
                            } else {
                                Text("\(cat.parent?.displayName ?? "") › \(cat.displayName)")
                            }
                        }
                    }
                    Divider()
                    Button("新建分组…") { newGroupName = ""; showNewGroup = true }
                } label: {
                    Text(selectedName.isEmpty ? String(localized: "未选择") : "\(viewModel.category(id: selection)?.parent?.displayName ?? "") › \(Category.displayName(selectedName))")
                }
                .controlSize(.small)
                .frame(maxWidth: 240, alignment: .leading)

                Spacer()
            }

            // 模型建议新建分类：等用户确认
            if selection == nil, let suggested, !suggested.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("体系里没有合适的分类，AI 建议新建「\(suggested)」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("新建并移入") {
                        if let cat = viewModel.createCategory(named: suggested, forWords: forWords, context: modelContext) {
                            selection = cat.id
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radius))
            } else if selection == nil {
                Text("AI 未能归类，请从上方选择；不选则按语言自动归入")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .alert("新建分组", isPresented: $showNewGroup) {
            TextField(forWords ? "如：法语" : "如：交通规则", text: $newGroupName)
            Button("创建并归入") {
                if let cat = viewModel.createCategory(named: newGroupName, forWords: forWords, context: modelContext) {
                    selection = cat.id
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将创建在「\(forWords ? "语言学习" : "知识片段")」下，Anki 会自动出现同名牌组。")
        }
    }
}

// MARK: - 辅助函数

/// 语言代码转中文显示名
private func languageDisplayName(_ code: String) -> String {
    let lowered = code.lowercased()
    for lang in Language.allCases {
        if lang.rawValue == lowered {
            return lang.displayName
        }
    }
    return code
}
