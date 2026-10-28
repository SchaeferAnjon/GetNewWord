// 字符串表各语言齐全：三个 xcstrings 里每条都有英文、德文，占位符对得上；
// 代码里用到的每条文字都在表里（拿编译时抽出来的 .stringsdata 对照，漏了的英德界面会冒出中文）

import Foundation
import Testing
@testable import GetNewWord

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let resources = repoRoot.appendingPathComponent("GetNewWord/Resources")
private let languages = ["en", "de"]

private struct Catalog {
    let name: String
    let strings: [String: [String: Any]]

    init(_ name: String) throws {
        self.name = name
        let data = try Data(contentsOf: resources.appendingPathComponent("\(name).xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "zh-Hans")
        strings = try #require(json["strings"] as? [String: [String: Any]])
    }

    func needsTranslation(_ key: String) -> Bool {
        !key.isEmpty && strings[key]?["shouldTranslate"] as? Bool != false
    }

    /// 某语言的译文；没翻、没翻完返回 nil
    func translation(_ key: String, _ lang: String) -> String? {
        let unit = ((strings[key]?["localizations"] as? [String: Any])?[lang] as? [String: Any])?["stringUnit"] as? [String: Any]
        guard unit?["state"] as? String == "translated", let value = unit?["value"] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

/// 占位符（%@、%lld、%1$@ …）去掉位置号后排序，用来比原文和译文
private func placeholders(_ s: String) -> [String] {
    s.replacingOccurrences(of: "%%", with: "")
        .matches(of: /%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|q)?[@dDiuUxXoOfeEgGcCsSpaA]/)
        .map { String($0.output).replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }
        .sorted()
}

struct LocalizationTests {
    @Test(arguments: ["Localizable", "InfoPlist", "Categories"])
    func everyEntryTranslated(_ name: String) throws {
        let catalog = try Catalog(name)
        var missing: [String] = []
        for key in catalog.strings.keys.sorted() where catalog.needsTranslation(key) {
            for lang in languages {
                guard let value = catalog.translation(key, lang) else {
                    missing.append("\(lang)「\(key)」")
                    continue
                }
                #expect(placeholders(value) == placeholders(key), "\(name) \(lang) 占位符对不上：「\(key)」→「\(value)」")
            }
        }
        #expect(missing.isEmpty, "\(name).xcstrings 缺 \(missing.count) 条译文：\(missing.prefix(20).joined(separator: "，"))")
    }

    /// 编译时 Xcode 把代码里的 String(localized:)、Text("…") 抽进 .stringsdata；每一条都要在表里、有英德译文
    @Test func everyStringInCodeIsInCatalog() throws {
        // 测试注入在 build/…/Build/Products/Debug/GetNewWord Dev.app 里跑；抽出来的文字在旁边的 Intermediates.noindex
        let build = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let objects = build.appendingPathComponent("Intermediates.noindex/GetNewWord.build/Debug/GetNewWord.build/Objects-normal/\(arch)")
        let files = try FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "stringsdata" }
        #expect(files.count > 20, "在 \(objects.path) 只找到 \(files.count) 个 .stringsdata")

        let catalogs = try Dictionary(uniqueKeysWithValues: ["Localizable", "InfoPlist", "Categories"].map { ($0, try Catalog($0)) })
        var missing: [String] = []
        var used = 0
        for file in files {
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let source = URL(fileURLWithPath: json["source"] as? String ?? "?").lastPathComponent
            for (table, entries) in json["tables"] as? [String: [[String: Any]]] ?? [:] {
                for entry in entries {
                    guard let key = entry["key"] as? String, !key.isEmpty else { continue }
                    used += 1
                    let line = (entry["location"] as? [String: Any])?["startingLine"] as? Int ?? 0
                    guard let catalog = catalogs[table] else {
                        missing.append("\(source):\(line) 用了没有的表 \(table)")
                        continue
                    }
                    guard catalog.strings[key] != nil else {
                        missing.append("\(source):\(line)「\(key)」不在 \(table).xcstrings")
                        continue
                    }
                    for lang in languages where catalog.needsTranslation(key) && catalog.translation(key, lang) == nil {
                        missing.append("\(source):\(line)「\(key)」没有 \(lang)")
                    }
                }
            }
        }
        #expect(used > 500)
        #expect(missing.isEmpty, "\(missing.count) 条：\(missing.prefix(20).joined(separator: "；"))")
    }

    /// Info.plist 里要给人看的权限说明都有译文；表里也别留已经删掉的键
    @Test func infoPlistStrings() throws {
        let catalog = try Catalog("InfoPlist")
        let info = try #require(Bundle.main.infoDictionary)
        let usage = info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
        #expect(usage.contains("NSScreenCaptureUsageDescription"))
        for key in usage {
            #expect(catalog.strings[key] != nil, "\(key) 不在 InfoPlist.xcstrings")
        }
        for key in catalog.strings.keys {
            #expect(info[key] != nil, "InfoPlist.xcstrings 里的 \(key) 在 Info.plist 里已经没有了")
        }
    }

    /// 内置分类（DefaultCategories.json）按界面语言显示，每个名字都要在 Categories.xcstrings 里
    @Test func builtInCategoriesTranslated() throws {
        let catalog = try Catalog("Categories")
        let data = try Data(contentsOf: resources.appendingPathComponent("DefaultCategories.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func names(_ list: [[String: Any]]) -> [String] {
            list.flatMap { [$0["name"] as? String ?? ""] + names($0["children"] as? [[String: Any]] ?? []) }
        }
        let all = names(json["categories"] as? [[String: Any]] ?? [])
        #expect(all.count > 3)
        for name in all {
            #expect(catalog.strings[name] != nil, "内置分类「\(name)」不在 Categories.xcstrings")
        }
    }

    /// 编出来的应用里，英德字符串表真的能查到译文
    @Test(arguments: languages)
    func compiledTables(_ lang: String) throws {
        let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "截图取词（自动保存）", value: nil, table: nil) != "截图取词（自动保存）")
        #expect(bundle.localizedString(forKey: "语言学习", value: nil, table: "Categories") != "语言学习")
    }
}
