// SettingsPages.swift
// GetNewWord
//
// 设置窗口各页：通用、翻译与学习、快捷键与取词、AI 服务、权限、关于我们、更新与关于。
// Anki、账号与同步在各自的文件里。

import SwiftUI
import ServiceManagement

// MARK: - 通用

struct GeneralSettingsPage: View {
    @AppStorage("appearance") private var appearance: String = Appearance.system.rawValue
    @AppStorage(FontScale.key) private var fontScale: Double = 1.0
    @AppStorage("autoSpeak") private var autoSpeak: Bool = true
    @AppStorage(TargetLanguage.key) private var target: TargetLanguage = .zhHans
    /// 拖动中的临时值：松手才写入 AppStorage。
    /// 连续写会让全 app 每 tick 重渲染，与鼠标 hitTest 撞在显示周期里 → AppKit 抛异常闪退（crash 报告 2026-08-31-155038）
    @State private var fontScaleDraft: Double = 1.0
    @State private var pendingLanguage: AppLanguage?
    @State private var floating = UserDefaults.standard.object(forKey: "showFloatingButton") as? Bool ?? true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(AppIcons.menuBarKey) private var menuBarIcon = true
    @AppStorage(AppIcons.dockKey) private var dockIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("界面语言").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                HStack(spacing: 8) {
                    ForEach(AppLanguage.allCases) { lang in
                        ChoiceCard(selected: AppLanguage.current == lang) {
                            if lang != AppLanguage.current { pendingLanguage = lang }
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lang.settingsWord).font(.system(size: 14, weight: .semibold))
                                Text(lang.nativeName).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }
                Text("改完会自动重开一次 GetNewWord。").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }

            SettingsGroup(title: "外观") {
                HStack(spacing: 16) {
                    ForEach(Appearance.allCases) { a in
                        Button { appearance = a.rawValue } label: {
                            VStack(spacing: 6) {
                                AppearanceThumb(appearance: a)
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .stroke(appearance == a.rawValue ? Theme.accent : Theme.border, lineWidth: appearance == a.rawValue ? 2 : 0.5))
                                Text(a.label).font(.system(size: 12))
                                    .foregroundStyle(appearance == a.rawValue ? Theme.text : Theme.text2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(12)
                Hairline()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("字号").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("⌘+ / ⌘− / ⌘0").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                    HStack(spacing: 10) {
                        Slider(value: $fontScaleDraft, in: 0.85...1.5, step: 0.05) { editing in
                            if !editing { fontScale = fontScaleDraft }   // 松手才生效
                        }
                        Text(String(format: "%.0f%%", fontScaleDraft * 100)).font(.system(size: 12).monospacedDigit()).frame(width: 40, alignment: .trailing)
                    }
                    // 拖动时这张词卡跟着变大变小
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(DemoSentence.word).font(.system(size: 15 * fontScaleDraft, weight: .semibold))
                            Text("die · 名词").font(.system(size: 11 * fontScaleDraft)).foregroundStyle(Theme.text3)
                        }
                        Text(DemoSentence.meaning(target)).font(.system(size: 13 * fontScaleDraft)).foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12)
                .onAppear { fontScaleDraft = fontScale }
            }

            SettingsGroup(title: "行为") {
                SettingsRow(title: "查词后自动朗读", icon: "speaker.wave.2") {
                    Toggle("", isOn: $autoSpeak).toggleStyle(.square).labelsHidden()
                }
                Hairline()
                SettingsRow(title: "桌面悬浮按钮", detail: "屏幕边上一个小圆钮，点一下就截图取词", icon: "circle.circle") {
                    Toggle("", isOn: $floating).toggleStyle(.square).labelsHidden()
                        .onChange(of: floating) { _, on in
                            UserDefaults.standard.set(on, forKey: "showFloatingButton")
                            FloatingButtonController.shared.setVisible(on)
                        }
                }
                Hairline()
                SettingsRow(title: "菜单栏显示图标", detail: "取景框里一个 A，点开是查词和设置", icon: "menubar.rectangle") {
                    Toggle("", isOn: $menuBarIcon).toggleStyle(.square).labelsHidden()
                        .disabled(menuBarIcon && !dockIcon)
                }
                Hairline()
                SettingsRow(title: "Dock 里显示图标", detail: "显示后 ⌘Tab 也能切到 GetNewWord", icon: "dock.rectangle") {
                    Toggle("", isOn: $dockIcon).toggleStyle(.square).labelsHidden()
                        .disabled(dockIcon && !menuBarIcon)
                        .onChange(of: dockIcon) { _, _ in AppIcons.applyDock() }
                }
                if !(dockIcon && menuBarIcon) {
                    Text("两处至少留一个，不然就找不到 GetNewWord 了。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Hairline()
                SettingsRow(title: "开机自动打开", detail: "登录 Mac 后自己待在菜单栏", icon: "power") {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.square).labelsHidden()
                        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                }
            }
            if let loginError {
                Text(loginError).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
        }
        .alert("切换界面语言需要重开 GetNewWord", isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } })) {
            Button("现在重开") { pendingLanguage?.applyAndRelaunch() }
            Button("取消", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("改成 \(pendingLanguage?.nativeName ?? "")，应用会退出并自动重新打开。")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = String(localized: "没能改开机自动打开：\(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

extension AppLanguage {
    /// 语言卡片上用那种语言写的「设置」
    var settingsWord: String {
        switch self {
        case .system: return String(localized: "设置")
        case .zhHans: return "设置"
        case .en: return "Settings"
        case .de: return "Einstellungen"
        }
    }
}

/// 外观缩略图：一个小窗口，跟随系统时左浅右深
private struct AppearanceThumb: View {
    let appearance: Appearance
    var body: some View {
        HStack(spacing: 0) {
            half(dark: appearance == .dark)
            if appearance == .system { half(dark: true) }
        }
        .frame(width: 78, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func half(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(dark ? Color(white: 0.85) : Color(white: 0.25)).frame(width: 22, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(dark ? Color(white: 0.45) : Color(white: 0.7)).frame(width: 14, height: 4)
            Spacer()
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.12) : Color(white: 0.96))
    }
}

// MARK: - 翻译与学习

struct TranslateSettingsPage: View {
    @AppStorage(TargetLanguage.key) private var target: TargetLanguage = .zhHans
    @AppStorage(LookupPanelStyle.key) private var panelStyle: LookupPanelStyle = .classic

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("查到的词和整句译成哪种语言。").font(.system(size: 13)).foregroundStyle(Theme.text2)
            TranslateIllustration(target: target)
            VStack(alignment: .leading, spacing: 6) {
                Text("翻译成").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                TargetLanguageGrid(target: $target)
                Text("主窗口工具栏的「译成」和菜单栏里也能换。只影响之后查的词，已经存下的不变。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("查词面板").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                // 四种样式两个一排，说明能完整显示
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: LookupPanelStyle.allCases.count, by: 2)), id: \.self) { i in
                        GridRow {
                            ForEach(LookupPanelStyle.allCases[i..<min(i + 2, LookupPanelStyle.allCases.count)]) { st in
                                ChoiceCard(selected: panelStyle == st) { panelStyle = st } content: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(st.title).font(.system(size: 13, weight: .semibold))
                                        Text(st.detail).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxHeight: .infinity, alignment: .top)
                                }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("下次查词时生效。").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
        }
    }
}

/// 8 种翻译语言，四个一排
struct TargetLanguageGrid: View {
    @Binding var target: TargetLanguage
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(TargetLanguage.allCases) { t in
                Button { target = t } label: {
                    Text(t.nativeName)
                        .font(.system(size: 13, weight: target == t ? .medium : .regular))
                        .foregroundStyle(target == t ? Theme.accent : Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(target == t ? Theme.accentSoft.opacity(0.5) : Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(target == t ? Theme.accent : Theme.borderStrong, lineWidth: target == t ? 1.5 : 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 快捷键与取词

struct ShortcutsSettingsPage: View {
    @AppStorage(TargetLanguage.key) private var target: TargetLanguage = .zhHans
    @AppStorage(AnalysisViewModel.hoverAutoSaveKey) private var hoverAutoSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            shortcutCard(title: "截图取词", detail: "框住屏幕上任何地方的词，AI 结合整句讲解，存进词库", prefs: .screenshot) {
                CaptureIllustration(target: target)
            }
            shortcutCard(title: "指词查词", detail: "鼠标指着视频字幕或网页里的词，按一下就弹出释义；默认只查不存", prefs: .hover) {
                PointIllustration(target: target)
            }
            SettingsGroup(title: "多按一个键", footer: "⌥ 不好按就换成 ⇧、⌃ 或 ⌘；选「不用」就没有这一组。") {
                SettingsRow(title: "截图取词时多按", detail: "只查不存，这一次不进词库") { ExtraModifierPicker(prefs: .screenshot) }
                Hairline()
                SettingsRow(title: "指词查词时多按", detail: "和下面的开关相反：开关关着就保存这一次") { ExtraModifierPicker(prefs: .hover) }
                Hairline()
                SettingsRow(title: "指词查词的词也加入词库") {
                    Toggle("", isOn: $hoverAutoSave).toggleStyle(.square).labelsHidden()
                }
            }
        }
    }

    private func shortcutCard<Demo: View>(title: LocalizedStringKey, detail: LocalizedStringKey, prefs: HotkeyPrefs,
                                          @ViewBuilder demo: () -> Demo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HotkeyKeyCaps(prefs: prefs)
            }
            demo()
        }
        .padding(14)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - AI 服务

struct AISettingsPage: View {
    @Bindable var viewModel: SettingsViewModel
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("截图里的词交给谁讲解。").font(.system(size: 13)).foregroundStyle(Theme.text2)
            HStack(spacing: 10) {
                ChoiceCard(selected: true) {} content: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("自带 Key").font(.system(size: 13.5, weight: .semibold))
                            Tag(text: "永久免费")
                        }
                        Text("你的 Key 直连服务商，费用走你的账户").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        AIRouteIllustration(provider: provider).frame(maxWidth: .infinity)
                    }
                }
                ChoiceCard(selected: false, disabled: true) {} content: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("会员").font(.system(size: 13.5, weight: .semibold))
                            Tag(text: "即将开放")
                        }
                        Text("不用申请 Key，用 GetNewWord 官方的 AI").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        HStack(spacing: 0) {
                            NodeBadge(icon: .app, label: "GetNewWord", width: 60)
                            FlowLine(active: false, width: 16)
                            NodeBadge(icon: .symbol("cloud"), label: String(localized: "官方 AI"), width: 60)
                            FlowLine(active: false, width: 16)
                            NodeBadge(icon: .symbol("sparkles"), label: String(localized: "讲解"), width: 60)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ProviderPicker(viewModel: viewModel, selected: $provider)
            Text("每家的 Key 分开存在钥匙串里，切换后立即生效。").font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
    }
}

// MARK: - 权限

struct PermissionsSettingsPage: View {
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("截图取词要读屏幕；这里看状态、补授权。").font(.system(size: 13)).foregroundStyle(Theme.text2)
            PermissionIllustration(granted: permissions.hasScreenRecording)
            if !permissions.hasScreenRecording {
                DragToGrantRow()
            }
            SettingsGroup(footer: "屏幕录制授权后要重开一次 GetNewWord 才生效。") {
                row(title: "屏幕录制", tag: "必需", detail: "截图取词时截下你框住的那一块",
                    granted: permissions.hasScreenRecording, pane: .screenRecording) { permissions.requestScreenRecording() }
            }
        }
        .onAppear { permissions.refresh() }
    }

    private func row(title: LocalizedStringKey, tag: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool,
                     pane: PermissionManager.Pane, request: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Tag(text: tag)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.ok)
                Button("系统设置") { permissions.openSettings(pane) }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
            } else {
                Button("去授权", action: request).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - 更新与关于

struct UpdatesSettingsPage: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppVariant.isDev ? "GetNewWord Dev" : "GetNewWord").font(.system(size: 16, weight: .semibold))
                    Text("版本 \(AppUpdater.currentVersion)").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    HStack(spacing: 6) {
                        Tag(text: "开源", filled: true)
                        Tag(text: "GPL-3.0-or-later")
                    }
                }
                Spacer()
                if let source = AppLinks.sourceCode {
                    Link("GitHub ↗", destination: source)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(16)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))

            MoveToApplicationsNotice()

            if updater.isAvailable {
                SettingsGroup(title: "更新", footer: "新版本从 GitHub Releases 下载，签名验证通过才安装。") {
                    SettingsRow(title: lastCheckText) {
                        Button("检查更新") { updater.checkForUpdates() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!updater.canCheckForUpdates)
                    }
                    Hairline()
                    SettingsRow(title: "自动检查更新", detail: "每天一次，在后台") {
                        Toggle("", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                            .toggleStyle(.square).labelsHidden()
                    }
                    Hairline()
                    SettingsRow(title: "自动下载并安装", detail: "下次打开就是新版") {
                        Toggle("", isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                            .toggleStyle(.square).labelsHidden()
                            .disabled(!updater.automaticallyChecks)
                    }
                }
            } else {
                Text("开发版不检查更新；正式版会每天自动检查。").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            }

            UsageGroup()
            PrivacyGroup()
        }
    }

    private var lastCheckText: LocalizedStringKey {
        if let t = updater.lastCheck {
            return "上次检查：\(t.formatted(date: .abbreviated, time: .shortened))"
        }
        return "还没检查过"
    }
}

/// 走完引导后也找得到的用法：快捷键跟着「快捷键与取词」里的设置走；下面能从头再看一遍引导
private struct UsageGroup: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AnalysisViewModel.hoverAutoSaveKey) private var hoverAutoSave = false
    @AppStorage(AppIcons.menuBarKey) private var menuBarIcon = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    var body: some View {
        SettingsGroup(title: "使用说明") {
            usage(HotkeyPrefs.screenshot.displayString, title: "截图取词", detail: "框住屏幕上的词或一段话，讲解完自动存进词库")
            Hairline()
            usage(HotkeyPrefs.hover.displayString, title: "指词查词",
                  detail: hoverAutoSave ? "鼠标指着词按一下，不用框选；查到的词也存进词库" : "鼠标指着词按一下，不用框选；只查不存")
            if let shot = Self.withExtra(.screenshot) {
                Hairline()
                usage(shot, title: "多按一个 \(HotkeyPrefs.screenshot.extra.symbol)", detail: "截图取词这一次只查不存")
            }
            if let hover = Self.withExtra(.hover) {
                Hairline()
                usage(hover, title: "多按一个 \(HotkeyPrefs.hover.extra.symbol)", detail: hoverAutoSave ? "指词查词这一次只查不存" : "指词查词这一次存进词库")
            }
            Hairline()
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template).foregroundStyle(Theme.text)
                    .frame(width: 28, height: 22)
                    .background(Theme.selected, in: RoundedRectangle(cornerRadius: 5))
                Text(menuBarIcon ? "GetNewWord 住在屏幕右上角的菜单栏里：点这个图标能打开主窗口和设置。"
                                 : "菜单栏图标关掉了：点 Dock 里的 GetNewWord 打开主窗口，⌘, 打开设置。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Hairline()
            SettingsRow(title: "重新看引导", detail: "从欢迎页再走一遍：界面语言、权限、AI、Anki、匿名统计和快捷键", icon: "arrow.counterclockwise") {
                Button("重新看引导") { restartOnboarding() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    /// 组合键再多按一个键（快捷键与取词里选的，默认 ⌥）的那一组；关掉了、本来就含这个键、和另一组撞了时没有这一组（HotkeyManager 不注册）
    private static func withExtra(_ prefs: HotkeyPrefs) -> String? {
        prefs.extraClashes ? nil : prefs.extraDisplayString
    }

    private func usage(_ combo: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            KeyCaps(combo: combo, size: 24)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 主窗口换回引导页（MainView 看 hasCompletedOnboarding），关掉挡在前面的设置窗口
    private func restartOnboarding() {
        AppLog.log("[Onboarding] restarted from settings")
        hasCompletedOnboarding = false
        NSApp.keyWindow?.close()
        openWindow(id: MainWindowOpener.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 查词时什么会发出去、发给谁（改了数据去向要同步改这里和官网隐私政策）
private struct PrivacyGroup: View {
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu
    @AppStorage(UsageConsent.key) private var usageConsent = ""

    var body: some View {
        SettingsGroup(title: "隐私与数据") {
            SettingsRow(title: "只在取词时截屏", detail: "截下框住的那一块（指词查词是光标附近），发给你选的 AI 服务商讲解，现在是 \(provider.displayName)。能认出字时只发附近几行文字，不发图。", icon: "camera.viewfinder")
            Hairline()
            SettingsRow(title: "词库存在这台 Mac 上", detail: "单词、语境和截图都在本机。登录同步时只同步词条和语境文字，截图和发音文件不上传。", icon: "internaldrive")
            Hairline()
            SettingsRow(title: "朗读", detail: "发音从有道词典下载，找不到时用 Wikimedia Commons 和 Google 的朗读，只发这个词。", icon: "speaker.wave.2")
            Hairline()
            SettingsRow(title: "匿名使用统计", detail: "我们会给前 100 位用户免费额度，所以需要统计有多少人在用。统计是匿名的。开着时每天发一次：随机编号、版本号、系统和芯片、用会员还是自带 Key、界面语言。不发查的词、词库、截图和 Key；关着什么都不发。", icon: "chart.bar") {
                Toggle("", isOn: Binding(get: { usageConsent == UsageConsent.yes.rawValue }, set: { UsageConsent.answer($0) }))
                    .toggleStyle(.square).labelsHidden()
            }
            Hairline()
            SettingsRow(title: "登录同步账号后", detail: "登录时报一次「登录」，之后每天报一次「打开」，记在同步用的账号下；不登录不报。", icon: "person.crop.circle")
            Hairline()
            SettingsRow(title: "隐私政策", detail: "官网上写得更全", icon: "hand.raised") {
                Button("打开") { NSWorkspace.shared.open(AppLinks.privacy) }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

// MARK: - 关于我们

struct AboutUsSettingsPage: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "官网") {
                row(icon: "globe", title: "软件官网", value: AppLinks.website.host() ?? "",
                    detail: "下载新版、看使用说明和隐私政策") {
                    Button("打开") { NSWorkspace.shared.open(AppLinks.website) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingsGroup(title: "联系方式") {
                row(icon: "envelope", title: "邮箱", value: AppLinks.email, detail: "用得不顺手、想要什么功能，都可以写信告诉我们。") {
                    Button("发邮件") { NSWorkspace.shared.open(AppLinks.mailto) }.buttonStyle(SecondaryButtonStyle())
                    Button(copied ? "已复制" : "复制") { copyEmail() }.buttonStyle(SecondaryButtonStyle())
                }
                Hairline()
                row(icon: "doc.text", title: "日志", value: (AppVariant.supportDirectory.path as NSString).abbreviatingWithTildeInPath,
                    detail: "报问题时把里面的 app.log 附在邮件里，我们能更快找到原因。日志不记 Key 和登录邮箱。") {
                    Button("打开日志文件夹") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.logFileURL]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func copyEmail() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppLinks.email, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// 标题 + 能选中复制的值（网址、邮箱）+ 右边按钮
    private func row<Buttons: View>(icon: String, title: LocalizedStringKey, value: String, detail: LocalizedStringKey?,
                                    @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(verbatim: value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) { buttons() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// 不在「应用程序」里时的提示和「移过去并重新打开」：「更新与关于」和欢迎页第一步共用
struct MoveToApplicationsNotice: View {
    @State private var moving = false
    @State private var error: String?

    var body: some View {
        if AppLocation.shouldOfferMove {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.system(size: 17)).foregroundStyle(Theme.warn)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("先把 GetNewWord 拖进「应用程序」").font(.system(size: 13, weight: .semibold))
                    Text("现在不是从「应用程序」文件夹打开的：自动更新装不上，以后会一直停在这一版。拖进去再打开，或者点右边的按钮。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(moving ? "正在移…" : "移过去并重新打开") { move() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(moving)
            }
            .padding(12)
            .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.warn.opacity(0.45), lineWidth: 0.5))
        }
    }

    private func move() {
        moving = true
        error = nil
        do {
            try AppLocation.moveToApplicationsAndRelaunch()
        } catch {
            AppLog.log("[Location] move failed: \(error)")
            self.error = String(localized: "没能移过去：\(error.localizedDescription)。可以自己把它拖进「应用程序」。")
            moving = false
        }
    }
}

/// 「把图标拖进系统设置的列表」：设置页和欢迎页的权限那一步共用
struct DragToGrantRow: View {
    var body: some View {
        HStack(spacing: 14) {
            DraggableAppIcon(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("把这个图标拖进系统设置的列表").font(.system(size: 13, weight: .medium))
                Text("点下面的「去授权」打开系统设置，把图标拖进「屏幕录制」的列表，开关会自动打开。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }
}
