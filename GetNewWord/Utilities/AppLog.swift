// AppLog.swift
// GetNewWord
//
// 极简文件日志：同时写 NSLog 与 ~/Library/Application Support/GetNewWord/app.log
// 用于排查"分析失败"这类只有用户端能复现的问题（tail -f 该文件即可）。
// 超过 1 MB 就把它改名成 app.1.log（覆盖上一份）再写新的，最多占 2 MB；用户反馈时附上这两个文件。
// 不记 Key、登录邮箱这类个人信息。

import Foundation

enum AppLog {
    nonisolated(unsafe) private static let queue = DispatchQueue(label: "com.getnewword.applog")
    private static let maxBytes: UInt64 = 1_000_000

    static var logFileURL: URL {
        AppVariant.supportDirectory.appendingPathComponent("app.log")
    }

    static var previousLogFileURL: URL {
        AppVariant.supportDirectory.appendingPathComponent("app.1.log")
    }

    static func log(_ message: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]   // 毫秒：排查查词各步耗时
        let line = "\(f.string(from: Date())) \(message)"
        NSLog("%@", message)
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            let url = logFileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                let size = (try? handle.seekToEnd()) ?? 0
                if size < maxBytes {
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                    return
                }
                try? handle.close()
                rotate()
            }
            try? data.write(to: url)
        }
    }

    /// app.log → app.1.log（旧的 app.1.log 删掉）
    private static func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: previousLogFileURL)
        try? fm.moveItem(at: logFileURL, to: previousLogFileURL)
    }
}
