// AnkiLiveTests.swift
// GetNewWord
//
// 连本机真开着的 Anki 跑一遍统一规范（DESIGN.md「往 Anki 里加卡」）：送一个词、一个新片段，搬一个老片段，再从 Anki 恢复。
// 平时跳过；要跑：TEST_RUNNER_GNW_LIVE_ANKI=1 xcodebuild test …（会在 Anki 里留下「GetNewWord Dev」开头的测试卡，跑完自己删）

import Foundation
import SwiftData
import Testing
@testable import GetNewWord

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GNW_LIVE_ANKI"] == "1"))
final class AnkiLiveTests {
    let anki = AnkiService.shared

    init() {
        anki.session = URLSession.shared
        anki.fieldCache.reset()
        anki.cardsChecked = false
        UserDefaults.standard.removeObject(forKey: AnkiService.unifyMigratedKey)
    }

    @Test func sendMigrateAndRestoreAgainstRealAnki() async throws {
        let stamp = String(Int(Date().timeIntervalSince1970))
        let context = try makeLibrary()
        let languages = Category(name: "语言学习")
        let english = Category(name: "英语", parent: languages)
        let business = Category(name: "商务", parent: english)
        let knowledge = Category(name: "知识片段")
        let traffic = Category(name: "交通规则", parent: knowledge)
        let fitness = Category(name: "健身", parent: knowledge)
        [languages, english, business, knowledge, traffic, fitness].forEach(context.insert)

        let word = WordEntry(word: "liveunify\(stamp)", phonetic: "/x/", language: .english, meaning: "n. 测试词",
                             contextMeaning: "测试词", contextSentence: "This liveunify\(stamp) is a test.", contextTranslation: "这是一个测试词。",
                             analysisNote: "", grammar: "", collocationsText: "", examplesText: "", etymology: "", difficulty: .b1, category: business)
        context.insert(word)

        // 老片段：升级前就在 Anki 里，在老笔记类型 GetNewWord Snippet、老牌组「知识片段::交通规则」
        try await anki.ensureSnippetModelExists()
        let old = KnowledgeSnippet(title: "老片段\(stamp)", content: "进环岛不打灯\n出环岛打右灯", sourceContext: "Beim Einfahren nicht blinken.",
                                   domain: "交通", syncStatus: .synced, category: traffic)
        context.insert(old)
        try await anki.ensureDeckExists(name: "知识片段::交通规则")
        old.ankiNoteId = try await anki.addNote(deckName: "知识片段::交通规则", modelName: anki.snippetModelName,
                                                fields: anki.snippetTextFields(old), tags: ["GetNewWord", "snippet"])

        // 新片段：升级后存的，还没进 Anki
        let fresh = KnowledgeSnippet(title: "新片段\(stamp)", content: "深蹲时膝盖和脚尖同向", sourceContext: "教练说的", domain: "健身",
                                     question: "深蹲时膝盖朝哪？\(stamp)", category: fitness)
        context.insert(fresh)
        try context.save()

        await anki.syncEverythingPending(context: context)

        // 单词：语言学习::英语，子分类写成标签
        let wordNote = try #require(word.ankiNoteId)
        let wordInfo = try #require(try await anki.notesInfo(notes: [wordNote]).first)
        #expect(wordInfo.tags.contains("来自::GetNewWord") && wordInfo.tags.contains("分类::商务"))
        let wordCards: [[String: AnyCodable]] = try await anki.send(action: "cardsInfo", params: ["cards": wordInfo.cards], as: [[String: AnyCodable]].self)
        #expect(wordCards.first?["deckName"]?.string == "语言学习::英语")

        // 新片段：学习卡 · 问答，进「知识」
        let freshNote = try #require(fresh.ankiNoteId)
        let freshInfo = try #require(try await anki.notesInfo(notes: [freshNote]).first)
        #expect(freshInfo.modelName == StudyCard.name)
        // 纸顶小字跟界面语言：内置分类「健身」在英文界面是 Fitness
        #expect(freshInfo.fields["Label"]?.value == "GetNewWord · " + Category.displayName("健身"))
        #expect(freshInfo.tags.contains("主题::健身"))
        let freshCards: [[String: AnyCodable]] = try await anki.send(action: "cardsInfo", params: ["cards": freshInfo.cards], as: [[String: AnyCodable]].self)
        #expect(freshCards.first?["deckName"]?.string == "知识")

        // 老片段：留在老笔记类型，搬进「知识」，补主题标签；空了的老牌组删掉
        let oldNote = try #require(old.ankiNoteId)
        let oldInfo = try #require(try await anki.notesInfo(notes: [oldNote]).first)
        #expect(oldInfo.modelName == anki.snippetModelName)
        #expect(oldInfo.tags.contains("主题::交通规则") && oldInfo.tags.contains("来自::GetNewWord"))
        let oldCards: [[String: AnyCodable]] = try await anki.send(action: "cardsInfo", params: ["cards": oldInfo.cards], as: [[String: AnyCodable]].self)
        #expect(oldCards.first?["deckName"]?.string == "知识")
        let decks = try await anki.deckNames()
        #expect(!decks.contains("知识片段::交通规则"))
        #expect(UserDefaults.standard.bool(forKey: AnkiService.unifyMigratedKey))

        // 单词卡的样式到了 v3（纸）
        let styling: [String: String] = try await anki.send(action: "modelStyling", params: ["modelName": anki.modelName], as: [String: String].self)
        #expect(AnkiCardTemplates.version(ofCSS: styling["css"] ?? "") == AnkiCardTemplates.version)

        // 从 Anki 恢复到一个空词库：分类按标签认回来
        let restored = try makeLibrary()
        let r1 = Category(name: "语言学习"), r2 = Category(name: "知识片段")
        restored.insert(r1); restored.insert(r2)
        try restored.save()
        _ = await anki.restoreFromAnki(context: restored)
        let words = try restored.fetch(FetchDescriptor<WordEntry>()).filter { $0.word == word.word }
        #expect(words.first?.category?.name == "商务")
        let snippets = try restored.fetch(FetchDescriptor<KnowledgeSnippet>())
        #expect(snippets.first { $0.title == fresh.title }?.category?.name == "健身")
        #expect(snippets.first { $0.title == fresh.title }?.content == "深蹲时膝盖和脚尖同向")
        #expect(snippets.first { $0.title == old.title }?.category?.name == "交通规则")

        print("LIVE notes word=\(wordNote) fresh=\(freshNote) old=\(old.ankiNoteId ?? 0)")
    }
}

/// cardsInfo 回的值五花八门：只取字符串
struct AnyCodable: Codable {
    let string: String?
    init(from decoder: Decoder) throws {
        string = try? decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {}
}
