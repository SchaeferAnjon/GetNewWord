// AnalysisResultPanel.swift
// GetNewWord
//
// 查词结果浮动面板（design/panels）：样式由设置决定——跟词浮签（可默认展开）或讲义卡，内容部件在 LookupCards.swift。
// 只讲一个词或一条知识片段；框选会自动存，指词查词默认只查、点「存进词库」才存。

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
    @AppStorage(LookupPanelStyle.key) private var style: LookupPanelStyle = .tag

    private var isLecture: Bool { style == .lecture }

    var body: some View {
        VStack(spacing: 0) {
            if isLecture {
                statusBar
                Hairline()
            }
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 语法拆解流式增长时整列一起动：下面的内容平滑下移，不留空隙
                    .animation(.easeOut(duration: 0.18), value: viewModel.grammarText)
            }
            Hairline()
            footer
        }
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        // 面板是 key window，系统会给第一个可聚焦控件套蓝色焦点环——整体禁用（对全部子视图生效）
        .focusEffectDisabled()
        .background {
            // 浮签半透明但底色留得很实：深色视频和白色 PDF 上字都清楚
            if isLecture { Theme.elevated } else { ZStack { VisualEffectBackground(); Theme.elevated.opacity(0.82) } }
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
                if viewModel.skippedAsDuplicate.contains(0) {
                    Label("这个词已在词库里，且语境几乎相同，本次未重复添加", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                if viewModel.analysisResult != nil, isLecture || expanded { wordCategoryRow }
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

    private var wordCategoryRow: some View {
        let w0 = viewModel.analysisResult?.analysis.words.first
        return CategoryAssignRow(
            viewModel: viewModel, forWords: true,
            modelCategory: w0?.category, suggested: w0?.suggestedCategory,
            selection: Binding(get: { viewModel.chosenWordCategory[0] },
                               set: { viewModel.chosenWordCategory[0] = $0; viewModel.applyCategoryChange(forWord: 0) }),
            modelContext: modelContext)
    }

    private func snippetCategoryRow(_ s: SnippetAnalysis) -> some View {
        CategoryAssignRow(
            viewModel: viewModel, forWords: false,
            modelCategory: s.category, suggested: s.suggestedCategory,
            selection: Binding(get: { viewModel.chosenSnippetCategory[0] },
                               set: { viewModel.chosenSnippetCategory[0] = $0; viewModel.applyCategoryChange(forSnippet: 0) }),
            modelContext: modelContext)
    }

    private var isEmptyResult: Bool {
        // 识别中（result 尚为 nil）显示占位，不算"空结果"
        guard let result = viewModel.analysisResult else { return false }
        return result.analysis.words.isEmpty && result.analysis.snippets.isEmpty
    }

    // MARK: 状态

    /// 一句话说现在怎样：正在认词 / 正在讲解 / 已存进 德语 / 只查看
    private var statusText: String {
        if let hint = viewModel.netHint { return hint }
        guard viewModel.analysisResult != nil else {
            if viewModel.cachedHit != nil { return String(localized: "词库直出 · 正在核对语境…") }
            return viewModel.quickWord != nil ? String(localized: "正在讲解…") : String(localized: "正在认词…")
        }
        if viewModel.autoSaved {
            let cat = (viewModel.savedWords[0]?.category ?? viewModel.savedSnippets[0]?.category)?.displayName
            // 浮签底栏窄，只说存到哪；讲义卡的状态条再补一句同步
            if !isLecture { return cat.map { String(localized: "已存进 \($0)") } ?? String(localized: "已存进词库") }
            return cat.map { String(localized: "已存进 \($0) · Anki 稍后同步") } ?? String(localized: "已存进词库 · Anki 稍后同步")
        }
        return String(localized: "只查看，没存")
    }

    // MARK: 讲义卡顶上的状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image).renderingMode(.template).foregroundStyle(Theme.text2)
            if viewModel.analysisResult == nil { ProgressView().controlSize(.mini) }
            Text(pinned ? String(localized: "已钉住") + " · " + statusText : statusText)
                .font(.system(size: 12)).foregroundStyle(viewModel.netHint != nil ? Theme.warn : Theme.text2).lineLimit(1)
            Spacer()
            toolIcons
            closeButton
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.surface)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 8) {
            if isLecture {
                Spacer()
            } else {
                if viewModel.analysisResult == nil { ProgressView().controlSize(.mini) }
                Text(statusText).font(.system(size: 11.5))
                    .foregroundStyle(viewModel.netHint != nil ? Theme.warn : Theme.text3).lineLimit(1)
                Spacer(minLength: 4)
            }
            if viewModel.autoSaved {
                Button("撤销") { viewModel.undoAutoSave() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("删掉这次保存的内容")
            } else if viewModel.analysisResult != nil, !isEmptyResult {
                Button("存进词库") { onSave() }.buttonStyle(PrimaryButtonStyle())
            }
            if !isLecture {
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

    /// 讲义卡状态条上的：钉住、在主窗口打开、找图（浮签底栏窄，只留钉住）
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

/// 「分解语法」小节：小灰标题 + 流式 Markdown；每来一段就长高，把释义及以下内容平滑推下去
struct GrammarBreakdownSection: View {
    let state: GrammarBreakdownState

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
            Text(Self.inline(l))
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
        .tracking(1.2)
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

/// 例句一条："外语原句 —— 中文"拆两行：原句斜体高亮，译文灰色小字
@ViewBuilder
func exampleView(_ line: String, word: String) -> some View {
    let parts = line.components(separatedBy: "——")
    let foreign = parts.first?.trimmingCharacters(in: .whitespaces) ?? line
    let chinese = parts.count > 1 ? parts.dropFirst().joined(separator: "——").trimmingCharacters(in: .whitespaces) : nil
    VStack(alignment: .leading, spacing: 2) {
        Text(TextHighlighter.highlight(word, in: foreign))
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
