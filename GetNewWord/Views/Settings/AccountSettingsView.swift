// AccountSettingsView.swift
// GetNewWord
//
// 设置 → 账号与同步：不登录也能用全部查词功能；多台 Mac 之间同步词库是会员功能。
// 会员才能在这里登录 Google；登录后告诉会员后台这张授权对应哪个账号，后台去 Supabase 打开这个账号的同步。
// 已经登录、但这个账号没开通同步的（不是会员、会员到期）：不拉不推，本机词库照常，写明原因。

import SwiftUI
import AuthenticationServices

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
                    SettingsGroup(title: "同步") {
                        SettingsRow(title: "这个账号还没开通同步",
                                    detail: "多台 Mac 同步是会员功能，本机词库不受影响。成了会员以后几秒内自动开始同步，云端以前的词都还在。") {
                            Button("开通会员") { PricingWindow.show() }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
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

    /// 登录 Google → 告诉会员后台绑这个账号 → 马上问一次能不能同步
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
