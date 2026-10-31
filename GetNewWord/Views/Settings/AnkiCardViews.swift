// AnkiCardViews.swift
// GetNewWord
//
// Anki 卡片相关的界面：设置里的「语境填空卡」选项、卡片升级的询问和设置页里的升级入口。
// 逻辑在 AnkiUpgrade.swift 和 AnkiService+Cards.swift。

import SwiftUI
import SwiftData

extension AnkiService.FillMode {
    var title: LocalizedStringKey {
        switch self {
        case .off: return "不加"
        case .frequent: return "查过 3 次以上的词"
        case .all: return "所有词"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .off: return "只有单词卡，卡片数不变"
        case .frequent: return "常碰到的词多一张填空卡"
        case .all: return "每个词都多一张，复习量翻倍"
        }
    }
}

/// 设置 › Anki：要不要给词加「语境填空」卡。选项改了就把已同步的词的 Fill 字段按新选项重写一遍
struct AnkiFillChoiceView: View {
    @AppStorage(AnkiService.FillMode.key) private var mode: AnkiService.FillMode = .off
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("语境填空卡").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2).padding(.leading, 2)
            HStack(spacing: 8) {
                ForEach(AnkiService.FillMode.allCases) { m in
                    ChoiceCard(selected: mode == m) { mode = m } content: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).font(.system(size: 13, weight: .semibold))
                            Text(m.detail).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("在最近遇到的那句话里把词挖掉，你想出来再翻面。也可以在词的右键菜单里只给某个词加。")
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: mode) { _, _ in
            let context = modelContext
            Task { await AnkiService.shared.applyFillChoice(context: context) }
        }
    }
}

/// 加字段前的询问。Anki 加了字段会要求下一次同步选「上传」，手机上没同步的复习记录会丢，所以先讲清楚
struct AnkiUpgradePromptView: View {
    var onContinue: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 22)).foregroundStyle(Theme.accent).frame(width: 40, height: 40)
                Text("升级 Anki 卡片").font(.system(size: 16, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("新卡片要在 Anki 里给两种笔记类型各加一个字段：知识卡的「问题」，单词卡的「语境填空」。")
                Text("加完以后 Anki 会要求下一次同步选「上传」。请先在手机上同步一次，再点「继续」；之后在电脑的 Anki 里同步时，选「上传」。")
                    .fontWeight(.medium)
                Text("如果你在 Anki 里自己改过这两种卡的模板，会被新模板覆盖。")
                    .foregroundStyle(Theme.text2)
                Text("点「以后再说」，卡片先保持现在的样子，这次启动里不再问；想升级时在 设置 → Anki 里点「升级卡片」。")
                    .foregroundStyle(Theme.text2)
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("以后再说", action: onLater).buttonStyle(SecondaryButtonStyle())
                Button("继续", action: onContinue).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bg)
    }
}

/// 主窗口上挂着：同步发现要加字段时弹出询问。主窗口没开就等到开了再弹，不抢用户正在看的东西
struct AnkiUpgradeSheetModifier: ViewModifier {
    /// 引导没走完、匿名统计的询问还在的时候不弹，免得两个窗口叠在一起
    var enabled: Bool
    @ObservedObject private var upgrade = AnkiUpgrade.shared
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { enabled && upgrade.promptVisible }, set: { upgrade.promptVisible = $0 })) {
            AnkiUpgradePromptView(
                onContinue: { upgrade.proceed(context: modelContext) },
                onLater: { upgrade.later() }
            )
        }
    }
}

/// 设置 › Anki 里的入口：字段还没加的时候显示，点「升级卡片」再弹一次询问
struct AnkiUpgradeRow: View {
    @ObservedObject private var upgrade = AnkiUpgrade.shared
    @State private var showPrompt = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if upgrade.structurePending {
            SettingsGroup(title: "卡片") {
                SettingsRow(title: "有新的卡片样式可以升级", detail: "要给 Anki 加两个字段，先在手机上同步一次") {
                    Button("升级卡片") { showPrompt = true }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .sheet(isPresented: $showPrompt) {
                AnkiUpgradePromptView(
                    onContinue: { showPrompt = false; upgrade.proceed(context: modelContext) },
                    onLater: { showPrompt = false; upgrade.later() }
                )
            }
        }
    }
}
