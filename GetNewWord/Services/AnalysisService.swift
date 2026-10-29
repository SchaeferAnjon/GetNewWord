// AnalysisService.swift
// GetNewWord
//
// 分析服务：协调截图 → API 分析 → 结果处理的完整流程

import Foundation
import AppKit
import SwiftData

/// 本地 OCR 拿到的文字版取词：目标文字 + 附近几行。有它就走纯文字请求，不让模型看图（快 2–3s）
struct TextLookup: Sendable {
    enum Scene: Sendable { case hover, region }
    let target: String
    let context: String
    /// en / de / fr / es
    let language: String
    /// 单词或短语（≤5 个词）；否则是整句/段落，按知识片段处理
    let isWord: Bool
    let scene: Scene
}

/// 分析结果包装
struct AnalysisResult {
    let screenshot: NSImage
    let screenshotPath: String?
    let analysis: WordAnalysisResult
}

@MainActor
class AnalysisService {
    static let shared = AnalysisService()

    private let screenshotService = ScreenshotService.shared
    private let zhipuService = ZhipuService.shared

    /// 当前分析状态
    var isAnalyzing: Bool = false

    private init() {}

    // MARK: - 公开方法

    /// 开始截图分析流程（失败时抛出具体错误；用户取消截图返回 nil 不抛错）
    /// 1. 调用截图服务获取区域截图
    /// 2. 将截图发送给智谱 API 分析（失败时抛出具体错误）
    /// 3. 返回分析结果
    /// 第 0 步：框选截图（用户取消返回 nil）
    func captureRegion() async -> (image: NSImage, path: String?, selection: NSImage?)? {
        #if DEBUG
        if let demo = DemoMode.capture() { return (demo.0, screenshotService.saveScreenshot(demo.0), demo.1) }
        #endif
        let shot: (NSImage?, NSImage?) = await withCheckedContinuation { continuation in
            screenshotService.startRegionScreenshot { image, selection in
                continuation.resume(returning: (image, selection))
            }
        }
        guard let image = shot.0 else { return nil }
        AppLog.log("[Analysis] screenshot captured \(Int(image.size.width))x\(Int(image.size.height))")
        let path = screenshotService.saveScreenshot(image)
        return (image, path, shot.1)
    }

    /// 框选取词的文字版：框里的字和红框图里的上下文并行 OCR（约 0.1–0.2s）；框里读不出字返回 nil，交给识图
    func regionText(context: NSImage, selection: NSImage?) async -> TextLookup? {
        guard let selCG = selection?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctxCG = context.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        async let selLines = HoverWordCapture.recognizeLines(in: selCG)
        async let ctxLines = HoverWordCapture.recognizeLines(in: ctxCG)
        let raw = await selLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let contextText = await ctxLines.joined(separator: "\n")
        guard !raw.isEmpty else { return nil }
        let isWord = raw.split(whereSeparator: \.isWhitespace).count <= 5
        let target = isWord ? raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'’“”—–")) : raw
        return TextLookup(target: target, context: contextText, language: HoverWordCapture.language(of: contextText),
                          isWord: isWord, scene: .region)
    }

    /// 指词查词：鼠标下的词自动当选区（红框语境图 + 单词小图 + 附近文字），认不出词时弹提示返回 nil
    func captureHoverWord() async -> (shot: HoverWordCapture.Shot, path: String?)? {
        guard screenshotService.hasScreenRecordingPermission() else {
            _ = await screenshotService.requestScreenRecordingPermission()
            return nil
        }
        guard let shot = await HoverWordCapture.capture() else {
            ErrorPanelController.shared.show(.noWord)
            return nil
        }
        AppLog.log("[Analysis] hover word '\(shot.word)' (\(shot.language)), \(shot.context.count) chars context")
        return (shot, screenshotService.saveScreenshot(shot.image))
    }

    /// 主分析（图 → 释义/语法/语境/分类）
    func analyze(image: NSImage, screenshotPath: String?, existingTags: [String] = [], categoryTree: String = "") async throws -> AnalysisResult {
        let analysis = try await zhipuService.analyzeScreenshot(image, existingTags: existingTags, categoryTree: categoryTree)
        return AnalysisResult(screenshot: image, screenshotPath: screenshotPath, analysis: analysis)
    }

    // MARK: - 分类体系

    /// 把分类树渲染成给模型看的文本，例如：
    /// 语言学习 > 德语
    /// 语言学习 > 英语
    /// 知识片段 > 健身
    func categoryTreeDescription(categories: [Category]) -> String {
        let leaves = categories.filter { $0.parent != nil }
            .sorted { ($0.parent?.name ?? "", $0.name) < ($1.parent?.name ?? "", $1.name) }
        return leaves.map { "\($0.parent?.name ?? "") > \($0.name)" }.joined(separator: "\n")
    }

    // MARK: - 标签库

    /// 当前所有已使用的标签（单词 + 知识片段），按使用频次降序，作为模型选标签的唯一来源
    nonisolated static func allExistingTags(context: ModelContext) -> [String] {
        var words = FetchDescriptor<WordEntry>()
        words.propertiesToFetch = [\.tags]
        var snippets = FetchDescriptor<KnowledgeSnippet>()
        snippets.propertiesToFetch = [\.tags]
        var counts: [String: Int] = [:]
        for w in (try? context.fetch(words)) ?? [] { for t in w.tags { counts[t, default: 0] += 1 } }
        for s in (try? context.fetch(snippets)) ?? [] { for t in s.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { $0.key }
    }

    /// 同上，在后台另开一个 ModelContext 读：要把全部词条和知识片段过一遍，2000 个词时主线程要卡 0.1 秒（Rosetta 下 0.2 秒），
    /// 查词一开始就发出去，和框选、本地 OCR 同时跑
    nonisolated static func existingTagsInBackground(container: ModelContainer) -> Task<[String], Never> {
        Task.detached(priority: .userInitiated) { allExistingTags(context: ModelContext(container)) }
    }

    // MARK: - 保存方法

    /// 将分析结果保存到数据库
    func saveResults(_ result: AnalysisResult, context: ModelContext) throws {
        // 查找或匹配分类
        let categories = fetchCategories(context: context)

        for word in result.analysis.words {
            try saveWord(word, screenshotPath: result.screenshotPath, category: nil, context: context, categories: categories)
        }

        for snippet in result.analysis.snippets {
            try saveSnippet(snippet, screenshotPath: result.screenshotPath, category: nil, context: context, categories: categories)
        }
    }

    /// 保存单个单词条目
    /// - Parameter approvedNewTags: 用户在结果面板里确认采纳的新标签（会并入 tags）
    @discardableResult
    func saveWord(
        _ word: WordAnalysis,
        screenshotPath: String?,
        category: Category?,
        context: ModelContext,
        categories: [Category]? = nil,
        approvedNewTags: [String] = []
    ) throws -> WordEntry {
        let language = matchLanguage(from: word.language)
        let difficulty = matchDifficulty(from: word.difficulty)
        let finalTags = Self.mergeTags(word.tags, approvedNewTags)

        // 同词同语言已存在：不新建条目，只追加一条语境（基础含义相同，语境不同）
        let key = "\(word.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(language.rawValue)"
        let existingDescriptor = FetchDescriptor<WordEntry>()
        if let existing = (try? context.fetch(existingDescriptor))?.first(where: { $0.dedupeKey == key }) {
            // 语境相似去重：同一页截两次、只差标点/空格/大小写的句子不再重复存
            if let dup = existing.sortedContexts.first(where: { Self.isSimilarSentence($0.sentence, word.contextSentence) }) {
                AppLog.log("[Analysis] context for '\(existing.word)' looks like an existing one (\(dup.sentence.prefix(30))…), skipped")
                if (existing.grammar ?? "").isEmpty, let g = word.grammar, !g.isEmpty { existing.grammar = g }
                existing.lookupCount = max(existing.lookupCount + 1, existing.sortedContexts.count)
                try context.save()
                return existing
            }
            let newContext = WordContext(
                sentence: word.contextSentence,
                translation: word.contextTranslation,
                note: word.analysisNote ?? "",
                screenshotPath: screenshotPath,
                word: existing
            )
            context.insert(newContext)
            // 旧条目若还没有语境列表，把它自己原有的语境也补进去，保证详情页完整
            if (existing.contexts ?? []).isEmpty, !existing.contextSentence.isEmpty {
                let legacy = WordContext(
                    sentence: existing.contextSentence, translation: existing.contextTranslation,
                    note: existing.analysisNote, screenshotPath: existing.screenshotPath,
                    createdAt: existing.createdAt, word: existing
                )
                context.insert(legacy)
            }
            // 音标缺失时补上；释义保留原有
            if (existing.phonetic ?? "").isEmpty, let p = word.phonetic, !p.isEmpty { existing.phonetic = p }
            if (existing.grammar ?? "").isEmpty, let g = word.grammar, !g.isEmpty { existing.grammar = g }
            if (existing.mnemonic ?? "").isEmpty, let m = word.mnemonic, !m.isEmpty { existing.mnemonic = m }
            if (existing.etymology ?? "").isEmpty, let e = word.etymology, !e.isEmpty { existing.etymology = e }
            if (existing.examplesText ?? "").isEmpty, let ex = word.examples, !ex.isEmpty { existing.examplesText = ex.joined(separator: "\n") }
            existing.tags = Self.mergeTags(existing.tags, finalTags)
            existing.lookupCount = max(existing.lookupCount + 1, existing.sortedContexts.count)
            existing.syncStatus = .notSynced  // 有新语境，需要重新同步到 Anki
            try context.save()
            AppLog.log("[Analysis] merged context into existing word '\(existing.word)' (now \(existing.sortedContexts.count) contexts)")
            return existing
        }

        // 自动匹配分类
        let matchedCategory = category ?? findCategory(for: language, categories: categories ?? fetchCategories(context: context))

        let entry = WordEntry(
            word: word.word,
            phonetic: word.phonetic,
            language: language,
            meaning: word.meaning,
            contextMeaning: word.contextMeaning,
            contextSentence: word.contextSentence,
            contextTranslation: word.contextTranslation,
            analysisNote: word.analysisNote ?? "",
            grammar: word.grammar,
            examplesText: (word.examples ?? []).isEmpty ? nil : (word.examples ?? []).joined(separator: "\n"),
            mnemonic: (word.mnemonic?.isEmpty == false) ? word.mnemonic : nil,
            etymology: (word.etymology?.isEmpty == false) ? word.etymology : nil,
            screenshotPath: screenshotPath,
            difficulty: difficulty,
            tags: finalTags,
            category: matchedCategory
        )

        entry.translationKeyword = (word.translationKeyword?.isEmpty == false) ? word.translationKeyword : nil
        context.insert(entry)
        // 第一条语境
        let firstContext = WordContext(
            sentence: word.contextSentence,
            translation: word.contextTranslation,
            note: word.analysisNote ?? "",
            screenshotPath: screenshotPath,
            word: entry
        )
        context.insert(firstContext)
        try context.save()
        // 保存即预下载真人发音（英/德/日/韩…），离线可播、Anki 同步直接带 [sound:]
        prefetchAudio(for: entry)
        return entry
    }

    /// 后台准备该词的发音文件并写回 audioPath：缓存 → 有道下载 → 本地 TTS 生成（保证德语等都有文件）
    func prefetchAudio(for entry: WordEntry) {
        let text = entry.word, lang = entry.language
        Task { @MainActor in
            if let path = await AudioService.shared.generateAudioFile(for: text, language: lang) {
                if entry.audioPath != path {
                    entry.audioPath = path
                    try? entry.modelContext?.save()
                }
            }
        }
    }

    /// 启动时给所有还没有发音文件的单词补下载（并发 3 个，避免刷接口）
    /// 哪些词缺发音文件在后台查（要读全部词、逐个看文件在不在，2000 个词时主线程要卡 0.2 秒），主线程只碰缺的那几个
    func backfillAudio(context: ModelContext) {
        let container = context.container
        Task { @MainActor in
            let missingIDs = await Task.detached(priority: .utility) { () -> [PersistentIdentifier] in
                var d = FetchDescriptor<WordEntry>()
                d.propertiesToFetch = [\.audioPath]
                let words = (try? ModelContext(container).fetch(d)) ?? []
                return words.filter { w in
                    guard let p = w.audioPath else { return true }
                    return !FileManager.default.fileExists(atPath: p)
                }.map(\.persistentModelID)
            }.value
            guard !missingIDs.isEmpty else { return }
            AppLog.log("[Audio] backfill \(missingIDs.count) words")
            // 顺序下载（每个 <1s），避免刷接口；SwiftData 对象只在主线程碰
            for id in missingIDs {
                guard let w = context.model(for: id) as? WordEntry, !w.isDeleted else { continue }
                if let path = await AudioService.shared.generateAudioFile(for: w.word, language: w.language) {
                    w.audioPath = path
                }
            }
            try? context.save()
        }
    }

    /// 启动时用：先在后台看有没有重复（要读全部词，2000 个词时主线程要卡 0.25 秒），真有才回主线程合并
    func mergeDuplicateWordsIfAny(context: ModelContext) {
        let container = context.container
        Task { @MainActor in
            let found = await Task.detached(priority: .utility) { () -> Bool in
                let words = (try? ModelContext(container).fetch(FetchDescriptor<WordEntry>())) ?? []
                var seen = Set<String>()
                return words.contains { !seen.insert($0.dedupeKey).inserted }
            }.value
            if found { self.mergeDuplicateWords(context: context) }
        }
    }

    /// 合并库里已有的重复单词（同词同语言）：保留最早的一条，其余条目的语境并入后删除。
    /// 在应用启动时调用一次，幂等。
    func mergeDuplicateWords(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<WordEntry>(sortBy: [SortDescriptor(\.createdAt)])) else { return }
        let groups = Dictionary(grouping: all) { $0.dedupeKey }
        var merged = 0
        for (_, entries) in groups where entries.count > 1 {
            let keeper = entries[0]
            var keeperContexts = keeper.contexts ?? []
            if keeperContexts.isEmpty, !keeper.contextSentence.isEmpty {
                let legacy = WordContext(sentence: keeper.contextSentence, translation: keeper.contextTranslation,
                                         note: keeper.analysisNote, screenshotPath: keeper.screenshotPath,
                                         createdAt: keeper.createdAt, word: keeper)
                context.insert(legacy)
                keeperContexts.append(legacy)
            }
            for dup in entries.dropFirst() {
                // 把重复条目自身的语境 + 它已有的 contexts 都挂到 keeper 上
                var moved = dup.contexts ?? []
                if moved.isEmpty, !dup.contextSentence.isEmpty {
                    let c = WordContext(sentence: dup.contextSentence, translation: dup.contextTranslation,
                                        note: dup.analysisNote, screenshotPath: dup.screenshotPath,
                                        createdAt: dup.createdAt, word: keeper)
                    context.insert(c)
                    moved = [c]
                } else {
                    for c in moved { c.word = keeper }
                }
                // 去掉完全相同句子的语境
                let existingSentences = Set(keeperContexts.map { $0.sentence })
                for c in moved where existingSentences.contains(c.sentence) { context.delete(c) }
                keeperContexts.append(contentsOf: moved.filter { !existingSentences.contains($0.sentence) })
                if (keeper.phonetic ?? "").isEmpty { keeper.phonetic = dup.phonetic }
                context.delete(dup)
                merged += 1
            }
        }
        if merged > 0 {
            try? context.save()
            AppLog.log("[DB] merged \(merged) duplicate word entries")
        }
    }

    /// 保存单个知识片段
    @discardableResult
    func saveSnippet(
        _ snippet: SnippetAnalysis,
        screenshotPath: String?,
        category: Category?,
        context: ModelContext,
        categories: [Category]? = nil,
        approvedNewTags: [String] = []
    ) throws -> KnowledgeSnippet {
        // 知识片段默认归入"其他"分类
        let allCategories = categories ?? fetchCategories(context: context)
        let matchedCategory = category ?? findSnippetCategory(categories: allCategories)

        let knowledgeSnippet = KnowledgeSnippet(
            title: snippet.title,
            content: snippet.content,
            sourceContext: snippet.sourceContext,
            screenshotPath: screenshotPath,
            tags: Self.mergeTags(snippet.tags, approvedNewTags),
            domain: snippet.domain ?? "",
            category: matchedCategory
        )

        context.insert(knowledgeSnippet)
        try context.save()
        return knowledgeSnippet
    }

    // MARK: - 私有方法

    /// 两个语境句是否"几乎一样"：规范化后相等，或词元 Jaccard ≥ 0.8
    static func isSimilarSentence(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let ta = norm(a), tb = norm(b)
        if ta.isEmpty || tb.isEmpty { return a == b }
        if ta == tb { return true }
        let sa = Set(ta), sb = Set(tb)
        let jaccard = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        return jaccard >= 0.8
    }

    /// 合并标签：去空、去重（大小写不敏感）、保持顺序
    static func mergeTags(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in a + b {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// 从数据库获取分类列表
    private func fetchCategories(context: ModelContext) -> [Category] {
        let descriptor = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 根据语言字符串匹配 Language 枚举
    private func matchLanguage(from code: String) -> Language {
        let lowered = code.lowercased()
        for lang in Language.allCases {
            if lang.rawValue == lowered {
                return lang
            }
        }
        // 尝试匹配英文名称
        switch lowered {
        case "german", "deutsch": return .german
        case "english": return .english
        case "chinese": return .chinese
        case "french", "français": return .french
        case "spanish", "español": return .spanish
        case "japanese", "日本語": return .japanese
        case "korean", "한국어": return .korean
        default: return .other
        }
    }

    /// 根据难度字符串匹配 Difficulty 枚举
    private func matchDifficulty(from raw: String) -> Difficulty {
        let lowered = raw.lowercased()
        return Difficulty.allCases.first { $0.rawValue == lowered } ?? .b1
    }

    /// 根据语言查找对应的分类
    private func findCategory(for language: Language, categories: [Category]) -> Category? {
        let languageNames: [String] = {
            switch language {
            case .german: return ["德语", "German"]
            case .english: return ["英语", "English"]
            case .chinese: return ["中文", "Chinese"]
            case .french: return ["法语", "French"]
            case .spanish: return ["西班牙语", "Spanish"]
            case .japanese: return ["日语", "Japanese"]
            case .korean: return ["韩语", "Korean"]
            case .other: return ["其他"]
            }
        }()

        return categories.first { category in
            languageNames.contains(category.name)
        }
    }

    /// 查找知识片段的默认分类
    private func findSnippetCategory(categories: [Category]) -> Category? {
        // 优先查找"其他"分类
        if let otherCat = categories.first(where: { $0.name == "其他" }) {
            return otherCat
        }
        // 其次查找"知识片段"父分类下的子分类
        if let snippetParent = categories.first(where: { $0.name == "知识片段" }),
           let firstChild = snippetParent.children.first {
            return firstChild
        }
        return nil
    }
}


// MARK: - 词库秒查：OCR 读到的目标文字比对已存词条，不等 AI

enum LocalOCR {
    /// OCR 文本 → 词库匹配候选：小写、去首尾标点 + 简单词形还原（复数/时态/德语词尾）
    static func lookupCandidates(_ raw: String) -> Set<String> {
        let base = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'’“”—–"))
            .lowercased()
        guard !base.isEmpty, base.count <= 60, base.components(separatedBy: " ").count <= 5 else { return [] }
        var out: Set<String> = [base]
        for suffix in ["ing", "es", "ed", "en", "s", "n", "e"] {
            if base.hasSuffix(suffix), base.count > suffix.count + 2 {
                out.insert(String(base.dropLast(suffix.count)))
            }
        }
        if base.hasSuffix("ing"), base.count > 5 { out.insert(String(base.dropLast(3)) + "e") }   // driving → drive
        return out
    }
}
