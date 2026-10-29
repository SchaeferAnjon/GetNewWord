// ImportExportService.swift
// GetNewWord
//
// 导入/导出服务：支持 CSV 和 JSON 格式的单词与知识片段导入导出

import Foundation
import SwiftData

class ImportExportService: @unchecked Sendable {
    static let shared = ImportExportService()

    private init() {}

    // MARK: - 启动自动备份

    /// 全量备份（词+语境+片段+分类）到 App Support/GetNewWord/backups，保留最近 14 份。
    /// 每次打开主窗口都做：在后台用自己的 ModelContext 读、写文件，不占主线程（2000 个词时主线程要卡 0.3 秒）
    @MainActor
    func autoBackup(context: ModelContext) {
        let container = context.container
        Task.detached(priority: .utility) {
            Self.writeBackup(context: ModelContext(container))
        }
    }

    private static func writeBackup(context: ModelContext) {
        do {
            let words = try context.fetch(FetchDescriptor<WordEntry>())
            let snippets = try context.fetch(FetchDescriptor<KnowledgeSnippet>())
            let categories = try context.fetch(FetchDescriptor<Category>())
            guard words.count + snippets.count > 0 else { return }
            let payload: [String: Any] = [
                "version": 2, "exportDate": Date().ISO8601Format(),
                "categories": categories.map { ["name": $0.name, "parent": $0.parent?.name ?? ""] },
                "words": words.map { w -> [String: Any] in [
                    "word": w.word, "phonetic": w.phonetic ?? "", "language": w.language.rawValue,
                    "meaning": w.meaning, "contextMeaning": w.contextMeaning ?? "",
                    "grammar": w.grammar ?? "", "analysisNote": w.analysisNote,
                    "collocations": w.collocationsText ?? "", "examples": w.examplesText ?? "",
                    "etymology": w.etymology ?? "", "difficulty": w.difficulty.rawValue,
                    "category": w.category?.name ?? "", "ankiNoteId": w.ankiNoteId ?? 0,
                    "createdAt": w.createdAt.ISO8601Format(),
                    "contexts": w.sortedContexts.map { ["sentence": $0.sentence, "translation": $0.translation, "createdAt": $0.createdAt.ISO8601Format()] }
                ] },
                "snippets": snippets.map { s -> [String: Any] in [
                    "title": s.title, "content": s.content, "sourceContext": s.sourceContext,
                    "domain": s.domain, "category": s.category?.name ?? "",
                    "ankiNoteId": s.ankiNoteId ?? 0, "createdAt": s.createdAt.ISO8601Format()
                ] }
            ]
            let dir = AppVariant.supportDirectory.appendingPathComponent("backups")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
            let url = dir.appendingPathComponent("backup_\(df.string(from: Date())).json")
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: url)
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("backup_") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for f in files.dropFirst(14) { try? FileManager.default.removeItem(at: f) }
            AppLog.log("[Backup] \(words.count) words / \(snippets.count) snippets → \(url.lastPathComponent)")
        } catch {
            AppLog.log("[Backup] failed: \(error)")
        }
    }

    // MARK: - Export

    /// 导出所有单词为 CSV
    func exportWordsToCSV(words: [WordEntry]) throws -> URL {
        let directory = getExportDirectory()

        var csv = "word,phonetic,language,meaning,contextSentence,contextTranslation,analysisNote,difficulty,tags,createdAt\n"

        for word in words {
            let row = [
                csvEscape(word.word),
                csvEscape(word.phonetic ?? ""),
                csvEscape(word.language.rawValue),
                csvEscape(word.meaning),
                csvEscape(word.contextSentence),
                csvEscape(word.contextTranslation),
                csvEscape(word.analysisNote),
                csvEscape(word.difficulty.rawValue),
                csvEscape(word.tags.joined(separator: ";")),
                csvEscape(word.createdAt.ISO8601Format())
            ].joined(separator: ",")
            csv += row + "\n"
        }

        let filename = generateFilename(prefix: "words", extension: "csv")
        let fileURL = directory.appendingPathComponent(filename)
        try csv.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// 导出所有单词为 JSON
    func exportWordsToJSON(words: [WordEntry]) throws -> URL {
        let directory = getExportDirectory()

        let wordDicts: [[String: Any]] = words.map { word in
            [
                "word": word.word,
                "phonetic": word.phonetic ?? "",
                "language": word.language.rawValue,
                "meaning": word.meaning,
                "contextSentence": word.contextSentence,
                "contextTranslation": word.contextTranslation,
                "analysisNote": word.analysisNote,
                "difficulty": word.difficulty.rawValue,
                "tags": word.tags,
                "createdAt": word.createdAt.ISO8601Format()
            ]
        }

        let payload: [String: Any] = [
            "version": 1,
            "exportDate": Date().ISO8601Format(),
            "words": wordDicts
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let filename = generateFilename(prefix: "words", extension: "json")
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    /// 导出所有知识片段为 JSON
    func exportSnippetsToJSON(snippets: [KnowledgeSnippet]) throws -> URL {
        let directory = getExportDirectory()

        let snippetDicts: [[String: Any]] = snippets.map { snippet in
            [
                "title": snippet.title,
                "content": snippet.content,
                "sourceContext": snippet.sourceContext,
                "tags": snippet.tags,
                "domain": snippet.domain,
                "createdAt": snippet.createdAt.ISO8601Format()
            ]
        }

        let payload: [String: Any] = [
            "version": 1,
            "exportDate": Date().ISO8601Format(),
            "snippets": snippetDicts
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let filename = generateFilename(prefix: "snippets", extension: "json")
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    // MARK: - Import

    /// 从 CSV 导入单词，返回导入数量
    func importWordsFromCSV(url: URL, context: ModelContext) throws -> Int {
        let content = try String(contentsOf: url, encoding: .utf8)
        // 引号里的换行属于字段（释义、用法常有多行），不能先按行切
        let rows = parseCSV(content).filter { $0 != [""] }

        guard rows.count > 1 else { return 0 }

        // 跳过表头
        var imported = 0
        for fields in rows.dropFirst() {
            guard fields.count >= 9 else { continue }

            let word = fields[0]
            let phonetic = fields[1].isEmpty ? nil : fields[1]
            let language = Language(rawValue: fields[2]) ?? .other
            let meaning = fields[3]
            let contextSentence = fields[4]
            let contextTranslation = fields[5]
            let analysisNote = fields[6]
            let difficulty = Difficulty(rawValue: fields[7]) ?? .a1
            let tags = fields[8].isEmpty ? [] : fields[8].components(separatedBy: ";")
            let createdAt: Date
            if fields.count > 9, !fields[9].isEmpty {
                createdAt = ISO8601DateFormatter().date(from: fields[9]) ?? Date()
            } else {
                createdAt = Date()
            }

            let entry = WordEntry(
                word: word,
                phonetic: phonetic,
                language: language,
                meaning: meaning,
                contextSentence: contextSentence,
                contextTranslation: contextTranslation,
                analysisNote: analysisNote,
                difficulty: difficulty,
                tags: tags,
                createdAt: createdAt
            )
            context.insert(entry)
            imported += 1
        }

        try context.save()
        return imported
    }

    /// 从 JSON 导入单词，返回导入数量
    func importWordsFromJSON(url: URL, context: ModelContext) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = json["words"] as? [[String: Any]] else {
            throw ImportError.invalidFormat
        }

        var imported = 0
        for dict in words {
            guard let word = dict["word"] as? String,
                  let meaning = dict["meaning"] as? String else { continue }

            let phonetic = dict["phonetic"] as? String
            let languageRaw = dict["language"] as? String ?? "other"
            let language = Language(rawValue: languageRaw) ?? .other
            let contextSentence = dict["contextSentence"] as? String ?? ""
            let contextTranslation = dict["contextTranslation"] as? String ?? ""
            let analysisNote = dict["analysisNote"] as? String ?? ""
            let difficultyRaw = dict["difficulty"] as? String ?? "a1"
            let difficulty = Difficulty(rawValue: difficultyRaw) ?? .a1
            let tags = dict["tags"] as? [String] ?? []

            let createdAt: Date
            if let dateStr = dict["createdAt"] as? String {
                createdAt = ISO8601DateFormatter().date(from: dateStr) ?? Date()
            } else {
                createdAt = Date()
            }

            let entry = WordEntry(
                word: word,
                phonetic: phonetic,
                language: language,
                meaning: meaning,
                contextSentence: contextSentence,
                contextTranslation: contextTranslation,
                analysisNote: analysisNote,
                difficulty: difficulty,
                tags: tags,
                createdAt: createdAt
            )
            context.insert(entry)
            imported += 1
        }

        try context.save()
        return imported
    }

    /// 从 JSON 导入知识片段，返回导入数量
    func importSnippetsFromJSON(url: URL, context: ModelContext) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snippets = json["snippets"] as? [[String: Any]] else {
            throw ImportError.invalidFormat
        }

        var imported = 0
        for dict in snippets {
            guard let title = dict["title"] as? String,
                  let content = dict["content"] as? String else { continue }

            let sourceContext = dict["sourceContext"] as? String ?? ""
            let domain = dict["domain"] as? String ?? "其他"
            let tags = dict["tags"] as? [String] ?? []

            let createdAt: Date
            if let dateStr = dict["createdAt"] as? String {
                createdAt = ISO8601DateFormatter().date(from: dateStr) ?? Date()
            } else {
                createdAt = Date()
            }

            let snippet = KnowledgeSnippet(
                title: title,
                content: content,
                sourceContext: sourceContext,
                tags: tags,
                domain: domain,
                createdAt: createdAt
            )
            context.insert(snippet)
            imported += 1
        }

        try context.save()
        return imported
    }

    // MARK: - Helpers

    /// 获取导出目录
    private func getExportDirectory() -> URL {
        let dir = AppVariant.supportDirectory.appendingPathComponent("exports")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 生成唯一文件名
    private func generateFilename(prefix: String, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "\(prefix)_\(timestamp).\(ext)"
    }

    /// CSV 字段转义
    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// 解析整份 CSV（RFC 4180）：引号里可以有逗号、换行，引号本身写成 ""；行尾 \n、\r\n 都认
    private func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = content.makeIterator()
        var pending = chars.next()
        while let char = pending {
            pending = chars.next()
            if inQuotes {
                if char == "\"" {
                    if pending == "\"" { field.append("\""); pending = chars.next() } else { inQuotes = false }
                } else {
                    field.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                row.append(field)
                field = ""
            } else if char.isNewline {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Import Error

enum ImportError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "文件格式无效，无法解析导入数据")
        }
    }
}
