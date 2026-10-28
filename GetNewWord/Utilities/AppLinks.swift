// AppLinks.swift
// GetNewWord
//
// 应用里出现的官网、隐私政策、联系邮箱、源码地址，集中在这一处改。

import Foundation

enum AppLinks {
    static let website = URL(string: "https://getnewword.us-cloud.uk")!
    static let privacy = URL(string: "https://getnewword.us-cloud.uk/privacy.html")!
    static let email = "infoschaeferanjon@gmail.com"

    /// 「更新与关于」的 GitHub 和付费页的「看源码」。仓库 1.2.0 发布时公开，在那之前没登录打开是 404
    static let sourceCode: URL? = URL(string: "https://github.com/SchaeferAnjon/GetNewWord")

    /// 发邮件：主题带上版本号，回信时知道是哪一版
    @MainActor static var mailto: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: "GetNewWord \(AppUpdater.currentVersion)")]
        return c.url!
    }
}
