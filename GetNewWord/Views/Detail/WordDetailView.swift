// WordDetailView.swift
// GetNewWord
//
// 单词详情（方向 A）：词头 + 朗读，右上三个图标（重新讲解 / 编辑 / 更多）→ 音标和两个灰标签、语法行
// → 「在这句里遇到」一块（原句高亮、译文、当时的截图；遇到几次就有几个页签）
// → 释义 / 用法 / 搭配 / 例句 / 构词和来历 → 最底下一行 Anki 牌组、复习次数、第一次遇到的时间。
// 支持就地编辑（铅笔 / ⌘E）：模型偶尔写错释义，直接改，不用删了重截。

import SwiftUI
import SwiftData
import AppKit

struct WordDetailView: View {
    @Environment(\.fontScale) private var fs
    let word: WordEntry
    var onDelete: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var actions = WordActions.shared
    @State private var showDeleteConfirm = false
    @State private var isSpeaking = false
    @State private var isEditing = false
    /// 「在这句里遇到」当前看第几次（从 0 数）
    @State private var ctxIndex = 0
    /// 「在这句里遇到」那块的宽度：窄窗口里缩略图放到文字下面
    @State private var cardWidth: CGFloat = 0

    // 编辑草稿
    @State private var dWord = ""
    @State private var dPhonetic = ""
    @State private var dGrammar = ""
    @State private var dMeaning = ""
    @State private var dNote = ""
    @State private var dContexts: [UUID: (String, String)] = [:]

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !word.sortedContexts.isEmpty { contextCard.padding(.top, 20) }
                VStack(alignment: .leading, spacing: 22) {
                    meaning
                    if isEditing || !word.analysisNote.isEmpty { analysis }
                    if !isEditing { aiExtras }
                }
                .padding(.top, 22)
                footer
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 792, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(Self.top)   // 整块内容（连顶上的留白）的顶
        }
        // 换词时不整个重建（.id 换掉会把滚动视图连同里面的一切拆了重搭，按住 ↓ 时跟不上），
        // 只把这个词自己的状态清掉、回到顶上
        .onChange(of: word.id) { _, _ in
            isEditing = false
            ctxIndex = 0
            isSpeaking = false
            // 等新词的内容排好再滚：同一轮里滚，排版时又按旧的位置放回去了
            DispatchQueue.main.async { proxy.scrollTo(Self.top, anchor: .top) }
        }
        }
        .background(Theme.bg)
        // ⌘⌫ 删除；编辑时让出给输入框（⌘⌫ 在输入框里是删到行首）
        .background {
            if !isEditing {
                Button("") { showDeleteConfirm = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .hidden()
            }
        }
        .alert("删除「\(word.word)」？", isPresented: $showDeleteConfirm) {
            Button("删除（含 Anki 卡）", role: .destructive) {
                let ids = [word.ankiNoteId].compactMap { $0 }   // 先取，再删实体
                Task { await AnkiService.shared.deleteAnkiNotes(ids: ids) }
                modelContext.delete(word)
                try? modelContext.save()
                onDelete?()
            }
            Button("仅本地删除", role: .destructive) {
                modelContext.delete(word)
                try? modelContext.save()
                onDelete?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("连同它的 \(word.sortedContexts.count) 条语境一起删除，不可撤销。「仅本地」保留 Anki 里的卡和复习进度。")
        }
    }

    private static let top = "top"

    // MARK: - 编辑

    private func beginEdit() {
        dWord = word.word
        dPhonetic = word.phonetic ?? ""
        dGrammar = word.grammar ?? ""
        dMeaning = word.meaning
        dNote = word.analysisNote
        dContexts = Dictionary(uniqueKeysWithValues: word.sortedContexts.map { ($0.id, ($0.sentence, $0.translation)) })
        isEditing = true
    }

    private func commitEdit() {
        word.word = dWord.trimmingCharacters(in: .whitespacesAndNewlines)
        word.phonetic = dPhonetic.isEmpty ? nil : dPhonetic
        word.grammar = dGrammar.isEmpty ? nil : dGrammar
        word.meaning = dMeaning
        word.analysisNote = dNote
        for ctx in word.contexts ?? [] {
            if let (s, t) = dContexts[ctx.id] { ctx.sentence = s; ctx.translation = t }
        }
        // 旧字段保持与第一条语境一致（兼容导出/旧代码）
        if let first = word.sortedContexts.first {
            word.contextSentence = first.sentence
            word.contextTranslation = first.translation
        }
        word.syncStatus = .notSynced   // 改过就要重新同步 Anki
        try? modelContext.save()
        isEditing = false
    }

    private func speak() {
        AudioService.shared.speak(word.word, language: word.language)
        isSpeaking = true
        Task { try? await Task.sleep(for: .seconds(2)); isSpeaking = false }
    }

    // MARK: - 词头

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                editHeader
            } else {
                HStack(spacing: 6) {
                    Text(word.word)
                        .font(Theme.font(26, .semibold, scale: fs))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    DetailIconButton(symbol: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2", help: "朗读（空格）") { speak() }
                        .keyboardShortcut(.space, modifiers: [])
                    Spacer(minLength: 8)
                    if actions.regenerating.contains(word.id) {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    } else {
                        DetailIconButton(symbol: "sparkles", help: "重新讲解：释义（含词性）、用法、例句、构词和来历") {
                            actions.regenerate(word, context: modelContext)
                        }
                    }
                    DetailIconButton(symbol: "pencil", help: "编辑（⌘E）") { beginEdit() }
                        .keyboardShortcut("e", modifiers: .command)
                    moreMenu
                }
                HStack(spacing: 8) {
                    if let phonetic = word.phonetic, !phonetic.isEmpty {
                        Text(TextHighlighter.ipa(phonetic))
                            .font(Theme.mono(12, scale: fs))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                    }
                    Tag(text: LocalizedStringKey(word.difficulty.displayName))
                    Tag(text: LocalizedStringKey(word.language.displayName))
                }
                if let g = word.grammar, !g.isEmpty {
                    Text(TextHighlighter.highlight(word.word, in: g, language: word.language))
                        .font(Theme.font(12, scale: fs))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var editHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("单词", text: $dWord)
                    .font(Theme.font(20, .semibold, scale: fs))
                    .editField()
                TextField("音标", text: $dPhonetic)
                    .font(Theme.mono(13, scale: fs))
                    .editField()
                    .frame(width: 180)
            }
            TextField("语法：der Fahrer, die Fahrer / trennbar · hält an · hielt an · hat angehalten", text: $dGrammar)
                .font(Theme.mono(12, scale: fs))
                .editField()
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { isEditing = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("保存") { commitEdit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    /// 「更多」：朗读、复制、搜图、删除
    private var moreMenu: some View {
        Menu {
            Button("朗读") { speak() }
            Button("复制单词") { WordActions.copy(word.word) }
            Button("在浏览器里搜图") { WordActions.searchImages(for: word) }
            Divider()
            Button("删除…", role: .destructive) { showDeleteConfirm = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    // MARK: - 在这句里遇到

    private var contextCard: some View {
        let list = word.sortedContexts
        let idx = min(ctxIndex, list.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    if list.count > 1 && !isEditing {
                        Text("遇到 \(list.count) 次，这是第 \(idx + 1) 次")
                    } else if list.count > 1 {
                        Text("遇到 \(list.count) 次")
                    } else {
                        Text("在这句里遇到")
                    }
                }
                .font(Theme.font(12, .medium, scale: fs))
                .foregroundStyle(Theme.text2)
                Spacer(minLength: 8)
                if list.count > 1 && !isEditing { contextTabs(count: list.count, current: idx) }
            }
            if isEditing {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, ctx in
                    editContext(ctx, index: index, total: list.count)
                }
            } else {
                contextBody(list[idx])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .background(GeometryReader { Color.clear.preference(key: CardWidthKey.self, value: $0.size.width) })
        .onPreferenceChange(CardWidthKey.self) { cardWidth = $0 }
    }

    /// 1 2 3 页签；多到放不下时折成一个菜单
    @ViewBuilder
    private func contextTabs(count: Int, current: Int) -> some View {
        if count <= 9 {
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Button { ctxIndex = i } label: {
                        Text("\(i + 1)")
                            .font(Theme.font(12, scale: fs))
                            .foregroundStyle(i == current ? Theme.text : Theme.text2)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(i == current ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(i == current ? Theme.borderStrong : .clear, lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Menu("\(current + 1) / \(count)") {
                ForEach(0..<count, id: \.self) { i in Button("第 \(i + 1) 次") { ctxIndex = i } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func contextBody(_ ctx: WordContext) -> some View {
        if cardWidth >= 560 {
            HStack(alignment: .top, spacing: 16) {
                contextText(ctx).frame(maxWidth: .infinity, alignment: .leading)
                if let path = ctx.screenshotPath { ScreenshotThumb(path: path) }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                contextText(ctx)
                if let path = ctx.screenshotPath { ScreenshotThumb(path: path, width: nil) }
            }
        }
    }

    private func contextText(_ ctx: WordContext) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(TextHighlighter.highlight(word.word, in: ctx.sentence, language: word.language))
                    .font(Theme.font(15, scale: fs))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !ctx.translation.isEmpty {
                    Text(TextHighlighter.emphasizeTranslation(word.translationKeyword, sense: word.contextMeaning, in: ctx.translation))
                        .font(Theme.font(13, scale: fs))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(ctx.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.font(12, scale: fs))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)
            }
    }

    private func editContext(_ ctx: WordContext, index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("原句", text: Binding(
                get: { dContexts[ctx.id]?.0 ?? ctx.sentence },
                set: { dContexts[ctx.id] = ($0, dContexts[ctx.id]?.1 ?? ctx.translation) }
            ), axis: .vertical).editField().lineLimit(1...4)
            TextField("译文", text: Binding(
                get: { dContexts[ctx.id]?.1 ?? ctx.translation },
                set: { dContexts[ctx.id] = (dContexts[ctx.id]?.0 ?? ctx.sentence, $0) }
            ), axis: .vertical).editField().lineLimit(1...4)
            if total > 1 {
                Button("删除这条语境", role: .destructive) {
                    modelContext.delete(ctx)
                    try? modelContext.save()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: - 区块

    private var meaning: some View {
        DetailSection(title: "释义") {
            if isEditing {
                TextField("释义", text: $dMeaning, axis: .vertical)
                    .editField()
                    .lineLimit(2...6)
            } else {
                Text(TextHighlighter.emphasizeMeaning(word.contextMeaning, in: word.meaning))
                    .font(Theme.font(15, scale: fs))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var analysis: some View {
        DetailSection(title: "用法") {
            if isEditing {
                TextField("用法 / 搭配 / 易错点", text: $dNote, axis: .vertical)
                    .editField()
                    .lineLimit(2...8)
            } else {
                Text(TextHighlighter.highlight(word.word, in: word.analysisNote, language: word.language))
                    .font(Theme.font(13, scale: fs))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「搭配 —— 中文」拆成两半；没有分隔就只有前半
    private func pair(_ line: String) -> (String, String?) {
        let parts = line.components(separatedBy: "——").map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts[0], parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    private func lines(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 搭配 / 例句 / 构词和来历
    @ViewBuilder
    private var aiExtras: some View {
        let colls = lines(word.collocationsText)
        if !colls.isEmpty {
            DetailSection(title: "搭配") {
                Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 4) {
                    ForEach(colls, id: \.self) { line in
                        let (phrase, tr) = pair(line)
                        GridRow {
                            Text(TextHighlighter.highlight(word.word, in: phrase, language: word.language))
                                .font(Theme.font(13, scale: fs))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                            if let tr {
                                Text(tr).font(Theme.font(13, scale: fs)).foregroundStyle(Theme.text2)
                            } else {
                                Color.clear.frame(width: 0, height: 0)
                            }
                        }
                    }
                }
            }
        }
        let exs = lines(word.examplesText)
        if !exs.isEmpty {
            DetailSection(title: "例句") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(exs, id: \.self) { line in
                        let (sentence, tr) = pair(line)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(TextHighlighter.highlight(word.word, in: sentence, language: word.language))
                                .font(Theme.font(13, scale: fs))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                            if let tr {
                                Text(tr).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if let e = word.etymology, !e.isEmpty {
            DetailSection(title: "构词和来历") {
                Text(TextHighlighter.highlight(word.word, in: e, language: word.language))
                    .font(Theme.font(13, scale: fs))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 底部一行

    private var footer: some View {
        FlowLayout(spacing: 18) {
            HStack(spacing: 6) {
                SyncDot(status: word.syncStatus)
                Text(word.syncStatus.footLabel)
                Text("· 牌组 \(AnkiService.shared.deckNameForWord(word))")
            }
            Text("复习 \(word.reviewCount) 次")
            Text("第一次遇到 \(word.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .font(Theme.font(12, scale: fs))
        .foregroundStyle(Theme.text2)
        .padding(.top, 14)
        .overlay(alignment: .top) { Hairline() }
        .padding(.top, 28)
    }
}

private struct CardWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
