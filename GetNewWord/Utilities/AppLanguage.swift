// AppLanguage.swift
// GetNewWord
//
// 软件界面语言：写进本应用自己的 AppleLanguages，重开后生效（macOS 只在启动时读它）。

import AppKit

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", en, de

    var id: String { rawValue }

    /// 用它自己的语言写，换错了也认得回来
    var nativeName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }

    static var current: AppLanguage {
        let own = UserDefaults.standard.persistentDomain(forName: AppVariant.bundleID)?["AppleLanguages"] as? [String]
        return own?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// 1.2 以前界面只有中文：已经用过的人升级后保持中文（不然跟随系统会突然变成英文），以后在设置里随时能改。
    /// 要赶在第一次读本地化字符串之前，所以在程序入口 Launcher.main 里调。
    static func keepChineseForExistingUsers() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "uiLanguageMigrated") else { return }
        d.set(true, forKey: "uiLanguageMigrated")
        if d.bool(forKey: "hasCompletedOnboarding") && current == .system {
            d.set([AppLanguage.zhHans.rawValue], forKey: "AppleLanguages")
        }
    }

    /// 存下并重开应用
    func applyAndRelaunch() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        // 先等本进程退出再开新的，不然两个实例抢同一个全局快捷键
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          Bundle.main.bundleURL.path]
        do {
            try task.run()
        } catch {
            AppLog.log("[Language] relaunch failed: \(error)")   // 语言已存下，下次手动打开时生效
            return
        }
        NSApp.terminate(nil)
    }
}
