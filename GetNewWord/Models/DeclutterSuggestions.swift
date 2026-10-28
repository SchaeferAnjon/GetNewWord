// DeclutterSuggestions.swift
// GetNewWord
//
// 内容臃肿治理建议数据模型

import Foundation
import SwiftData

/// 臃肿治理建议，包含可归档、可合并、可移除的单词分析结果
struct DeclutterSuggestions {
    /// 可归档的单词（已掌握 + 超过30天未复习）
    let archivableWords: [WordEntry]
    /// 可合并的近义词对
    let mergeablePairs: [WordPair]
    /// 建议移除的单词（太简单 + 已掌握）
    let removableWords: [WordEntry]
    /// 当前总卡片数
    let totalCards: Int
    /// 建议减少的卡片数
    let suggestedReduction: Int
    /// 用于保存操作的数据库上下文
    let context: ModelContext

    /// 单词对，用于表示可合并的近义词
    struct WordPair {
        let first: WordEntry
        let second: WordEntry
    }

    /// 空建议，用于无数据或错误场景
    static func empty(context: ModelContext) -> DeclutterSuggestions {
        DeclutterSuggestions(
            archivableWords: [],
            mergeablePairs: [],
            removableWords: [],
            totalCards: 0,
            suggestedReduction: 0,
            context: context
        )
    }
}
