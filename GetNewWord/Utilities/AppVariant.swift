// AppVariant.swift
// GetNewWord
//
// 正式版 / 开发版：Debug 构建的 bundle id 以 .dev 结尾（GetNewWord Dev）。
// 两者的设置（UserDefaults 按 bundle id 分开）、数据目录、钥匙串、Anki 牌组和模板都分开，
// 开发版可以从欢迎页从头走一遍，不碰正式版的词库。

import Foundation

enum AppVariant {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.getnewword.app"
    static let isDev = bundleID.hasSuffix(".dev")

    /// 跑单元测试时，测试包被注入开发版里运行（make test）
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// ~/Library/Application Support/GetNewWord（开发版：GetNewWord Dev）。
    /// 单元测试用一个临时文件夹：日志、导出、截图都不写进开发版自己的数据
    static let supportDirectory: URL = {
        let dir = isUnitTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("GetNewWordTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 正式版 GetNewWord；开发版 GetNewWord Dev；另外的开发副本（如 com.getnewword.app.main.dev，多个 Agent 并行测）各用各的
    private static var folderName: String {
        guard isDev else { return "GetNewWord" }
        return bundleID == "com.getnewword.app.dev" ? "GetNewWord Dev" : "GetNewWord Dev (\(bundleID))"
    }

    /// Anki 里的根牌组和卡片模板名都带这个前缀
    static let ankiName = isDev ? "GetNewWord Dev" : "GetNewWord"
}
