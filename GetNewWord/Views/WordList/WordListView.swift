// WordListView.swift
// GetNewWord
//
// 单词列表（方向 A）：顶上一行「128 个词」和分组，下面是自绘选择层（不用 List 的系统深蓝高亮）
// - 单击选中一个，选中是灰底；上下方向键换词，⌘⌫ 删除；右键菜单有朗读、重新讲解、复制、移到分类、搜图、删除
// - ⌘ 点 toggle；⇧ 点范围选；⌘A 全选
// - 按下拖动出现半透明选框（marquee），框碰到哪行哪行被选中——欧路/访达式框选
// - 打开列表时自动选中最新的一个词，右栏不留空
// - 词库不用 @Query 拿：@Query 每次重算 body 都把整个词库重新取一遍，换词、滚动时 body 重算得很勤，2000 个词就卡；
//   这里开列表和每次存盘后才取一次，过滤和分组也只在条件变了时重算（WordListCache）。行用 LazyVStack，只建看得见的

import SwiftUI
import SwiftData
import AppKit

struct WordListView: View {
    @Binding var selectedWord: WordEntry?
    /// 多选集合；恰好一个时右栏显示详情
    @Binding var selectedIDs: Set<UUID>
    @Binding var groupMode: CategorySidebar.GroupMode
    let selectedCategory: Category?
    let searchText: String?

    /// 整个词库和过滤分组后的结果；别处存盘后 version 加一，下次 body 重新取；
    /// 主窗口自己存的（查到新词、补全写回、改分类）缓存里就地改好，edits 加一，只重新过滤分组
    @State private var cache = WordListCache()
    @State private var version = 0
    @State private var edits = 0
    @Query(sort: [SortDescriptor<Category>(\.name)])
    private var categories: [Category]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.fontScale) private var fs
    /// 第一个词存好的提示条，关掉或词多起来之后不再出现
    @AppStorage("firstWordNoteDismissed") private var noteDismissed = false
    @FocusState private var focused: Bool

    // MARK: 框选状态
    /// 每行的位置只在框选时用：放在不触发重算的盒子里，滚动、行出现消失时不重算整个列表
    @State private var rowFrames = RowFrameBox()
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeRect: CGRect? = nil
    /// ⇧ 范围选的锚点
    @State private var anchorID: UUID? = nil
    /// 待确认删除的一批单词（右键菜单触发）
    @State private var pendingDelete: [WordEntry] = []
    @State private var showDeleteConfirm = false

    private let space = "wordlist"

    var body: some View {
        let list = current   // 条件没变就是上次算好的
        let total = list.all.count
        return VStack(spacing: 0) {
            header(count: list.order.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if total == 1 && !noteDismissed { firstNote }
                        listContent(list)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 空白处按下也能开始框选/清空选择
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture)
                    // 选框画在内容上、用内容的坐标：滚动时行的位置不变，不用每滚一下就重新上报
                    .overlay(alignment: .topLeading) {
                        if let rect = marqueeRect {
                            Rectangle()
                                .fill(Theme.accent.opacity(0.10))
                                .overlay(Rectangle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: space)
                    .onPreferenceChange(RowFramesKey.self) { [rowFrames] in rowFrames.frames = $0 }
                }
                .onChange(of: selectedIDs) { _, ids in
                    syncSelection(ids)
                    if ids.count == 1, let id = ids.first { proxy.scrollTo(id) }
                }
                // 从统计、知识片段点过来时，选中的词可能在很下面
                .onAppear {
                    DispatchQueue.main.async {
                        if selectedIDs.count == 1, let id = selectedIDs.first { proxy.scrollTo(id, anchor: .center) }
                    }
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
            guard press.modifiers.contains(.command), !selectedIDs.isEmpty else { return .ignored }
            pendingDelete = current.words(for: selectedIDs)
            showDeleteConfirm = true
            return .handled
        }
        .onAppear { reconcileSelection() }
        .onChange(of: selectedCategory?.id) { _, _ in reconcileSelection() }
        .onChange(of: searchText) { _, _ in reconcileSelection() }
        // 存盘（查到新词、删词、改词、移分类、同步）之后：自己存的就地更新，别的（后台同步、导入）重新取词库
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if cache.absorb(note, context: modelContext) { edits += 1 } else { version += 1 }
        }
        .onChange(of: total) { _, new in
            reconcileSelection()   // 第一个词存好：直接落到它的详情；删掉了选中的：换一个
            if new > 1 { noteDismissed = true }
        }
        .onChange(of: selectedWord) { _, word in
            if word == nil && selectedIDs.count == 1 { selectedIDs = [] }
        }
        .alert("删除 \(pendingDelete.count) 个单词？", isPresented: $showDeleteConfirm) {
            Button("删除（含 Anki 卡）", role: .destructive) { performDelete(alsoAnki: true) }
            Button("仅本地删除", role: .destructive) { performDelete(alsoAnki: false) }
            Button("取消", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("不可撤销。「仅本地」保留 Anki 里的卡和复习进度。")
        }
        // ⌘A 全选（隐藏按钮承载快捷键）
        .background(
            Button("") { selectedIDs = Set(current.orderIDs) }
                .keyboardShortcut("a", modifiers: .command)
                .hidden()
        )
    }

    // MARK: - 顶部

    private func header(count: Int) -> some View {
        HStack {
            Text("\(count) 个词")
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text2)
            Spacer()
            GroupMenu(mode: $groupMode, options: [.all, .byDay, .byDifficulty, .byCategory])
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 40)
    }

    /// 第一个词存好之后列表顶上的一条绿色提示
    private var firstNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(Theme.font(13, scale: fs)).foregroundStyle(Theme.ok)
            Text("第一个词存好了。以后查的词都会出现在这里；Anki 打开时自动同步过去。")
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            DetailIconButton(symbol: "xmark", help: "关掉") { noteDismissed = true }
                .scaleEffect(0.75)
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private func listContent(_ list: WordListCache) -> some View {
        if list.order.isEmpty {
            if let s = searchText, !s.isEmpty {
                EmptyHint(symbol: "magnifyingglass", title: "没有找到", message: "换个词搜，或者清掉搜索框。")
                    .frame(height: 240)
            } else {
                EmptyHint(symbol: "folder", title: "这个分类里还没有词", message: "查词时可以选存进哪个分类；右键一个词也能移过来。")
                    .frame(height: 240)
            }
        } else {
            ForEach(list.sections) { section in
                if let title = section.title {
                    GroupHeader(title: title, count: section.rows.count)
                }
                ForEach(section.rows) { row in
                    wordRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func wordRow(_ row: WordListCache.Row) -> some View {
        SelectableRow(selected: selectedIDs.contains(row.id)) {
            WordCardView(word: row.word)
        }
        .onTapGesture { handleClick(row.word) }
        .contextMenu { rowMenu(row.word) }
        .background(rowFrameReader(row.id))
    }

    /// 上报每行在列表坐标系里的位置（框选命中检测用）
    private func rowFrameReader(_ id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: RowFramesKey.self, value: [id: geo.frame(in: .named(space))])
        }
    }

    // MARK: - 点选 / 框选 / 键盘

    private func handleClick(_ word: WordEntry) {
        focused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            // ⌘ 点：toggle
            if selectedIDs.contains(word.id) { selectedIDs.remove(word.id) } else { selectedIDs.insert(word.id) }
            anchorID = word.id
        } else if mods.contains(.shift), let anchor = anchorID {
            // ⇧ 点：从锚点到此的范围
            let order = current.orderIDs
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: word.id) {
                selectedIDs = Set(order[min(a, b)...max(a, b)])
            } else {
                selectedIDs = [word.id]
            }
        } else {
            selectedIDs = [word.id]
            anchorID = word.id
        }
    }

    /// 上下方向键换词：当前没选就从第一个开始，到头不再往外走
    private func moveSelection(_ delta: Int) {
        let order = current.orderIDs
        guard !order.isEmpty else { return }
        let current = (selectedIDs.count == 1 ? selectedIDs.first : anchorID).flatMap { order.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), order.count - 1) } ?? 0
        selectedIDs = [order[next]]
        anchorID = order[next]
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
            .onChanged { value in
                if marqueeStart == nil { marqueeStart = value.startLocation }
                let start = marqueeStart ?? value.startLocation
                let rect = CGRect(
                    x: min(start.x, value.location.x),
                    y: min(start.y, value.location.y),
                    width: abs(value.location.x - start.x),
                    height: abs(value.location.y - start.y)
                )
                marqueeRect = rect
                // 选框碰到哪行，哪行被选中
                selectedIDs = Set(rowFrames.frames.filter { $0.value.intersects(rect) }.map { $0.key })
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeRect = nil
                if selectedIDs.isEmpty { selectedWord = nil }
            }
    }

    /// 恰好选中一个 → 右栏显示详情；多选/清空 → 交给批量视图
    private func syncSelection(_ ids: Set<UUID>) {
        if ids.count == 1, let id = ids.first {
            selectedWord = current.byID[id]
        } else {
            selectedWord = nil
        }
    }

    /// 换分类、搜索、词库变了之后右栏不留空：选中的词不在当前列表里就去掉；一个都没选就选第一个
    private func reconcileSelection() {
        Task { @MainActor in
            let order = current.orderIDs
            let valid = selectedIDs.intersection(order)
            if valid != selectedIDs { selectedIDs = valid }
            if valid.isEmpty, let first = order.first {
                selectedIDs = [first]
                anchorID = first
            }
            if selectedIDs.isEmpty { selectedWord = nil }
        }
    }

    // MARK: - 右键菜单

    private var languageCategories: [Category] {
        categories.filter { $0.parent?.name == "语言学习" }.sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private func rowMenu(_ word: WordEntry) -> some View {
        if selectedIDs.count > 1 && selectedIDs.contains(word.id) {
            let targets = current.words(for: selectedIDs)
            Menu("移到分类") {
                ForEach(languageCategories, id: \.id) { cat in
                    Button(cat.displayName) { move(targets, to: cat) }
                }
                Divider()
                Button("未分组") { move(targets, to: nil) }
            }
            Divider()
            Button("删除选中的 \(selectedIDs.count) 个单词…", role: .destructive) {
                pendingDelete = targets
                showDeleteConfirm = true
            }
        } else {
            Button("朗读") { AudioService.shared.speak(word.word, language: word.language) }
            Button("重新讲解") { WordActions.shared.regenerate(word, context: modelContext) }
            Button("复制") { WordActions.copy(word.word) }
            Menu("移到分类") {
                ForEach(languageCategories, id: \.id) { cat in
                    if word.category?.id == cat.id {
                        Label(cat.displayName, systemImage: "checkmark")
                    } else {
                        Button(cat.displayName) { move([word], to: cat) }
                    }
                }
                Divider()
                Button("未分组") { move([word], to: nil) }
            }
            Button("在浏览器里搜图") { WordActions.searchImages(for: word) }
            Divider()
            Button("删除「\(word.word)」…", role: .destructive) {
                pendingDelete = [word]
                showDeleteConfirm = true
            }
        }
    }

    private func move(_ words: [WordEntry], to cat: Category?) {
        for w in words {
            w.category = cat
            w.syncStatus = .notSynced   // 下次同步搬牌组
            // 在某个分类里看的时候，移走的词就不在这页了
            if let current = selectedCategory, cat?.id != current.id { selectedIDs.remove(w.id) }
        }
        try? modelContext.save()
        AppLog.log("[Move] \(words.count) words to '\(cat?.name ?? "未分组")'")
    }

    private func performDelete(alsoAnki: Bool) {
        let targets = pendingDelete
        if alsoAnki {
            let ids = targets.compactMap { $0.ankiNoteId }   // 先取，再删实体
            Task { await AnkiService.shared.deleteAnkiNotes(ids: ids) }
        }
        for w in targets {
            selectedIDs.remove(w.id)
            if selectedWord?.id == w.id { selectedWord = nil }
            modelContext.delete(w)
        }
        try? modelContext.save()
        pendingDelete = []
        if selectedIDs.isEmpty { selectedWord = nil }
    }

    // MARK: - 数据

    /// 当前条件下的列表（显示顺序、分组、按 id 找词）；条件和词库都没变时直接用上次的
    private var current: WordListCache {
        cache.refresh(version: version, edits: edits, category: selectedCategory?.id, search: searchText, group: groupMode, context: modelContext)
    }
}

// MARK: - 列表缓存

/// 词库、过滤和分组的结果。是个普通类（不触发重算）：换词、滚动重算 body 时不再重新取词库、重新过滤分组
@MainActor
final class WordListCache {
    struct Row: Identifiable {
        let id: UUID
        let word: WordEntry
    }
    struct Section: Identifiable {
        let id: String
        let title: String?
        let rows: [Row]
    }
    private struct Key: Equatable {
        let version: Int
        let edits: Int
        let category: UUID?
        let search: String?
        let group: CategorySidebar.GroupMode
    }

    /// 整个词库，按时间倒序
    private(set) var all: [WordEntry] = []
    private(set) var byID: [UUID: WordEntry] = [:]
    private(set) var sections: [Section] = []
    /// 显示顺序（范围选 / 全选 / 方向键用）
    private(set) var order: [WordEntry] = []
    private(set) var orderIDs: [UUID] = []
    private var loadedVersion: Int?
    private var key: Key?

    func refresh(version: Int, edits: Int, category: UUID?, search: String?, group: CategorySidebar.GroupMode, context: ModelContext) -> WordListCache {
        let newKey = Key(version: version, edits: edits, category: category, search: search, group: group)
        guard newKey != key else { return self }
        if loadedVersion != version {
            let d = FetchDescriptor<WordEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            all = (try? context.fetch(d)) ?? []
            byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            loadedVersion = version
        }
        key = newKey
        let filtered = Self.filter(all, category: category, search: search)
        let groups: [(title: String?, words: [WordEntry])]
        switch group {
        case .all: groups = [(nil, filtered)]
        case .byDay: groups = groupByDay(filtered) { $0.createdAt }.map { ($0.title, $0.items) }
        case .byDifficulty:
            groups = Difficulty.allCases.compactMap { diff in
                let words = filtered.filter { $0.difficulty == diff }
                return words.isEmpty ? nil : (diff.displayName, words)
            }
        case .byCategory: groups = Self.groupedByCategory(filtered).map { ($0.title, $0.words) }
        }
        sections = groups.map { g in
            Section(id: g.title ?? "", title: g.title, rows: g.words.map { Row(id: $0.id, word: $0) })
        }
        order = groups.flatMap { $0.words }
        orderIDs = sections.flatMap { $0.rows.map(\.id) }
        return self
    }

    /// 主窗口这个 ModelContext 自己存的盘：新词按时间插进 all、删掉的拿掉，改了的对象本来就是同一个，不用整个词库重取
    /// （2000 个词时重取一次主线程要 0.2 秒，查一个词要存三四次盘）。返回 false 时调用方整个重取：
    /// 还没取过、别的 ModelContext 存的（后台同步）、一次进来很多（导入）、通知里没带改了哪些
    func absorb(_ note: Notification, context: ModelContext) -> Bool {
        guard loadedVersion != nil, (note.object as? ModelContext) === context, let info = note.userInfo,
              let inserted = info["inserted"] as? [PersistentIdentifier],
              let deleted = info["deleted"] as? [PersistentIdentifier], info["updated"] is [PersistentIdentifier]
        else { return false }
        let newIDs = inserted.filter { $0.entityName == "WordEntry" }
        guard newIDs.count <= 50 else { return false }
        let gone = Set(deleted.filter { $0.entityName == "WordEntry" })
        if !gone.isEmpty {
            all.removeAll { gone.contains($0.persistentModelID) }
            byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        for id in newIDs {
            guard let w = context.model(for: id) as? WordEntry, !w.isDeleted, byID[w.id] == nil else { continue }
            // 按时间倒序插：新查的词在最前面，导入的老词插到它的日子里
            let at = all.firstIndex { $0.createdAt < w.createdAt } ?? all.endIndex
            all.insert(w, at: at)
            byID[w.id] = w
        }
        key = nil   // 下次 refresh 重新过滤分组（改了分类、难度的也要挪组）
        return true
    }

    func words(for ids: Set<UUID>) -> [WordEntry] {
        ids.compactMap { byID[$0] }
    }

    private static func filter(_ words: [WordEntry], category: UUID?, search: String?) -> [WordEntry] {
        var result = words
        if let category {
            result = result.filter { $0.category?.id == category }
        }
        if let search, !search.isEmpty {
            let lowered = search.lowercased()
            result = result.filter {
                $0.word.lowercased().contains(lowered) ||
                $0.meaning.lowercased().contains(lowered) ||
                $0.contextSentence.lowercased().contains(lowered)
            }
        }
        return result
    }

    /// 按分类：分类名排序，没归类的放最后
    private static func groupedByCategory(_ words: [WordEntry]) -> [(title: String, words: [WordEntry])] {
        let none = String(localized: "未分组")
        let grouped = Dictionary(grouping: words) { $0.category?.displayName ?? none }
        return grouped.sorted { lhs, rhs in
            if lhs.key == none { return false }
            if rhs.key == none { return true }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }
}

/// 框选用的每行位置
final class RowFrameBox {
    var frames: [UUID: CGRect] = [:]
}

// MARK: - 行位置上报

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 可选中的行

/// 列表行的底：选中灰底，圆角 8（悬停不再变灰，免得和选中分不清）
struct SelectableRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selected : .clear))
            .contentShape(Rectangle())
    }
}
