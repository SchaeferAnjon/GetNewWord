// AnkiInstaller.swift
// GetNewWord
//
// 一键装好 Anki 桌面版和 AnkiConnect 插件，并检测三件事：Anki 装了没、插件装了没、连得上没。
// Anki 安装包取 GitHub 最新 release 的 dmg；插件从 AnkiWeb 下载 .ankiaddon（zip）解压进 addons21。

import AppKit
import Foundation

@MainActor
@Observable
final class AnkiInstaller {
    static let shared = AnkiInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(Double)   // 0…1
        case installing
        case failed(String)
    }

    static let pluginCode = "2055492159"
    static let manualDownloadPage = URL(string: "https://apps.ankiweb.net")!
    static let pluginPage = URL(string: "https://ankiweb.net/shared/info/2055492159")!

    private(set) var ankiApp: URL?
    private(set) var ankiVersion: String?
    private(set) var pluginInstalled = false
    private(set) var ankiRunning = false
    private(set) var connected = false
    private(set) var checking = false
    var ankiPhase: Phase = .idle
    var pluginPhase: Phase = .idle
    var restarting = false
    /// Anki 有对话框挡着退不掉时的提示
    private(set) var restartBlocked = false

    /// 新版 Anki 用 net.ankiweb.anki，老版本是 net.ankiweb.dtop
    private let bundleIDs = ["net.ankiweb.anki", "net.ankiweb.dtop"]

    private var addonsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Anki2/addons21", directoryHint: .isDirectory)
    }
    private var pluginDir: URL { addonsDir.appending(path: Self.pluginCode, directoryHint: .isDirectory) }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60   // 安装包 230 MB 左右
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - 检测

    func refresh() async {
        checking = true
        ankiApp = bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        ankiVersion = ankiApp.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        pluginInstalled = FileManager.default.fileExists(atPath: pluginDir.appending(path: "__init__.py").path)
        ankiRunning = runningAnki != nil
        connected = await AnkiService.shared.isAnkiRunning()
        checking = false
    }

    private var runningAnki: NSRunningApplication? {
        bundleIDs.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
    }

    // MARK: - 安装 Anki

    func installAnki() async {
        ankiPhase = .downloading(0)
        do {
            let dmgURL = try await latestDMG()
            let dmg = try await download(dmgURL) { [weak self] p in self?.ankiPhase = .downloading(p) }
            ankiPhase = .installing
            do {
                try await copyApp(fromDMG: dmg)
                try? FileManager.default.removeItem(at: dmg)
            } catch {
                // 没有写 /Applications 的权限时退回手动：打开 dmg，让用户自己拖
                AppLog.log("[AnkiInstaller] copy failed: \(error.localizedDescription)，改为打开 dmg")
                NSWorkspace.shared.open(dmg)
                ankiPhase = .failed(String(localized: "已下载好安装包并打开，请把 Anki 拖进「应用程序」"))
                return
            }
            ankiPhase = .idle
            await refresh()
        } catch {
            AppLog.log("[AnkiInstaller] install Anki failed: \(error.localizedDescription)")
            ankiPhase = .failed(error.localizedDescription)
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let assets: [Asset]
    }

    /// GitHub 最新 release 里本机架构的 dmg（mac-apple / mac-intel）
    private func latestDMG() async throws -> URL {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ankitects/anki/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let arch = isAppleSilicon ? "mac-apple" : "mac-intel"
        guard let asset = release.assets.first(where: { $0.name.contains(arch) && $0.name.hasSuffix(".dmg") }) else {
            throw InstallError(String(localized: "没找到适合这台 Mac 的 Anki 安装包"))
        }
        return asset.browser_download_url
    }

    private var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    private func copyApp(fromDMG dmg: URL) async throws {
        let mount = FileManager.default.temporaryDirectory.appending(path: "anki-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path], timeout: 120)
        defer {
            Task.detached { try? await Self.runDetached("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60) }
        }
        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw InstallError(String(localized: "安装包里没有找到 Anki.app"))
        }
        let target = URL(filePath: "/Applications").appending(path: app.lastPathComponent)
        try await run("/usr/bin/ditto", [app.path, target.path], timeout: 300)
    }

    // MARK: - 安装 AnkiConnect

    func installPlugin() async {
        pluginPhase = .downloading(0)
        do {
            // AnkiWeb 按 Anki 版本号（26.09.3 → 260903）给对应版本的插件
            let point = ankiVersion.map(Self.pointVersion) ?? 0
            let url = URL(string: "https://ankiweb.net/shared/download/\(Self.pluginCode)?v=2.1&p=\(point)")!
            let zip = try await download(url) { [weak self] p in self?.pluginPhase = .downloading(p) }
            pluginPhase = .installing
            let fm = FileManager.default
            try? fm.removeItem(at: pluginDir)
            try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, pluginDir.path], timeout: 60)
            try? fm.removeItem(at: zip)
            guard fm.fileExists(atPath: pluginDir.appending(path: "__init__.py").path) else {
                throw InstallError(String(localized: "下载到的插件不完整，请重试"))
            }
            // Anki 插件管理器靠 meta.json 显示名字
            let meta = ["name": "AnkiConnect", "mod": Int(Date().timeIntervalSince1970)] as [String: Any]
            try JSONSerialization.data(withJSONObject: meta).write(to: pluginDir.appending(path: "meta.json"))
            pluginPhase = .idle
            await refresh()
        } catch {
            AppLog.log("[AnkiInstaller] install plugin failed: \(error.localizedDescription)")
            pluginPhase = .failed(error.localizedDescription)
        }
    }

    nonisolated static func pointVersion(_ version: String) -> Int {
        let parts = version.split(separator: ".").compactMap { Int($0) } + [0, 0, 0]
        return parts[0] * 10000 + parts[1] * 100 + parts[2]
    }

    // MARK: - 打开 / 重启 Anki

    /// Anki 在跑就先退出再打开（新装的插件要重启才加载），然后等 AnkiConnect 起来
    func restartAnki() async {
        guard let ankiApp else { return }
        restarting = true
        restartBlocked = false
        if let running = runningAnki {
            running.terminate()
            for _ in 0..<40 where !running.isTerminated {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // 开着对话框（如插件安装窗口）的 Anki 不响应退出：切到前台让用户关掉，不强杀以免丢数据
            guard running.isTerminated else {
                running.activate()
                restartBlocked = true
                restarting = false
                return
            }
        }
        _ = try? await NSWorkspace.shared.openApplication(at: ankiApp, configuration: NSWorkspace.OpenConfiguration())
        // Anki 冷启动加载插件要几秒，最多等 30 秒
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
            if connected { break }
        }
        restarting = false
    }

    // MARK: - 工具

    private func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = DownloadProgress(progress)
        let (temp, response) = try await session.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InstallError(String(localized: "下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）"))
        }
        // 系统给的临时文件名是随机的，挪成带原文件名的，之后打开 dmg 时 Finder 显示得清楚
        let kept = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: temp, to: kept)
        return kept
    }

    private func run(_ tool: String, _ args: [String], timeout: TimeInterval) async throws {
        try await Self.runDetached(tool, args, timeout: timeout)
    }

    /// 跑一个系统命令，超时就杀掉；非 0 退出码带上它的错误输出抛出
    nonisolated private static func runDetached(_ tool: String, _ args: [String], timeout: TimeInterval) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = args
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    throw InstallError(String(localized: "\(URL(filePath: tool).lastPathComponent) 超时"))
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw InstallError(String(localized: "\(URL(filePath: tool).lastPathComponent) 失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"))
            }
        }.value
    }
}

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 把下载进度转给主线程
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @MainActor (Double) -> Void
    private var lastReported = -1.0

    init(_ onProgress: @escaping @MainActor (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard p - lastReported >= 0.01 || p >= 1 else { return }   // 每 1% 报一次，别刷爆界面
        lastReported = p
        Task { @MainActor in onProgress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
