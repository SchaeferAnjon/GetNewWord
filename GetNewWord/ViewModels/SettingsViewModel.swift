// SettingsViewModel.swift
// GetNewWord
//
// 偏好设置与引导流程的 ViewModel

import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    // MARK: - AI 提供商
    /// 各家输入框里的 Key（启动时从 Keychain 读出）；验证通过才写回 Keychain
    var apiKeys: [APIProvider: String] = [:]
    /// 没有条目 = 未验证
    var keyValid: [APIProvider: Bool] = [:]
    /// 验证失败的具体原因（如余额不足）
    var keyErrors: [APIProvider: String] = [:]
    var validatingProvider: APIProvider? = nil
    /// 用户改过的模型名；空 = 用推荐模型
    var models: [APIProvider: String] = [:]
    var customBaseURL: String = ""
    /// 从各家接口拉到的模型列表
    var availableModels: [APIProvider: [String]] = [:]
    var loadingModels: Set<APIProvider> = []
    var modelListErrors: [APIProvider: String] = [:]

    // MARK: - 首次使用
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - 权限状态
    var hasScreenPermission: Bool {
        ScreenshotService.shared.hasScreenRecordingPermission()
    }

    init() {
        loadSavedSettings()
    }

    // MARK: - 加载已保存的设置

    private func loadSavedSettings() {
        let defaults = UserDefaults.standard
        // 从 Keychain 加载已保存的 API Key
        for p in APIProvider.allCases {
            apiKeys[p] = ZhipuService.shared.key(for: p) ?? ""
            models[p] = defaults.string(forKey: p.modelDefaultsKey) ?? ""
        }
        customBaseURL = defaults.string(forKey: APIProvider.customBaseURLKey) ?? ""
    }

    // MARK: - API Key 操作

    /// 改了 Key / 模型 / 地址，之前的验证结果就作废
    func setKey(_ value: String, for p: APIProvider) {
        apiKeys[p] = value
        modelListErrors[p] = nil
        resetValidation(p)
    }

    func setModel(_ value: String, for p: APIProvider) {
        models[p] = value
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: p.modelDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: p.modelDefaultsKey)
        }
        resetValidation(p)
    }

    func setCustomBaseURL(_ value: String) {
        customBaseURL = value
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: APIProvider.customBaseURLKey)
        availableModels[.custom] = nil
        modelListErrors[.custom] = nil
        resetValidation(.custom)
    }

    private func resetValidation(_ p: APIProvider) {
        keyValid[p] = nil
        keyErrors[p] = nil
    }

    /// 发一条极短请求验证 Key，通过就存进 Keychain
    func validateKey(for p: APIProvider) async {
        let key = apiKeys[p, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        validatingProvider = p
        resetValidation(p)
        do {
            keyValid[p] = try await ZhipuService.shared.validateKey(key, provider: p)
        } catch let error as ZhipuServiceError {
            keyValid[p] = false
            keyErrors[p] = error.localizedDescription   // 已按界面语言写好，带服务商名
        } catch {
            keyValid[p] = false
            keyErrors[p] = String(localized: "连不上 \(p.displayName)：\(error.localizedDescription)")   // URLSession 直接抛的网络错误
        }
        if keyValid[p] == true {
            ZhipuService.shared.setKey(key, for: p)
        }
        validatingProvider = nil
        if keyValid[p] == true { await fetchModels(for: p) }
    }

    /// 用输入框里的 Key 拉这家的模型列表；没填 Key 时什么都不做
    func fetchModels(for p: APIProvider) async {
        let key = apiKeys[p, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !loadingModels.contains(p) else { return }
        loadingModels.insert(p)
        modelListErrors[p] = nil
        do {
            availableModels[p] = try await ZhipuService.shared.listModels(key: key, provider: p)
        } catch {
            modelListErrors[p] = String(localized: "拉取模型列表失败：\(error.localizedDescription)")
        }
        loadingModels.remove(p)
    }

    /// 打开某家的设置时，有 Key 又还没拉过就自动拉一次
    func fetchModelsIfNeeded(for p: APIProvider) async {
        guard availableModels[p] == nil, modelListErrors[p] == nil else { return }
        await fetchModels(for: p)
    }

    // MARK: - 引导操作

    /// 完成引导
    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    // MARK: - 权限请求

    /// 请求屏幕录制权限
    func requestScreenPermission() async {
        _ = await ScreenshotService.shared.requestScreenRecordingPermission()
    }
}
