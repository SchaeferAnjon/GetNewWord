// 词库：同词只留一条、语境追加，几乎一样的句子不重复存；启动时合并重复词条；OCR 文字秒查词库的候选词形

import Foundation
import SwiftData
import Testing
@testable import GetNewWord

private func analysis(_ word: String, language: String = "en", sentence: String, translation: String = "译文",
                      grammar: String? = nil, phonetic: String? = nil) -> WordAnalysis {
    WordAnalysis(word: word, phonetic: phonetic, language: language, meaning: "n. 新释义", contextMeaning: nil,
                 contextSentence: sentence, contextTranslation: translation, translationKeyword: nil, analysisNote: "用法",
                 grammar: grammar, examples: ["Example —— 例句"], mnemonic: nil, etymology: nil, difficulty: "b2",
                 tags: ["新"], category: nil, suggestedCategory: nil)
}

@MainActor
struct LibraryTests {
    let service = AnalysisService.shared

    /// 库里已有的词（不走 saveWord 新建那条路：新建会去下发音）
    private func existing(_ context: ModelContext, word: String = "confluence", language: Language = .english,
                          sentence: String = "The town sits at the confluence of two rivers.") throws -> WordEntry {
        let entry = WordEntry(word: word, language: language, meaning: "n. 汇合处", contextSentence: sentence,
                              contextTranslation: "小镇坐落在两条河的交汇处。", analysisNote: "旧用法", tags: ["旧"],
                              syncStatus: .synced)
        context.insert(entry)
        context.insert(WordContext(sentence: sentence, translation: entry.contextTranslation, word: entry))
        try context.save()
        return entry
    }

    @Test func sameWordAddsContext() throws {
        let context = try makeLibrary()
        let entry = try existing(context)
        let saved = try service.saveWord(analysis("Confluence ", sentence: "A confluence of factors led to the crash.",
                                                  phonetic: "/ˈkɒnfluəns/"),
                                         screenshotPath: nil, category: nil, context: context)
        #expect(saved.id == entry.id)
        #expect(try context.fetchCount(FetchDescriptor<WordEntry>()) == 1)
        #expect(entry.sortedContexts.map(\.sentence) == ["The town sits at the confluence of two rivers.",
                                                         "A confluence of factors led to the crash."])
        #expect(entry.meaning == "n. 汇合处")          // 释义保留原有的
        #expect(entry.phonetic == "/ˈkɒnfluəns/")      // 缺的补上
        #expect(entry.tags == ["旧", "新"])
        #expect(entry.lookupCount == 2)
        #expect(entry.syncStatus == .notSynced)         // 有新语境，要重新同步到 Anki
    }

    /// 同一页截两次：只差大小写、标点的句子不再存一遍，只记一次查询
    @Test func similarSentenceSkipped() throws {
        let context = try makeLibrary()
        let entry = try existing(context)
        try service.saveWord(analysis("confluence", sentence: "the town sits at the confluence of two rivers", grammar: "n."),
                             screenshotPath: nil, category: nil, context: context)
        #expect(entry.sortedContexts.count == 1)
        #expect(entry.lookupCount == 2)
        #expect(entry.grammar == "n.")
    }

    /// 同一个词形、不同语言是两个词
    @Test func differentLanguageIsAnotherWord() throws {
        let context = try makeLibrary()
        let english = try existing(context, word: "die", language: .english, sentence: "Never say die.")
        #expect(english.dedupeKey == "die|en")
        let german = try existing(context, word: "die", language: .german, sentence: "Die Straße ist frei.")
        #expect(german.dedupeKey == "die|de")
        #expect(try context.fetchCount(FetchDescriptor<WordEntry>()) == 2)
    }

    @Test func mergeDuplicates() throws {
        let context = try makeLibrary()
        let first = try existing(context, sentence: "First sentence here.")
        first.createdAt = Date(timeIntervalSince1970: 1_000)
        // 两台设备各自新建的同词条目：一条带 contexts，一条只有老字段
        let second = WordEntry(word: "CONFLUENCE", language: .english, meaning: "n. 汇合", contextSentence: "Second sentence.",
                               contextTranslation: "第二句。", analysisNote: "", createdAt: Date(timeIntervalSince1970: 2_000))
        second.phonetic = "/ˈkɒnfluəns/"
        let third = WordEntry(word: "confluence", language: .english, meaning: "n. 汇合", contextSentence: "",
                              contextTranslation: "", analysisNote: "", createdAt: Date(timeIntervalSince1970: 3_000))
        context.insert(second)
        context.insert(third)
        context.insert(WordContext(sentence: "First sentence here.", translation: "重复的", word: third))
        context.insert(WordContext(sentence: "Third sentence.", translation: "第三句。", word: third))
        try context.save()

        service.mergeDuplicateWords(context: context)

        let words = try context.fetch(FetchDescriptor<WordEntry>())
        #expect(words.count == 1)
        let keeper = try #require(words.first)
        #expect(keeper.id == first.id)                  // 留最早的
        #expect(keeper.phonetic == "/ˈkɒnfluəns/")
        #expect(Set(keeper.sortedContexts.map(\.sentence)) == ["First sentence here.", "Second sentence.", "Third sentence."])
        #expect(try context.fetchCount(FetchDescriptor<WordContext>()) == 3)

        service.mergeDuplicateWords(context: context)  // 幂等
        #expect(try context.fetchCount(FetchDescriptor<WordEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<WordContext>()) == 3)
    }

    @Test func similarSentences() {
        #expect(AnalysisService.isSimilarSentence("Hello, world!", "hello world"))
        #expect(AnalysisService.isSimilarSentence("The quick brown fox jumps over the lazy dog",
                                                  "The quick brown fox jumps over the lazy dog today"))
        #expect(!AnalysisService.isSimilarSentence("The quick brown fox", "A slow green turtle"))
        #expect(AnalysisService.isSimilarSentence("…", "…"))
        #expect(!AnalysisService.isSimilarSentence("…", "!"))
    }

    @Test func mergeTags() {
        #expect(AnalysisService.mergeTags(["A", " b ", ""], ["a", "C", "b"]) == ["A", "b", "C"])
    }

    /// 查重按词筛：不分大小写、首尾空格，只认同一种语言；只是包含这个词的别的词不算
    @Test func existingEntryMatchesWholeWordOnly() throws {
        let context = try makeLibrary()
        let german = try existing(context, word: "Straße", language: .german, sentence: "Die Straße ist frei.")
        _ = try existing(context, word: "Straßenbahn", language: .german, sentence: "Die Straßenbahn kommt.")
        _ = try existing(context, word: "confluences", sentence: "Two confluences.")
        #expect(service.existingEntry(word: " straße ", languageRaw: "de", context: context)?.id == german.id)
        #expect(service.existingEntry(word: "Straße", languageRaw: "en", context: context) == nil)
        #expect(service.existingEntry(word: "confluence", languageRaw: "en", context: context) == nil)
    }

    /// OCR 读到的字查词库：词形变化也认（driving → drive），原样那个词形优先
    @Test func cachedEntryFromOCR() throws {
        let context = try makeLibrary()
        let drive = try existing(context, word: "drive", sentence: "We drive home.")
        _ = try existing(context, word: "driver", sentence: "The driver waved.")
        #expect(service.cachedEntry(candidates: LocalOCR.lookupCandidates("Driving,"), context: context)?.id == drive.id)
        let driving = try existing(context, word: "Driving", sentence: "Driving is fun.")
        #expect(service.cachedEntry(candidates: LocalOCR.lookupCandidates("driving"), context: context)?.id == driving.id)
        #expect(service.cachedEntry(candidates: LocalOCR.lookupCandidates("drove"), context: context) == nil)
    }

    /// 主窗口自己存的盘：新词按时间插到列表里、删掉的拿掉，不用重取；别的 ModelContext 存的照旧整个重取
    @Test func wordListAbsorbsOwnSaves() throws {
        let context = try makeLibrary()
        let old = try existing(context, word: "old", sentence: "An old one.")
        old.createdAt = Date(timeIntervalSinceNow: -86_400)
        try context.save()
        let cache = WordListCache()
        _ = cache.refresh(version: 0, edits: 0, category: nil, search: nil, group: .all, context: context)
        #expect(cache.all.map(\.word) == ["old"])

        final class Saves: @unchecked Sendable { var last: Notification? }
        let saves = Saves()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { saves.last = $0 }
        defer { NotificationCenter.default.removeObserver(token) }
        let fresh = try existing(context, word: "fresh", sentence: "A fresh one.")
        #expect(cache.absorb(try #require(saves.last), context: context))
        _ = cache.refresh(version: 0, edits: 1, category: nil, search: nil, group: .all, context: context)
        #expect(cache.all.map(\.word) == ["fresh", "old"])
        #expect(cache.orderIDs == [fresh.id, old.id])

        context.delete(old)
        try context.save()
        #expect(cache.absorb(try #require(saves.last), context: context))
        _ = cache.refresh(version: 0, edits: 2, category: nil, search: nil, group: .all, context: context)
        #expect(cache.all.map(\.word) == ["fresh"])

        let other = ModelContext(context.container)
        other.insert(WordEntry(word: "synced", meaning: "m", contextSentence: "", contextTranslation: "", analysisNote: ""))
        try other.save()
        #expect(!cache.absorb(try #require(saves.last), context: context))
    }

    @Test func ocrCandidates() {
        #expect(LocalOCR.lookupCandidates("Driving,") == ["driving", "driv", "drive"])
        #expect(LocalOCR.lookupCandidates("“Rivers”").contains("river"))
        #expect(LocalOCR.lookupCandidates("Fahrern").contains("fahrer"))
        #expect(LocalOCR.lookupCandidates("go").contains("go"))
        #expect(LocalOCR.lookupCandidates("one two three four five six").isEmpty)
        #expect(LocalOCR.lookupCandidates("  ").isEmpty)
    }
}
