// AccountSettingsView.swift
// GetNewWord
//
// 设置 → 账号与同步：不登录也能用全部查词功能；多台 Mac 之间同步词库是会员功能。
// 会员才能在这里登录 Google；登录后告诉会员后台这张授权对应哪个账号，后台去 Supabase 打开这个账号的同步。
// 已经登录、但这个账号没开通同步的：按原因写（不是会员 / 是会员但同步还没打开 / 授权绑的是别的账号 / 绑定出错），
// 付了钱的人不再被引去「开通会员」。本机词库照常。

import SwiftUI
import AuthenticationServices

/// 登录着、Supabase 不让这个账号同步时写什么
enum SyncNotice: Equatable {
    /// 不是会员：开通会员
    case notMember
    /// 是会员，后台的同步资格还没配好（/status 里没有 sync）：配好后自动打开
    case notReady
    /// 是会员，这张授权的同步绑的是别的账号：问要不要换成这个
    case linkedElsewhere(String)
    /// 是会员，正在打开（或后台推送还没到 Supabase）：给「重试」
    case opening
    /// 是会员，绑定出错了
    case failed(MemberError)

    static func of(isMember: Bool, sync: MemberStatus.Sync?, sessionEmail: String?, linkError: MemberError?) -> SyncNotice {
        guard isMember else { return .notMember }
        guard let sync else { return .notReady }
        if let linkError { return linkError.code == "not-ready" ? .notReady : .failed(linkError) }
        if sync.linked, let other = sync.email, !MemberService.sameEmail(other, sessionEmail) { return .linkedElsewhere(other) }
        return .opening
    }

    /// 别人的邮箱只露头一个字和域名：s…@gmail.com
    static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return email }
        return String(email[email.startIndex]) + "…" + email[at...]
    }

    var title: String {
        switch self {
        case .notMember: return String(localized: "这个账号还没开通同步")
        case .notReady: return String(localized: "会员已开通，同步还没开通")
        case .linkedElsewhere(let email): return String(localized: "这张授权的同步绑的是 \(Self.masked(email))")
        case .opening: return String(localized: "会员已开通，正在为这个账号打开同步")
        case .failed(let e):
            switch e.code {
            case "link-limit": return String(localized: "30 天里换绑太多次了")
            case "bad-supabase-token": return String(localized: "Google 登录过期了")
            default: return String(localized: "同步暂时打不开")
            }
        }
    }

    var detail: String {
        switch self {
        case .notMember: return String(localized: "多台 Mac 同步是会员功能，本机词库不受影响。成了会员以后几秒内自动开始同步，云端以前的词都还在。")
        case .notReady: return String(localized: "我们这边的同步服务还没配好，配好后自动打开，不用再买。本机词库不受影响。")
        case .linkedElsewhere: return String(localized: "换成这个账号？换了以后原来那个账号就不能用这张授权同步了。30 天里最多换 3 次。")
        case .opening: return String(localized: "一般几秒就好，云端以前的词都还在。一直没好就点「重试」。")
        case .failed(let e):
            switch e.code {
            case "link-limit": return String(localized: "一张授权 30 天里最多换 3 次同步账号，过几天再试。本机词库不受影响。")
            case "bad-supabase-token": return String(localized: "退出登录再用 Google 登录一次就好。")
            default: return String(localized: "同步服务暂时连不上，不是你的问题。过一会儿点「重试」。")
            }
        }
    }
}

struct AccountSettingsView: View {
    @ObservedObject private var auth = SupabaseAuth.shared
    @ObservedObject private var sync = CloudSyncService.shared
    @ObservedObject private var member = MemberService.shared
    @State private var confirmSignOut = false
    @State private var signInError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SyncIllustration(active: auth.session != nil && sync.access != .denied)

            if let session = auth.session {
                SettingsGroup(title: "账号") {
                    SettingsRow(title: "已登录", detail: LocalizedStringKey(session.email ?? session.userId)) {
                        Button("退出登录") { confirmSignOut = true }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                if sync.access == .denied {
                    SyncNoticeGroup(notice: SyncNotice.of(isMember: member.isMember, sync: member.status?.sync,
                                                          sessionEmail: session.email, linkError: member.currentLinkFailure),
                                    busy: member.linking || sync.isSyncing,
                                    onLink: { link(replacing: $0) },
                                    onSignOut: { confirmSignOut = true })
                } else {
                    SettingsGroup(title: "同步", footer: "本地保存后几秒内自动上传，另一台每分钟或回到前台时拉取。音频和截图文件不同步。") {
                        SettingsRow(title: "上次同步",
                                    detail: LocalizedStringKey(sync.lastSyncAt?.formatted(date: .abbreviated, time: .standard) ?? "—")) {
                            Button(sync.isSyncing ? String(localized: "同步中…") : String(localized: "立即同步")) { Task { await sync.syncNow() } }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(sync.isSyncing)
                        }
                        if !sync.lastResult.isEmpty {
                            Hairline()
                            Text(sync.lastResult).font(.system(size: 12)).foregroundStyle(Theme.text2)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }
                }
            } else if member.isMember {
                SettingsGroup(footer: "查词、词库、同步到 Anki 都不用账号；登录只为几台 Mac 用同一个词库。") {
                    SettingsRow(title: "会员可以多台 Mac 同步词库",
                                detail: "用 Google 登录，登录同一个账号的 Mac 自动同步单词、语境、知识片段和分类。") {
                        Button { signIn() } label: {
                            HStack(spacing: 6) {
                                if auth.isSigningIn { ProgressView().controlSize(.small) }
                                Label("用 Google 登录", systemImage: "person.crop.circle")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(auth.isSigningIn)
                    }
                    if let signInError {
                        Hairline()
                        Text(signInError).font(.system(size: 12)).foregroundStyle(Theme.warn)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
            } else {
                SettingsGroup {
                    SettingsRow(title: "多台 Mac 同步是会员功能",
                                detail: "本机词库不受影响：查词、词库、同步到 Anki 都不用账号。成了会员以后在这里用 Google 登录。") {
                        Button("开通会员") { PricingWindow.show() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .task { await member.refresh(maxAge: 30) }
        .confirmationDialog("退出登录？", isPresented: $confirmSignOut) {
            Button("退出登录", role: .destructive) {
                Task { await sync.signOut() }
            }
        } message: {
            Text("本机词库会保留，但不再与其他电脑同步。")
        }
    }

    /// 请会员后台把这张授权的同步绑到这个账号（或再推一次），然后马上问一次能不能同步
    private func link(replacing: Bool) {
        Task {
            await member.linkSync(replacing: replacing)
            sync.recheckAccess()
        }
    }

    /// 登录 Google → 这张授权没绑过（或绑的就是这个账号）就绑上 → 马上问一次能不能同步
    private func signIn() {
        signInError = nil
        Task {
            do {
                try await auth.signInWithGoogle()
                await member.linkSync()
                sync.recheckAccess()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return
            } catch {
                signInError = error.localizedDescription
            }
        }
    }
}

/// 这个账号现在不让同步时的那一组：按原因写，给对应的按钮；付了钱的不引去「开通会员」
struct SyncNoticeGroup: View {
    let notice: SyncNotice
    /// 正在绑定或正在同步：「重试」转圈、点不了
    var busy = false
    /// 请后台绑到这个账号；参数 = 是不是换掉原来绑的账号
    var onLink: (Bool) -> Void = { _ in }
    var onSignOut: () -> Void = {}

    var body: some View {
        SettingsGroup(title: "同步") {
            SettingsRow(title: LocalizedStringKey(notice.title), detail: LocalizedStringKey(notice.detail)) { action }
        }
    }

    @ViewBuilder private var action: some View {
        switch notice {
        case .notMember:
            Button("开通会员") { PricingWindow.show() }.buttonStyle(PrimaryButtonStyle())
        case .linkedElsewhere:
            Button("换成这个账号") { onLink(true) }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
        case .failed(let e) where e.code == "bad-supabase-token":
            Button("退出登录") { onSignOut() }.buttonStyle(SecondaryButtonStyle())
        case .failed(let e) where e.code == "link-limit":
            EmptyView()
        case .opening, .failed:
            Button { onLink(false) } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("重试")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(busy)
        case .notReady:
            EmptyView()
        }
    }
}
