// SettingsView.swift
// GetNewWord
//
// 设置窗口（design/settings-v2 方向 A「侧栏图解」）：左侧九页，右侧每页先一张示意图，再是那一页的设置。
// 侧栏底部是方案卡；缺屏幕录制权限、还没填 Key 时，对应那一页亮一个点。

import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, translate, shortcuts, ai, anki, permissions, account, aboutUs, updates
    var id: String { rawValue }

    /// 别处（付费页、菜单）先写这个键再打开设置，就直接落到那一页
    static let key = "settingsPage"

    var title: LocalizedStringKey {
        switch self {
        case .general: return "通用"
        case .translate: return "翻译与学习"
        case .shortcuts: return "快捷键与取词"
        case .ai: return "AI 服务"
        case .anki: return "Anki"
        case .permissions: return "权限"
        case .account: return "账号与同步"
        case .aboutUs: return "关于我们"
        case .updates: return "更新与关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .translate: return "character.bubble"
        case .shortcuts: return "keyboard"
        case .ai: return "sparkles"
        case .anki: return "rectangle.stack"
        case .permissions: return "lock"
        case .account: return "icloud"
        case .aboutUs: return "person.2"
        case .updates: return "info.circle"
        }
    }
}

struct SettingsView: View {
    static let sidebarWidth: CGFloat = 210
    @AppStorage(SettingsPage.key) private var page: SettingsPage = .general
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu
    @ObservedObject private var permissions = PermissionManager.shared
    /// 整个设置窗口共用：切到别的页再回来，没验证完的 Key 还在
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                Text(page.title)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                Hairline()
                ScrollView {
                    // 里面的示意图有固定宽度，合计要小于 800 − 侧栏 − 边距 − 滚动条（「总是显示滚动条」时约 15）≈ 526，
                    // 超了会把整页推出窗口
                    pageContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(page)
            }
            .background(Theme.bg)
        }
        .frame(width: 800, height: 600)
        .tint(Theme.accent)
        .onAppear { permissions.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { p in
                Button { page = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol).font(.system(size: 13)).frame(width: 18)
                            .foregroundStyle(page == p ? Theme.text : Theme.text2)
                        Text(p.title).font(.system(size: 13))
                        Spacer()
                        if needsAttention(p) { Circle().fill(Theme.warn).frame(width: 6, height: 6) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(page == p ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            PlanCard()
        }
        .padding(10)
        .padding(.top, 8)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    private func needsAttention(_ p: SettingsPage) -> Bool {
        switch p {
        case .permissions: return !permissions.hasScreenRecording
        case .ai: return (ZhipuService.shared.key(for: provider) ?? "").isEmpty
        default: return false
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .translate: TranslateSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .ai: AISettingsPage(viewModel: viewModel)
        case .anki: AnkiSettingsView()
        case .permissions: PermissionsSettingsPage()
        case .account: AccountSettingsView()
        case .aboutUs: AboutUsSettingsPage()
        case .updates: UpdatesSettingsPage()
        }
    }
}

/// 从任何地方打开设置并落到某一页（报错面板这种 AppKit 浮窗里拿不到 SwiftUI 的 openSettings）
@MainActor
enum SettingsOpener {
    /// 菜单栏菜单出现时存下 SwiftUI 的打开动作
    static var action: OpenSettingsAction?

    static func open(_ page: SettingsPage? = nil) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: SettingsPage.key) }
        NSApp.activate(ignoringOtherApps: true)
        if let action { action(); return }
        // 退路：应用菜单里的「设置…」（⌘,），没有 Dock 图标时菜单也在
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            menu.performActionForItem(at: i)
        }
    }
}
