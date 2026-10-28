// UsageConsentViews.swift
// GetNewWord
//
// 匿名使用统计的询问（UsagePing.swift；文案照会议字幕 shared/consent.js 的中文原文，换成本软件的名字和它会发的内容）。
// 欢迎引导里的那一步和主窗口的询问共用这段正文。「同意」「不用了」一样大、一样的样式，都不预先选中，回车不替人选。

import SwiftUI

struct UsageConsentBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我们会给前 100 位用户免费额度，所以需要统计有多少人在用。统计是匿名的。")
                .font(.system(size: 13, weight: .medium))
            Text("同意后，GetNewWord 每天会发给我们一次：")
            VStack(alignment: .leading, spacing: 6) {
                bullet("一个随机编号：只用来数人数，是装软件时随机生成的，跟你的名字、邮箱和电脑硬件都没有关系")
                bullet("版本号，用的是 Mac 还是 Windows、什么芯片")
                bullet("用会员还是自带 Key，界面是什么语言")
            }
            Text("不会发你查的词、词库、截图和你的 Key，也不记你的 IP 地址。")
            Text("不同意也能用全部功能。以后随时可以在 设置 → 更新与关于 → 匿名使用统计 里改。")
                .foregroundStyle(Theme.text2)
        }
        .font(.system(size: 12.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•").foregroundStyle(Theme.text3)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 两个一样的按钮，点哪个都记下来（UsageConsent.answer），然后交给调用方往下走
struct UsageConsentButtons: View {
    var answered: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            button("同意", agree: true)
            button("不用了", agree: false)
        }
    }

    private func button(_ title: LocalizedStringKey, agree: Bool) -> some View {
        Button {
            UsageConsent.answer(agree)
            answered()
        } label: {
            Text(title).frame(minWidth: 96)
        }
        .buttonStyle(ConsentButtonStyle())
    }
}

/// 比 SecondaryButtonStyle 大一号的描边按钮：两个按钮都用它，没有哪个是主按钮
private struct ConsentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(configuration.isPressed ? Theme.selected : Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong, lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

/// 主窗口问一次：1.2.0 以前装的人更新后第一次打开主窗口时，和引导里没答那一步的人。
/// 点了任何一个按钮就记成 yes / no，以后不再问；按 Esc、点外面关不掉。没点就退出的，下次打开主窗口还问（一直是「没问过」，不发）
struct UsageConsentSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                Text("帮我们知道有多少人在用 GetNewWord？").font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            UsageConsentBody()
            HStack {
                Spacer()
                UsageConsentButtons()
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.bg)
        .interactiveDismissDisabled()
    }
}
