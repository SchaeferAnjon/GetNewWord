// SelfTest.swift
// GetNewWord
//
// 启动冒烟测试：`GetNewWord.app/Contents/MacOS/GetNewWord --selftest <out.json>`。
// 编出来的包能不能启动、Sparkle 框架和资源有没有打进去、三种界面语言的字符串表在不在、词库能不能建，
// 查完写一个 JSON 就退出（全过退出码 0，否则 1）。CI 编完 Release 后跑它（.github/workflows/build.yml）。
// 不开窗口，不读写这台 Mac 上的设置、词库和日志：词库建在临时文件夹里，查完删掉。

import AppKit
import Sparkle
import SwiftData

enum SelfTest {
    /// `--selftest <out.json>` 里的路径；没有这个参数就是 nil
    static func outputPath(in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "--selftest") else { return nil }
        return arguments.indices.contains(i + 1) ? arguments[i + 1] : "selftest.json"
    }

    private struct Check {
        let name: String
        let ok: Bool
        let detail: String
    }

    /// 全部检查都过返回 true
    @MainActor
    static func run(writingTo path: String) -> Bool {
        let checks = [version(), sparkle(), localizations(), resources(), library()]
        let ok = checks.allSatisfy(\.ok)
        let info = Bundle.main.infoDictionary ?? [:]
        let report: [String: Any] = [
            "ok": ok,
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "arch": arch,
            "translated": isTranslated,
            "checks": checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] },
        ]
        for c in checks { print("\(c.ok ? "ok  " : "FAIL") \(c.name): \(c.detail)") }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("FAIL 写不了 \(path)：\(error)")
            return false
        }
        return ok
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// x86_64 那一半在 Apple 芯片上靠 Rosetta 跑时为 true
    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    private static func version() -> Check {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        let ok = !short.isEmpty && Int(build) != nil && feed.hasPrefix("https://") && !key.isEmpty
        return Check(name: "version", ok: ok, detail: "\(short) (\(build)), SUFeedURL \(feed.isEmpty ? "缺" : "有"), SUPublicEDKey \(key.isEmpty ? "缺" : "有")")
    }

    /// Sparkle 是动态链接的：框架没打进包里，进程根本起不来；这里再核对一下版本
    private static func sparkle() -> Check {
        let bundle = Bundle(for: SPUUpdater.self)
        let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let embedded = bundle.bundleURL.resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
        return Check(name: "sparkle", ok: !v.isEmpty && embedded, detail: "Sparkle \(v) \(embedded ? "在包里" : "不在包里：\(bundle.bundleURL.path)")")
    }

    /// 英文、德文的字符串表都在，而且是翻好的（不是中文原文）
    private static func localizations() -> Check {
        var problems: [String] = []
        let have = Set(Bundle.main.localizations)
        let missing = ["zh-Hans", "en", "de"].filter { !have.contains($0) }
        if !missing.isEmpty { problems.append("缺语言 \(missing.joined(separator: ","))") }
        let samples: [(table: String, key: String)] = [
            ("Localizable", "截图取词（自动保存）"),
            ("Categories", "语言学习"),
            ("InfoPlist", "NSScreenCaptureUsageDescription"),
        ]
        for lang in ["en", "de"] {
            guard let path = Bundle.main.path(forResource: lang, ofType: "lproj"), let bundle = Bundle(path: path) else {
                problems.append("没有 \(lang).lproj")
                continue
            }
            for s in samples {
                let value = bundle.localizedString(forKey: s.key, value: "\u{0}", table: s.table)
                if value == "\u{0}" || value == s.key || value.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                    problems.append("\(lang) \(s.table) 没翻「\(s.key)」")
                }
            }
        }
        return Check(name: "localizations", ok: problems.isEmpty, detail: problems.isEmpty ? "zh-Hans、en、de 齐全" : problems.joined(separator: "；"))
    }

    private static func resources() -> Check {
        var problems: [String] = []
        let categories = Bundle.main.url(forResource: "DefaultCategories", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["categories"] as? [Any]
        if categories?.isEmpty ?? true { problems.append("DefaultCategories.json 缺或读不了") }
        if Bundle.main.url(forResource: "NOTICE", withExtension: nil) == nil { problems.append("缺 NOTICE") }
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil { problems.append("缺 AppIcon.icns") }
        let logos = APIProvider.allCases.compactMap(\.logoAsset).filter { NSImage(named: $0) == nil }
        if !logos.isEmpty { problems.append("缺图标 \(logos.joined(separator: ","))") }
        return Check(name: "resources", ok: problems.isEmpty, detail: problems.isEmpty ? "分类、NOTICE、应用图标、\(APIProvider.allCases.count - 1) 个服务商图标都在" : problems.joined(separator: "；"))
    }

    /// 用正式的模型定义在临时文件夹建一个词库，存一个词再读出来
    @MainActor
    private static func library() -> Check {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GetNewWord-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let schema = Schema([WordEntry.self, WordContext.self, KnowledgeSnippet.self, Category.self])
            let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("GetNewWord.store"))
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let category = Category(name: "英语")
            let word = WordEntry(word: "selftest", language: .english, meaning: "n. 自检", contextSentence: "Run the selftest.",
                                 contextTranslation: "跑一下自检。", analysisNote: "", category: category)
            context.insert(category)
            context.insert(word)
            context.insert(WordContext(sentence: word.contextSentence, translation: word.contextTranslation, word: word))
            try context.save()
            let reread = ModelContext(container)
            let words = try reread.fetch(FetchDescriptor<WordEntry>())
            let ok = words.count == 1 && words.first?.contexts?.count == 1 && words.first?.category?.name == "英语"
            return Check(name: "library", ok: ok, detail: ok ? "新建、存、读一个词都正常" : "读回来的不对：\(words.count) 个词")
        } catch {
            return Check(name: "library", ok: false, detail: "\(error)")
        }
    }
}
