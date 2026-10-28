// AnkiConnectModels.swift
// GetNewWord
//
// AnkiConnect API 请求/响应模型及 AnyCodable 类型擦除包装

import Foundation

// MARK: - AnyCodable

/// 类型擦除的 Codable 包装，用于构造混合类型的 AnkiConnect params
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String:
            try container.encode(str)
        case let int as Int:
            try container.encode(int)
        case let bool as Bool:
            try container.encode(bool)
        case let double as Double:
            try container.encode(double)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let codable as Codable:
            try container.encode(codable)
        default:
            try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}

// MARK: - AnkiConnect 请求

struct AnkiConnectRequest: Codable {
    let action: String
    let version: Int
    let params: [String: AnyCodable]?

    init(action: String, version: Int = 6, params: [String: Any]? = nil) {
        self.action = action
        self.version = version
        self.params = params?.mapValues { AnyCodable($0) }
    }
}

// MARK: - AnkiConnect 响应

struct AnkiConnectResponse<T: Codable>: Codable {
    let result: T?
    let error: String?
}

// MARK: - AnkiNoteInfo

/// Anki 笔记信息，对应 notesInfo 接口返回的单条数据
struct AnkiNoteInfo: Codable {
    let noteId: Int
    let fields: [String: AnkiFieldValue]
    let tags: [String]
    let cards: [Int]

    struct AnkiFieldValue: Codable {
        let value: String
        let order: Int
    }
}
