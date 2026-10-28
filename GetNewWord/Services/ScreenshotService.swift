// ScreenshotService.swift
// GetNewWord
//
// 截图服务：使用 CGWindowListCreateImage 截取屏幕，
// 通过 ScreenshotOverlayController 显示覆盖层让用户框选区域

import Foundation
import AppKit
import ScreenCaptureKit

@MainActor
class ScreenshotService {
    static let shared = ScreenshotService()

    /// 截图完成回调类型：(带红框的语境图, 纯选区小图——本地 OCR 秒查词库用)
    typealias CompletionHandler = @Sendable (NSImage?, NSImage?) -> Void

    private var overlayController: ScreenshotOverlayController?

    private init() {}

    // MARK: - 区域截图

    /// 开始区域截图（会显示覆盖层让用户框选）
    func startRegionScreenshot(completion: @escaping CompletionHandler) {
        // 先检查权限
        guard hasScreenRecordingPermission() else {
            // 请求权限
            Task { @MainActor in
                let granted = await requestScreenRecordingPermission()
                if granted {
                    self.performRegionScreenshot(completion: completion)
                } else {
                    completion(nil, nil)
                }
            }
            return
        }

        performRegionScreenshot(completion: completion)
    }

    /// 执行区域截图
    private func performRegionScreenshot(completion: @escaping CompletionHandler) {
        // 逐屏幕独立截图，确保每个覆盖层窗口的坐标与图片像素坐标完全一致
        let screenImages = capturePerScreen()
        guard !screenImages.isEmpty else {
            // 截屏失败：屏幕录制权限可能对当前进程未生效
            // （授权后未重启，或应用重新构建导致 TCC 记录失效等），提示用户重启
            showPermissionRestartAlert()
            completion(nil, nil)
            return
        }

        // 创建覆盖层控制器
        let controller = ScreenshotOverlayController()
        overlayController = controller

        // 显示覆盖层，让用户框选区域（传入每个屏幕对应的截图）
        controller.showOverlay(screenImages: screenImages) { [weak self] image, selection in
            Task { @MainActor in
                self?.overlayController = nil
                completion(image, selection)
            }
        }
    }

    // MARK: - 全屏截图

    /// 截取每个屏幕的独立截图，返回 [(screen, image)]
    func capturePerScreen() -> [(screen: NSScreen, image: NSImage)] {
        var results: [(NSScreen, NSImage)] = []

        for screen in NSScreen.screens {
            let frame = screen.frame

            guard let cgImage = CGWindowListCreateImage(
                frame,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            ) else { continue }

            // 使用 CGImage 的实际像素尺寸创建 NSImage
            let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
            let nsImage = NSImage(cgImage: cgImage, size: pixelSize)
            results.append((screen, nsImage))
        }

        return results
    }

    /// 截取整个屏幕内容（合并所有屏幕，保留用于其他用途）
    func captureFullScreen() -> NSImage? {
        var combinedFrame = CGRect.zero
        for screen in NSScreen.screens {
            combinedFrame = combinedFrame.union(screen.frame)
        }

        if combinedFrame.isEmpty {
            if let mainScreen = NSScreen.main {
                combinedFrame = mainScreen.frame
            } else {
                return nil
            }
        }

        guard let cgImage = CGWindowListCreateImage(
            combinedFrame,
            .optionAll,
            kCGNullWindowID,
            .bestResolution
        ) else {
            return nil
        }

        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: pixelSize)
    }

    // MARK: - 权限管理

    /// 检查是否已有屏幕录制权限
    func hasScreenRecordingPermission() -> Bool {
        // CGPreflightScreenCaptureAccess 在 macOS 12.3+ 可用
        return CGPreflightScreenCaptureAccess()
    }

    /// 请求屏幕录制权限
    ///
    /// macOS 的屏幕录制权限（TCC）授予后对已运行的进程不生效，必须重启应用。
    /// 因此本方法检测到「权限从无到有」时，会提示用户重启应用并返回 false，
    /// 中断本次截图（重启后用户再按快捷键即可正常截图）。
    func requestScreenRecordingPermission() async -> Bool {
        // 已有权限则直接返回，避免重复弹出系统权限对话框
        if hasScreenRecordingPermission() {
            return true
        }

        // 第一次弹系统对话框；系统只弹一次，之前弹过就直接打开系统设置对应页面
        await PermissionManager.shared.promptScreenRecording()

        // 轮询等待用户在系统设置中完成授权（最多 60 秒）
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if hasScreenRecordingPermission() {
                // 权限刚授予：当前进程无法使用，需要重启应用才能生效
                relaunchAppForPermission()
                return false // 中断本次截图，重启后用户再按快捷键
            }
        }
        return false
    }

    /// 权限刚授予后提示用户重启应用，并提供一键重启
    ///
    /// 重启实现说明：
    /// - 不能「先 open 再退出」：`open` 对已运行的应用只会激活旧实例，不会启动新实例；
    /// - 不能用 `open -n` 双实例并存：新实例启动时旧实例仍持有 Carbon 热键，
    ///   会导致新实例的全局快捷键注册失败。
    /// 因此通过 shell 脚本等待当前进程完全退出后，再启动新实例，保证重启可靠。
    func relaunchAppForPermission() {
        let alert = NSAlert()
        alert.messageText = String(localized: "权限已授予，需要重启应用")
        alert.informativeText = String(localized: "屏幕录制权限已成功授予。\n点击「重新启动」后应用将自动重启，快捷键截图功能即可正常使用。")
        alert.addButton(withTitle: String(localized: "重新启动"))
        alert.addButton(withTitle: String(localized: "稍后手动重启"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 重启脚本：等待当前进程（按 PID）完全退出后，再重新打开应用
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; sleep 0.3; open \"$2\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            script,
            "relaunch",                                          // $0（占位）
            String(ProcessInfo.processInfo.processIdentifier),  // $1 = 当前进程 PID
            Bundle.main.bundleURL.path                           // $2 = 应用 bundle 路径
        ]

        do {
            try task.run()
        } catch {
            NSLog("ScreenshotService: 启动重启脚本失败: \(error)")
            return
        }

        // 稍作延迟让脚本就位，随后退出当前实例（脚本会在进程退出后启动新实例）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSApp.terminate(nil)
        }
    }

    /// 截屏失败（权限对当前进程未生效）时，提示用户重启应用
    private func showPermissionRestartAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "无法截取屏幕")
        alert.informativeText = String(localized: "屏幕录制权限可能对当前进程未生效。\n请完全退出应用（菜单栏图标 → 退出）后重新打开，或到「系统设置 → 隐私与安全性 → 屏幕录制」中先关闭再重新开启 GetNewWord 的权限，然后重启应用。")
        alert.addButton(withTitle: String(localized: "好"))

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 保存截图

    /// 获取截图保存目录
    func getScreenshotDirectory() -> String {
        let fileManager = FileManager.default
        let dir = AppVariant.supportDirectory.appendingPathComponent("screenshots")

        // 确保目录存在
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.path
    }

    /// 保存截图到文件：路径当场给出，PNG 编码和写盘放后台（2000px 级的图在主线程编码要一两百毫秒，挡住查词）
    /// - Returns: 将要写入的文件路径，图取不出像素时返回 nil
    func saveScreenshot(_ image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let dir = getScreenshotDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "screenshot_\(formatter.string(from: Date())).png"
        let filePath = (dir as NSString).appendingPathComponent(filename)

        DispatchQueue.global(qos: .utility).async {
            guard let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
            do {
                try pngData.write(to: URL(fileURLWithPath: filePath))
            } catch {
                AppLog.log("[Screenshot] 保存失败 \(filePath): \(error.localizedDescription)")
            }
        }
        return filePath
    }
}
