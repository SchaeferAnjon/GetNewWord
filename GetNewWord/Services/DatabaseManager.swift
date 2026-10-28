// DatabaseManager.swift
// GetNewWord
//
// 数据库管理器：提供 CRUD 和查询接口

import Foundation
import SwiftData

@MainActor
final class DatabaseManager {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - CRUD: WordEntry

    func addWord(_ entry: WordEntry) {
        context.insert(entry)
        saveIfNeeded()
    }

    func deleteWord(_ entry: WordEntry) {
        context.delete(entry)
        saveIfNeeded()
    }

    func updateWord(_ entry: WordEntry) {
        saveIfNeeded()
    }

    // MARK: - CRUD: KnowledgeSnippet

    func addSnippet(_ snippet: KnowledgeSnippet) {
        context.insert(snippet)
        saveIfNeeded()
    }

    func deleteSnippet(_ snippet: KnowledgeSnippet) {
        context.delete(snippet)
        saveIfNeeded()
    }

    func updateSnippet(_ snippet: KnowledgeSnippet) {
        saveIfNeeded()
    }

    // MARK: - 查询: WordEntry

    func fetchWords(
        filter: ((FetchDescriptor<WordEntry>) -> FetchDescriptor<WordEntry>)? = nil,
        sortBy: [SortDescriptor<WordEntry>] = [SortDescriptor(\.createdAt, order: .reverse)]
    ) -> [WordEntry] {
        var descriptor = FetchDescriptor<WordEntry>(sortBy: sortBy)
        if let filter {
            descriptor = filter(descriptor)
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchWordsByDate(_ date: Date) -> [WordEntry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        let predicate = #Predicate<WordEntry> { entry in
            entry.createdAt >= startOfDay && entry.createdAt < endOfDay
        }
        let descriptor = FetchDescriptor<WordEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchWordsByLanguage(_ lang: Language) -> [WordEntry] {
        let langRaw = lang.rawValue
        let predicate = #Predicate<WordEntry> { entry in
            entry.languageRaw == langRaw
        }
        let descriptor = FetchDescriptor<WordEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchWordsByDifficulty(_ diff: Difficulty) -> [WordEntry] {
        let diffRaw = diff.rawValue
        let predicate = #Predicate<WordEntry> { entry in
            entry.difficultyRaw == diffRaw
        }
        let descriptor = FetchDescriptor<WordEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func searchWords(query: String) -> [WordEntry] {
        let lowered = query.lowercased()
        let predicate = #Predicate<WordEntry> { entry in
            entry.word.localizedStandardContains(lowered) ||
            entry.meaning.localizedStandardContains(lowered) ||
            entry.contextSentence.localizedStandardContains(lowered)
        }
        let descriptor = FetchDescriptor<WordEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 查询: KnowledgeSnippet

    func fetchSnippets(
        filter: ((FetchDescriptor<KnowledgeSnippet>) -> FetchDescriptor<KnowledgeSnippet>)? = nil,
        sortBy: [SortDescriptor<KnowledgeSnippet>] = [SortDescriptor(\.createdAt, order: .reverse)]
    ) -> [KnowledgeSnippet] {
        var descriptor = FetchDescriptor<KnowledgeSnippet>(sortBy: sortBy)
        if let filter {
            descriptor = filter(descriptor)
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 查询: Category

    func fetchCategories() -> [Category] {
        let descriptor = FetchDescriptor<Category>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 预置分类

    func seedDefaultCategories() {
        let existingCount = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
        guard existingCount == 0 else { return }

        // 语言学习 > 德语
        let languageParent = Category(name: "语言学习", icon: "globe", colorHex: "#4A90D9")
        let germanCat = Category(name: "德语", icon: "flag.de", colorHex: "#FFD700")
        germanCat.parent = languageParent

        // 语言学习 > 英语
        let englishCat = Category(name: "英语", icon: "flag.us", colorHex: "#FF6B6B")
        englishCat.parent = languageParent

        // 知识片段 > 健身 / 医学 / 其他
        let snippetParent = Category(name: "知识片段", icon: "book.pages", colorHex: "#7B68EE")
        let fitnessCat = Category(name: "健身", icon: "figure.strengthtraining.traditional", colorHex: "#FF8C00")
        fitnessCat.parent = snippetParent

        let medicalCat = Category(name: "医学", icon: "cross.case", colorHex: "#E74C3C")
        medicalCat.parent = snippetParent

        let otherCat = Category(name: "其他", icon: "ellipsis.circle", colorHex: "#95A5A6")
        otherCat.parent = snippetParent

        [languageParent, snippetParent].forEach { context.insert($0) }
        [germanCat, englishCat, fitnessCat, medicalCat, otherCat].forEach { context.insert($0) }

        saveIfNeeded()
    }

    // MARK: - Private

    private func saveIfNeeded() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("DatabaseManager: 保存失败 - \(error)")
        }
    }
}
