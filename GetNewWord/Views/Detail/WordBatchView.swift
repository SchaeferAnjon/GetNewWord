// WordBatchView.swift
// GetNewWord
//
// 多选单词时右栏的批量操作面板：归入分类 / 同步 Anki / 朗读 / 删除（和设置页同一种白底分组）

import SwiftUI
import SwiftData

struct WordBatchView: View {
    @Environment(\.fontScale) private var fs
    let words: [WordEntry]
    var onDone: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor<Category>(\.name)])
    private var categories: [Category]

    @State private var showDeleteConfirm = false
    @State private var isSyncing = false

    private var languageCategories: [Category] {
        categories.filter { $0.parent?.name == "语言学习" }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 头部
            VStack(alignment: .leading, spacing: 4) {
                Text("已选中 \(words.count) 个单词")
                    .font(Theme.font(22, .semibold, scale: fs))
                    .foregroundStyle(Theme.text)
                Text(words.prefix(8).map { $0.word }.joined(separator: "、") + (words.count > 8 ? " …" : ""))
                    .font(Theme.font(13, scale: fs))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(2)
            }

            SettingsGroup {
                SettingsRow(title: "归入分类", icon: "folder") {
                    Menu {
                        ForEach(languageCategories, id: \.id) { cat in
                            Button("\(cat.parent?.displayName ?? "") › \(cat.displayName)") { assignAll(to: cat) }
                        }
                        Divider()
                        Button("未分组") { assignAll(to: nil) }
                    } label: {
                        Text("选择分类…")
                    }
                    .fixedSize()
                }
                Hairline()
                SettingsRow(title: "同步到 Anki", detail: "把这 \(words.count) 个词推给 Anki", icon: "arrow.triangle.2.circlepath") {
                    Button(isSyncing ? "同步中…" : "同步") {
                        Task {
                            isSyncing = true
                            for w in words { w.syncStatus = .notSynced }
                            try? modelContext.save()
                            await AnkiService.shared.syncAllPendingWords(words, context: modelContext)
                            isSyncing = false
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isSyncing)
                }
                Hairline()
                SettingsRow(title: "依次朗读", icon: "speaker.wave.2") {
                    Button("朗读") {
                        Task { @MainActor in
                            for w in words {
                                AudioService.shared.speak(w.word, language: w.language)
                                try? await Task.sleep(for: .seconds(1.6))
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Hairline()
                SettingsRow(title: "删除", detail: "连同各自的语境一起删除", icon: "trash") {
                    Button("删除这 \(words.count) 个单词…", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .foregroundStyle(Theme.danger)
                }
            }

            Text("提示：列表里按住拖动可连选，⌘ 点选、⇧ 范围选，⌘A 全选")
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text3)

            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .alert("删除 \(words.count) 个单词？", isPresented: $showDeleteConfirm) {
            Button("删除（含 Anki 卡）", role: .destructive) {
                let ids = words.compactMap { $0.ankiNoteId }   // 先取，再删实体
                Task { await AnkiService.shared.deleteAnkiNotes(ids: ids) }
                for w in words { modelContext.delete(w) }
                try? modelContext.save()
                onDone?()
            }
            Button("仅本地删除", role: .destructive) {
                for w in words { modelContext.delete(w) }
                try? modelContext.save()
                onDone?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("连同各自的语境一起删除，不可撤销。「仅本地」保留 Anki 里的卡和复习进度。")
        }
    }

    private func assignAll(to cat: Category?) {
        for w in words {
            w.category = cat
            w.syncStatus = .notSynced
        }
        try? modelContext.save()
        AppLog.log("[Batch] assigned \(words.count) words to '\(cat?.name ?? "未分组")'")
    }
}
