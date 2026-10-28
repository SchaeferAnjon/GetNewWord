// KeychainManager.swift
// GetNewWord
//
// Keychain 管理器，用于安全存储和读取敏感数据（如 API Key）

import Foundation
import Security

class KeychainManager: @unchecked Sendable {
    static let shared = KeychainManager()

    private let serviceName = AppVariant.bundleID

    private init() {}

    // MARK: - Public

    /// 保存字符串到 Keychain
    /// - Parameters:
    ///   - key: 存储键
    ///   - value: 存储值
    /// - Returns: 是否保存成功
    @discardableResult
    func save(key: String, value: String) -> Bool {
        // 先尝试删除已有的同 key 条目，避免重复
        delete(key: key)

        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 从 Keychain 读取字符串
    /// - Parameter key: 存储键
    /// - Returns: 存储的字符串，不存在时返回 nil
    func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// 从 Keychain 删除条目
    /// - Parameter key: 存储键
    /// - Returns: 是否删除成功
    @discardableResult
    func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
