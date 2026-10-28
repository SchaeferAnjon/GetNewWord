// OnboardingView.swift
// GetNewWord
//
// 首次使用引导（design/settings-v2 A3，左侧步骤清单）：
// 欢迎（界面语言、翻译成）→ 权限 → 选择 AI → 连接 Anki（可选）→ 匿名统计（同意或不用了）→ 开始使用

import SwiftUI
import AppKit

struct OnboardingView: View {
    @State private var viewModel = SettingsViewModel()
    @ObservedObject private var permissions = PermissionManager.shared
    @AppStorage(TargetLanguage.key) private var target: TargetLanguage = .zhHans
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu
    @AppStorage(UsageConsent.key) private var usageConsent = ""
    @State private var step = 0
    @State private var pendingLanguage: AppLanguage?
    let onComplete: () -> Void

    private let steps: [(title: LocalizedStringKey, note: LocalizedStringKey)] = [
        ("欢迎", "语言"), ("权限", "截图要用"), ("选择 AI", "必填"), ("连接 Anki", "可选"), ("匿名统计", "选一个"), ("开始使用", "")
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch step {
                        case 0: welcomeStep
                        case 1: permissionsStep
                        case 2: aiStep
                        case 3: ankiStep
                        case 4: statsStep
                        default: readyStep
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 44)
                    .padding(.top, 36)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                    .id(step)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                footer.frame(height: 64).padding(.horizontal, 28)
            }
            .background(Theme.bg)
        }
        .tint(Theme.accent)
        .onAppear { permissions.refresh() }
        // 在权限这一步授权好就自己翻到下一步
        .onChange(of: permissions.hasScreenRecording) { _, granted in
            if granted && step == 1 { go(2) }
        }
        .alert("切换界面语言需要重开 GetNewWord", isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } })) {
            Button("现在重开") { pendingLanguage?.applyAndRelaunch() }
            Button("取消", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("改成 \(pendingLanguage?.nativeName ?? "")，应用会退出并自动重新打开。")
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GetNewWord").font(.system(size: 14, weight: .semibold))
                    Text("首次设置").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)

            VStack(spacing: 2) {
                ForEach(steps.indices, id: \.self) { stepRow($0) }
            }
            Spacer()
            Button("跳过，稍后在设置里配置") { finish() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    /// 每步按真实状态打勾
    private func isDone(_ i: Int) -> Bool {
        switch i {
        case 0: return step > 0
        case 1: return permissions.hasScreenRecording
        case 2: return hasKey
        case 3: return AnkiInstaller.shared.connected
        case 4: return !usageConsent.isEmpty
        default: return false
        }
    }

    private var hasKey: Bool { !(ZhipuService.shared.key(for: provider) ?? "").isEmpty || viewModel.keyValid[provider] == true }

    private func stepRow(_ i: Int) -> some View {
        let current = i == step
        let done = isDone(i) && !current
        return Button { go(i) } label: {
            HStack(spacing: 10) {
                ZStack {
                    if done {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(Theme.ok)
                    } else {
                        Circle().stroke(current ? Theme.text : Theme.borderStrong, lineWidth: 1.2)
                        Text("\(i + 1)").font(.system(size: 11, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? Theme.text : Theme.text2)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(steps[i].title).font(.system(size: 13)).foregroundStyle(current ? Theme.text : Theme.text2)
                    Text(steps[i].note).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.elevated)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 14) {
            if step == 4 && !usageConsent.isEmpty {
                Text(usageConsent == UsageConsent.yes.rawValue ? "已选：同意" : "已选：不用了")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if step > 0 {
                Button("上一步") { go(step - 1) }.buttonStyle(.plain).foregroundStyle(Theme.text2)
            }
            if step == 4 {
                // 两个一样的按钮，没有主按钮，回车不替人选
                UsageConsentButtons { go(5) }
            } else {
                Button(nextTitle) { next() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(step == 2 && !hasKey)
            }
        }
    }

    private var nextTitle: LocalizedStringKey {
        switch step {
        case 0: return "开始设置"
        case 1: return permissions.hasScreenRecording ? "继续" : "稍后再授权"
        case 3: return AnkiInstaller.shared.connected ? "继续" : "先不连"
        case 5: return "开始使用"
        default: return "继续"
        }
    }

    private func go(_ target: Int) {
        withAnimation(.easeOut(duration: 0.22)) { step = target }
    }

    private func next() {
        if step == steps.count - 1 { finish() } else { go(step + 1) }
    }

    private func finish() {
        viewModel.completeOnboarding()
        // 跳过引导的人也在这时申请截图要用的权限，不等第一次按快捷键
        PermissionManager.shared.requestMissingAtLaunch()
        onComplete()
    }

    private func header(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 1 欢迎：界面语言、翻译成

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            MoveToApplicationsNotice()
            CaptureIllustration(target: target)
            VStack(alignment: .leading, spacing: 6) {
                Text("看到生词，框一下就懂").font(.system(size: 22, weight: .semibold))
                Text("GetNewWord 帮你在读外语时随手积累单词：框住、讲解、存进词库、同步到 Anki。")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("界面语言").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                Picker("", selection: Binding(get: { AppLanguage.current }, set: { if $0 != AppLanguage.current { pendingLanguage = $0 } })) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("讲解和翻译用的语言（上面的示意会跟着变）").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                TargetLanguageGrid(target: $target)
            }
        }
    }

    // MARK: - 2 权限

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("打开屏幕录制", "截图取词要截下你框住的那一块屏幕。点「授权」后系统会带你到这个开关，打开后重开一次 GetNewWord 就生效。")
            PermissionIllustration(granted: permissions.hasScreenRecording)
            if !permissions.hasScreenRecording { DragToGrantRow() }
            SettingsGroup {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("屏幕录制").font(.system(size: 13, weight: .medium))
                            Tag(text: "必需")
                        }
                        Text("截图取词时截下你框住的那一块").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    if permissions.hasScreenRecording {
                        Label("已授权", systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.ok)
                    } else {
                        Button("授权") { permissions.requestScreenRecording() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(12)
            }
        }
        .onAppear { permissions.askedThisLaunch = true }
    }

    // MARK: - 3 选择 AI

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("用哪种 AI 讲解？", "填好一家就能用，之后随时在设置里换。")
            HStack(spacing: 10) {
                planCard(title: "免费试用", tag: "即将开放", big: "7 天", detail: "什么都不用填", selected: false, disabled: true)
                planCard(title: "会员", tag: "即将开放", big: "免配置", detail: "不用 Key，官方 AI", selected: false, disabled: true)
                planCard(title: "自带 Key", tag: "永久免费", big: "免费", detail: "10 家服务商可选", selected: true, disabled: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            ProviderPicker(viewModel: viewModel, selected: $provider)
        }
    }

    private func planCard(title: LocalizedStringKey, tag: LocalizedStringKey, big: LocalizedStringKey, detail: LocalizedStringKey,
                          selected: Bool, disabled: Bool) -> some View {
        ChoiceCard(selected: selected, disabled: disabled) {} content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Tag(text: tag)
                }
                Text(big).font(.system(size: 17, weight: .bold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
        }
    }

    // MARK: - 4 Anki

    private var ankiStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("连接 Anki", "查过的词自动做成卡片，按间隔重复复习。下面三步都能一键完成；不用 Anki 就点「先不连」。")
            AnkiLinkIllustration(connected: AnkiInstaller.shared.connected)
            AnkiSetupView(style: .card)
        }
    }

    // MARK: - 5 匿名统计

    private var statsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("帮我们知道有多少人在用 GetNewWord？").font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            UsageConsentBody()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - 6 开始使用

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("可以开始了", "在任何地方遇到生词，按下面的快捷键。")
            shortcutRow(title: "截图取词", detail: "框住屏幕上的词或一段话", combo: HotkeyPrefs.screenshot.displayString)
            shortcutRow(title: "指词查词", detail: "鼠标指着词，不用框选", combo: HotkeyPrefs.hover.displayString)
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template).foregroundStyle(Theme.text)
                    .frame(width: 28, height: 22)
                    .background(Theme.selected, in: RoundedRectangle(cornerRadius: 5))
                Text("GetNewWord 住在屏幕右上角的菜单栏里：点这个图标能打开主窗口和设置。")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func shortcutRow(title: LocalizedStringKey, detail: LocalizedStringKey, combo: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            KeyCaps(combo: combo)
        }
        .padding(14)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }
}
