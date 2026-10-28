// AppLocation.swift
// GetNewWord
//
// 应用在不在「应用程序」文件夹里。从 DMG、「下载」直接打开的那份，Sparkle 下好更新也替换不了，
// 以后会一直停在那一版：欢迎页和「更新与关于」据此提示，并能一键拷过去、从新位置重开。

import AppKit

enum AppLocation {
    /// 在 /Applications 或 ~/Applications（含子文件夹）里
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return folders.contains { path.hasPrefix($0 + "/") }
    }

    /// 要不要提示。开发版从 Xcode 的编译目录（…/Build/Products/…）跑不算；拷进 DMG 测这个提示时照样出现
    static var shouldOfferMove: Bool {
        !isInApplications && !(AppVariant.isDev && Bundle.main.bundleURL.path.contains("/Build/Products/"))
    }

    /// 拷进「应用程序」（不能写时用 ~/Applications），那里的旧版扔进废纸篓；
    /// 原来这份在可写的地方就也扔进废纸篓（DMG 只读、被系统临时搬去运行的 App Translocation 都留着），然后从新位置重开
    @MainActor static func moveToApplicationsAndRelaunch() throws {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fm.isWritableFile(atPath: folder.path) {
            folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let target = folder.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: target)
        // 用户已经从 DMG 打开过它：拷过去的那份去掉「来自互联网」标记，重开时不再弹一次 Gatekeeper 确认
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
        try xattr.run()
        xattr.waitUntilExit()
        AppLog.log("[Location] copied into \(folder.path)")

        let readOnly = try source.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly ?? true
        if !readOnly && !source.path.contains("/AppTranslocation/") {
            do {
                try fm.trashItem(at: source, resultingItemURL: nil)
            } catch {
                AppLog.log("[Location] old copy left in place: \(error)")   // 新的那份已经好了，旧的留着不影响
            }
        }

        // 等本进程退出再开新的，不然两个实例抢同一个全局快捷键
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
                              "relaunch", String(ProcessInfo.processInfo.processIdentifier), target.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}
