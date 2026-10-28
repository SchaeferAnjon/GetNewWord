// AnkiSetupView.swift
// GetNewWord
//
// Anki 安装清单（设置 → Anki 与引导第 3 步共用）：
// ① Anki 桌面版 ② AnkiConnect 插件 ③ 连接，每步可一键完成，底下附手动步骤

import SwiftUI
import AppKit

struct AnkiSetupView: View {
    enum Style { case form, card }
    var style: Style = .form

    @State private var installer = AnkiInstaller.shared
    @State private var showHelp = false

    var body: some View {
        Group {
            if style == .card {
                VStack(spacing: 0) {
                    ankiRow.padding(rowPadding)
                    Divider()
                    pluginRow.padding(rowPadding)
                    Divider()
                    connectRow.padding(rowPadding)
                    Divider()
                    help.padding(rowPadding)
                }
                .background(Theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            } else {
                ankiRow
                pluginRow
                connectRow
                help
            }
        }
        .task { await installer.refresh() }
        // 从 Anki 切回来时重新检测（用户可能刚手动装好）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await installer.refresh() }
        }
    }

    private var rowPadding: EdgeInsets { EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14) }

    // MARK: - ① Anki 桌面版

    private var ankiRow: some View {
        let installed = installer.ankiApp != nil
        return row(1, done: installed, title: "Anki 桌面版",
                   detail: installed ? String(localized: "已安装 \(installer.ankiVersion ?? "")") : String(localized: "免费的记忆卡片软件，安装包约 230 MB")) {
            if !installed {
                phaseControl(installer.ankiPhase, action: "一键安装") { Task { await installer.installAnki() } }
            }
        }
    }

    // MARK: - ② AnkiConnect 插件

    private var pluginRow: some View {
        row(2, done: installer.pluginInstalled, title: "AnkiConnect 插件",
            detail: installer.pluginInstalled ? String(localized: "已安装") : String(localized: "让 GetNewWord 能把卡片写进 Anki，代码 \(AnkiInstaller.pluginCode)")) {
            if !installer.pluginInstalled {
                phaseControl(installer.pluginPhase, action: "一键安装") { Task { await installer.installPlugin() } }
                    .disabled(installer.ankiApp == nil)
                    .help(installer.ankiApp == nil ? String(localized: "先装好 Anki") : "")
            }
        }
    }

    // MARK: - ③ 连接

    private var connectRow: some View {
        let detail: String = {
            if installer.connected { return String(localized: "已连接，可以同步卡片了") }
            if installer.restarting { return String(localized: "正在打开 Anki，等插件加载…") }
            if installer.restartBlocked { return String(localized: "Anki 里有对话框没关，退不出去。先在 Anki 里关掉它，再点「重启 Anki」") }
            if installer.ankiApp == nil { return String(localized: "先装好 Anki 和插件") }
            if !installer.pluginInstalled { return String(localized: "先装好插件") }
            if installer.ankiRunning { return String(localized: "Anki 开着但连不上：刚装的插件要重启 Anki 才生效") }
            return String(localized: "Anki 没有打开")
        }()
        return row(3, done: installer.connected, title: "连接 Anki", detail: detail) {
            if installer.restarting || installer.checking {
                ProgressView().controlSize(.small)
            } else if !installer.connected, installer.ankiApp != nil, installer.pluginInstalled {
                Button(installer.ankiRunning ? "重启 Anki" : "打开 Anki") { Task { await installer.restartAnki() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("检测") { Task { await installer.refresh() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(installer.checking || installer.restarting)
        }
    }

    // MARK: - 手动步骤

    private var help: some View {
        DisclosureGroup(isExpanded: $showHelp) {
            VStack(alignment: .leading, spacing: 8) {
                helpStep("1", "打开 apps.ankiweb.net 下载 Mac 版 Anki，把 Anki 拖进「应用程序」，打开一次。")
                helpStep("2", "在 Anki 菜单栏选「工具 → 插件 → 获取插件…」，粘贴代码 \(AnkiInstaller.pluginCode)，点「确定」。")
                helpStep("3", "退出并重新打开 Anki，回到这里点「检测」。")
                helpStep("4", "之后用 GetNewWord 时保持 Anki 开着，卡片会自动同步。")
                HStack(spacing: 14) {
                    Link("Anki 官网 ↗", destination: AnkiInstaller.manualDownloadPage)
                    Link("插件页面 ↗", destination: AnkiInstaller.pluginPage)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AnkiInstaller.pluginCode, forType: .string)
                    } label: {
                        Label("复制插件代码", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.top, 2)
            }
            .padding(.top, 6)
        } label: {
            Label("想自己动手装？查看手动步骤", systemImage: "questionmark.circle")
                .foregroundStyle(Theme.text2)
        }
    }

    private func helpStep(_ n: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n).font(.caption.weight(.semibold)).foregroundStyle(Theme.text3).frame(width: 12)
            Text(text).font(.caption).foregroundStyle(Theme.text2).textSelection(.enabled)
        }
    }

    // MARK: - 行与安装进度

    private func row<Trailing: View>(_ n: Int, done: Bool, title: LocalizedStringKey, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.ok)
                } else {
                    Circle().stroke(Theme.borderStrong, lineWidth: 1.5)
                    Text("\(n)").font(.caption).foregroundStyle(Theme.text2)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(Theme.text2)
            }
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func phaseControl(_ phase: AnkiInstaller.Phase, action: LocalizedStringKey, start: @escaping () -> Void) -> some View {
        switch phase {
        case .idle:
            Button(action, action: start).buttonStyle(PrimaryButtonStyle())
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 90)
                Text("下载中 \(Int(p * 100))%").font(.caption).foregroundStyle(Theme.text2).monospacedDigit()
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在安装").font(.caption).foregroundStyle(Theme.text2)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(Theme.danger).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
                Button("重试", action: start).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
