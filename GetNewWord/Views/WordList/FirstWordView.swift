// FirstWordView.swift
// GetNewWord
//
// 空词库的主窗口（方向 A）：中栏和右栏合成一页「查第一个词」。
// 上面一块演示（一句真的德语，屏幕上有真字，框得到），下面三步清单：选一个 AI → 允许屏幕录制（把图标拖进系统设置）
// → 框住一个词。当前这步浅色底、黑色按钮，做完打勾变灰；前两步做完，第三步的「试一下」才亮。

import SwiftUI

struct FirstWordView: View {
    @Environment(\.fontScale) private var fs
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var permissions = PermissionManager.shared
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu
    @AppStorage(AnalysisViewModel.hoverAutoSaveKey) private var hoverAutoSave = false
    @AppStorage(AIPlan.key) private var plan: AIPlan = .member
    @ObservedObject private var member = MemberService.shared
    /// 第三步：框一个词
    let onTry: () -> Void

    @State private var hasKey = false
    /// 点过「打开系统设置」：行里浮出能拖的图标
    @State private var openedSystemSettings = false

    private let sentence = "Die Studie zeigt, dass die Nachhaltigkeit der Lieferketten deutlich zugenommen hat."
    private let demoWord = "Nachhaltigkeit"

    /// 会员：领到试用或已是会员；自带 Key：填好了 Key
    private var aiDone: Bool { plan == .member ? member.state.ready : hasKey }
    private var permDone: Bool { permissions.hasScreenRecording }
    private var ready: Bool { aiDone && permDone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                demo
                Text("查第一个词")
                    .font(Theme.font(22, .semibold, scale: fs))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 26)
                Text("做完下面三步，以后在网页、PDF 或视频字幕里看到生词，按一下快捷键框住它，讲解就存到这里。")
                    .font(Theme.font(13, scale: fs))
                    .foregroundStyle(Theme.text2)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                steps.padding(.top, 18)
                Text("Anki 可以以后再连：设置 › Anki。快捷键在 设置 › 快捷键与取词 里能改。")
                    .font(Theme.font(12, scale: fs))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: 708, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .onAppear { refresh() }
        // 去设置里选了 AI 回来、或系统设置里授权回来，清单跟着变
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        hasKey = !(ZhipuService.shared.key(for: provider) ?? "").isEmpty
        permissions.refresh()
    }

    // MARK: - 演示

    /// 一句真的德语，Nachhaltigkeit 浅浅标出来；下面是快捷键和一句话
    private var demo: some View {
        Stage(height: 196) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.system(size: 11))
                        Text("spiegel.de · 一篇关于供应链的报道").font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.text3)
                    Text(highlighted)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(width: 420, alignment: .leading)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

                HStack(spacing: 10) {
                    KeyCaps(combo: HotkeyPrefs.screenshot.displayString, size: 26)
                    Text("框住上面的 \(demoWord)")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
        }
    }

    private var highlighted: AttributedString {
        var a = AttributedString(sentence)
        if let r = a.range(of: demoWord) {
            a[r].foregroundColor = Theme.accent
            a[r].backgroundColor = Theme.accentSoft
            a[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }

    // MARK: - 三步

    private var steps: some View {
        VStack(spacing: 0) {
            step(1, current: !aiDone, done: aiDone,
                 title: "选一个 AI",
                 detail: aiDetail) {
                if !aiDone {
                    if plan == .member, member.isAvailable {
                        Button("看会员方案") { PricingWindow.show() }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("去选择") { openAISettings() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            Hairline()
            step(2, current: aiDone && !permDone, done: permDone,
                 title: "允许屏幕录制",
                 detail: permDone ? Text("已允许，截图取词可以用了")
                                  : Text("截图取词要看到屏幕上的字。打开系统设置，把 GetNewWord 的图标拖进列表。")) {
                if !permDone {
                    HStack(spacing: 10) {
                        if openedSystemSettings { DraggableAppIcon(size: 24) }
                        if aiDone {
                            Button("打开系统设置") { openPermissionSettings() }.buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button("打开系统设置") { openPermissionSettings() }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
            Hairline()
            step(3, current: ready, done: false,
                 title: "框住一个词",
                 detail: hotkeyHint) {
                if ready {
                    Button("在上面那句试一下") { onTry() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Text("先完成上面两步").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
        }
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var aiDetail: Text {
        if plan == .member {
            let card = PlanCard.memberContent(member.state)
            return Text(verbatim: [card.title, card.count, card.detail].compactMap { $0 }.joined(separator: " · "))
        }
        return aiDone ? Text("\(provider.displayName) · 自带 Key，永久免费")
                      : Text("讲解靠它。DeepSeek、通义、Kimi 等 10 家可选；自带 Key 永久免费。")
    }

    /// 第三步的说明：指词快捷键默认只看释义不存，设置里打开「加入词库」后反过来
    private var hotkeyHint: Text {
        let shot = HotkeyPrefs.screenshot.displayString
        let hover = HotkeyPrefs.hover.displayString
        return hoverAutoSave
            ? Text("在任何地方按 \(shot) 框词；指着词按 \(hover) 直接存进词库。")
            : Text("在任何地方按 \(shot) 框词；指着词按 \(hover) 只看释义不存。")
    }

    private func step<Action: View>(_ n: Int, current: Bool, done: Bool, title: LocalizedStringKey, detail: Text,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ok)
                } else if current {
                    Circle().fill(Theme.text)
                    Text("\(n)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.bg)
                } else {
                    Circle().stroke(Theme.borderStrong, lineWidth: 1.5)
                    Text("\(n)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.font(13, .medium, scale: fs))
                    .foregroundStyle(current ? Theme.text : Theme.text2)
                detail
                    .font(Theme.font(12, scale: fs))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 66)
        .background(current ? Theme.selected : .clear)
    }

    // MARK: - 动作

    /// 第 1 步：打开设置里的「AI 服务」那一页
    private func openAISettings() {
        UserDefaults.standard.set(SettingsPage.ai.rawValue, forKey: SettingsPage.key)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// 第 2 步：带去系统设置，旁边浮出能拖的图标；行里也放一个
    private func openPermissionSettings() {
        openedSystemSettings = true
        permissions.requestScreenRecording()
    }
}
