// KnowledgeSnippet.swift
// GetNewWord
//
// 知识片段数据模型

import Foundation
import SwiftData

@Model
final class KnowledgeSnippet {
    var id: UUID
    var title: String
    var content: String
    var sourceContext: String
    var screenshotPath: String?
    var tags: [String]
    var domain: String
    var createdAt: Date
    var isArchived: Bool
    var syncStatusRaw: String
    var ankiNoteId: Int? = nil
    /// Anki 知识卡正面的问题（整理时让 AI 顺手出的）；老片段没有，卡片正面用标题
    var question: String? = nil

    @Relationship(deleteRule: .nullify)
    var category: Category?

    @Relationship(deleteRule: .nullify)
    var relatedWords: [WordEntry]

    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .notSynced }
        set { syncStatusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        sourceContext: String,
        screenshotPath: String? = nil,
        tags: [String] = [],
        domain: String,
        question: String? = nil,
        createdAt: Date = Date(),
        isArchived: Bool = false,
        syncStatus: SyncStatus = .notSynced,
        category: Category? = nil,
        relatedWords: [WordEntry] = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.sourceContext = sourceContext
        self.screenshotPath = screenshotPath
        self.tags = tags
        self.domain = domain
        self.question = question
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.syncStatusRaw = syncStatus.rawValue
        self.category = category
        self.relatedWords = relatedWords
    }
}
