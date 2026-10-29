// ClassicCard.swift
// GetNewWord
//
// 查词面板「经典卡片」：1.1.7 用户天天用的那版卡片内部，原样搬回（默认样式）。
// 一张卡从上到下：词头和标签 → 语法分解 → 释义 → 语境 → 取词那一刻的截图（红框圈住那个词）→ 用法 → 搭配 → 例句 → 词根词源 → 归入。
// 外面的窗口、状态条、钉住 / 撤销这些按钮还是 AnalysisResultPanel 那一套。
// 和 1.1.7 只差两处：音标只套一层斜杠（模型自带 /…/ 时不再显示成 //…//），截图先缩到面板用得上的大小再显示。

import SwiftUI
import AppKit

// MARK: - 单词卡

struct ClassicWordCard: View {
    let word: WordAnalysis
    let isSelected: Bool
    var skippedAsDuplicate = false
    var showCheckbox = true
    let onToggle: () -> Void
    let categoryPicker: () -> CategoryAssignRow
    var onRemove: (() -> Void)? = nil
    var enrichment: WordEnrichment? = nil
    var screenshot: NSImage? = nil
    var lookupCount = 1
    /// 「分解语法」的流式内容（只给第一个词，语境句属于它）
    var grammar: GrammarBreakdownState? = nil

    private var usage: String? { enrichment?.usage ?? word.analysisNote }
    private var collocations: [String]? { enrichment?.collocations }
    private var examples: [String]? { enrichment?.examples ?? word.examples }
    private var etymology: String? { enrichment?.etymology ?? word.etymology }
    private var language: Language { Language(rawValue: word.language.lowercased()) ?? .other }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 词头：大字 + 音标同行，标签一排
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if showCheckbox {
                        Button(action: onToggle) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(word.word)
                        .font(.system(size: 28, weight: .bold))
                        .textSelection(.enabled)
                    if let p = word.phonetic, !p.isEmpty {
                        Text(TextHighlighter.ipa(p))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                    }
                    ClassicSpeakButton(word: word.word, language: language)
                    Spacer()
                }
                HStack(spacing: 6) {
                    Chip(text: word.difficulty.uppercased(), tone: .custom(Theme.levelColor(Difficulty(rawValue: word.difficulty.lowercased()) ?? .b1)))
                    Chip(text: language == .other ? word.language : language.displayName, mono: false)
                    if lookupCount > 1 { Chip(text: "×\(lookupCount)", tone: .accent) }
                    Spacer()
                    if let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "trash").font(.caption).foregroundStyle(Theme.text3)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("单项移除：只把这个词从本次保存中撤掉（其余保留）")
                    }
                }
                // 变化那行：灰字，里面查的词的变形标紫（和讲义卡、浮签、主窗口一样）；字体、位置照 1.1.7
                if let g = word.grammar, !g.isEmpty {
                    Text(TextHighlighter.highlight(word.word, in: g, language: language, grammar: g))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                }
                if skippedAsDuplicate {
                    Label("这个词已在词库里，且语境几乎相同，本次未重复添加", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.text2)
                }
            }

            Hairline()

            if let grammar { GrammarBreakdownSection(state: grammar, word: word.word, language: language, grammar: word.grammar) }

            ClassicSection("释义") {
                Text(TextHighlighter.emphasizeMeaning(word.contextMeaning, in: word.meaning))
                    .font(.system(size: 15.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !word.contextSentence.isEmpty {
                ClassicSection("语境") {
                    ClassicContext(word: word.word, language: language, grammar: word.grammar, sentence: word.contextSentence,
                                   translation: word.contextTranslation, keyword: word.translationKeyword, sense: word.contextMeaning)
                }
            }

            if let screenshot {
                ClassicSection("截图") { ClassicScreenshot(image: screenshot) }
            }

            if let usage, !usage.isEmpty {
                ClassicSection("用法") {
                    Text(TextHighlighter.highlight(word.word, in: usage, language: language, grammar: word.grammar))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 补全（用法、例句、词根词源）没到就一直显示；失败时会标成空补全而停下
            if enrichment == nil, examples == nil, collocations == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("用法 · 例句 · 词根词源 生成中…").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }

            ClassicExtras(word: word.word, language: language, grammar: word.grammar,
                          collocations: collocations, examples: examples, etymology: etymology)

            categoryPicker()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }
}

// MARK: - 词库直出卡（指词 / 框选命中已存的词：秒出完整内容，主分析在后台核对语境）

struct ClassicCachedCard: View {
    let entry: WordEntry
    var enrichment: WordEnrichment? = nil
    var lookupCount = 1
    var grammar: GrammarBreakdownState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(entry.word).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                    if let p = entry.phonetic, !p.isEmpty {
                        Text(TextHighlighter.ipa(p)).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text2)
                    }
                    ClassicSpeakButton(word: entry.word, language: entry.language)
                    Spacer()
                }
                HStack(spacing: 6) {
                    Chip(text: entry.difficulty.displayName, tone: .custom(Theme.levelColor(entry.difficulty)))
                    Chip(text: entry.language.displayName, mono: false)
                    if lookupCount > 1 { Chip(text: "×\(lookupCount)", tone: .accent) }
                    Spacer()
                }
                if let g = entry.grammar, !g.isEmpty {
                    Text(TextHighlighter.highlight(entry.word, in: g, language: entry.language, grammar: g))
                        .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text2)
                }
                Label("词库里已有这个词，直接展示；正在核对本次语境是否新增", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            Hairline()
            if let grammar { GrammarBreakdownSection(state: grammar, word: entry.word, language: entry.language, grammar: entry.grammar) }
            ClassicSection("释义") {
                Text(TextHighlighter.emphasizeMeaning(entry.contextMeaning, in: entry.meaning))
                    .font(.system(size: 15.5)).fixedSize(horizontal: false, vertical: true)
            }
            if let ctx = entry.sortedContexts.last {
                ClassicSection("语境") {
                    ClassicContext(word: entry.word, language: entry.language, grammar: entry.grammar, sentence: ctx.sentence,
                                   translation: ctx.translation, keyword: entry.translationKeyword, sense: entry.contextMeaning)
                }
            }
            if let u = enrichment?.usage, !u.isEmpty {
                ClassicSection("用法") {
                    Text(TextHighlighter.highlight(entry.word, in: u, language: entry.language, grammar: entry.grammar))
                        .font(.system(size: 14)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ClassicExtras(word: entry.word, language: entry.language, grammar: entry.grammar, collocations: enrichment?.collocations,
                          examples: enrichment?.examples, etymology: enrichment?.etymology)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }
}

// MARK: - 知识片段卡

struct ClassicSnippetCard: View {
    let snippet: SnippetAnalysis
    var onRemove: (() -> Void)? = nil
    let categoryPicker: () -> CategoryAssignRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snippet.title).font(.headline)
                Spacer()
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "trash").font(.caption).foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                    .help("从这次保存中移除这条知识片段")
                }
            }
            Text(snippet.content).font(.system(size: 14.5))
            if !snippet.sourceContext.isEmpty {
                Text(snippet.sourceContext).font(.caption).foregroundStyle(.secondary).italic()
            }
            categoryPicker()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }
}

// MARK: - 骨架卡（主分析还没回来）

struct ClassicSkeletonCard: View {
    let quickWord: ZhipuService.QuickWord?
    /// 补全先回来时的释义（指词查词常比主分析早到），先显示，语境部分继续占位
    var meaning: String? = nil
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let q = quickWord {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(q.word).font(.system(size: 28, weight: .bold))
                    Chip(text: q.language.uppercased(), mono: false)
                    Spacer()
                }
            } else {
                bar(180, 26).opacity(pulse ? 0.55 : 1)
            }
            Hairline()
            if let meaning, !meaning.isEmpty {
                Text(meaning).font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                if meaning?.isEmpty ?? true { bar(260, 14) }
                bar(420, 12)
                bar(360, 12)
                bar(300, 12)
            }
            .opacity(pulse ? 0.55 : 1)
        }
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .onAppear { pulse = true }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Theme.selected).frame(maxWidth: width).frame(height: height)
    }
}

// MARK: - 小部件

/// 小灰标题 + 内容
private struct ClassicSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.text3)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 语境：左竖线 + 斜体原句（被查的词高亮）+ 灰色译文（对应的词标出来）
private struct ClassicContext: View {
    let word: String
    let language: Language
    let grammar: String?
    let sentence: String
    let translation: String
    let keyword: String?
    let sense: String?
    var body: some View {
        QuoteBlock {
            Text(TextHighlighter.highlight(word, in: sentence, language: language, grammar: grammar))
                .font(.system(size: 14.5))
                .italic()
                .fixedSize(horizontal: false, vertical: true)
            if !translation.isEmpty {
                Text(TextHighlighter.emphasizeTranslation(keyword, sense: sense, in: translation))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 搭配、例句、词根词源（查的词在里面出现也标紫）
private struct ClassicExtras: View {
    let word: String
    let language: Language
    let grammar: String?
    let collocations: [String]?
    let examples: [String]?
    let etymology: String?
    var body: some View {
        if let c = collocations, !c.isEmpty {
            ClassicSection("搭配") {
                VStack(alignment: .leading, spacing: 6) { ForEach(c, id: \.self) { exampleView($0, word: word, language: language, grammar: grammar) } }
            }
        }
        if let ex = examples, !ex.isEmpty {
            ClassicSection("例句") {
                VStack(alignment: .leading, spacing: 6) { ForEach(ex, id: \.self) { exampleView($0, word: word, language: language, grammar: grammar) } }
            }
        }
        if let e = etymology, !e.isEmpty {
            ClassicSection("词根词源") {
                Text(TextHighlighter.highlight(word, in: e, language: language, grammar: grammar)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ClassicSpeakButton: View {
    let word: String
    let language: Language
    var body: some View {
        Button {
            AudioService.shared.speak(word, language: language)
        } label: {
            Image(systemName: "speaker.wave.2").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text2)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .help("朗读")
    }
}

/// 取词那一刻的语境图：红框圈住框选（或指着）的那个词，框外略压暗（ContextImage 画的）。
/// 原图是屏幕像素，最宽两千多像素；先缩到面板最宽时用得上的大小再交给 SwiftUI，滚动时不用每帧缩放一张大图
private struct ClassicScreenshot: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: ScreenshotThumbnail.make(image))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).stroke(Theme.border, lineWidth: 0.5))
    }
}

/// 截图缩略图：每张原图只缩一次（同一次查词里面板会重画很多次）
@MainActor
enum ScreenshotThumbnail {
    /// 面板拖到很宽时截图最多占 ~900pt 宽、180pt 高；按 2 倍屏给像素
    nonisolated static let maxPixels = CGSize(width: 1800, height: 360)
    private static var cache: (source: NSImage, thumb: NSImage)?

    static func make(_ image: NSImage) -> NSImage {
        if let cache, cache.source === image { return cache.thumb }
        let thumb = downscale(image) ?? image
        cache = (image, thumb)
        return thumb
    }

    /// 按比例缩到 maxPixels 以内；本来就不大的原样返回
    nonisolated static func downscale(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxPixels.width / CGFloat(cg.width), maxPixels.height / CGFloat(cg.height))
        guard scale < 1 else { return image }
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        // 点大小保持原图的宽高比，显示时由 aspectRatio 撑满
        return NSImage(cgImage: out, size: NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
    }
}
