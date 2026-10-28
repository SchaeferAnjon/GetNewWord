// SnippetListView.swift
// GetNewWord
//
// 知识片段列表（方向 A）：每条是标题和两行摘要，右边是分类；选中灰底，上下方向键换条，
// 右键有复制正文、移到分类、删除。支持搜索、分类过滤、分组显示；按 UUID 选中，避免 SwiftData 对象 tag 不响应。

import SwiftUI
import SwiftData
import AppKit

struct SnippetListView: View {
    @Binding var selectedSnippet: KnowledgeSnippet?
    @Binding var groupMode: CategorySidebar.GroupMode
    let selectedCategory: Category?
    let searchText: String?

    @Query(sort: [SortDescriptor<KnowledgeSnippet>(\.createdAt, order: .reverse)])
    private var allSnippets: [KnowledgeSnippet]
    @Query(sort: [SortDescriptor<Category>(\.name)])
    private var categories: [Category]

    @State private var selectedID: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.fontScale) private var fs
    @State private var pendingDelete: KnowledgeSnippet?
    @FocusState private var focused: Bool

    var body: some View {
        let snippets = filteredSnippets   // 每次渲染只过滤一遍
        return VStack(spacing: 0) {
            header(count: snippets.count)
            ScrollViewReader { proxy in
                ScrollView {
                    listContent(snippets)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedID) { _, id in
                    selectedSnippet = id.flatMap { id in allSnippets.first { $0.id == id } }
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .background(Theme.bg)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers.contains(.command),
                  let id = selectedID, let s = allSnippets.first(where: { $0.id == id }) else { return .ignored }
            pendingDelete = s
            return .handled
        }
        .onAppear { reconcileSelection() }
        .onChange(of: selectedCategory?.id) { _, _ in reconcileSelection() }
        .onChange(of: searchText) { _, _ in reconcileSelection() }
        .onChange(of: allSnippets.count) { _, _ in reconcileSelection() }
        .onChange(of: selectedSnippet) { _, s in
            if s == nil { selectedID = nil }
        }
        .alert("删除「\(pendingDelete?.title ?? "")」？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除（含 Anki 卡）", role: .destructive) { performDelete(alsoAnki: true) }
            Button("仅本地删除", role: .destructive) { performDelete(alsoAnki: false) }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("此操作不可撤销。「仅本地」保留 Anki 里的卡和复习进度。")
        }
    }

    // MARK: - 顶部

    private func header(count: Int) -> some View {
        HStack {
            Text("\(count) 个片段")
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text2)
            Spacer()
            GroupMenu(mode: $groupMode, options: [.all, .byDay, .byCategory])
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 40)
    }

    // MARK: - 内容

    @ViewBuilder
    private func listContent(_ filtered: [KnowledgeSnippet]) -> some View {
        if filtered.isEmpty {
            if let s = searchText, !s.isEmpty {
                EmptyHint(symbol: "magnifyingglass", title: "没有找到", message: "换个词搜，或者清掉搜索框。")
                    .frame(height: 240)
            } else {
                EmptyHint(symbol: "folder", title: "这个分类里还没有片段", message: "右键一条片段，可以移到这个分类。")
                    .frame(height: 240)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                switch groupMode {
                case .all, .byDifficulty:
                    snippetSection(snippets: filtered)
                case .byDay:
                    ForEach(Self.groupedByDay(filtered), id: \.title) { group in
                        GroupHeader(title: group.title, count: group.snippets.count)
                        snippetSection(snippets: group.snippets)
                    }
                case .byCategory:
                    ForEach(Self.groupedByCategory(filtered), id: \.title) { group in
                        GroupHeader(title: group.title, count: group.snippets.count)
                        snippetSection(snippets: group.snippets)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func snippetSection(snippets: [KnowledgeSnippet]) -> some View {
        ForEach(snippets, id: \.id) { snippet in
            SelectableRow(selected: selectedID == snippet.id) {
                SnippetCardView(snippet: snippet)
            }
            .onTapGesture {
                focused = true
                selectedID = snippet.id
            }
            .contextMenu { rowMenu(snippet) }
        }
    }

    @ViewBuilder
    private func rowMenu(_ snippet: KnowledgeSnippet) -> some View {
        Button("复制正文") { WordActions.copy(snippet.content) }
        Menu("移到分类") {
            ForEach(snippetCategories, id: \.id) { cat in
                if snippet.category?.id == cat.id {
                    Label(cat.displayName, systemImage: "checkmark")
                } else {
                    Button(cat.displayName) { move(snippet, to: cat) }
                }
            }
            Divider()
            Button("未分组") { move(snippet, to: nil) }
        }
        Divider()
        Button("删除「\(snippet.title)」…", role: .destructive) {
            pendingDelete = snippet
        }
    }

    private var snippetCategories: [Category] {
        categories.filter { $0.parent?.name == "知识片段" }.sorted { $0.name < $1.name }
    }

    private func move(_ snippet: KnowledgeSnippet, to cat: Category?) {
        snippet.category = cat
        snippet.syncStatus = .notSynced   // 下次同步搬牌组
        try? modelContext.save()
        // 在某个分类里看的时候，移走的片段就不在这页了
        if let current = selectedCategory, cat?.id != current.id, selectedID == snippet.id { selectedID = nil }
    }

    private func performDelete(alsoAnki: Bool) {
        guard let s = pendingDelete else { return }
        if alsoAnki {
            let title = s.title
            let nid = s.ankiNoteId
            Task { await AnkiService.shared.deleteAnkiNote(forSnippet: nid, title: title) }
        }
        if selectedSnippet?.id == s.id { selectedSnippet = nil }
        modelContext.delete(s)
        try? modelContext.save()
        pendingDelete = nil
    }

    // MARK: - 选择

    private func moveSelection(_ delta: Int) {
        let order = displayOrder.map { $0.id }
        guard !order.isEmpty else { return }
        let next = selectedID.flatMap { order.firstIndex(of: $0) }.map { min(max($0 + delta, 0), order.count - 1) } ?? 0
        selectedID = order[next]
    }

    /// 换分类、搜索、片段变了之后右栏不留空：选中的不在当前列表里就去掉；没选就选第一个
    private func reconcileSelection() {
        Task { @MainActor in
            if selectedID == nil { selectedID = selectedSnippet?.id }   // 从别的页回来：接着上次选的
            if let id = selectedID, !displayOrder.contains(where: { $0.id == id }) { selectedID = nil }
            if selectedID == nil, let first = displayOrder.first { selectedID = first.id }
        }
    }

    // MARK: - 过滤逻辑

    private var displayOrder: [KnowledgeSnippet] {
        let filtered = filteredSnippets
        switch groupMode {
        case .all, .byDifficulty: return filtered
        case .byDay: return Self.groupedByDay(filtered).flatMap { $0.snippets }
        case .byCategory: return Self.groupedByCategory(filtered).flatMap { $0.snippets }
        }
    }

    private var filteredSnippets: [KnowledgeSnippet] {
        var result = allSnippets

        if let category = selectedCategory {
            result = result.filter { $0.category?.id == category.id }
        }

        if let search = searchText, !search.isEmpty {
            let lowered = search.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(lowered) ||
                $0.content.lowercased().contains(lowered) ||
                $0.domain.lowercased().contains(lowered)
            }
        }

        return result
    }

    private static func groupedByDay(_ snippets: [KnowledgeSnippet]) -> [(title: String, snippets: [KnowledgeSnippet])] {
        groupByDay(snippets) { $0.createdAt }.map { ($0.title, $0.items) }
    }

    private static func groupedByCategory(_ snippets: [KnowledgeSnippet]) -> [(title: String, snippets: [KnowledgeSnippet])] {
        let none = String(localized: "未分组")
        let grouped = Dictionary(grouping: snippets) { $0.category?.displayName ?? none }
        return grouped.sorted { lhs, rhs in
            if lhs.key == none { return false }
            if rhs.key == none { return true }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }
}

// MARK: - 知识片段行

struct SnippetCardView: View {
    @Environment(\.fontScale) private var fs
    let snippet: KnowledgeSnippet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snippet.title)
                    .font(Theme.font(13, .medium, scale: fs))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(snippet.category?.displayName ?? String(localized: "未分组"))
                    .font(Theme.font(12, scale: fs))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(snippet.content.prefix(120))
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}
