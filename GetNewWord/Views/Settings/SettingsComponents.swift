// SettingsComponents.swift
// GetNewWord
//
// 设置窗口、付费页、欢迎页共用的小部件（design/settings-v2 方向 A「侧栏图解」）：
// 白底分组卡片、设置行、示意图舞台、方角开关、黑底主按钮、键帽、方案卡。

import SwiftUI

/// 组名 + 白底卡片；行之间由调用方放 Hairline()（macOS 14 没有 Group(subviews:)）
struct SettingsGroup<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 一行：标题、说明、右边控件
struct SettingsRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.text2).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: LocalizedStringKey, detail: LocalizedStringKey? = nil, icon: String? = nil) {
        self.init(title: title, detail: detail, icon: icon) { EmptyView() }
    }
}

/// 示意图的底：surface 色、10 圆角，高度固定，动画不让布局跳
struct Stage<Content: View>: View {
    var height: CGFloat = 130
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// 方角开关（轨道 5、滑块 3）
struct SquareToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(configuration.isOn ? Theme.accent : Theme.borderStrong)
                        .frame(width: 32, height: 18)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == SquareToggleStyle {
    static var square: SquareToggleStyle { SquareToggleStyle() }
}

/// 实心主按钮：浅色黑底白字，深色白底黑字；一屏只放一个
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.text.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 描边次按钮
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(configuration.isPressed ? Theme.selected : Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong, lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// 键帽（⇧ ⌘ A），大的用在快捷键说明
struct KeyCap: View {
    let key: String
    var size: CGFloat = 38
    var body: some View {
        Text(key)
            .font(.system(size: size * 0.42, weight: .medium))
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1.5)
    }
}

/// 把 "⇧⌘A" 拆成键帽，中间加号
struct KeyCaps: View {
    let combo: String
    var size: CGFloat = 38
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.split(combo).enumerated()), id: \.offset) { i, k in
                if i > 0 { Text("+").font(.system(size: 11)).foregroundStyle(Theme.text3) }
                KeyCap(key: k, size: size)
            }
        }
    }
    /// 修饰符一个字一个键，剩下的整体是主键（如 F5、Space）
    static func split(_ s: String) -> [String] {
        let mods: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var keys = s.prefix { mods.contains($0) }.map(String.init)
        let rest = s.drop { mods.contains($0) }
        if !rest.isEmpty { keys.append(String(rest)) }
        return keys
    }
}

/// 小标签：必需 / 可选 / 永久免费
struct Tag: View {
    let text: LocalizedStringKey
    var filled = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(filled ? Theme.bg : Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(filled ? Theme.text : Theme.selected, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 可选卡片（界面语言、外观、翻译语言、AI 用法）
struct ChoiceCard<Content: View>: View {
    let selected: Bool
    var disabled = false
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(selected ? Theme.accentSoft.opacity(0.5) : Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : Theme.borderStrong, lineWidth: selected ? 2 : 0.5))
                .contentShape(Rectangle())
                .opacity(disabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - 方案卡（设置侧栏底部、主窗口侧栏底部）

/// 现在用的是哪种、还剩多少：会员（试用剩几次、今天剩几次、到期日、欠费）或自带 Key。点开是方案和价格
struct PlanCard: View {
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu
    @AppStorage(AIPlan.key) private var plan: AIPlan = .member
    @ObservedObject private var member = MemberService.shared

    private var hasKey: Bool { !(ZhipuService.shared.key(for: provider) ?? "").isEmpty }

    var body: some View {
        let card = content
        Button { PricingWindow.show() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if plan == .own, hasKey {
                        ProviderLogo(provider: provider, size: 13)
                    } else if card.warn {
                        Circle().fill(Theme.warn).frame(width: 7, height: 7)
                    } else if plan == .member {
                        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    Text(card.title).font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                    if let count = card.count {
                        Text(count).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(card.warn ? Theme.warn : Theme.text)
                            .monospacedDigit()
                    }
                }
                Text(card.detail)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(card.warn ? Theme.warn.opacity(0.6) : Theme.border, lineWidth: card.warn ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: (title: String, detail: String, count: String?, warn: Bool) {
        if plan == .own {
            return hasKey ? (String(localized: "自带 Key"), String(localized: "永久免费 · 想省事可看会员"), nil, false)
                          : (String(localized: "还没选 AI"), String(localized: "选一种用法才能查词"), nil, true)
        }
        return Self.memberContent(member.state)
    }

    /// 会员模式下卡片上写什么（单独拿出来，测试和会员页共用）
    static func memberContent(_ state: MemberState) -> (title: String, detail: String, count: String?, warn: Bool) {
        switch state {
        case .unavailable:
            return (String(localized: "会员"), String(localized: "开发版没连会员服务器"), nil, true)
        case .connecting:
            return (String(localized: "会员"), String(localized: "正在连接会员服务器…"), nil, false)
        case .offline:
            return (String(localized: "会员"), String(localized: "连不上会员服务器，联网后自动重试"), nil, true)
        case .trial(let left, let total):
            return (String(localized: "免费试用"), String(localized: "共 \(total) 次，用完可订阅或换自带 Key"), String(localized: "剩 \(left) 次"), false)
        case .trialUsedUp:
            return (String(localized: "试用用完了"), String(localized: "订阅会员接着用，或换自带 Key"), nil, true)
        case .trialClosed(let daily):
            return (String(localized: "没领到免费试用"),
                    daily ? String(localized: "注册那天的免费名额满了；可订阅或换自带 Key") : String(localized: "前 100 位的名额发完了；可订阅或换自带 Key"), nil, true)
        case .member(let until, let autoRenew, let expiring, let pastDue, let left, _):
            if pastDue { return (String(localized: "续费没扣成"), String(localized: "打开「管理订阅」换一张卡"), nil, true) }
            let count = left.map { String(localized: "今天剩 \($0)") }
            guard let until else { return (String(localized: "会员"), String(localized: "会员在用"), count, false) }
            if expiring { return (String(localized: "会员快到期了"), String(localized: "\(MemberText.day(until)) 到期，续买一段接着用"), count, true) }
            return (String(localized: "会员"), autoRenew ? String(localized: "自动续费 · 下次 \(MemberText.day(until))") : String(localized: "用到 \(MemberText.day(until))"), count, false)
        case .dailyLimit(let reset):
            return (String(localized: "今天的次数用完了"),
                    reset.map { String(localized: "\($0.formatted(date: .omitted, time: .shortened)) 恢复") } ?? String(localized: "北京时间早上 8 点恢复"), nil, true)
        case .paymentFailed:
            return (String(localized: "续费没扣成"), String(localized: "打开「管理订阅」换一张卡"), nil, true)
        case .ended:
            return (String(localized: "会员到期了"), String(localized: "续订或再买一段，或换自带 Key"), nil, true)
        }
    }
}
