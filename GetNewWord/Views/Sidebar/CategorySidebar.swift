// CategorySidebar.swift
// GetNewWord
//
// 侧栏（design/main-window 方向 A「三栏书房」）：
// 顶部三页（单词 / 知识片段 / 统计，右边是数量，快捷键放进悬停提示）→ 分类（只列当前这页的，统计页不列）
// → 底部 Anki 状态加同步按钮 → 方案卡。选中是灰底，不再有竖条。

import SwiftUI
import SwiftData

struct CategorySidebar: View {
    @Environment(\.fontScale) private var fs
    @Binding var selectedTab: SelectedTab
    @Binding var selectedCategory: Category?
    let isSyncingAnki: Bool
    let onSyncAnki: () -> Void

    @Query(sort: [SortDescriptor<Category>(\.name)])
    private var categories: [Category]

    @Query private var allWords: [WordEntry]
    @Query private var allSnippets: [KnowledgeSnippet]
    @Environment(\.modelContext) private var modelContext

    /// nil = 还没查过；Anki 开着才连得上
    @State private var ankiOnline: Bool?

    // MARK: 分类增删改状态
    @State private var renamingCategory: Category?
    @State private var renameText = ""
    @State private var newCategoryParent: Category?
    @State private var newCategoryName = ""
    @State private var deletingCategory: Category?

    enum SelectedTab: String, CaseIterable {
        case words = "单词"
        case snippets = "知识片段"
        case stats = "统计"

        var symbol: String {
            switch self {
            case .words: return "character.book.closed"
            case .snippets: return "doc.text"
            case .stats: return "chart.bar"
            }
        }
        var kbd: String {
            switch self {
            case .words: return "⌘1"
            case .snippets: return "⌘2"
            case .stats: return "⌘3"
            }
        }
        /// 这一页的分类挂在哪个根分类下（统计页没有）
        var rootName: String? {
            switch self {
            case .words: return "语言学习"
            case .snippets: return "知识片段"
            case .stats: return nil
            }
        }
    }

    enum GroupMode: String, CaseIterable {
        case all, byDay, byDifficulty, byCategory

        var title: LocalizedStringKey {
            switch self {
            case .all: return "不分组"
            case .byDay: return "按天"
            case .byDifficulty: return "按难度"
            case .byCategory: return "按分类"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 导航
            VStack(spacing: 1) {
                ForEach(SelectedTab.allCases, id: \.self) { tab in
                    navRow(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)

            if let root = currentRoot {
                categoryHeader(root)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        categoryRow(name: allRowTitle, symbol: "tray", count: itemCount, dim: false,
                                    selected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        .contextMenu {
                            Button("新建分类…") { newCategoryParent = root; newCategoryName = "" }
                        }
                        ForEach(leafCategories(of: root), id: \.id) { cat in
                            leafRow(cat, root: root)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                ankiLine
                // 方案卡：自带 Key / 还没选 AI，点开是付费页
                PlanCard()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 210)
        .background(Theme.surface)
        .modifier(crudAlerts)
        .task { await watchAnki() }
        .onChange(of: isSyncingAnki) { _, syncing in
            if !syncing { Task { await refreshAnki() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAnki() }
        }
    }

    /// 三个增删改弹窗（拆出来避免 body 表达式过长导致编译器超时）
    private var crudAlerts: CategoryCRUDAlerts {
        CategoryCRUDAlerts(
            renamingCategory: $renamingCategory, renameText: $renameText,
            newCategoryParent: $newCategoryParent, newCategoryName: $newCategoryName,
            deletingCategory: $deletingCategory,
            onRename: performRename, onCreate: performCreate, onDelete: performDelete,
            itemCount: itemCount(of:)
        )
    }

    // MARK: - 分类增删改

    private func performRename() {
        guard let cat = renamingCategory else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != cat.name else { renamingCategory = nil; return }
        cat.name = name
        // 里面的条目标记待同步 → 下次同步 changeDeck 搬牌组
        for w in cat.words { w.syncStatus = .notSynced }
        for sn in cat.snippets { sn.syncStatus = .notSynced }
        try? modelContext.save()
        AppLog.log("[Category] renamed to '\(name)', \(cat.words.count + cat.snippets.count) items marked for re-sync")
        renamingCategory = nil
    }

    private func performCreate() {
        guard let parent = newCategoryParent else { return }
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { newCategoryParent = nil; return }
        guard !parent.children.contains(where: { $0.name == name }) else { newCategoryParent = nil; return }
        let cat = Category(name: name, icon: parent.name == "语言学习" ? "character.book.closed" : "folder", colorHex: "#4A90D9")
        cat.parent = parent
        modelContext.insert(cat)
        try? modelContext.save()
        AppLog.log("[Category] created '\(parent.name) > \(name)'")
        newCategoryParent = nil
    }

    private func performDelete() {
        guard let cat = deletingCategory else { return }
        // 条目不删，回到未分组并标记待同步
        for w in cat.words { w.category = nil; w.syncStatus = .notSynced }
        for sn in cat.snippets { sn.category = nil; sn.syncStatus = .notSynced }
        if selectedCategory?.id == cat.id { selectedCategory = nil }
        modelContext.delete(cat)
        try? modelContext.save()
        AppLog.log("[Category] deleted '\(cat.name)'")
        deletingCategory = nil
    }

    private func itemCount(of cat: Category?) -> Int {
        guard let cat else { return 0 }
        return cat.words.count + cat.snippets.count
    }

    // MARK: - Anki 状态

    /// 每 30 秒看一次 Anki 开没开（用户中途打开 Anki 也能跟上）
    private func watchAnki() async {
        while !Task.isCancelled {
            await refreshAnki()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func refreshAnki() async {
        ankiOnline = await AnkiService.shared.isAnkiRunning()
    }

    /// 还没推给 Anki 的单词和知识片段（失败过的也算，下次同步会重试）
    private var pendingCount: Int {
        allWords.filter { $0.syncStatus == .notSynced || $0.syncStatus == .syncFailed }.count
            + allSnippets.filter { $0.syncStatus == .notSynced || $0.syncStatus == .syncFailed }.count
    }

    private var ankiLine: some View {
        HStack(spacing: 8) {
            if ankiOnline == true {
                Circle().fill(pendingCount == 0 ? Theme.ok : Theme.warn).frame(width: 7, height: 7)
                Group {
                    if pendingCount == 0 { Text("Anki · 全部已同步") } else { Text("Anki · \(pendingCount) 个等着同步") }
                }
                .foregroundStyle(Theme.text2)
            } else {
                Text("Anki").foregroundStyle(Theme.text2)
                Spacer(minLength: 4)
                Group {
                    if allWords.isEmpty && allSnippets.isEmpty { Text("没连上，可以以后再连") } else { Text("没连上") }
                }
                .foregroundStyle(Theme.text3)
            }
            if ankiOnline == true { Spacer(minLength: 4) }
            if isSyncingAnki {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 24, height: 24)
            } else if ankiOnline == true {
                DetailIconButton(symbol: "arrow.triangle.2.circlepath", help: "把未同步的单词按分类树同步为 Anki 牌组（⇧⌘S）") {
                    onSyncAnki()
                }
                .scaleEffect(0.9)
            }
        }
        .font(Theme.font(12, scale: fs))
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 28)
    }

    // MARK: - 行

    private var currentRoot: Category? {
        guard let name = selectedTab.rootName else { return nil }
        return categories.first { $0.parent == nil && $0.name == name }
    }

    private func leafCategories(of root: Category) -> [Category] {
        root.children.sorted { $0.name < $1.name }
    }

    private var allRowTitle: String {
        selectedTab == .words ? String(localized: "全部单词") : String(localized: "全部片段")
    }

    private func navRow(_ tab: SelectedTab) -> some View {
        let selected = selectedTab == tab
        let count: Int? = {
            switch tab {
            case .words: return allWords.count
            case .snippets: return allSnippets.count
            case .stats: return nil
            }
        }()
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(Theme.font(13, scale: fs))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                Text(LocalizedStringKey(tab.rawValue))
                    .font(Theme.font(13, selected ? .medium : .regular, scale: fs))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(tab.kbd)
        .keyboardShortcut(KeyEquivalent(Character(String(tab.kbd.last!))), modifiers: .command)
    }

    /// 「分类」小标题，悬停出现加号（新建）
    private func categoryHeader(_ root: Category) -> some View {
        HStack {
            Text("分类").font(Theme.font(12, .medium, scale: fs)).foregroundStyle(Theme.text2)
            Spacer()
            DetailIconButton(symbol: "plus", help: "新建分类") {
                newCategoryParent = root
                newCategoryName = ""
            }
            .scaleEffect(0.8)
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 18)
        .frame(height: 28)
    }

    @ViewBuilder
    private func leafRow(_ cat: Category, root: Category) -> some View {
        let count = selectedTab == .snippets ? cat.snippets.count : cat.words.count
        categoryRow(name: cat.displayName, symbol: selectedTab == .snippets ? "folder" : "globe", count: count, dim: count == 0,
                    selected: selectedCategory?.id == cat.id) {
            selectedCategory = cat
        }
        .contextMenu {
            Button("重命名…") { renamingCategory = cat; renameText = cat.name }
            Button("新建同级分类…") { newCategoryParent = root; newCategoryName = "" }
            Divider()
            Button("删除「\(cat.displayName)」…", role: .destructive) { deletingCategory = cat }
        }
    }

    /// dim：里面还没有东西的分类灰着，不写数字
    private func categoryRow(name: String, symbol: String, count: Int, dim empty: Bool, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(Theme.font(12, scale: fs))
                    .frame(width: 18)
                    .foregroundStyle(empty ? Theme.text3 : (selected ? Theme.text : Theme.text2))
                Text(name)
                    .font(Theme.font(13, selected ? .medium : .regular, scale: fs))
                    .foregroundStyle(empty ? Theme.text3 : (selected ? Theme.text : Theme.text2))
                    .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var itemCount: Int {
        switch selectedTab {
        case .words: return allWords.count
        case .snippets: return allSnippets.count
        case .stats: return allWords.count + allSnippets.count
        }
    }
}

// MARK: - Color hex 扩展

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") { hexSanitized.removeFirst() }
        guard hexSanitized.count == 6, let hexValue = UInt64(hexSanitized, radix: 16) else { return nil }
        let r = Double((hexValue >> 16) & 0xFF) / 255.0
        let g = Double((hexValue >> 8) & 0xFF) / 255.0
        let b = Double(hexValue & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}


// MARK: - 分类增删改弹窗

struct CategoryCRUDAlerts: ViewModifier {
    @Binding var renamingCategory: Category?
    @Binding var renameText: String
    @Binding var newCategoryParent: Category?
    @Binding var newCategoryName: String
    @Binding var deletingCategory: Category?
    let onRename: () -> Void
    let onCreate: () -> Void
    let onDelete: () -> Void
    let itemCount: (Category?) -> Int

    func body(content: Content) -> some View {
        content
            .alert("重命名分类", isPresented: Binding(get: { renamingCategory != nil }, set: { if !$0 { renamingCategory = nil } })) {
                TextField("名称", text: $renameText)
                Button("重命名") { onRename() }
                Button("取消", role: .cancel) { renamingCategory = nil }
            } message: {
                Text("Anki 里对应的牌组会在下次同步时跟着搬过去。")
            }
            .alert("新建分类", isPresented: Binding(get: { newCategoryParent != nil }, set: { if !$0 { newCategoryParent = nil } })) {
                TextField("名称（如 交通规则）", text: $newCategoryName)
                Button("创建") { onCreate() }
                Button("取消", role: .cancel) { newCategoryParent = nil }
            } message: {
                Text("将创建在「\(newCategoryParent?.name ?? "")」下，同名 Anki 牌组会在同步时自动创建。")
            }
            .alert("删除分类「\(deletingCategory?.name ?? "")」？", isPresented: Binding(get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } })) {
                Button("删除", role: .destructive) { onDelete() }
                Button("取消", role: .cancel) { deletingCategory = nil }
            } message: {
                Text("里面的 \(itemCount(deletingCategory)) 个条目不会被删除，会变为「未分组」（单词下次同步按语言归组）。")
            }
    }
}
