// FloatingButtonController.swift
// GetNewWord
//
// 桌面悬浮球：置顶小圆钮，点击 = 截图取词，右键 = 快速查词 / 隐藏。
// 可拖动，位置记住；设置 → 通用 可开关。

import AppKit
import SwiftUI

@MainActor
final class FloatingButtonController {
    static let shared = FloatingButtonController()

    private var panel: NSPanel?
    private var onCapture: (() -> Void)?
    private var onLookup: (() -> Void)?

    private let posKey = "floatingButtonPos"
    private let size: CGFloat = 44

    private init() {}

    func configure(onCapture: @escaping () -> Void, onLookup: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onLookup = onLookup
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "showFloatingButton") == nil ? true : defaults.bool(forKey: "showFloatingButton")
        setVisible(enabled)
    }

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    private func show() {
        guard panel == nil else { return }

        let content = NSHostingView(rootView: FloatingButtonView(
            onCapture: { [weak self] in self?.onCapture?() },
            onLookup: { [weak self] in self?.onLookup?() },
            onHide: { [weak self] in
                UserDefaults.standard.set(false, forKey: "showFloatingButton")
                self?.hide()
            }
        ))
        content.sizingOptions = []
        content.frame = NSRect(x: 0, y: 0, width: size, height: size)

        let panel = KeyableBorderlessPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // 按住拖动
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // 恢复上次位置；默认右侧居中偏上
        if let posString = UserDefaults.standard.string(forKey: posKey) {
            panel.setFrameOrigin(NSPointFromString(posString))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - size - 16, y: f.midY + 100))
        }

        // 移动后记住位置
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            let origin = panel.frame.origin
            DispatchQueue.main.async {
                UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "floatingButtonPos")
            }
        }

        panel.orderFrontRegardless()
        self.panel = panel
        AppLog.log("[Float] button shown")
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - 悬浮球视图

private struct FloatingButtonView: View {
    let onCapture: () -> Void
    let onLookup: () -> Void
    let onHide: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onCapture) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(hovering ? 1.0 : 0.88))
                    .shadow(color: .black.opacity(0.25), radius: hovering ? 6 : 3, y: 1)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .frame(width: 40, height: 40)
        .padding(2)
        .scaleEffect(hovering ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("截图取词（右键更多）")
        .contextMenu {
            Button("截图取词（自动保存）") { onCapture() }
            Button("快速查词（不保存）") { onLookup() }
            Divider()
            Button("打开主窗口") { MainWindowOpener.open() }
            Button("隐藏悬浮球") { onHide() }
        }
    }
}
