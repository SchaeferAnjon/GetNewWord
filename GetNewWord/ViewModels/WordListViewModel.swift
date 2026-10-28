// WordListViewModel.swift
// GetNewWord
//
// 单词/知识片段列表 ViewModel

import Foundation

@MainActor
class WordListViewModel: ObservableObject {
    @Published var sortOrder: SortOrder = .dateDescending
    @Published var filterLanguage: Language?
    @Published var filterDifficulty: Difficulty?

    enum SortOrder: String, CaseIterable {
        case dateDescending = "最新优先"
        case dateAscending = "最早优先"
        case alphabetical = "字母顺序"
        case difficulty = "难度排序"
    }
}
