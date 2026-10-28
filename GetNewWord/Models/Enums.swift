// Enums.swift
// GetNewWord
//
// 数据模型枚举定义

import Foundation

enum Language: String, Codable, CaseIterable {
    case german = "de"
    case english = "en"
    case chinese = "zh"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"
    case other

    var displayName: String {
        switch self {
        case .german: return String(localized: "德语")
        case .english: return String(localized: "英语")
        case .chinese: return String(localized: "中文")
        case .french: return String(localized: "法语")
        case .spanish: return String(localized: "西班牙语")
        case .japanese: return String(localized: "日语")
        case .korean: return String(localized: "韩语")
        case .other: return String(localized: "其他")
        }
    }

    /// 简体中文名，不跟界面语言变：Anki 牌组和卡片上的「语言」用它（内置分类的名字也是中文）
    var chineseName: String {
        switch self {
        case .german: return "德语"
        case .english: return "英语"
        case .chinese: return "中文"
        case .french: return "法语"
        case .spanish: return "西班牙语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .other: return "其他"
        }
    }
}

enum Difficulty: String, Codable, CaseIterable, Comparable {
    case a1, a2, b1, b2, c1, c2

    var displayName: String {
        rawValue.uppercased()
    }

    static func < (lhs: Difficulty, rhs: Difficulty) -> Bool {
        let order: [Difficulty] = [.a1, .a2, .b1, .b2, .c1, .c2]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

enum EntryCategory: String, Codable, CaseIterable {
    case word = "word"
    case snippet = "snippet"

    var displayName: String {
        switch self {
        case .word: return "单词"
        case .snippet: return "知识片段"
        }
    }
}

enum SyncStatus: String, Codable {
    case notSynced = "not_synced"
    case synced = "synced"
    case syncFailed = "sync_failed"
    case archived = "archived"

    var displayName: String {
        switch self {
        case .notSynced: return String(localized: "未同步")
        case .synced: return String(localized: "已同步")
        case .syncFailed: return String(localized: "同步失败")
        case .archived: return String(localized: "已归档")
        }
    }
}

/// 释义和译文写成哪种语言（设置和主窗口工具栏都能改；默认简体中文）
enum TargetLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans", zhHant = "zh-Hant", en, de, fr, es, ja, ko

    static let key = "targetLanguage"
    static var current: TargetLanguage {
        TargetLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .zhHans
    }

    var id: String { rawValue }

    /// 用它自己的语言写名字，换了界面语言也认得出
    var nativeName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    /// 写进提示词的名字
    var promptName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文（台湾用语）"
        case .en: return "英语（English）"
        case .de: return "德语（Deutsch）"
        case .fr: return "法语（Français）"
        case .es: return "西班牙语（Español）"
        case .ja: return "日语（日本語）"
        case .ko: return "韩语（한국어）"
        }
    }
}
