// GetNewWordApp.swift
// GetNewWord
//
// macOS 应用入口
// 只需要屏幕录制权限（截取屏幕内容以提取单词）；快捷键用 Carbon 注册、点面板外关闭用鼠标全局监听，都不要辅助功能权限

import SwiftUI
import SwiftData

/// 程序入口：先做必须赶在 SwiftUI 读本地化字符串之前的事，再交给 App。
/// （放进 App.init 已经晚了：那时界面语言已经定了，要到下次启动才生效）
@main
enum Launcher {
    static func main() {
        if let output = SelfTest.outputPath(in: CommandLine.arguments) {
            exit(SelfTest.run(writingTo: output) ? 0 : 1)
        }
        if AppVariant.isUnitTesting {
            // 测试只要一个空的应用进程：不开窗口、不注册快捷键、不碰开发版的词库；临时数据目录测完删掉
            atexit { try? FileManager.default.removeItem(at: AppVariant.supportDirectory) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
            return
        }
        AppLanguage.keepChineseForExistingUsers()
        // 用法第一次定下来：1.2.0 以前填过 Key 的照旧自带 Key，新用户默认会员。要赶在界面读它之前
        AIPlan.settle { APIProvider.allCases.contains { !(ZhipuService.shared.key(for: $0) ?? "").isEmpty } }
        GetNewWordApp.main()
    }
}

struct GetNewWordApp: App {
    /// SwiftData 模型容器
    let container: ModelContainer = {
        let schema = Schema([WordEntry.self, WordContext.self, KnowledgeSnippet.self, Category.self])
        // 独立存储路径：SwiftData 默认的 Application Support/default.store 是所有未沙盒 App 共享的文件，
        // 会被其他同样用默认配置的进程（实测 icloudmailagent）打开甚至改写，导致写入失败与数据回滚（丢词根因）。
        let config = ModelConfiguration(schema: schema, url: AppVariant.supportDirectory.appendingPathComponent("GetNewWord.store"))
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }()

    /// 分析流程 ViewModel
    /// @State 而不是 @StateObject：App 只负责持有，不订阅它的变化——
    /// 否则查词时每改一个 @Published 都重算整个 App（含菜单栏菜单的词条查询），主线程卡 0.3s
    @State private var analysisVM = AnalysisViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppIcons.menuBarKey) private var showMenuBarIcon = true

    init() {
        _ = AppUpdater.shared   // 启动时就开始按计划查更新，不等打开设置
    }

    var body: some Scene {
        // 主窗口
        Window("GetNewWord", id: MainWindowOpener.id) {
            MainView()
                .environmentObject(analysisVM)
                .environment(\.analysisVM, analysisVM)
                .environment(\.modelContext, container.mainContext)
                .appAppearance()
                .frame(minWidth: 1100, minHeight: 680)
        }
        .modelContainer(container)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("放大字号") { FontScale.step(+1) }.keyboardShortcut("+", modifiers: .command)
                Button("缩小字号") { FontScale.step(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("默认字号") { FontScale.reset() }.keyboardShortcut("0", modifiers: .command)
            }
        }

        // 偏好设置窗口
        Settings {
            SettingsView()
                .environment(\.modelContext, container.mainContext)
                .appAppearance()
        }
        .modelContainer(container)

        // 状态栏菜单栏图标
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView(analysisVM: analysisVM)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

/// 菜单栏图标：logo 的取景框四角 + A，模板图，跟随菜单栏深浅色
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.set()
            let box = rect.insetBy(dx: 1.5, dy: 1.5)
            let arm: CGFloat = 4.5, radius: CGFloat = 2
            let corners = NSBezierPath()
            corners.lineWidth = 1.5
            corners.lineCapStyle = .round
            for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                                   (box.maxX, box.maxY, -1.0, -1.0), (box.minX, box.maxY, 1.0, -1.0)] {
                let corner = NSPoint(x: x, y: y)
                corners.move(to: NSPoint(x: x, y: y + dy * arm))
                corners.line(to: NSPoint(x: x, y: y + dy * radius))
                corners.curve(to: NSPoint(x: x + dx * radius, y: y), controlPoint1: corner, controlPoint2: corner)
                corners.line(to: NSPoint(x: x + dx * arm, y: y))
            }
            corners.stroke()
            let letter = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .heavy)])
            let size = letter.size()
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 0.5))
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// 菜单栏视图
struct MenuBarView: View {
    /// 只调用不订阅：查词时的状态变化不用重算菜单
    let analysisVM: AnalysisViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings

    @Query(
        sort: \WordEntry.createdAt,
        order: .reverse
    )
    private var todayWords: [WordEntry]

    @State private var isSyncing = false
    @AppStorage(TargetLanguage.key) private var target: TargetLanguage = .zhHans

    var body: some View {
        // 截图取词
        Button("截图取词（自动保存）") {
            Task { await analysisVM.triggerAnalysis(modelContext: modelContext, mode: .capture) }
        }
        Button("快速查词（不保存）") {
            Task { await analysisVM.triggerAnalysis(modelContext: modelContext, mode: .lookup) }
        }

        Divider()

        // 今日新增（最近 5 个单词）
        let filteredTodayWords = todayWords.filter { word in
            Calendar.current.isDateInToday(word.createdAt)
        }
        if !filteredTodayWords.isEmpty {
            Text("今日新增 (\(filteredTodayWords.count))")
                .font(.headline)
            ForEach(filteredTodayWords.prefix(5)) { word in
                Button("\(word.word) — \(word.meaning)") {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Divider()
        }

        // 同步 Anki
        Button(isSyncing ? "同步中..." : "同步 Anki") {
            Task {
                isSyncing = true
                await AnkiService.shared.syncEverythingPending(context: modelContext)
                isSyncing = false
            }
        }
        .disabled(isSyncing)

        Divider()

        // 打开主窗口
        Button("打开主窗口") {
            MainWindowOpener.open()
        }

        Menu("翻译成") {
            Picker("翻译成", selection: $target) {
                ForEach(TargetLanguage.allCases) { Text($0.nativeName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()

        if AppUpdater.shared.isAvailable {
            Button("检查更新…") { AppUpdater.shared.checkForUpdates() }
        }

        // 偏好设置（macOS 14+ 用 openSettings 环境动作；旧的 showSettingsWindow: 选择器已失效）
        Button("偏好设置...") {
            SettingsOpener.action = openSettings
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        // 退出
        Button("退出 GetNewWord") {
            NSApp.terminate(nil)
        }
    }
}


// MARK: - 主窗口唤起（面板按钮 / 菜单栏 / 悬浮球共用）

@MainActor
enum MainWindowOpener {
    static let id = "main"
    /// 主窗口首次出现时存下；没有 Dock 图标，关掉的主窗口只能靠它重新打开
    static var openWindow: OpenWindowAction?

    /// 打开/唤起主窗口：Window 场景只有一个实例，已开着就前置，关掉了就重建
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: id)
    }
}

// MARK: - 外观 / 字号（全局，AppStorage 驱动）

enum FontScale {
    static let key = "fontScale"
    static let steps: [Double] = [0.85, 0.92, 1.0, 1.1, 1.2, 1.35, 1.5]
    static var current: Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v == 0 ? 1.0 : v
    }
    static func step(_ delta: Int) {
        let idx = steps.firstIndex { abs($0 - current) < 0.01 } ?? 2
        let next = min(max(idx + delta, 0), steps.count - 1)
        UserDefaults.standard.set(steps[next], forKey: key)
    }
    static func reset() { UserDefaults.standard.set(1.0, forKey: key) }
}

/// 把用户选的外观（跟随系统/浅/深）和字号缩放注入到任意根视图（主窗口、NSPanel 里的 SwiftUI 都用它）
struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appearance") private var appearance: String = Appearance.system.rawValue
    @AppStorage(FontScale.key) private var fontScale: Double = 1.0
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
            .environment(\.fontScale, CGFloat(fontScale == 0 ? 1 : fontScale))
            .dynamicTypeSize(dynamicSize(for: fontScale))
    }
    /// 系统字体（.body/.caption 等）用 dynamicTypeSize 跟着缩放
    private func dynamicSize(for scale: Double) -> DynamicTypeSize {
        switch scale {
        case ..<0.9: return .xSmall
        case ..<0.97: return .small
        case ..<1.05: return .medium
        case ..<1.15: return .large
        case ..<1.3: return .xLarge
        case ..<1.45: return .xxLarge
        default: return .xxxLarge
        }
    }
}
extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}

// MARK: - Dock / 菜单栏图标（设置 → 通用 里开关，至少留一个）

enum AppIcons {
    static let dockKey = "showDockIcon"
    static let menuBarKey = "showMenuBarIcon"

    static var showDock: Bool { UserDefaults.standard.bool(forKey: dockKey) }   // 默认不显示（Info.plist LSUIElement）

    /// 显示 Dock 图标 = 普通应用；不显示 = 只在菜单栏的辅助应用
    @MainActor static func applyDock() {
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppIcons.applyDock() }
        AppLog.log("[Location] in Applications: \(AppLocation.isInApplications)")   // 不在的话自动更新装不上
        MemberService.shared.start()   // 会员模式查一次状态，回到前台再查（MemberService.swift）
        UsagePing.shared.start()   // 用户同意了才每天匿名报到一次（UsagePing.swift）
        #if DEBUG
        DemoMode.installShots()   // 实测留图：GNW_SHOT_DIR + SIGUSR1
        #endif
    }

    /// 点 Dock 图标：没开着的窗口就打开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in MainWindowOpener.open() } }
        return true
    }
}
