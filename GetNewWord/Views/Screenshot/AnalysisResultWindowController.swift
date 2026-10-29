// AnalysisResultWindowController.swift
// GetNewWord
//
// NSPanel 包装器：用于显示浮动分析结果面板

import AppKit
import Carbon.HIToolbox
import SwiftUI
import SwiftData

/// 无边框窗口默认不能成为 key window，面板里的输入框（加标签）收不到键盘；
/// nonactivating panel 可以在不激活 app 的前提下接收键盘，显式放开。
/// 弹出时不设成 key：键盘留给原来的 App（看视频时空格照样暂停/播放），用户点进面板才拿到键盘。
final class KeyableBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
class AnalysisResultWindowController {
    var panel: NSPanel?
    private var viewModel: AnalysisViewModel?
    private var modelContext: ModelContext?

    /// 用户拖边缘调过的大小，下次弹出沿用（按样式分开记；收起的浮签每次都用默认的小尺寸）
    private static func sizeKey(_ style: LookupPanelStyle) -> String { "resultPanelSize.\(style.rawValue)" }
    /// 1.1.x 只有一种面板，大小记在这里；经典卡片就是那一种，没调过经典卡片的大小时沿用它
    static let legacySizeKey = "resultPanelSize"

    /// 这种样式上次关面板时的大小（收起的浮签不记）
    static func savedSize(_ style: LookupPanelStyle, defaults: UserDefaults = .standard) -> NSSize? {
        guard style != .tag else { return nil }
        let raw = defaults.string(forKey: sizeKey(style)) ?? (style == .classic ? defaults.string(forKey: legacySizeKey) : nil)
        return raw.map(NSSizeFromString).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    }
    private static let minSize = NSSize(width: 360, height: 200)

    /// 显示分析结果浮动面板
    func show(viewModel: AnalysisViewModel, modelContext: ModelContext) {
        // 钉住时：新一轮取词沿用原位置和大小、保持钉住；未钉住才回到鼠标附近
        let wasPinned = pinned
        let preservedFrame: NSRect? = wasPinned ? panel?.frame : nil
        // 关旧面板（不重置钉住状态）
        removeDismissMonitors()
        closePanel()
        pendingDismiss = nil

        self.viewModel = viewModel
        self.modelContext = modelContext

        // 大小：用户调过就沿用，否则高度跟随屏幕（最多离屏幕上下各留 60pt）；都不超出屏幕可见区域
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let vf = mouseScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let style = LookupPanelStyle.current
        openedStyle = style
        var fresh = style.panelSize(expanded: style != .tag)
        // 经典卡片和 1.1.7 一样：高度最多 780，离屏幕上下各留 60
        if style == .classic { fresh.height = min(fresh.height, vf.height - 120) }
        let wanted = preservedFrame?.size ?? Self.savedSize(style) ?? fresh
        let panelSize = NSSize(width: max(Self.minSize.width, min(wanted.width, vf.width - 20)),
                               height: max(Self.minSize.height, min(wanted.height, vf.height - 20)))

        let contentView = AnalysisResultPanel(
            viewModel: viewModel,
            modelContext: modelContext,
            onSave: { [weak self] in
                guard let self = self, let context = self.modelContext else { return }
                viewModel.saveSelectedResults(context: context)
                self.dismiss()
            },
            onDismiss: { [weak self] in
                viewModel.dismissPanel()
                self?.dismiss()
            },
            onTogglePin: { [weak self] in self?.setPinned($0) },
            startPinned: wasPinned,
            onResize: { [weak self] in self?.resize(to: $0) }
        )

        let hostingView = NSHostingView(rootView: contentView)
        // 不让 NSHostingView 往窗口的约束系统里发 invalidation：
        // hitTest（鼠标移动）期间 SwiftUI 懒更新 → setNeedsUpdateConstraints 落在显示周期里 → AppKit 抛异常闪退
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]

        // 欧路词典式：无标题栏红绿灯，点面板外任意位置 / Esc / ✕ 关闭；拖边缘可调大小
        let panel = KeyableBorderlessPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minSize
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 必须为 false：Swift 侧持有强引用，若 close() 时 AppKit 再 release 一次会 over-release 崩溃
        panel.isReleasedWhenClosed = false

        panel.contentView = hostingView
        let dismissAction: () -> Void = { [weak self] in
            viewModel.dismissPanel()
            self?.dismiss()
        }
        pendingDismiss = dismissAction
        pinned = wasPinned
        installDismissMonitors(for: panel, onDismiss: dismissAction, escOnly: wasPinned)

        if let preservedFrame {
            // 钉住：留在用户拖到的地方。只有顶栏已不在任何屏幕上（显示器拔掉/分辨率变了）才拉回可见区域，
            // 与 Windows 版 panel-bounds 同语义（PR #1 移植）
            let origin = NSPoint(x: preservedFrame.minX, y: preservedFrame.maxY - panelSize.height)
            let header = NSRect(x: origin.x, y: origin.y + panelSize.height - 40, width: panelSize.width, height: 40)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(header).width >= 100 }) {
                panel.setFrameOrigin(origin)
            } else {
                let x = min(max(origin.x, vf.minX + 10), vf.maxX - panelSize.width - 10)
                let y = min(max(origin.y, vf.minY + 10), vf.maxY - panelSize.height - 10)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        } else {
            // 欧陆词典风格：显示在鼠标右下方；靠近屏幕右/下边界时向左/上收回屏幕内
            let x = min(max(mouseLocation.x + 16, vf.minX + 10), vf.maxX - panelSize.width - 10)
            let y = min(max(mouseLocation.y - panelSize.height - 16, vf.minY + 10), vf.maxY - panelSize.height - 10)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// 钉住：移除关闭监听；取消钉住则重新装上
    var isPinned: Bool { pinned }
    private var pinned = false
    private var pendingDismiss: (() -> Void)?
    func setPinned(_ p: Bool) {
        pinned = p
        if let panel, let action = pendingDismiss {
            // 钉住：只保留 Esc 关闭；未钉住：点外面 / Esc 都关闭
            installDismissMonitors(for: panel, onDismiss: action, escOnly: p)
        } else if p {
            removeDismissMonitors()
        }
    }

    /// 关闭面板
    func dismiss() {
        pinned = false
        removeDismissMonitors()
        closePanel()
    }

    /// 浮签展开 / 收起：上沿不动，往下长；超出屏幕就往上收
    private func resize(to size: NSSize) {
        guard let panel else { return }
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let h = min(size.height, vf.height - 20), w = min(size.width, vf.width - 20)
        var frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - h, width: w, height: h)
        if frame.minY < vf.minY + 10 { frame.origin.y = vf.minY + 10 }
        if frame.maxX > vf.maxX - 10 { frame.origin.x = vf.maxX - 10 - w }
        panel.setFrame(frame, display: true, animate: true)
    }

    /// 这个面板按哪种样式打开的：关的时候按它记尺寸（中途在设置里换了样式也不记错）
    private var openedStyle: LookupPanelStyle = .classic

    /// 关掉面板前记下大小
    private func closePanel() {
        guard let panel else { return }
        let style = openedStyle
        if style != .tag { UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: Self.sizeKey(style)) }
        // 关的时候不播 utilityWindow 的淡出：点外面要立刻消失
        panel.animationBehavior = .none
        panel.orderOut(nil)
        self.panel = nil
    }

    // MARK: - 欧路式关闭：点面板外 / Esc

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private static let escHotkeyID = "result-panel-esc"

    private func installDismissMonitors(for panel: NSPanel, onDismiss: @escaping () -> Void, escOnly: Bool = false) {
        removeDismissMonitors()
        // 面板不是 key window，Esc 落在别的 App 上：面板开着时临时把 Esc 注册成全局热键
        HotkeyManager.shared.register(identifier: Self.escHotkeyID, keyCode: UInt32(kVK_Escape), modifiers: 0) {
            Task { @MainActor [weak self] in self?.escapePressed() }
        }
        guard !escOnly else { return }
        // 点了别的 app：关（钉住时不装这个）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in onDismiss() }
        }
        // 本 app 内点面板外也关
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak panel] event in
            if event.window !== panel {
                Task { @MainActor in onDismiss() }
            }
            return event
        }
    }

    /// 框选覆盖层在场时（钉住的面板开着又框选），Esc 归框选层，只取消截图
    private func escapePressed() {
        if let overlay = NSApp.windows.first(where: { $0 is OverlayWindow && $0.isVisible }) {
            overlay.contentView?.cancelOperation(nil)
        } else {
            pendingDismiss?()
        }
    }

    private func removeDismissMonitors() {
        HotkeyManager.shared.unregister(identifier: Self.escHotkeyID)
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}
