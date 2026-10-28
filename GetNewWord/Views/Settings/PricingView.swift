// PricingView.swift
// GetNewWord
//
// 付费页（design/settings-v2 A2，照 Typefree）：免费试用 / 会员 / 自带 Key 三栏 + 常见问题。
// 收款和授权码服务还没上线：试用和会员两栏写「即将开放」，不放激活框；自带 Key 现在就能用。

import SwiftUI

struct PricingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsPage.key) private var settingsPage: SettingsPage = .general
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu

    private var hasKey: Bool { !(ZhipuService.shared.key(for: provider) ?? "").isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                        .frame(width: 24, height: 24).background(Theme.selected, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            VStack(spacing: 8) {
                Text("GetNewWord · 看到生词，框一下就懂").font(.system(size: 20, weight: .semibold))
                HStack(spacing: 8) {
                    Tag(text: "开源", filled: true)
                    Text("软件开源、永久免费；会员买的是不用配置的 AI 讲解").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    if let source = AppLinks.sourceCode {
                        Link("看源码 →", destination: source)
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                    }
                }
            }
            .padding(.bottom, 22)

            HStack(alignment: .top, spacing: 14) {
                column(title: "免费试用", tag: "新用户", price: "免费", unit: "· 7 天", subtitle: "下载就能用，什么都不用填",
                       features: ["截图取词、指词查词全都能用", "AI 讲解的费用我们出", "到期后转成下面两种之一"]) {
                    Button("即将开放") {}.buttonStyle(SecondaryButtonStyle()).disabled(true)
                }
                column(title: "会员", tag: "免配置", price: "即将开放", unit: "", subtitle: "不用申请任何 Key，装好就能用", highlighted: true,
                       features: ["截图讲解、指词查词、语法拆解全包", "多台 Mac 同步词库", "不用注册账号，授权码激活", "到期后仍可填自己的 Key 免费用"]) {
                    Button("即将开放") {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
                }
                column(title: "自带 Key", tag: "永久免费", price: "免费", unit: "· 不限时间", subtitle: "填你自己的 AI 服务 Key",
                       features: ["不限次数", "费用走你自己的账户", "智谱、DeepSeek、通义等 10 家可选"]) {
                    Button(hasKey ? "在用 · 去改 Key →" : "去填 Key →") {
                        settingsPage = .ai
                        dismiss()
                        openSettings()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                Text("常见问题").font(.system(size: 14, weight: .semibold)).padding(.bottom, 10)
                Grid(horizontalSpacing: 28, verticalSpacing: 0) {
                    GridRow(alignment: .top) {
                        faq("可以一直免费用吗？", "可以。软件开源，自带 Key 不限时间、不限次数。")
                        faq("会员和自带 Key 有什么区别？", "会员不用去各家申请 Key，费用我们出；自带 Key 费用走你自己的账户。")
                    }
                    GridRow(alignment: .top) {
                        faq("要注册账号吗？", "不用。查词、词库、Anki 都不用账号；只有多台 Mac 同步词库要登录，这是会员功能。")
                        faq("会员什么时候开放？", "收款和授权码服务在做，开放后这一页就能开通。现在可以先用自带 Key。")
                    }
                }
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 30)
        .padding(.top, 14)
        .padding(.bottom, 26)
        .frame(width: 790)
        .background(Theme.bg)
    }

    private func column<Action: View>(title: LocalizedStringKey, tag: LocalizedStringKey, price: LocalizedStringKey, unit: LocalizedStringKey,
                                      subtitle: LocalizedStringKey, highlighted: Bool = false, features: [LocalizedStringKey],
                                      @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Tag(text: tag, filled: highlighted)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price).font(.system(size: 24, weight: .bold))
                    Text(unit).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            action().frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(features.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).padding(.top, 3)
                        Text(f).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlighted ? Theme.text : Theme.border, lineWidth: highlighted ? 2 : 0.5))
    }

    private func faq(_ q: LocalizedStringKey, _ a: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Hairline()
            Text(q).font(.system(size: 12.5, weight: .medium)).padding(.top, 10)
            Text(a).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
