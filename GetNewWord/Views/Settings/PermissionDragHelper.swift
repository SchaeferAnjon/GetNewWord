// PermissionDragHelper.swift
// GetNewWord
//
// 拖图标授权：系统设置的「屏幕录制」列表接受把 .app 拖进去，拖进去就加上并打开开关。
// 点「去授权」时打开系统设置，并在它的窗口下方浮出一个小面板，上面是能拖的 GetNewWord 图标；
// 跟着系统设置窗口走，授权成功、系统设置关掉或点 ✕ 时消失。

import SwiftUI
import AppKit

/// 能拖的应用图标：拖出去的是本 App 的文件地址，和从 Finder 里拖 .app 一样
struct DraggableAppIcon: View {
    var size: CGFloat = 48
    @State private var hovering = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .padding(6)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0; if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("把图标拖进系统设置的列表")
    }
}

@MainActor
final class PermissionDragHelper {
    static let shared = PermissionDragHelper()

    private var panel: NSPanel?
    private var follow: Task<Void, Never>?
    private let size = NSSize(width: 340, height: 92)

    func show() {
        hide()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HelperView { [weak self] in self?.hide() }.appAppearance())
        self.panel = panel

        // 系统设置要一会儿才开窗；之后用户可能挪动它，跟着走
        follow = Task { @MainActor [weak self] in
            var seen = false
            for _ in 0..<600 {   // 最多 4 分钟
                guard let self, !Task.isCancelled else { return }
                if let frame = Self.systemSettingsFrame() {
                    // 系统设置早就开着时 open URL 不会把它带到前面，列表被别的窗口挡住就没法拖
                    // macOS 14 起只能由前台应用把前台让给别人（yieldActivation），自己不在前台时这步不生效
                    if !seen, let ss = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                        NSApp.yieldActivation(to: ss)
                        ss.activate()
                    }
                    seen = true
                    self.place(beside: frame)
                    if !panel.isVisible { panel.orderFrontRegardless() }
                } else if seen {
                    self.hide()   // 系统设置关掉了
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            self?.hide()
        }
    }

    func hide() {
        follow?.cancel()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// 优先贴在系统设置窗口右边（列表在窗口右半边，往左一拖就到）；右边放不下就放下面，再不行压在它底部里面
    private func place(beside ss: NSRect) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.intersects(ss) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin: NSPoint
        if ss.maxX + 12 + size.width <= visible.maxX {
            origin = NSPoint(x: ss.maxX + 12, y: ss.midY - size.height / 2)
        } else if ss.minY - size.height - 10 >= visible.minY {
            origin = NSPoint(x: ss.midX - size.width / 2, y: ss.minY - size.height - 10)
        } else {
            origin = NSPoint(x: ss.maxX - size.width - 16, y: ss.minY + 16)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// 系统设置主窗口的位置（Cocoa 坐标，左下原点）
    private static func systemSettingsFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let win = list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard let b = win?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 200,
              let primary = NSScreen.screens.first else { return nil }
        // CG 坐标是左上原点、以主屏顶边为 0
        return NSRect(x: x, y: primary.frame.maxY - y - h, width: w, height: h)
    }

    private struct HelperView: View {
        let close: () -> Void
        @State private var nudge = false

        var body: some View {
            HStack(spacing: 14) {
                DraggableAppIcon(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left").font(.system(size: 11, weight: .semibold))
                            .offset(x: nudge ? -3 : 1)
                        Text("把图标拖进系统设置的列表")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    Text("拖进去开关就打开了，再按系统提示重开一次。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2)
                        .frame(width: 18, height: 18).background(Theme.selected, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(width: 340, height: 92)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { nudge = true }
            }
        }
    }
}
