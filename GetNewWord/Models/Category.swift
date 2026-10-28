// Category.swift
// GetNewWord
//
// 分类数据模型

import Foundation
import SwiftData

@Model
final class Category {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String

    @Relationship(deleteRule: .nullify)
    var parent: Category?

    @Relationship(deleteRule: .cascade, inverse: \Category.parent)
    var children: [Category]

    @Relationship(deleteRule: .nullify, inverse: \WordEntry.category)
    var words: [WordEntry]

    @Relationship(deleteRule: .nullify, inverse: \KnowledgeSnippet.category)
    var snippets: [KnowledgeSnippet]

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        colorHex: String = "#808080",
        parent: Category? = nil,
        children: [Category] = [],
        words: [WordEntry] = [],
        snippets: [KnowledgeSnippet] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.parent = parent
        self.children = children
        self.words = words
        self.snippets = snippets
    }
}

extension Category {
    /// 内置分类（语言学习、德语、知识片段……）按界面语言显示；数据和 Anki 牌组仍用存的名字
    static func displayName(_ name: String) -> String {
        Bundle.main.localizedString(forKey: name, value: name, table: "Categories")
    }
    var displayName: String { Self.displayName(name) }
}
