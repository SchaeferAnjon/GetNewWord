// WordContext.swift
// GetNewWord
//
// 单词的一次「语境」：同一个单词在不同地方遇到时基础含义相同，但句子/截图不同。
// WordEntry 只保留一份（词、音标、释义），每次遇到都追加一条 WordContext。

import Foundation
import SwiftData

@Model
final class WordContext {
    var id: UUID
    var sentence: String
    var translation: String
    var note: String
    var screenshotPath: String?
    var createdAt: Date

    var word: WordEntry?

    init(
        id: UUID = UUID(),
        sentence: String,
        translation: String,
        note: String = "",
        screenshotPath: String? = nil,
        createdAt: Date = Date(),
        word: WordEntry? = nil
    ) {
        self.id = id
        self.sentence = sentence
        self.translation = translation
        self.note = note
        self.screenshotPath = screenshotPath
        self.createdAt = createdAt
        self.word = word
    }
}
