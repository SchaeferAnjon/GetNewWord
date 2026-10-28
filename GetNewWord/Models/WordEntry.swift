// WordEntry.swift
// GetNewWord
//
// 单词条目数据模型

import Foundation
import SwiftData

@Model
final class WordEntry {
    var id: UUID
    var word: String
    var phonetic: String?
    var languageRaw: String
    var meaning: String
    /// 当前语境义项（meaning 的子串，高亮用）
    var contextMeaning: String?
    var contextSentence: String
    var contextTranslation: String
    /// 目标词在译文中对应的字词（译文精确高亮用）
    var translationKeyword: String? = nil
    /// 查询次数（同词重复截取也计数）
    var lookupCount: Int = 1
    var analysisNote: String
    /// 语法信息：德语名词「der Fahrer, die Fahrer」、动词「trennbar · hielt an · angehalten」、形容词比较级等
    var grammar: String?
    /// 常用搭配（每行一条，"搭配 —— 中文"）
    var collocationsText: String?
    /// 例句（每行一条，"原句 —— 中文"）
    var examplesText: String?
    /// 助记
    var mnemonic: String?
    /// 词根词源
    var etymology: String?
    var audioPath: String?
    var screenshotPath: String?
    var difficultyRaw: String
    var tags: [String]
    var createdAt: Date
    var reviewCount: Int
    var ankiNoteId: Int?
    var syncStatusRaw: String
    var isArchived: Bool

    @Relationship(deleteRule: .nullify)
    var category: Category?

    @Relationship(inverse: \KnowledgeSnippet.relatedWords)
    var relatedSnippets: [KnowledgeSnippet]?

    /// 该单词的所有语境（同词多次遇到时追加，删除单词时级联删除）
    @Relationship(deleteRule: .cascade, inverse: \WordContext.word)
    var contexts: [WordContext]?

    /// 按时间排序的语境列表；旧数据没有 contexts 时回退到自身的 contextSentence 字段
    var sortedContexts: [WordContext] {
        let list = (contexts ?? []).sorted { $0.createdAt < $1.createdAt }
        if list.isEmpty, !contextSentence.isEmpty {
            return [WordContext(sentence: contextSentence, translation: contextTranslation,
                                note: analysisNote, screenshotPath: screenshotPath, createdAt: createdAt)]
        }
        return list
    }

    /// 用于去重的规范化键：小写词形 + 语言
    var dedupeKey: String { "\(word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(languageRaw)" }

    var language: Language {
        get { Language(rawValue: languageRaw) ?? .other }
        set { languageRaw = newValue.rawValue }
    }

    var difficulty: Difficulty {
        get { Difficulty(rawValue: difficultyRaw) ?? .a1 }
        set { difficultyRaw = newValue.rawValue }
    }

    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .notSynced }
        set { syncStatusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        word: String,
        phonetic: String? = nil,
        language: Language = .german,
        meaning: String,
        contextMeaning: String? = nil,
        contextSentence: String,
        contextTranslation: String,
        analysisNote: String,
        grammar: String? = nil,
        collocationsText: String? = nil,
        examplesText: String? = nil,
        mnemonic: String? = nil,
        etymology: String? = nil,
        audioPath: String? = nil,
        screenshotPath: String? = nil,
        difficulty: Difficulty = .a1,
        tags: [String] = [],
        createdAt: Date = Date(),
        reviewCount: Int = 0,
        ankiNoteId: Int? = nil,
        syncStatus: SyncStatus = .notSynced,
        isArchived: Bool = false,
        category: Category? = nil
    ) {
        self.id = id
        self.word = word
        self.phonetic = phonetic
        self.languageRaw = language.rawValue
        self.meaning = meaning
        self.contextMeaning = contextMeaning
        self.contextSentence = contextSentence
        self.contextTranslation = contextTranslation
        self.analysisNote = analysisNote
        self.grammar = grammar
        self.collocationsText = collocationsText
        self.examplesText = examplesText
        self.mnemonic = mnemonic
        self.etymology = etymology
        self.audioPath = audioPath
        self.screenshotPath = screenshotPath
        self.difficultyRaw = difficulty.rawValue
        self.tags = tags
        self.createdAt = createdAt
        self.reviewCount = reviewCount
        self.ankiNoteId = ankiNoteId
        self.syncStatusRaw = syncStatus.rawValue
        self.isArchived = isArchived
        self.category = category
    }
}
