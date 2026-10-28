// 导出再导入（ImportExportService）：CSV、JSON 的单词和 JSON 的知识片段，内容带逗号、引号、换行也原样回来

import Foundation
import SwiftData
import Testing
@testable import GetNewWord

/// 导出的文件名只精确到秒：一个一个跑，免得两个测试写同一个文件
@MainActor
@Suite(.serialized)
struct ImportExportTests {
    let service = ImportExportService.shared
    /// ISO8601 只到秒：拿整秒的时间比
    let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func sampleWords(in context: ModelContext) throws -> [WordEntry] {
        let words = [
            WordEntry(word: "confluence", phonetic: "/ˈkɒnfluəns/", language: .english, meaning: "n. 汇合处；汇流",
                      contextSentence: "The town sits at the confluence of two rivers, \"they say\".",
                      contextTranslation: "据说，小镇坐落在两条河的交汇处。", analysisNote: "第一行\n第二行，带逗号",
                      difficulty: .c1, tags: ["地理", "河流"], createdAt: created),
            WordEntry(word: "Vorfahrt", language: .german, meaning: "n. 优先通行权", contextSentence: "Achtung: \"Vorfahrt\"",
                      contextTranslation: "注意：优先通行", analysisNote: "", difficulty: .b1, createdAt: created.addingTimeInterval(60)),
            WordEntry(word: "rendez-vous 🥐", language: .french, meaning: "n. 约会, 会面", contextSentence: "",
                      contextTranslation: "", analysisNote: "\"引号\"开头", difficulty: .a2, tags: [], createdAt: created.addingTimeInterval(120)),
        ]
        words.forEach(context.insert)
        try context.save()
        return words
    }

    private func expectSame(_ exported: [WordEntry], _ imported: [WordEntry]) {
        #expect(imported.count == exported.count)
        let byWord = Dictionary(uniqueKeysWithValues: imported.map { ($0.word, $0) })
        for e in exported {
            guard let i = byWord[e.word] else {
                Issue.record("没导回来：\(e.word)")
                continue
            }
            #expect(i.phonetic ?? "" == e.phonetic ?? "", "\(e.word)")
            #expect(i.language == e.language, "\(e.word)")
            #expect(i.meaning == e.meaning, "\(e.word)")
            #expect(i.contextSentence == e.contextSentence, "\(e.word)")
            #expect(i.contextTranslation == e.contextTranslation, "\(e.word)")
            #expect(i.analysisNote == e.analysisNote, "\(e.word)")
            #expect(i.difficulty == e.difficulty, "\(e.word)")
            #expect(i.tags == e.tags, "\(e.word)")
            #expect(i.createdAt == e.createdAt, "\(e.word)")
        }
    }

    @Test func wordsJSONRoundTrip() throws {
        let source = try makeLibrary()
        let words = try sampleWords(in: source)
        let url = try service.exportWordsToJSON(words: words)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeLibrary()
        #expect(try service.importWordsFromJSON(url: url, context: target) == 3)
        expectSame(words, try target.fetch(FetchDescriptor<WordEntry>()))
    }

    @Test func wordsCSVRoundTrip() throws {
        let source = try makeLibrary()
        let words = try sampleWords(in: source)
        let url = try service.exportWordsToCSV(words: words)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeLibrary()
        #expect(try service.importWordsFromCSV(url: url, context: target) == 3)
        expectSame(words, try target.fetch(FetchDescriptor<WordEntry>()))
    }

    /// Excel 存的 CSV 是 \r\n 换行
    @Test func csvWithWindowsLineEndings() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("words.csv")
        let csv = "word,phonetic,language,meaning,contextSentence,contextTranslation,analysisNote,difficulty,tags,createdAt\r\n"
            + "run,,en,v. 跑,Run!,跑！,,a1,,2026-09-14T10:00:00Z\r\n"
            + "\"walk, slowly\",,en,\"v. 走\r\n慢慢走\",,,,a2,a;b,\r\n"
        try csv.write(to: url, atomically: true, encoding: .utf8)
        let target = try makeLibrary()
        #expect(try service.importWordsFromCSV(url: url, context: target) == 2)
        let words = try target.fetch(FetchDescriptor<WordEntry>(sortBy: [SortDescriptor(\.word)]))
        #expect(words.map(\.word) == ["run", "walk, slowly"])
        #expect(words.last?.meaning == "v. 走\r\n慢慢走")
        #expect(words.last?.tags == ["a", "b"])
        #expect(words.first?.createdAt == CloudDate.parse("2026-09-14T10:00:00Z"))
    }

    @Test func snippetsJSONRoundTrip() throws {
        let source = try makeLibrary()
        let snippet = KnowledgeSnippet(title: "右侧优先", content: "没有标志的路口，\n右边来的车先走。", sourceContext: "rechts vor links",
                                       tags: ["驾考"], domain: "驾驶", createdAt: created)
        source.insert(snippet)
        try source.save()
        let url = try service.exportSnippetsToJSON(snippets: [snippet])
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeLibrary()
        #expect(try service.importSnippetsFromJSON(url: url, context: target) == 1)
        let s = try #require(try target.fetch(FetchDescriptor<KnowledgeSnippet>()).first)
        #expect(s.title == snippet.title)
        #expect(s.content == snippet.content)
        #expect(s.sourceContext == snippet.sourceContext)
        #expect(s.tags == snippet.tags)
        #expect(s.domain == snippet.domain)
        #expect(s.createdAt == snippet.createdAt)
    }

    @Test func notAnExport() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("other.json")
        try Data(#"{"items":[]}"#.utf8).write(to: url)
        let target = try makeLibrary()
        #expect(throws: ImportError.self) { try service.importWordsFromJSON(url: url, context: target) }
        #expect(throws: ImportError.self) { try service.importSnippetsFromJSON(url: url, context: target) }
    }

    /// 导出写进数据目录下的 exports；跑测试时那是临时文件夹
    @Test func exportsGoToDataFolder() throws {
        let url = try service.exportWordsToJSON(words: [])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.deletingLastPathComponent().lastPathComponent == "exports")
        #expect(url.path.hasPrefix(AppVariant.supportDirectory.path))
    }
}
