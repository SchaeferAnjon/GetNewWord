// AppUpdater.swift
// GetNewWord
//
// 自动更新（Sparkle）：每天自动查 GitHub Release 里的 appcast.xml，有新版弹窗，一键下载、替换、重开。
// 开发版不查（feed 是正式版的，装上会把开发版换成正式版）。

import Foundation
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    var isAvailable: Bool { !AppVariant.isDev }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: !AppVariant.isDev,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    /// 后台下载好，退出时安装（不弹窗）
    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
