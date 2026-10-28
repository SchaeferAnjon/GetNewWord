// AnkiSettingsView.swift
// GetNewWord
//
// Anki 集成设置视图：连接状态、牌组管理、同步控制

import SwiftUI
import SwiftData

struct AnkiSettingsView: View {
    @State private var isConnected = false
    @State private var isSyncing = false
    @State private var deckNames: [String] = []
    @State private var syncedCount = 0
    @State private var pendingCount = 0
    @State private var failedCount = 0
    @State private var statusMessage = ""
    @State private var isInitializingDecks = false

    @Environment(\.modelContext) private var modelContext

    private var ankiService: AnkiService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AnkiLinkIllustration(connected: isConnected)

            // 没连上时先教用户装 Anki 和插件
            if !isConnected {
                AnkiSetupView(style: .card)
            } else {
                SettingsGroup(title: "同步") {
                    HStack(spacing: 24) {
                        statItem(title: "已同步", value: syncedCount, color: Theme.ok)
                        statItem(title: "待同步", value: pendingCount, color: Theme.warn)
                        statItem(title: "失败", value: failedCount, color: Theme.danger)
                    }
                    .padding(12)
                    Hairline()
                    SettingsRow(title: "把还没同步的词推到 Anki") {
                        Button(isSyncing ? "同步中…" : "立即同步") { Task { await syncAll() } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isSyncing)
                    }
                }

                SettingsGroup(title: "牌组") {
                    if deckNames.isEmpty {
                        SettingsRow(title: "暂无牌组")
                    } else {
                        ForEach(deckNames, id: \.self) { name in
                            HStack(spacing: 8) {
                                Image(systemName: deckIcon(for: name)).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 16)
                                Text(name).font(.system(size: 12.5))
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                    Hairline()
                    HStack {
                        Button {
                            Task { await initializeDecks() }
                        } label: {
                            Text(isInitializingDecks ? "初始化中…" : "初始化牌组结构")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isInitializingDecks || isSyncing)
                        Spacer()
                        Button("刷新牌组列表") { Task { await loadDeckNames() } }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    .padding(12)
                }

                SettingsGroup(title: "内容治理") {
                    SettingsRow(title: "分析臃肿情况", detail: "找出可归档、可合并、太简单的卡片") {
                        Button("分析") { Task { await analyzeDeclutter() } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isSyncing)
                    }
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .task {
            await testConnection()
        }
        .onChange(of: AnkiInstaller.shared.connected) { _, connected in
            if connected { Task { await testConnection() } }
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func statItem(title: LocalizedStringKey, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 连接

    private func testConnection() async {
        statusMessage = String(localized: "正在检测连接…")
        let running = await ankiService.isAnkiRunning()
        isConnected = running
        statusMessage = running ? String(localized: "Anki 连接正常") : String(localized: "无法连接到 Anki，请确认 Anki 已启动")
        if running {
            await loadDeckNames()
            await loadSyncStats()
        }
    }

    // MARK: - 牌组

    private func loadDeckNames() async {
        do {
            let names = try await ankiService.deckNames()
            await MainActor.run {
                deckNames = names.sorted()
            }
        } catch {
            await MainActor.run {
                deckNames = []
                statusMessage = String(localized: "获取牌组列表失败：\(error.localizedDescription)")
            }
        }
    }

    private func initializeDecks() async {
        isInitializingDecks = true
        statusMessage = String(localized: "正在初始化牌组结构…")
        do {
            try await ankiService.initializeDeckStructure()
            await loadDeckNames()
            await MainActor.run {
                statusMessage = String(localized: "牌组结构初始化完成")
            }
        } catch {
            await MainActor.run {
                statusMessage = String(localized: "初始化失败：\(error.localizedDescription)")
            }
        }
        isInitializingDecks = false
    }

    // MARK: - 同步

    private func loadSyncStats() async {
        let descriptor = FetchDescriptor<WordEntry>()
        let allWords = (try? modelContext.fetch(descriptor)) ?? []
        await MainActor.run {
            syncedCount = allWords.filter { $0.syncStatus == .synced }.count
            pendingCount = allWords.filter { $0.syncStatus == .notSynced }.count
            failedCount = allWords.filter { $0.syncStatus == .syncFailed }.count
        }
    }

    @MainActor
    private func syncAll() async {
        isSyncing = true
        statusMessage = String(localized: "正在同步…")

        let descriptor = FetchDescriptor<WordEntry>()
        let allWords = (try? modelContext.fetch(descriptor)) ?? []
        let pendingWords = allWords.filter {
            $0.syncStatus == .notSynced || $0.syncStatus == .syncFailed
        }

        await ankiService.syncAllPendingWords(pendingWords, context: modelContext)

        await loadSyncStats()
        isSyncing = false
        statusMessage = String(localized: "同步完成")
    }

    // MARK: - 内容治理

    private func analyzeDeclutter() async {
        let descriptor = FetchDescriptor<WordEntry>()
        let allWords = (try? modelContext.fetch(descriptor)) ?? []
        let suggestions = ankiService.getDeclutterSuggestions(words: allWords, context: modelContext)

        await MainActor.run {
            var lines: [String] = []
            lines.append(String(localized: "总卡片数：\(suggestions.totalCards)"))
            lines.append(String(localized: "建议减少：\(suggestions.suggestedReduction)"))
            if !suggestions.archivableWords.isEmpty {
                lines.append(String(localized: "可归档：\(suggestions.archivableWords.count) 个单词"))
            }
            if !suggestions.mergeablePairs.isEmpty {
                lines.append(String(localized: "可合并：\(suggestions.mergeablePairs.count) 对近义词"))
            }
            if !suggestions.removableWords.isEmpty {
                lines.append(String(localized: "可移除：\(suggestions.removableWords.count) 个简单词"))
            }
            statusMessage = lines.joined(separator: "\n")
        }
    }

    // MARK: - 辅助

    private func deckIcon(for name: String) -> String {
        if name.contains("/") && !name.hasSuffix("/") {
            return "folder.fill"
        }
        if name.contains("语言") || name.contains("德语") || name.contains("英语") {
            return "globe"
        }
        if name.contains("知识") {
            return "book.closed"
        }
        return "folder"
    }
}
