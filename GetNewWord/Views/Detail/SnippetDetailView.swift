// SnippetDetailView.swift
// GetNewWord
//
// 知识片段详情（方向 A）：标题、出处一行、正文（Markdown），再是「原文」那句和截图、
// 「相关的词」（点了跳到那个词）、标签、底部一行同步状态。右上角编辑（标题和正文可改）和更多。

import SwiftUI
import SwiftData
import AppKit

struct SnippetDetailView: View {
    @Environment(\.fontScale) private var fs
    let snippet: KnowledgeSnippet
    var onDelete: (() -> Void)? = nil
    /// 点「相关的词」：回到单词页并选中它
    var onOpenWord: ((WordEntry) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirm = false
    @State private var newTag = ""
    @State private var isEditing = false
    @State private var dTitle = ""
    @State private var dContent = ""
    @State private var sourceExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerSection
                contentSection
                if !snippet.sourceContext.isEmpty || snippet.screenshotPath != nil { sourceSection }
                if !snippet.relatedWords.isEmpty { relatedWordsSection }
                if !snippet.tags.isEmpty || !isEditing { tagsSection }
                footer
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 792, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .id(snippet.id)                    // 切换片段时重置编辑状态
        .background {
            if !isEditing {
                Button("") { showDeleteConfirm = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .hidden()
            }
        }
        .alert("删除「\(snippet.title)」？", isPresented: $showDeleteConfirm) {
            Button("删除（含 Anki 卡）", role: .destructive) {
                let title = snippet.title
                let nid = snippet.ankiNoteId
                Task { await AnkiService.shared.deleteAnkiNote(forSnippet: nid, title: title) }
                modelContext.delete(snippet)
                try? modelContext.save()
                onDelete?()
            }
            Button("仅本地删除", role: .destructive) {
                modelContext.delete(snippet)
                try? modelContext.save()
                onDelete?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销。「仅本地」保留 Anki 里的卡和复习进度。")
        }
    }

    // MARK: - 编辑

    private func beginEdit() {
        dTitle = snippet.title
        dContent = snippet.content
        isEditing = true
    }

    private func commitEdit() {
        let title = dTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { snippet.title = title }
        snippet.content = dContent
        snippet.syncStatus = .notSynced   // 改过就要重新同步 Anki
        try? modelContext.save()
        isEditing = false
    }

    // MARK: - 标题区

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField("标题", text: $dTitle)
                    .font(Theme.font(20, .semibold, scale: fs))
                    .editField()
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { isEditing = false }
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("保存") { commitEdit() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.top, 4)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text(snippet.title)
                        .font(Theme.font(20, .semibold, scale: fs))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .help(snippet.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    DetailIconButton(symbol: "pencil", help: "编辑（⌘E）") { beginEdit() }
                        .keyboardShortcut("e", modifiers: .command)
                    moreMenu
                }
                // 出处一行：分组（= 左侧分类树 = Anki 牌组）· 日期 · 同步状态
                HStack(spacing: 6) {
                    Text("\(snippet.category?.parent?.displayName ?? String(localized: "知识片段")) › \(snippet.category?.displayName ?? String(localized: "未分组"))")
                    Text("· \(snippet.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    SyncDot(status: snippet.syncStatus)
                    Text(snippet.syncStatus.footLabel)
                }
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text2)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("复制正文") { WordActions.copy(snippet.content) }
            Divider()
            Button("删除…", role: .destructive) { showDeleteConfirm = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    // MARK: - 正文（Markdown 渲染）

    @ViewBuilder
    private var contentSection: some View {
        if isEditing {
            TextField("正文（支持 Markdown）", text: $dContent, axis: .vertical)
                .font(Theme.font(14, scale: fs))
                .editField()
                .lineLimit(6...30)
        } else {
            // 按空行分段，段与段之间留出呼吸
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                    Text(AttributedString(markdownString: p))
                        .font(Theme.font(14, scale: fs))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var paragraphs: [String] {
        snippet.content.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 原文

    private var sourceSection: some View {
        DetailSection(title: "原文") {
            HStack(alignment: .top, spacing: 16) {
                if snippet.sourceContext.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snippet.sourceContext)
                            .font(Theme.font(14, scale: fs))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.text)
                            .lineLimit(sourceExpanded ? nil : 6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if snippet.sourceContext.count > 220 {
                            Button(sourceExpanded ? "收起" : "展开") { sourceExpanded.toggle() }
                                .buttonStyle(.plain)
                                .font(Theme.font(12, scale: fs))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.borderStrong).frame(width: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let path = snippet.screenshotPath { ScreenshotThumb(path: path) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 相关的词

    private var relatedWordsSection: some View {
        DetailSection(title: "相关的词") {
            FlowLayout(spacing: 6) {
                ForEach(snippet.relatedWords, id: \.id) { word in
                    Button { onOpenWord?(word) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(word.word).font(Theme.font(13, scale: fs)).foregroundStyle(Theme.text)
                            Text(word.meaning).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("看这个词")
                }
            }
        }
    }

    // MARK: - 标签：点 ✕ 删，输入回车加

    private var tagsSection: some View {
        DetailSection(title: "标签") {
            FlowLayout(spacing: 6) {
                ForEach(snippet.tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(Theme.font(11, .medium, scale: fs))
                        Button {
                            snippet.tags.removeAll { $0 == tag }
                            snippet.syncStatus = .notSynced
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("去掉这个标签")
                    }
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Theme.selected, in: RoundedRectangle(cornerRadius: 5))
                }
                TextField("+ 标签", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(Theme.font(11, scale: fs))
                    .padding(.horizontal, 7)
                    .frame(width: 76, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])))
                    .onSubmit {
                        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty, !snippet.tags.contains(t) {
                            snippet.tags.append(t)
                            snippet.syncStatus = .notSynced
                            try? modelContext.save()
                        }
                        newTag = ""
                    }
            }
        }
    }

    // MARK: - 底部一行

    private var footer: some View {
        FlowLayout(spacing: 18) {
            Text("关联 \(snippet.relatedWords.count) 个词")
            Text("创建于 \(snippet.createdAt.formatted(date: .long, time: .shortened))")
        }
        .font(Theme.font(12, scale: fs))
        .foregroundStyle(Theme.text2)
        .padding(.top, 14)
        .overlay(alignment: .top) { Hairline() }
        .padding(.top, 6)
    }
}

// MARK: - Markdown 辅助

extension AttributedString {
    init(markdownString: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: markdownString, options: options) {
            self = attributed
        } else {
            self = AttributedString(markdownString)
        }
    }
}

// MARK: - FlowLayout（简易流式布局）

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (positions, CGSize(width: maxX, height: currentY + lineHeight))
    }
}
