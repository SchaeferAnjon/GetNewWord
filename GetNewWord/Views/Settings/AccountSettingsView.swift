// AccountSettingsView.swift
// GetNewWord
//
// 设置 → 账号与同步：不登录也能用全部查词功能；多台 Mac 之间同步词库是会员功能。
// 会员开放前，没登录的人在这里登录不了；已经登录的电脑照常同步。

import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject private var auth = SupabaseAuth.shared
    @ObservedObject private var sync = CloudSyncService.shared
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SyncIllustration(active: auth.session != nil)

            if let session = auth.session {
                SettingsGroup(title: "账号") {
                    SettingsRow(title: "已登录", detail: LocalizedStringKey(session.email ?? session.userId)) {
                        Button("退出登录") { confirmSignOut = true }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                SettingsGroup(title: "同步", footer: "本地保存后几秒内自动上传，另一台每分钟或回到前台时拉取。音频和截图文件不同步。") {
                    SettingsRow(title: "上次同步",
                                detail: LocalizedStringKey(sync.lastSyncAt?.formatted(date: .abbreviated, time: .standard) ?? "—")) {
                        Button(sync.isSyncing ? "同步中…" : "立即同步") { Task { await sync.syncNow() } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(sync.isSyncing)
                    }
                    if !sync.lastResult.isEmpty {
                        Hairline()
                        Text(sync.lastResult).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
            } else {
                SettingsGroup {
                    SettingsRow(title: "不登录也能用全部查词功能",
                                detail: "查词、词库、同步到 Anki 都不用账号。多台 Mac 之间同步词库是会员功能，会员开放后在这里登录。") {
                        Button {} label: {
                            Label("用 Google 登录", systemImage: "person.crop.circle")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(true)
                    }
                }
            }
        }
        .confirmationDialog("退出登录？", isPresented: $confirmSignOut) {
            Button("退出登录", role: .destructive) {
                Task { await sync.signOut() }
            }
        } message: {
            Text("本机词库会保留，但不再与其他电脑同步。")
        }
    }
}
