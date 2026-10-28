// ProviderViews.swift
// GetNewWord
//
// 引导页与设置页共用的 AI 提供商小部件：官方图标、Key 验证状态

import SwiftUI

extension APIProvider {
    /// 菜单里只能放 Image，所以单独给出
    var logo: Image { logoAsset.map { Image($0) } ?? Image(systemName: "slider.horizontal.3") }
}

/// 提供商官方图标（Assets 里的矢量图）；单色图标随文字色，自定义用 SF Symbol
struct ProviderLogo: View {
    let provider: APIProvider
    var size: CGFloat = 20

    var body: some View {
        provider.logo
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
    }
}

/// Key 验证状态：验证中 / 可以用了 / 无效（附原因）
struct KeyStatusLabel: View {
    let validating: Bool
    let valid: Bool?
    let error: String?

    var body: some View {
        if validating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("验证中").foregroundStyle(.secondary)
            }
        } else if let valid {
            Label(valid ? String(localized: "可以用了") : (error ?? String(localized: "Key 无效，请检查后重试")),
                  systemImage: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(valid ? Theme.ok : Theme.danger)
                .lineLimit(2)
        }
    }
}

/// 模型输入框旁的下拉：列出从这家接口拉到的模型，点一下填进去；也能恢复推荐、重新拉取
struct ModelMenu: View {
    let provider: APIProvider
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        let p = provider
        let models = viewModel.availableModels[p] ?? []
        let current = p.model
        if viewModel.loadingModels.contains(p) {
            ProgressView().controlSize(.small).help("正在拉取模型列表")
        } else {
            Menu {
                if models.isEmpty {
                    Text(viewModel.modelListErrors[p] ?? String(localized: "填好 Key 后会自动拉取模型列表"))
                } else {
                    Section("\(p.displayName) 可用的模型（\(models.count)）") {
                        ForEach(models, id: \.self) { id in
                            Button {
                                viewModel.setModel(id == p.defaultModel ? "" : id, for: p)
                            } label: {
                                if id == current { Label(id, systemImage: "checkmark") } else { Text(id) }
                            }
                        }
                    }
                }
                Divider()
                if !p.defaultModel.isEmpty {
                    Button("恢复推荐（\(p.defaultModel)）") { viewModel.setModel("", for: p) }
                }
                Button("重新拉取列表") { Task { await viewModel.fetchModels(for: p) } }
                    .disabled(viewModel.apiKeys[p, default: ""].isEmpty)
            } label: {
                Label(models.isEmpty ? "选择" : "选择（\(models.count)）", systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(viewModel.modelListErrors[p] ?? String(localized: "从官方模型列表里选"))
        }
    }
}

/// 10 家服务商分两组列出，选中的那家展开填 Key、模型、思考模式（设置的 AI 服务页和欢迎页共用）
struct ProviderPicker: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var selected: APIProvider
    @AppStorage("thinkingEnabled") private var thinkingEnabled = false
    @AppStorage("thinkingLevel") private var thinkingLevel = "low"

    var body: some View {
        VStack(spacing: 0) {
            groupHeader("国内可直连", first: true)
            ForEach(APIProvider.allCases.filter(\.isDomestic)) { row($0) }
            groupHeader("海外与其他", first: false)
            ForEach(APIProvider.allCases.filter { !$0.isDomestic }) { row($0) }
        }
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
        .task(id: selected) { await viewModel.fetchModelsIfNeeded(for: selected) }
    }

    private func groupHeader(_ title: LocalizedStringKey, first: Bool) -> some View {
        VStack(spacing: 0) {
            if !first { Hairline() }
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
        }
        .background(Theme.surface)
    }

    private func row(_ p: APIProvider) -> some View {
        let isOn = p == selected
        let hasKey = !(ZhipuService.shared.key(for: p) ?? "").isEmpty
        return VStack(spacing: 0) {
            Hairline()
            Button {
                withAnimation(.easeOut(duration: 0.18)) { selected = p }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .strokeBorder(isOn ? Theme.accent : Theme.borderStrong, lineWidth: isOn ? 5 : 1.2)
                        .frame(width: 15, height: 15)
                    ProviderLogo(provider: p, size: 18)
                    Text(p.displayName).font(.system(size: 13, weight: .medium))
                    Text(p.blurb).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    Spacer()
                    if hasKey && !isOn {
                        Label("已填 Key", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(Theme.ok)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOn { keyForm(p) }
        }
        .background(isOn ? Theme.accentSoft.opacity(0.45) : .clear)
    }

    private func keyForm(_ p: APIProvider) -> some View {
        let key = Binding(get: { viewModel.apiKeys[p, default: ""] }, set: { viewModel.setKey($0, for: p) })
        let model = Binding(get: { viewModel.models[p, default: ""] }, set: { viewModel.setModel($0, for: p) })
        let baseURL = Binding(get: { viewModel.customBaseURL }, set: { viewModel.setCustomBaseURL($0) })
        let validating = viewModel.validatingProvider == p
        let saved = !key.wrappedValue.isEmpty && key.wrappedValue == ZhipuService.shared.key(for: p)

        return VStack(alignment: .leading, spacing: 8) {
            if p == .custom {
                line("接口地址") {
                    TextField("", text: baseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
            }
            line("API Key") {
                SecureField("", text: key, prompt: Text("粘贴 Key"))
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .onSubmit { Task { await viewModel.validateKey(for: p) } }
                Button("验证") { Task { await viewModel.validateKey(for: p) } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(key.wrappedValue.isEmpty || validating)
            }
            line("模型") {
                TextField("", text: model, prompt: Text(p.defaultModel.isEmpty ? String(localized: "填模型名") : p.defaultModel))
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                ModelMenu(provider: p, viewModel: viewModel)
            }
            line("") {
                Group {
                    if validating || viewModel.keyValid[p] != nil {
                        KeyStatusLabel(validating: validating, valid: viewModel.keyValid[p], error: viewModel.keyErrors[p])
                    } else if let error = viewModel.modelListErrors[p] {
                        Text(error).foregroundStyle(Theme.danger)
                    } else {
                        Text(key.wrappedValue.isEmpty ? "还没填 Key" : saved ? "已保存，可点验证确认" : "点「验证」后保存")
                            .foregroundStyle(Theme.text3)
                    }
                }
                Spacer()
                if let url = p.keyPage {
                    Link("去官网拿 Key ↗", destination: url).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            if p.thinkingControl != .none {
                line("") {
                    Toggle(isOn: $thinkingEnabled) {
                        Text("思考模式（更准，慢不少）").font(.system(size: 12.5))
                        Spacer()
                    }
                    .toggleStyle(.square)
                }
                if thinkingEnabled && p.thinkingControl == .level {
                    line("") {
                        Picker("", selection: $thinkingLevel) {
                            Text("低").tag("low"); Text("高").tag("high"); Text("最高").tag("max")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        Spacer()
                    }
                }
            }
        }
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        // 粘贴完停半秒就自动验证，通过即存进钥匙串，不用记得点「验证」（task 随 Key 变化重启，等于防抖）
        .task(id: key.wrappedValue) {
            let k = key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard k.count >= 8, k != ZhipuService.shared.key(for: p), viewModel.keyValid[p] == nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, viewModel.validatingProvider == nil else { return }
            await viewModel.validateKey(for: p)
        }
    }

    private func line<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 60, alignment: .leading)
            content()
        }
    }
}
