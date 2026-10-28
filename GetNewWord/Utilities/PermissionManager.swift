// PermissionManager.swift
// GetNewWord
//
// 截图取词要用的系统权限：只有屏幕录制。启动时缺就先说明再申请，不等到第一次按快捷键；
// 设置里也能随时查看状态、授权或跳转系统设置。
// 不要辅助功能：快捷键是 Carbon RegisterEventHotKey，点面板外关闭是鼠标的全局监听，都不需要它。

import AppKit
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
    }

    @Published private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()

    /// 屏幕录制的系统对话框每个 App 只弹一次，之后再请求要直接打开系统设置
    private static let screenPromptedKey = "screenRecordingPrompted"
    private var activeObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    /// 这次启动已经提醒过屏幕录制（弹过说明，或用户在欢迎页看过权限那一步）
    var askedThisLaunch = false

    private init() {
        // 用户从系统设置切回来时刷新状态
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PermissionManager.shared.refresh() }
        }
    }

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != hasScreenRecording { hasScreenRecording = screen }
    }

    /// 启动时调用：只在缺「屏幕录制」时弹说明（截图取词离不开它）；已授权则什么都不做。
    func requestMissingAtLaunch() {
        // 一次启动最多问一次；欢迎页的权限那步也算问过
        guard !askedThisLaunch else { return }
        askedThisLaunch = true
        refresh()
        AppLog.log("[Permission] launch check: screen=\(hasScreenRecording)")
        guard !hasScreenRecording else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "GetNewWord 需要屏幕录制权限")
        alert.informativeText = String(localized: "截图取词要截取屏幕区域。授权后需要重启 App 才生效；以后也可以在「设置 → 权限」里授权。")
        alert.addButton(withTitle: String(localized: "去授权"))
        alert.addButton(withTitle: String(localized: "稍后"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            AppLog.log("[Permission] launch prompt dismissed")
            return
        }
        requestScreenRecording()
    }

    /// 带用户去系统设置，并在它旁边浮出能拖的图标（拖进列表就授权）
    func requestScreenRecording() {
        promptScreenRecording()
        PermissionDragHelper.shared.show()
        startPolling()
    }

    /// 只负责把用户带到授权入口：每次都先向系统登记（授权记录被重置 / 签名变化后，App 才会重新出现在列表里），
    /// 第一次由系统弹对话框，之后再直接打开系统设置对应页面
    func promptScreenRecording() {
        CGRequestScreenCaptureAccess()
        if UserDefaults.standard.bool(forKey: Self.screenPromptedKey) {
            openSettings(.screenRecording)
        } else {
            UserDefaults.standard.set(true, forKey: Self.screenPromptedKey)
        }
    }

    func openSettings(_ pane: Pane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 授权发生在系统设置里：轮询 2 分钟刷新状态；屏幕录制从无到有时提示重启
    private func startPolling() {
        pollTask?.cancel()
        let hadScreen = hasScreenRecording
        pollTask = Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                refresh()
                if !hadScreen && hasScreenRecording {
                    PermissionDragHelper.shared.hide()
                    ScreenshotService.shared.relaunchAppForPermission()
                    return
                }
                if hasScreenRecording { PermissionDragHelper.shared.hide(); return }
            }
        }
    }
}
