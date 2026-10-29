// PricingView.swift
// GetNewWord
//
// 方案和价格（design/settings-v2 A2，照 Typefree）：免费试用 / 会员 / 自带 Key 三栏，下面授权码和常见问题。
// 会员一栏：月付、年付（刷卡自动续费），人民币另有微信一次买 1 个月 / 1 年（不自动续费）；点了在浏览器里付款，
// 这里每 3 秒问一次后台，付完马上变成会员。已经是会员的显示到期日、今天剩几次和「管理订阅」（Stripe 客户门户）。
// 单独一个窗口（PricingWindow）：设置侧栏的方案卡、主窗口侧栏、查词报错浮窗都从这里打开。

import SwiftUI
import AppKit

/// 方案和价格的窗口：同一时间只有一个，再打开就前置
@MainActor
enum PricingWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    static let size = NSSize(width: 840, height: 680)

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: PricingView(onClose: { PricingWindow.close() }).appAppearance())
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(size)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.title = String(localized: "方案和价格")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in
                if let o = PricingWindow.closeObserver { NotificationCenter.default.removeObserver(o) }
                PricingWindow.closeObserver = nil
                PricingWindow.window = nil
            }
        }
        AppLog.log("[Member] pricing opened")
    }

    static func close() { window?.close() }
}

struct PricingView: View {
    let onClose: () -> Void
    @ObservedObject private var member = MemberService.shared
    @AppStorage(AIPlan.key) private var plan: AIPlan = .member
    @AppStorage("apiProvider") private var provider: APIProvider = .zhipu
    @AppStorage("pricingPeriod") private var period = "month"
    @AppStorage("pricingCurrency") private var currency = Locale.current.language.languageCode?.identifier == "zh" ? "cny" : "usd"
    @State private var code = ""
    @State private var codeMessage: String?
    @State private var codeBusy = false
    @State private var actionError: MemberError?
    @State private var busy: String?

    private var hasKey: Bool { !(ZhipuService.shared.key(for: provider) ?? "").isEmpty }
    private var status: MemberStatus? { member.status }
    private var state: MemberState { member.state }

    var body: some View {
        VStack(spacing: 0) {
            // 关窗用左上角的红点；Esc 也能关
            Button("") { onClose() }.keyboardShortcut(.cancelAction).hidden().frame(height: 0)
            ScrollView {
                VStack(spacing: 0) {
                    hero.padding(.top, 36).padding(.bottom, 18)
                    banner
                    HStack(alignment: .top, spacing: 14) {
                        trialColumn
                        memberColumn
                        ownColumn
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    licenseRow.padding(.top, 18)
                    faq.padding(.top, 22)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 26)
            }
        }
        .frame(width: PricingWindow.size.width, height: PricingWindow.size.height)
        .background(Theme.bg)
        .tint(Theme.accent)
        .task { await member.refresh(maxAge: 30) }
        // 买了就是要用会员：自带 Key 的人付完款，换成会员用法
        .onChange(of: member.justPaid) { _, paid in
            if paid, plan == .own { plan = .member }
        }
    }

    // MARK: - 顶部

    private var hero: some View {
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
    }

    /// 付款中、刚付完、出错：三栏上面一条
    @ViewBuilder private var banner: some View {
        if member.justPaid {
            bannerRow(icon: "checkmark.circle.fill", color: Theme.ok, text: paidText) {
                Button("好") { member.justPaid = false }.buttonStyle(SecondaryButtonStyle())
            }
        } else if let p = member.purchase {
            bannerRow(icon: nil, color: Theme.text2, text: p.mode == "pass" ? String(localized: "在浏览器里付款，付完这里自动生效。微信付款到账可能要一两分钟。")
                                                                     : String(localized: "在浏览器里付款，付完这里自动生效。")) {
                Button("不等了") { member.cancelPurchase() }.buttonStyle(SecondaryButtonStyle())
            }
        } else if let e = actionError ?? member.notice {
            bannerRow(icon: "exclamationmark.circle.fill", color: Theme.warn, text: "\(MemberText.title(e))：\(MemberText.detail(e))") {
                if ["already-subscribed", "payment-failed"].contains(e.code) {
                    Button("管理订阅") { portal() }.buttonStyle(SecondaryButtonStyle())
                }
                Button("知道了") { actionError = nil; member.notice = nil }.buttonStyle(SecondaryButtonStyle())
            }
        } else if member.lastError != nil, status != nil {
            bannerRow(icon: "wifi.slash", color: Theme.text3, text: String(localized: "连不上会员服务器，下面是上次的状态。")) { EmptyView() }
        }
    }

    /// 付完款的那一句：自动续费的写下次扣款日，一次买的写用到哪天（今天的次数用完了也照样写）
    private var paidText: String {
        guard let s = status, s.isMember else { return String(localized: "付款成功，已经是会员了。") }
        let until = MemberStatus.date(s.autoRenew ? s.subscription?.periodEnd ?? s.memberUntil : s.memberUntil)
        return String(localized: "付款成功，已经是会员了。\(memberLine(until: until, autoRenew: s.autoRenew, pastDue: s.subscription?.status == "past_due"))")
    }

    private func bannerRow<Trailing: View>(icon: String?, color: Color, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).foregroundStyle(color)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
        .padding(.bottom, 14)
    }

    // MARK: - 免费试用

    private var trialColumn: some View {
        column(title: "免费试用", tag: "前 100 位新用户", price: "30 次", unit: "· 不过期", subtitle: "装好就能用，什么都不用填",
               features: ["截图取词、指词查词、语法拆解全能用", "不用注册，不用登录", "框一次词算一次，讲解和补全都在里面", "用完可以订阅，或填自己的 Key"]) {
            if plan == .own, member.isAvailable {
                Button("换成会员用法") { switchToMember() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button(trialButtonTitle) {}.buttonStyle(SecondaryButtonStyle()).disabled(true)
            }
        }
    }

    private var trialButtonTitle: String {
        switch state {
        case .unavailable: return String(localized: "开发版没连会员服务器")
        case .notClaimed: return String(localized: "第一次查词时领取")
        case .connecting: return String(localized: "正在领取…")
        case .offline: return String(localized: "连不上会员服务器")
        case .trial(let left, _): return String(localized: "试用中 · 剩 \(left) 次")
        case .trialUsedUp: return String(localized: "试用已用完")
        case .trialClosed(let miss): return miss == .full ? String(localized: "名额已发完，这台没领到") : String(localized: "这台没领到试用")
        case .member, .dailyLimit: return String(localized: "已是会员")
        case .paymentFailed, .ended: return (status?.trial.left ?? 0) > 0 ? String(localized: "试用剩 \(status?.trial.left ?? 0) 次") : String(localized: "试用已用完")
        }
    }

    // MARK: - 会员

    private var prices: MemberStatus.Prices {
        status?.prices ?? ["month": ["cny": 990, "usd": 199], "year": ["cny": 9900, "usd": 1990]]
    }
    private var pricesReady: Bool { status?.prices != nil }
    private var passReady: Bool { status?.passPrices?[period]?["cny"] != nil }

    private var priceText: String { MemberText.price(prices[period]?[currency] ?? 0, currency) }

    private var memberColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("会员").font(.system(size: 13.5, weight: .semibold))
                Tag(text: "推荐", filled: true)
                Tag(text: "免配置")
                Spacer(minLength: 0)
                Picker("", selection: $currency) {
                    Text(verbatim: "¥").tag("cny")
                    Text(verbatim: "$").tag("usd")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 74)
            }
            if case .member(let until, let autoRenew, let expiring, let pastDue, let left, let limit) = state {
                memberNow(until: until, autoRenew: autoRenew, expiring: expiring, pastDue: pastDue, left: left, limit: limit)
            } else if case .dailyLimit(let reset) = state {
                let autoRenew = status?.autoRenew ?? false
                memberNow(until: MemberStatus.date(autoRenew ? status?.subscription?.periodEnd ?? status?.memberUntil : status?.memberUntil),
                          autoRenew: autoRenew, expiring: status?.expiring ?? false, pastDue: false, left: 0, limit: status?.today?.limit, reset: reset)
            } else {
                buyArea
            }
            features([
                "每天最多 200 次，北京时间早上 8 点重置",
                "多台 Mac 同步词库（登录 Google）",
                "不用注册账号；授权码一个最多用在 2 台 Mac 上",
                currency == "cny" ? "刷卡按月、按年自动续费，随时取消；也能用微信一次买" : "刷卡按月、按年自动续费，随时取消",
            ])
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.text, lineWidth: 2))
    }

    /// 还不是会员：月付 / 年付、订阅按钮；人民币下面再给一次买
    private var buyArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $period) {
                Text("月付").tag("month")
                Text("年付").tag("year")
            }
            .pickerStyle(.segmented).labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(priceText).font(.system(size: 24, weight: .bold))
                    (period == "month" ? Text("· 每月，自动续费") : Text("· 每年，自动续费")).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                (period == "year" ? Text("年付约等于 10 个月的钱") : Text("不用申请任何 Key，买了就能用")).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            if state == .paymentFailed {
                // 续费没扣成（Stripe 还在重试）：再开一单后台也不收，换一张卡就恢复
                Text("上一期的续费没扣成，换一张卡就恢复，不用重新订阅。").font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                portalButton(pastDue: true)
            } else if member.isAvailable, status != nil, !pricesReady {
                Text("购买还没开通，过一阵再来；现在可以先用自带 Key。").font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button { buy(mode: "sub") } label: {
                    HStack(spacing: 6) {
                        if busy == "sub" { ProgressView().controlSize(.small) }
                        Text("订阅 · \(priceText)")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canBuy)
                if currency == "cny", passReady || status == nil {
                    passButton
                }
                if !member.isAvailable {
                    Text("开发版没连会员服务器，买不了").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
            }
        }
    }

    private var canBuy: Bool { member.isAvailable && member.purchase == nil && busy == nil }

    /// 微信一次买：跟着上面选的月付 / 年付，1 个月 ¥9.9、1 年 ¥99，不自动续费
    private var passButton: some View {
        let amount = status?.passPrices?[period]?["cny"] ?? (period == "month" ? 990 : 9900)
        return Button { buy(mode: "pass") } label: {
            HStack(spacing: 6) {
                if busy == "pass" { ProgressView().controlSize(.small) }
                period == "month" ? Text("微信一次买 1 个月 · \(MemberText.price(amount, "cny"))") : Text("微信一次买 1 年 · \(MemberText.price(amount, "cny"))")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!canBuy)
        .help("不自动续费；快到期时提醒你续买")
    }

    /// 已经是会员：到期日、今天剩几次、管理订阅；不会自动续费的给续买
    private func memberNow(until: Date?, autoRenew: Bool, expiring: Bool, pastDue: Bool, left: Int?, limit: Int?, reset: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                    Text("已是会员").font(.system(size: 22, weight: .bold))
                }
                Text(memberLine(until: until, autoRenew: autoRenew, pastDue: pastDue))
                    .font(.system(size: 12)).foregroundStyle(pastDue || expiring ? Theme.warn : Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let reset {
                    Text("今天的 \(limit ?? 200) 次用完了，\(reset.formatted(date: .omitted, time: .shortened)) 恢复")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                } else if let left, let limit {
                    Text("今天还能查 \(left) 次（每天 \(limit) 次）").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            if status?.subscription != nil {
                portalButton(pastDue: pastDue)
            }
            // 续费没扣成的（还在宽限里）：只给「管理订阅 · 换一张卡」，一次买、开订阅后台都不收
            if !autoRenew, !pastDue {
                // 一次买的、点了到期取消的：续买接在现在的会员后面，天数不白过。点了到期取消的订阅在「管理订阅」里续订
                let canPass = currency == "cny" && passReady
                let canSub = !canPass && status?.subscription == nil
                if canPass {
                    Picker("", selection: $period) {
                        Text("1 个月").tag("month")
                        Text("1 年").tag("year")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    passButton
                } else if canSub {
                    Button { buy(mode: "sub") } label: { Text("开自动续费 · \(priceText)").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!canBuy)
                }
                if expiring {
                    Group {
                        if canPass { Text("快到期了，续买一段接着用。") }
                        else if canSub { Text("快到期了，开自动续费接着用。") }
                        else { Text("快到期了，在「管理订阅」里续订就不会断。") }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private func portalButton(pastDue: Bool) -> some View {
        Button { portal() } label: {
            HStack(spacing: 6) {
                if busy == "portal" { ProgressView().controlSize(.small) }
                pastDue ? Text("管理订阅 · 换一张卡") : Text("管理订阅")
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(pastDue ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
        .disabled(busy != nil)
    }

    private func memberLine(until: Date?, autoRenew: Bool, pastDue: Bool) -> String {
        guard let until else { return String(localized: "会员在用") }
        if pastDue { return String(localized: "续费没扣成，\(MemberText.day(until)) 前换好卡就不会断。") }
        if autoRenew { return String(localized: "自动续费，下次扣款 \(MemberText.day(until))") }
        if status?.subscription?.cancelAtPeriodEnd == true { return String(localized: "已取消自动续费，用到 \(MemberText.day(until))") }
        return String(localized: "用到 \(MemberText.day(until))，不会自动续费")
    }

    // MARK: - 自带 Key

    private var ownColumn: some View {
        column(title: "自带 Key", tag: "永久免费", price: "免费", unit: "· 不限次数", subtitle: "填你自己的 AI 服务 Key",
               features: ["不限次数", "费用走你自己的账户", "智谱、DeepSeek、通义等 10 家可选", "查的词直接发给服务商，不经过我们"]) {
            Button(plan == .own ? (hasKey ? String(localized: "在用 · 去改 Key →") : String(localized: "去填 Key →")) : String(localized: "改用自带 Key →")) {
                plan = .own
                onClose()
                SettingsOpener.open(.ai)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: - 授权码

    private var licenseRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            (status?.code == nil ? Text("在别的电脑上买过？输入授权码") : Text("换一个授权码，或在另一台 Mac 上用"))
                .font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                TextField("GW-XXXX-XXXX-XXXX", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { activate() }
                Button("粘贴") {
                    code = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { activate() } label: {
                    HStack(spacing: 6) {
                        if codeBusy { ProgressView().controlSize(.small) }
                        Text("激活")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || codeBusy || !member.isAvailable)
            }
            if let codeMessage {
                Text(codeMessage).font(.system(size: 12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if let s = status, let myCode = s.code {
                HStack(spacing: 8) {
                    Text("这台 Mac 的授权码").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Text(myCode).font(.system(size: 12.5, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(myCode, forType: .string)
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Text("已用在 \(s.devices) 台电脑上，最多 \(s.maxDevices) 台").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    Spacer(minLength: 0)
                    if !s.trialOnly {
                        Button("解绑这台电脑") { unbind() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            .help("这台退回自己的免费试用（剩几次就几次），授权码留给别的电脑用")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }

    // MARK: - 常见问题

    private var faq: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("常见问题").font(.system(size: 14, weight: .semibold)).padding(.bottom, 10)
            Grid(horizontalSpacing: 28, verticalSpacing: 0) {
                GridRow(alignment: .top) {
                    faqItem("一次查词怎么算？", "框一个词或指一个词算一次：讲解、例句补全、拆语法都在这一次里，自动重试不另算。词库里点「补全」另算一次。")
                    faqItem("免费试用有多少？", "前 100 位新用户每人 30 次，不过期，不用注册。名额发完就没有了，这一栏会照实写。")
                }
                GridRow(alignment: .top) {
                    faqItem("怎么付钱、怎么取消？", "刷卡（人民币或美元）按月或按年自动续费，随时在「管理订阅」里取消，用到当期结束。人民币还能用微信一次买 1 个月或 1 年，不自动续费，快到期时提醒你续买。")
                    faqItem("会员和自带 Key 有什么区别？", "会员不用去各家申请 Key，费用我们出，每天最多 200 次；自带 Key 永久免费、不限次数，费用走你自己的账户。随时能换。")
                }
                GridRow(alignment: .top) {
                    faqItem("查的词会被存吗？", "会员的请求经我们的服务器转给 DeepSeek，只记次数和用量，不存查了什么。词库只在你的 Mac 上。")
                    faqItem("换电脑、多台 Mac 怎么办？", "授权码一个最多 2 台：新电脑上输授权码就行。多台 Mac 同步词库是会员功能，在「设置 › 账号与同步」登录 Google。")
                }
            }
        }
    }

    // MARK: - 部件

    private func column<Action: View>(title: LocalizedStringKey, tag: LocalizedStringKey, price: LocalizedStringKey, unit: LocalizedStringKey,
                                      subtitle: LocalizedStringKey, features: [LocalizedStringKey], @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Tag(text: tag)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price).font(.system(size: 24, weight: .bold))
                    Text(unit).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            action().frame(maxWidth: .infinity)
            self.features(features)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }

    private func features(_ list: [LocalizedStringKey]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).padding(.top, 3)
                    Text(f).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func faqItem(_ q: LocalizedStringKey, _ a: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Hairline()
            Text(q).font(.system(size: 12.5, weight: .medium)).padding(.top, 10)
            Text(a).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    private func switchToMember() {
        plan = .member
        Task { await member.refresh() }
    }

    private func buy(mode: String) {
        actionError = nil
        member.notice = nil
        busy = mode
        Task {
            defer { busy = nil }
            do {
                try await member.buy(plan: period, currency: mode == "pass" ? "cny" : currency, mode: mode)
            } catch {
                actionError = member.explain(error as? MemberError ?? .network)
            }
        }
    }

    private func portal() {
        actionError = nil
        member.notice = nil
        busy = "portal"
        Task {
            defer { busy = nil }
            do { try await member.openPortal() } catch { actionError = member.explain(error as? MemberError ?? .network) }
        }
    }

    private func activate() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !codeBusy else { return }
        codeBusy = true
        codeMessage = nil
        Task {
            defer { codeBusy = false }
            do {
                try await member.activate(code: value)
                code = ""
                if plan == .own { plan = .member }
                codeMessage = nil
            } catch {
                let e = member.explain(error as? MemberError ?? .network)
                codeMessage = "\(MemberText.title(e))：\(MemberText.detail(e))"
            }
        }
    }

    private func unbind() {
        Task {
            do { try await member.unbind() } catch { actionError = error as? MemberError ?? .network }
        }
    }
}

/// 两种按钮样式按条件换（会员欠费时「管理订阅」变成主按钮）
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
