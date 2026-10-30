// MainView.swift
// GetNewWord
//
// 主界面（design/main-window 方向 A「三栏书房」）：侧栏 → 列表 → 详情三栏。
// 侧栏选看什么，中栏是列表，右栏是这个词的全部；统计占满中栏和右栏；
// 空词库时中栏右栏合成一页「查第一个词」（FirstWordView）。

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MainView: View {
    /// 只调用不订阅（见 AnalysisVMKey）；错误横幅和截图按钮由下面两个小视图各自订阅
    @Environment(\.analysisVM) private var analysisVMRef
    private var analysisVM: AnalysisViewModel { analysisVMRef! }
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(UsageConsent.key) private var usageConsent = ""
    /// 主窗口出来一会儿再问匿名统计，不和窗口一起弹
    @State private var consentReady = false

    // MARK: - 导航状态
    // 关掉主窗口只是把窗口藏起来（Window 场景），这些状态留着，从菜单栏再打开还是关之前那一页、那个词
    @State private var selectedTab: CategorySidebar.SelectedTab = .words
    @State private var selectedCategory: Category? = nil
    @State private var groupMode: CategorySidebar.GroupMode = .byDay
    @State private var selectedWord: WordEntry? = nil
    @State private var selectedWordIDs: Set<UUID> = []
    @State private var selectedSnippet: KnowledgeSnippet? = nil
    @State private var searchText: String = ""

    @State private var isSyncingAnki = false

    // MARK: - 导入/导出状态
    @State private var showFileImporter = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var showImportResult = false
    @State private var importResultMessage = ""

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView(onComplete: {
                    hasCompletedOnboarding = true
                })
            } else {
                mainContent
            }
        }
        .overlay(alignment: .top) { AnalysisErrorOverlay() }
        // 匿名使用统计没回答过（老用户更新后、引导里没答那一步的）：走完引导后问一次，答了才关（UsageConsentViews.swift）
        .sheet(isPresented: Binding(get: { consentReady && hasCompletedOnboarding && usageConsent.isEmpty }, set: { _ in })) {
            UsageConsentSheet()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            consentReady = true
        }
        .onAppear {
            MainWindowOpener.openWindow = openWindow
            // 下面这些一个进程只做一次：主窗口关了再开还会走 onAppear，不重来
            guard !MainWindowOpener.launched else { return }
            MainWindowOpener.launched = true
            // 快捷键注册放在这里，不受 onboarding 状态影响，确保应用启动即注册；
            // 设置里改了组合键就重新注册（register 会先注销旧的），主窗口关着时也要改得了
            let hotkeyVM = analysisVM, hotkeyContainer = modelContext.container
            Self.registerHotkeys(vm: hotkeyVM, container: hotkeyContainer)
            NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.registerHotkeys(vm: hotkeyVM, container: hotkeyContainer) }
            }
            HoverWordCapture.warmUp()
            #if DEBUG
            DemoMode.start(analysisVM, context: modelContext)
            PerfProbe.startIfRequested()
            #endif
            // 悬浮球也只配一次：闭包里直接拿视图模型和词库，不经过这个窗口的环境
            let vm = analysisVM, container = modelContext.container
            FloatingButtonController.shared.configure(
                onCapture: {
                    Task { @MainActor in await vm.triggerAnalysis(modelContext: container.mainContext, mode: .capture) }
                },
                onLookup: {
                    Task { @MainActor in await vm.triggerAnalysis(modelContext: container.mainContext, mode: .lookup) }
                }
            )
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            // 左栏：三页 + 分类 + Anki 状态 + 方案卡
            CategorySidebar(
                selectedTab: $selectedTab,
                selectedCategory: $selectedCategory,
                isSyncingAnki: isSyncingAnki,
                onSyncAnki: syncAnki
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
        } detail: {
            // 中栏 + 右栏：按页签换
            detailArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .overlay(alignment: .top) { Hairline() }
                .modifier(OptionalSearch(enabled: selectedTab != .stats, text: $searchText, prompt: searchPrompt))
                .navigationTitle(navigationTitle)
                .toolbarBackground(Theme.bg, for: .windowToolbar)
                .toolbar {
                    // 释义和译文写成哪种语言
                    ToolbarItem(placement: .primaryAction) {
                        TargetLanguageMenu()
                    }
                    // 截图取词：带字和快捷键
                    ToolbarItem(placement: .primaryAction) {
                        ScreenshotToolbarButton(action: triggerScreenshot)
                    }
                    // 同步、导出、导入都收进「更多」
                    ToolbarItem(placement: .primaryAction) {
                        moreMenu
                    }
                    // 统计页没有搜索框：留一块同宽的空位，切页时「译成」和「截图取词」不跟着跳
                    ToolbarItem(placement: .primaryAction) {
                        if selectedTab == .stats { Color.clear.frame(width: 262, height: 1) }
                    }
                }
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.commaSeparatedText, .json],
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }
                .alert("导入结果", isPresented: $showImportResult) {
                    Button("确定", role: .cancel) {}
                } message: {
                    Text(importResultMessage)
                }
                .alert("导出失败", isPresented: $showExportError) {
                    Button("确定", role: .cancel) {}
                } message: {
                    Text(exportErrorMessage)
                }
        }
        .onAppear {
            // 走完引导、第一次看到词库时做一次；主窗口关了再开不重来（全量备份、云同步、启动时的 Anki 同步都只要一次）
            guard !MainWindowOpener.libraryReady else { return }
            MainWindowOpener.libraryReady = true
            seedDefaultCategoriesIfNeeded()
        }
        // 同步 Anki 的快捷键（侧栏收起时按钮不在，快捷键照样有用）
        .background {
            Button("") { syncAnki() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .hidden()
        }
        // 结果面板由 AnalysisViewModel 直接弹出（不依赖主窗口是否打开/是否在引导页）
        // 换页签：分类、分组、搜索都回到默认；选中的词和片段留着，回来接着看
        .onChange(of: selectedTab) { _, _ in
            selectedCategory = nil
            groupMode = .byDay
            searchText = ""
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("同步 Anki") { syncAnki() }
                .disabled(isSyncingAnki)
            Divider()
            Button("导出单词 CSV") { exportWordsCSV() }
            Button("导出单词 JSON") { exportWordsJSON() }
            Divider()
            Button("导入…") { showFileImporter = true }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("更多：同步 Anki、导出、导入")
    }

    /// 中栏和右栏
    @ViewBuilder
    private var detailArea: some View {
        switch selectedTab {
        case .words:
            WordsPage(
                selectedWord: $selectedWord,
                selectedIDs: $selectedWordIDs,
                groupMode: $groupMode,
                selectedCategory: selectedCategory,
                searchText: searchText.isEmpty ? nil : searchText,
                onTry: triggerScreenshot
            )
        case .snippets:
            SnippetsPage(
                selectedSnippet: $selectedSnippet,
                groupMode: $groupMode,
                selectedCategory: selectedCategory,
                searchText: searchText.isEmpty ? nil : searchText,
                onOpenWord: openWord
            )
        case .stats:
            StatsDashboardView(onOpenWord: openWord)
        }
    }

    /// 从统计、知识片段点一个词：回到单词页，选中它
    private func openWord(_ word: WordEntry) {
        selectedCategory = nil
        searchText = ""
        selectedWord = word
        selectedWordIDs = [word.id]
        selectedTab = .words
    }

    // MARK: - 辅助属性

    private var navigationTitle: String {
        switch selectedTab {
        case .words: return String(localized: "单词")
        case .snippets: return String(localized: "知识片段")
        case .stats: return String(localized: "统计")
        }
    }

    private var searchPrompt: String {
        switch selectedTab {
        case .words: return String(localized: "搜索单词、释义、语境...")
        case .snippets: return String(localized: "搜索知识片段...")
        case .stats: return ""
        }
    }

    // MARK: - 私有方法

    /// 同步未同步单词到 Anki（牌组 = 分类树）
    private func syncAnki() {
        Task {
            isSyncingAnki = true
            await AnkiService.shared.syncEverythingPending(context: modelContext)
            isSyncingAnki = false
        }
    }

    /// 触发截图分析
    private func triggerScreenshot() {
        Task {
            await analysisVM.triggerAnalysis(modelContext: modelContext)
        }
    }

    /// 注册全局快捷键。只在启动时注册一次，闭包里直接拿视图模型和词库、不经过这个窗口的环境：
    /// 主窗口关着（或以后被重建）时快捷键照常查词
    private static func registerHotkeys(vm: AnalysisViewModel, container: ModelContainer) {
        HotkeyManager.shared.registerDefaultHotkeys(
            screenshotHandler: {
                Task { @MainActor in
                    await vm.triggerAnalysis(modelContext: container.mainContext, mode: .capture)
                }
            },
            lookupHandler: {
                Task { @MainActor in
                    await vm.triggerAnalysis(modelContext: container.mainContext, mode: .lookup)
                }
            },
            hoverHandler: {
                Task { @MainActor in
                    await vm.triggerAnalysis(modelContext: container.mainContext, mode: AnalysisViewModel.hoverMode, source: .hover)
                }
            },
            hoverOptionHandler: {
                Task { @MainActor in
                    let mode: AnalysisViewModel.Mode = AnalysisViewModel.hoverMode == .capture ? .lookup : .capture
                    await vm.triggerAnalysis(modelContext: container.mainContext, mode: mode, source: .hover)
                }
            }
        )
    }

    /// 预置默认分类
    private func seedDefaultCategoriesIfNeeded() {
        let dbManager = DatabaseManager(context: modelContext)
        dbManager.seedDefaultCategories()
        // 合并历史上重复保存的同一个单词（保留各自语境）
        AnalysisService.shared.mergeDuplicateWordsIfAny(context: modelContext)
        // 给没有发音文件的旧单词补下载（英/德/日/韩…）
        AnalysisService.shared.backfillAudio(context: modelContext)
        // 每次启动做一次全量 JSON 备份（词库意外损坏时可恢复；保留最近 14 份）
        ImportExportService.shared.autoBackup(context: modelContext)
        // 登录共用账号后：词库与云端双向同步（未登录空转）
        CloudSyncService.shared.start(context: modelContext)
        // 后台看板：已登录则报今天的「打开」（回到前台由 SupabaseAuth 自己监听）
        SupabaseAuth.shared.trackDailyOpen()
        // 截图取词要用的权限：启动就申请，不等第一次按快捷键（新用户走引导页的权限步骤）
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                PermissionManager.shared.requestMissingAtLaunch()
            }
        }
        // 启动 8 秒后自动把积压的未同步条目推给 Anki（Anki 没开则静默跳过）
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            // 灾难恢复：本地没有任何已同步的单词而 Anki 里有卡 → 自动反向导入
            let synced = (try? modelContext.fetchCount(FetchDescriptor<WordEntry>(predicate: #Predicate { $0.ankiNoteId != nil }))) ?? 0
            if synced == 0 {
                _ = await AnkiService.shared.restoreFromAnki(context: modelContext)
            }
            await AnkiService.shared.syncEverythingPending(context: modelContext)
        }
    }

    // MARK: - 导出方法

    private func exportWordsCSV() {
        do {
            let descriptor = FetchDescriptor<WordEntry>()
            let words = try modelContext.fetch(descriptor)
            let url = try ImportExportService.shared.exportWordsToCSV(words: words)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func exportWordsJSON() {
        do {
            let descriptor = FetchDescriptor<WordEntry>()
            let words = try modelContext.fetch(descriptor)
            let url = try ImportExportService.shared.exportWordsToJSON(words: words)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    // MARK: - 导入方法

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            let count: Int
            if ext == "csv" {
                count = try ImportExportService.shared.importWordsFromCSV(url: url, context: modelContext)
            } else if ext == "json" {
                count = try ImportExportService.shared.importWordsFromJSON(url: url, context: modelContext)
            } else {
                importResultMessage = String(localized: "不支持的文件格式")
                showImportResult = true
                return
            }
            importResultMessage = String(localized: "成功导入 \(count) 条记录")
            showImportResult = true
        } catch {
            importResultMessage = String(localized: "导入失败：\(error.localizedDescription)")
            showImportResult = true
        }
    }
}

// MARK: - 错误横幅

/// 顶部错误横幅：红色背景的醒目提示，带关闭按钮
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 480)
        .shadow(radius: 4)
    }
}

// MARK: - 订阅查词状态的小视图

/// 错误横幅：截图分析失败时在窗口顶部醒目提示
private struct AnalysisErrorOverlay: View {
    @EnvironmentObject private var analysisVM: AnalysisViewModel

    var body: some View {
        Group {
            if let errorMsg = analysisVM.errorMessage {
                ErrorBanner(message: errorMsg) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        analysisVM.clearError()
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: analysisVM.errorMessage)
    }
}

/// 工具栏的截图取词按钮：带字和快捷键，分析中置灰
private struct ScreenshotToolbarButton: View {
    @EnvironmentObject private var analysisVM: AnalysisViewModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder")
                Text("截图取词")
                Kbd(keys: HotkeyPrefs.screenshot.displayString)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(analysisVM.isAnalyzing)
        .help("框住屏幕上的词，讲解存进词库")
    }
}

/// 搜索框只在单词和知识片段页出现；统计页没有可搜的
private struct OptionalSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: prompt)
        } else {
            content
        }
    }
}

// MARK: - 单词页 / 知识片段页

/// 单词页：词库是空的就是「查第一个词」，不然左边列表右边详情
private struct WordsPage: View {
    @Binding var selectedWord: WordEntry?
    @Binding var selectedIDs: Set<UUID>
    @Binding var groupMode: CategorySidebar.GroupMode
    let selectedCategory: Category?
    let searchText: String?
    let onTry: () -> Void

    /// 只问有没有词，不把整个词库拉进来
    @Query(WordsPage.oneWord) private var anyWord: [WordEntry]
    @Environment(\.modelContext) private var modelContext

    private static var oneWord: FetchDescriptor<WordEntry> {
        var d = FetchDescriptor<WordEntry>()
        d.fetchLimit = 1
        return d
    }

    var body: some View {
        if anyWord.isEmpty {
            FirstWordView(onTry: onTry)
        } else {
            HStack(spacing: 0) {
                WordListView(
                    selectedWord: $selectedWord,
                    selectedIDs: $selectedIDs,
                    groupMode: $groupMode,
                    selectedCategory: selectedCategory,
                    searchText: searchText
                )
                .frame(width: 360)
                Rectangle().fill(Theme.border).frame(width: 0.5)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selectedIDs.count > 1 {
            // 多选 → 批量操作面板
            WordBatchView(words: wordsForSelection) {
                selectedIDs = []
                selectedWord = nil
            }
        } else if let word = selectedWord {
            WordDetailView(word: word) {
                selectedWord = nil
                selectedIDs = []
            }
        } else {
            EmptyHint(symbol: "text.book.closed", title: "选一个词看详情")
        }
    }

    /// 当前多选对应的单词对象：只取选中的那几个（框选时每拖一下都要算，取整个词库再筛 2000 个词时每下卡 0.25 秒）
    private var wordsForSelection: [WordEntry] {
        let ids = Array(selectedIDs)
        let descriptor = FetchDescriptor<WordEntry>(predicate: #Predicate { ids.contains($0.id) },
                                                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}

/// 知识片段页：一条都没有时是一个小图标加一句话
private struct SnippetsPage: View {
    @Binding var selectedSnippet: KnowledgeSnippet?
    @Binding var groupMode: CategorySidebar.GroupMode
    let selectedCategory: Category?
    let searchText: String?
    let onOpenWord: (WordEntry) -> Void

    @Query(SnippetsPage.oneSnippet) private var anySnippet: [KnowledgeSnippet]

    private static var oneSnippet: FetchDescriptor<KnowledgeSnippet> {
        var d = FetchDescriptor<KnowledgeSnippet>()
        d.fetchLimit = 1
        return d
    }

    var body: some View {
        if anySnippet.isEmpty {
            EmptyHint(symbol: "doc.text", title: "还没有知识片段", message: "截图时框住一段说明性文字，就会存成知识片段。")
        } else {
            HStack(spacing: 0) {
                SnippetListView(
                    selectedSnippet: $selectedSnippet,
                    groupMode: $groupMode,
                    selectedCategory: selectedCategory,
                    searchText: searchText
                )
                .frame(width: 360)
                Rectangle().fill(Theme.border).frame(width: 0.5)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let snippet = selectedSnippet {
            SnippetDetailView(snippet: snippet, onDelete: { selectedSnippet = nil }, onOpenWord: onOpenWord)
        } else {
            EmptyHint(symbol: "doc.text", title: "选一条片段看详情")
        }
    }
}

/// 工具栏「译成 简体中文 ▾」：改的是之后查的词，已存的不变
struct TargetLanguageMenu: View {
    @AppStorage(TargetLanguage.key) private var target: TargetLanguage = .zhHans

    var body: some View {
        Menu {
            Picker("译成", selection: $target) {
                ForEach(TargetLanguage.allCases) { Text($0.nativeName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Text("已经存下的词不会变")
        } label: {
            Text("译成 \(target.nativeName)")
        }
        .fixedSize()
        .help("释义和译文写成哪种语言；只影响之后查的词")
    }
}
