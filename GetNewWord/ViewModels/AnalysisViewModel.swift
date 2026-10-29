// AnalysisViewModel.swift
// GetNewWord
//
// 分析流程 ViewModel
// - 取词模式（默认）：分析完成 → 立即自动保存 → 面板只做展示，可撤销、可改分类；随后后台同步 Anki
// - 查词模式（⌥ + 快捷键）：只看释义，不入库；面板上有显式「保存」

import SwiftUI
import SwiftData

/// 只拿来调用、不订阅变化的引用。主窗口和菜单栏若订阅整个 ViewModel，查词时每改一个 @Published
/// 都会重算主窗口（几百个词条的列表），主线程被占住，截屏、发请求都要排队（实测各慢 0.7s）。
/// 要显示查词状态的小视图自己用 @EnvironmentObject 订阅。
private struct AnalysisVMKey: EnvironmentKey {
    static let defaultValue: AnalysisViewModel? = nil
}

extension EnvironmentValues {
    var analysisVM: AnalysisViewModel? {
        get { self[AnalysisVMKey.self] }
        set { self[AnalysisVMKey.self] = newValue }
    }
}

@MainActor
class AnalysisViewModel: ObservableObject {
    enum Mode { case capture, lookup }
    /// 设置开关「指词查词加入词库」，默认关：指词快捷键只查不存，加 ⌥ 才保存；打开后反过来
    static let hoverAutoSaveKey = "hoverAutoSave"
    static var hoverMode: Mode { UserDefaults.standard.bool(forKey: hoverAutoSaveKey) ? .capture : .lookup }
    /// 取词来源：框选截图，或直接取鼠标下的词
    enum Source { case region, hover }

    @Published var isAnalyzing = false
    @Published var analysisResult: AnalysisResult?
    @Published var showResultPanel = false
    @Published var errorMessage: String?
    @Published var selectedIndices: Set<Int> = []  // 用户选择要保存的单词索引（查词模式下用）
    @Published var mode: Mode = .capture

    /// 自动保存后的落库对象（撤销 / 改分类时用）
    @Published var savedWords: [Int: WordEntry] = [:]
    @Published var savedSnippets: [Int: KnowledgeSnippet] = [:]
    /// 是否已经自动保存（面板据此显示「已保存 · 撤销」还是「保存」）
    @Published var autoSaved = false
    /// 本次保存中因"语境几乎相同"而被跳过的词（面板提示）
    @Published var skippedAsDuplicate: Set<Int> = []
    /// 自动保存了，其实什么都没新存：认出的词都已在词库里、语境几乎一样，也没有知识片段。
    /// 面板状态条照实写「已在词库里」，不再写「已存进」，撤销也藏起来（没东西可撤）
    var savedNothingNew: Bool {
        guard autoSaved, let a = analysisResult?.analysis else { return false }
        return Self.savedNothingNew(wordCount: a.words.count, snippetCount: a.snippets.count, skipped: skippedAsDuplicate,
                                    removedWords: removedWords, removedSnippets: removedSnippets)
    }
    nonisolated static func savedNothingNew(wordCount: Int, snippetCount: Int, skipped: Set<Int>,
                                            removedWords: Set<Int>, removedSnippets: Set<Int>) -> Bool {
        let words = (0..<wordCount).filter { !removedWords.contains($0) }
        let snippetLeft = (0..<snippetCount).contains { !removedSnippets.contains($0) }
        return !words.isEmpty && !snippetLeft && words.allSatisfy(skipped.contains)
    }
    /// 用户在回执面板里单独移除的条目（不再显示，也已从库里删掉）
    @Published var removedWords: Set<Int> = []
    @Published var removedSnippets: Set<Int> = []
    /// 知识片段的当前标签（面板可增删；写回已保存实体）
    @Published var snippetTags: [Int: [String]] = [:]
    /// 二段式：例句/助记/词根词源（后台补全）
    @Published var enrichments: [Int: WordEnrichment] = [:]
    @Published var enrichingIndices: Set<Int> = []
    /// 极速识词结果（面板骨架期先显示词头 + 播发音）
    @Published var quickWord: ZhipuService.QuickWord? = nil
    /// 词库命中：快速识词认出的词已在库里 → 面板直接展示已存词条（主分析继续跑，用于并入新语境）
    @Published var cachedHit: WordEntry? = nil
    /// 网络慢/重试中的提示（面板副标题）；结果一到就清空
    @Published var netHint: String? = nil
    /// 「分解语法」：nil = 没点过；点了之后流式累积的 Markdown（插在释义上方）
    @Published var grammarText: String? = nil
    @Published var grammarStreaming = false
    @Published var grammarError: String? = nil
    private var grammarTask: Task<Void, Never>?
    private var retryObserver: NSObjectProtocol?
    /// 识词 / 主分析两路并行，各自广播重试次数；只让副标题往上走，避免「第 2 次」被另一路的「第 1 次」盖回去
    private var maxRetryShown = 0
    private var enrichStarted = false
    /// 本轮分析标识：Esc/点面板外取消后，旧线程的结果一律丢弃、不入库
    private var runID = UUID()
    private var analyzeTask: Task<AnalysisResult, Error>?
    private var sideTasks: [Task<Void, Never>] = []

    // MARK: 分类体系归属

    @Published var categories: [Category] = []
    @Published var chosenWordCategory: [Int: UUID] = [:]
    @Published var chosenSnippetCategory: [Int: UUID] = [:]

    private let analysisService = AnalysisService.shared
    private let resultWindow = AnalysisResultWindowController()
    private var modelContext: ModelContext?

    func leafCategories(forWords: Bool) -> [Category] {
        let parentName = forWords ? "语言学习" : "知识片段"
        return categories.filter { $0.parent?.name == parentName }.sorted { $0.name < $1.name }
    }

    func category(id: UUID?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    /// 用户同意模型的建议：在对应父分类下新建一个分类并选中它
    func createCategory(named name: String, forWords: Bool, context: ModelContext) -> Category? {
        let parentName = forWords ? "语言学习" : "知识片段"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = categories.first(where: { $0.name == trimmed && $0.parent?.name == parentName }) { return existing }
        guard let parent = categories.first(where: { $0.name == parentName && $0.parent == nil }) else { return nil }
        let cat = Category(name: trimmed, icon: forWords ? "character.book.closed" : "folder", colorHex: "#4A90D9")
        cat.parent = parent
        context.insert(cat)
        try? context.save()
        categories.append(cat)
        AppLog.log("[Category] created '\(parentName) > \(trimmed)'")
        return cat
    }

    /// 面板里改了分类：已保存的条目立即改归属
    func applyCategoryChange(forWord index: Int) {
        guard let entry = savedWords[index] else { return }
        entry.category = category(id: chosenWordCategory[index])
        entry.syncStatus = .notSynced
        try? modelContext?.save()
    }
    func applyCategoryChange(forSnippet index: Int) {
        guard let s = savedSnippets[index] else { return }
        s.category = category(id: chosenSnippetCategory[index])
        s.syncStatus = .notSynced
        try? modelContext?.save()
    }

    // MARK: 触发分析

    func triggerAnalysis(modelContext: ModelContext, mode: Mode = .capture, source: Source = .region) async {
        guard !isAnalyzing else { return }
        guard ZhipuService.shared.isConfigured else {
            let msg = String(localized: "还没填 \(ZhipuService.shared.currentProviderName) 的 API Key：打开设置 → AI 服务填一下")
            errorMessage = msg
            ErrorPanelController.shared.show(.noKey)
            return
        }

        // 框选期间只占用 isAnalyzing 防重入；面板内容一律不动——
        // 钉住的面板得保留上一个词，用户按 Esc 放弃框选后它不能变成「识别中」
        isAnalyzing = true
        PanelPerf.mark(.trigger, eventTime: HotkeyManager.lastPressedAt)
        if !resultWindow.isPinned { resultWindow.dismiss() }
        let tagsTask = AnalysisService.existingTagsInBackground(container: modelContext.container)

        // 0. 框选（取消则静默退出，面板保持原样）；指词模式直接取鼠标下的词，没认出词就提示后退出。
        // 两种都尽量拿到「文字版」（本地 OCR 读出目标和附近几行）：有文字就走纯文字请求，比让模型看图快 2–3s
        let image: NSImage, screenshotPath: String?
        let text: TextLookup?
        if source == .hover {
            guard let (shot, path) = await analysisService.captureHoverWord() else {
                isAnalyzing = false
                return
            }
            image = shot.image
            screenshotPath = path
            text = TextLookup(target: shot.word, context: shot.context, language: shot.language, isWord: true, scene: .hover)
        } else {
            guard let (img, path, sel) = await analysisService.captureRegion() else {
                isAnalyzing = false
                return
            }
            image = img
            screenshotPath = path
            text = await analysisService.regionText(context: img, selection: sel)
        }

        PanelPerf.mark(.captured)
        // 框选成功，才开始新一轮：清空上一轮状态（钉住的面板此时原地刷新为骨架态）
        self.modelContext = modelContext
        self.mode = mode
        errorMessage = nil
        analysisResult = nil
        selectedIndices = []
        chosenWordCategory = [:]
        chosenSnippetCategory = [:]
        savedWords = [:]
        savedSnippets = [:]
        skippedAsDuplicate = []
        enrichments = [:]
        enrichingIndices = []
        removedWords = []
        removedSnippets = []
        snippetTags = [:]
        autoSaved = false
        quickWord = nil
        cachedHit = nil
        netHint = nil
        resetGrammar()
        maxRetryShown = 0
        enrichStarted = false
        runID = UUID()
        let myRun = runID
        installRetryObserver()

        categories = (try? modelContext.fetch(FetchDescriptor<Category>())) ?? []
        let categoryTree = analysisService.categoryTreeDescription(categories: categories)
        let existingTags = await tagsTask.value

        // 有文字版：主分析和补全立刻在后台发出，不等面板首帧（首帧要占主线程约 0.5s）
        let textMain: Task<WordAnalysisResult, Error>?
        let textEnrich: Task<WordEnrichment, Error>?
        if let text {
            textMain = Task.detached {
                try await ZhipuService.shared.analyzeText(text, existingTags: existingTags, categoryTree: categoryTree)
            }
            textEnrich = text.isWord ? Task.detached {
                try await ZhipuService.shared.enrichWord(word: text.target, language: text.language, sentence: text.context)
            } : nil
            AppLog.log("[Analysis] text path '\(text.target.prefix(40))' (\(text.language), \(text.isWord ? "word" : "passage"), \(text.context.count) chars context)")
        } else {
            textMain = nil
            textEnrich = nil
            AppLog.log("[Analysis] no text in selection, image path")
        }

        // 1. 面板立刻弹出（骨架态），不再只显示小转圈
        showResultPanel = true
        resultWindow.show(viewModel: self, modelContext: modelContext)
        PanelPerf.mark(.shown)

        // 8 秒还没结果：告诉用户是对面慢，不是软件没反应（重试通知会再覆盖这句）
        let slowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self.runID == myRun, self.analysisResult == nil, self.netHint == nil else { return }
            self.netHint = String(localized: "服务端响应慢，仍在等待回复…")
        }
        sideTasks.append(slowTask)

        // 1.5 词库命中秒出：拿本地 OCR 读到的目标文字比对已存词条
        if let target = text?.target {
            let candidates = LocalOCR.lookupCandidates(target)
            if !candidates.isEmpty,
               let hit = ((try? modelContext.fetch(FetchDescriptor<WordEntry>())) ?? [])
                   .first(where: { candidates.contains($0.word.lowercased()) }) {
                quickWord = ZhipuService.QuickWord(word: hit.word, language: hit.language.rawValue)
                cachedHit = hit
                enrichStarted = true
                enrichments[0] = WordEnrichment(
                    meaning: nil,
                    usage: hit.analysisNote.isEmpty ? nil : hit.analysisNote,
                    collocations: hit.collocationsText?.components(separatedBy: "\n"),
                    examples: hit.examplesText?.components(separatedBy: "\n"),
                    etymology: hit.etymology
                )
                let defaults = UserDefaults.standard
                let speakOn = defaults.object(forKey: "autoSpeak") == nil ? true : defaults.bool(forKey: "autoSpeak")
                if speakOn { AudioService.shared.speak(hit.word, language: hit.language) }
                AppLog.log("[Analysis] OCR cache hit '\(hit.word)' (\(target.prefix(40)))")
            }
        }

        if let text {
            // 2'. 文字版：词头直接用 OCR 结果，立刻出词头 + 发音，补全已经在路上（不再让模型看图识词）
            if cachedHit != nil {
                textEnrich?.cancel()   // 词库直出自带补全
            } else if text.isWord {
                quickWord = ZhipuService.QuickWord(word: text.target, language: text.language)
                let defaults = UserDefaults.standard
                let speakOn = defaults.object(forKey: "autoSpeak") == nil ? true : defaults.bool(forKey: "autoSpeak")
                if speakOn { AudioService.shared.speak(text.target, language: Language(rawValue: text.language) ?? .english) }
                startEnrichment(word: text.target, language: text.language, meaning: "", sentence: text.context, prefetched: textEnrich)
            }
        } else {
            // 2. 框里读不出字（图片等）：极速识图识词（~2s，出词头 + 发音 + 提前起跑补全）
            let quickTask = Task { @MainActor in
                if let q = try? await ZhipuService.shared.quickExtract(image) {
                    guard self.runID == myRun else { return }          // 已取消
                    guard self.analysisResult == nil else { return }   // 主分析已回来就不用了
                    guard !q.word.isEmpty else {
                        AppLog.log("[Analysis] quick: 知识片段截图，跳过发音/预补全")
                        return
                    }
                    self.quickWord = q
                    AppLog.log("[Analysis] quick word '\(q.word)' (\(q.language))")
                    let defaults = UserDefaults.standard
                    let speakOn = defaults.object(forKey: "autoSpeak") == nil ? true : defaults.bool(forKey: "autoSpeak")
                    if speakOn {
                        let lang = Language(rawValue: q.language.lowercased()) ?? .english
                        AudioService.shared.speak(q.word, language: lang)
                    }
                    // 词库命中：立刻直出已存词条（含现成补全，不再请求）；主分析继续核对语境
                    let langRaw = (Language(rawValue: q.language.lowercased()) ?? .other).rawValue
                    let key = "\(q.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(langRaw)"
                    if let hit = (try? modelContext.fetch(FetchDescriptor<WordEntry>()))?.first(where: { $0.dedupeKey == key }) {
                        self.cachedHit = hit
                        self.enrichStarted = true
                        self.enrichments[0] = WordEnrichment(
                            meaning: nil,
                            usage: hit.analysisNote.isEmpty ? nil : hit.analysisNote,
                            collocations: hit.collocationsText?.components(separatedBy: "\n"),
                            examples: hit.examplesText?.components(separatedBy: "\n"),
                            etymology: hit.etymology
                        )
                        AppLog.log("[Analysis] cache hit '\(hit.word)' (x\(hit.lookupCount))")
                    } else {
                        self.startEnrichment(word: q.word, language: q.language, meaning: "", sentence: "")
                    }
                }
            }
            sideTasks.append(quickTask)
        }

        // 3. 主分析（释义/语法/语境/分类）
        do {
            let task = Task {
                if let textMain {
                    // 文字版：纯文字请求（上面已发出），这里只等结果
                    let analysis = try await withTaskCancellationHandler { try await textMain.value } onCancel: { textMain.cancel() }
                    return AnalysisResult(screenshot: image, screenshotPath: screenshotPath, analysis: analysis)
                }
                return try await self.analysisService.analyze(
                    image: image, screenshotPath: screenshotPath,
                    existingTags: existingTags, categoryTree: categoryTree
                )
            }
            analyzeTask = task
            let result = enforceExclusive(try await task.value)
            PanelPerf.mark(.result(cached: cachedHit != nil))
            guard runID == myRun else {
                isAnalyzing = false
                AppLog.log("[Analysis] cancelled, dropping result")
                return
            }
            isAnalyzing = false
            netHint = nil
            // 快速识词是否认对了（词头一致）
            var quickOK = false
            if let q = quickWord, let first = result.analysis.words.first,
               Self.isSameHeadword(first.word, q.word) { quickOK = true }
            if enrichStarted && !quickOK {
                // 快速识词认错了（或其实是知识片段）→ 丢弃预生成的补全，交回常规补全
                enrichStarted = false
                enrichments[0] = nil
            }
            self.analysisResult = result
            selectedIndices = Set(result.analysis.words.indices)
            for (i, w) in result.analysis.words.enumerated() {
                if let cat = matchCategory(named: w.category, forWords: true) { chosenWordCategory[i] = cat.id }
            }
            for (i, s) in result.analysis.snippets.enumerated() {
                if let cat = matchCategory(named: s.category, forWords: false) { chosenSnippetCategory[i] = cat.id }
                snippetTags[i] = s.tags
            }

            if mode == .capture {
                autoSave(result: result, context: modelContext)
            }

            showResultPanel = true
            AppLog.log("[Analysis] ✓ words=\(result.analysis.words.count) snippets=\(result.analysis.snippets.count) mode=\(mode) autoSaved=\(autoSaved)")
            if !quickOK { autoSpeakIfEnabled(result) }   // 快速通道没赶上/认错了，这里读正确的
            enrichWordsInBackground(result)
        } catch {
            isAnalyzing = false
            if error is CancellationError || runID != myRun {
                AppLog.log("[Analysis] cancelled")
                return
            }
            resultWindow.dismiss()
            showResultPanel = false
            AppLog.log("[Analysis] ✗ \(error)")
            errorMessage = String(localized: "分析失败：\(error.localizedDescription)")
            ErrorPanelController.shared.show(LookupFailure.from(error))
        }
    }

    private func installRetryObserver() {
        guard retryObserver == nil else { return }
        retryObserver = NotificationCenter.default.addObserver(forName: .zhipuRetrying, object: nil, queue: .main) { [weak self] note in
            let n = note.userInfo?["retry"] as? Int ?? 1
            Task { @MainActor [weak self] in
                guard let self, self.analysisResult == nil, n > self.maxRetryShown else { return }
                self.maxRetryShown = n
                self.netHint = String(localized: "服务端响应慢，正在重试（第 \(n) 次）…")
            }
        }
    }

    /// 单词 / 知识片段二选一：模型偶尔两者都给时客户端兜底。
    /// 快速识词认出了具体单词 → 按查词处理；否则（空词头/没赶上）按知识片段处理。
    private func enforceExclusive(_ result: AnalysisResult) -> AnalysisResult {
        let a = result.analysis
        guard !a.words.isEmpty, !a.snippets.isEmpty else { return result }
        let keepWord = (quickWord?.word.isEmpty == false)
        AppLog.log("[Analysis] 模型同时返回单词+片段，兜底保留\(keepWord ? "单词" : "片段")")
        let filtered = WordAnalysisResult(words: keepWord ? a.words : [], snippets: keepWord ? [] : a.snippets)
        return AnalysisResult(screenshot: result.screenshot, screenshotPath: result.screenshotPath, analysis: filtered)
    }

    /// 提前起跑的补全（识词一到就发，不等主分析）；prefetched = 已经在后台发出的同一个请求
    private func startEnrichment(word: String, language: String, meaning: String, sentence: String,
                                 prefetched: Task<WordEnrichment, Error>? = nil) {
        guard !enrichStarted else { return }
        enrichStarted = true
        enrichingIndices = [0]
        let myRun = runID
        let request = prefetched ?? Task.detached {
            try await ZhipuService.shared.enrichWord(word: word, language: language, meaning: meaning, sentence: sentence)
        }
        let t = Task { @MainActor in
            do {
                let e = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
                guard self.runID == myRun else { return }
                if let r = self.analysisResult,
                   r.analysis.words.first?.word.caseInsensitiveCompare(word) != .orderedSame {
                    AppLog.log("[Analysis] pre-enrich '\(word)' 丢弃（实际词头 '\(r.analysis.words.first?.word ?? "-")'）")
                } else {
                    enrichments[0] = e
                    applyEnrichmentToSaved(0, e)
                    if autoSaved, let context = modelContext { scheduleAnkiSync(context: context) }
                }
            } catch {
                AppLog.log("[Analysis] pre-enrich '\(word)' failed: \(error.localizedDescription)")
                enrichStarted = false   // 允许主分析后的常规补全重试
                if analysisResult != nil, enrichments[0] == nil {
                    enrichments[0] = WordEnrichment(meaning: nil, usage: nil, collocations: nil, examples: nil, etymology: nil)   // 停掉加载圈
                }
            }
            enrichingIndices.remove(0)
        }
        sideTasks.append(t)
    }

    private func applyEnrichmentToSaved(_ i: Int, _ e: WordEnrichment) {
        guard let entry = savedWords[i] else { return }
        if let u = e.usage, !u.isEmpty { entry.analysisNote = u }
        if let c = e.collocations, !c.isEmpty { entry.collocationsText = c.joined(separator: "\n") }
        if let ex = e.examples, !ex.isEmpty { entry.examplesText = ex.joined(separator: "\n") }
        if let et = e.etymology, !et.isEmpty { entry.etymology = et }
        try? modelContext?.save()
    }

    /// 快速识词与主分析给出的词头是否算同一个词。主分析常把词还原成原形（jerking→jerk、
    /// obscured→obscure、steamed up→steam up），逐字比较会误判为"认错了"而把同一个词再念一遍。
    /// 判据：按空格拆词后逐词比较，每对词共同前缀足够长且词尾差异不超过 5 个字符就算同一个词；
    /// 词数不同或词根不同（Britain/beloved）才算认错，交回主分析重读。
    static func isSameHeadword(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> [String] {
            s.lowercased()
                .replacingOccurrences(of: "-", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        let wa = norm(a), wb = norm(b)
        guard !wa.isEmpty, wa.count == wb.count else { return false }
        for (x, y) in zip(wa, wb) {
            if x == y { continue }
            let cx = Array(x), cy = Array(y)
            var cp = 0
            while cp < cx.count, cp < cy.count, cx[cp] == cy[cp] { cp += 1 }
            let shorter = min(cx.count, cy.count)
            guard cp >= max(3, shorter - 2) else { return false }
            guard (cx.count - cp) + (cy.count - cp) <= 5 else { return false }
        }
        return true
    }

    /// 查词后自动朗读：读第一个识别到的单词（设置里可关，默认开）
    private func autoSpeakIfEnabled(_ result: AnalysisResult) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoSpeak") == nil ? true : defaults.bool(forKey: "autoSpeak")
        guard enabled, let first = result.analysis.words.first else { return }
        let lang = Language(rawValue: first.language.lowercased()) ?? .english
        AppLog.log("[Audio] auto-speak '\(first.word)'")
        AudioService.shared.speak(first.word, language: lang)
    }

    private func matchCategory(named raw: String?, forWords: Bool) -> Category? {
        guard let raw, !raw.isEmpty else { return nil }
        let leaf = raw.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces) ?? raw
        return leafCategories(forWords: forWords).first { $0.name.caseInsensitiveCompare(leaf) == .orderedSame }
    }

    // MARK: 分解语法

    /// 当前面板正在展示的语境句（主分析优先；词库直出期取已存词条最近一条语境）
    var grammarSentence: (sentence: String, word: String, language: String)? {
        if let w = analysisResult?.analysis.words.first, !w.contextSentence.isEmpty {
            return (w.contextSentence, w.word, w.language)
        }
        if let hit = cachedHit, let ctx = hit.sortedContexts.last, !ctx.sentence.isEmpty {
            return (ctx.sentence, hit.word, hit.language.rawValue)
        }
        return nil
    }

    /// 面板卡片用的打包快照（nil = 没点过按钮，卡片不显示小节）
    var grammarState: GrammarBreakdownState? {
        guard let t = grammarText else { return nil }
        return GrammarBreakdownState(text: t, streaming: grammarStreaming, error: grammarError)
    }

    /// 点「分解语法」：把语境整句流式拆解，文本随生成逐段追加到 `grammarText`
    func breakDownGrammar() {
        guard !grammarStreaming, let target = grammarSentence else { return }
        grammarTask?.cancel()
        grammarText = ""
        grammarError = nil
        grammarStreaming = true
        let myRun = runID
        AppLog.log("[Grammar] start '\(target.word)': \(target.sentence.prefix(80))")
        grammarTask = Task { @MainActor in
            do {
                try await ZhipuService.shared.streamGrammarBreakdown(
                    sentence: target.sentence, word: target.word, language: target.language
                ) { piece in
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == myRun, self.grammarStreaming else { return }
                        self.grammarText = (self.grammarText ?? "") + piece
                    }
                }
            } catch {
                guard self.runID == myRun else { return }
                if error is CancellationError { return }
                AppLog.log("[Grammar] ✗ \(error.localizedDescription)")
                grammarError = error.localizedDescription
            }
            guard self.runID == myRun else { return }
            grammarStreaming = false
        }
    }

    private func resetGrammar() {
        grammarTask?.cancel()
        grammarTask = nil
        grammarText = nil
        grammarStreaming = false
        grammarError = nil
    }

    // MARK: 自动保存 / 撤销

    /// 取词模式：分析一到就全部落库。分类：模型选中的 → 该分类；没选中 → 单词按语言、片段进「其他」。
    /// 模型建议新建的分类不会自动创建（那是用户的决定），面板上可以一键「新建并移入」。
    private func autoSave(result: AnalysisResult, context: ModelContext) {
        do {
            for (index, word) in result.analysis.words.enumerated() {
                let before = try? context.fetchCount(FetchDescriptor<WordContext>())
                let entry = try analysisService.saveWord(
                    word, screenshotPath: result.screenshotPath,
                    category: category(id: chosenWordCategory[index]), context: context
                )
                let after = try? context.fetchCount(FetchDescriptor<WordContext>())
                if let b = before, let a = after, a == b, entry.createdAt < Date().addingTimeInterval(-5) {
                    skippedAsDuplicate.insert(index)   // 老词 + 没新增语境 = 被相似去重跳过
                }
                savedWords[index] = entry
                if chosenWordCategory[index] == nil { chosenWordCategory[index] = entry.category?.id }
            }
            for (index, snippet) in result.analysis.snippets.enumerated() {
                let s = try analysisService.saveSnippet(
                    snippet, screenshotPath: result.screenshotPath,
                    category: category(id: chosenSnippetCategory[index]), context: context
                )
                savedSnippets[index] = s
                if chosenSnippetCategory[index] == nil { chosenSnippetCategory[index] = s.category?.id }
                snippetTags[index] = s.tags
            }
            autoSaved = true
            if result.analysis.words.isEmpty {
                scheduleAnkiSync(context: context)   // 只有片段：直接同步；有单词则等补全后再同步
            }
        } catch {
            errorMessage = String(localized: "保存失败：\(error.localizedDescription)")
            AppLog.log("[Analysis] ✗ autosave: \(error)")
        }
    }

    /// 二段式：面板先出，例句/助记/词根词源用纯文本请求后台补全（不带图，2–4 秒）
    private func enrichWordsInBackground(_ result: AnalysisResult) {
        let words = result.analysis.words
        guard !words.isEmpty else { return }
        // 快速通道已经在补第一个词：把结果写回刚保存的实体即可
        if enrichStarted {
            if let e = enrichments[0] { applyEnrichmentToSaved(0, e) }
            if words.count == 1 {
                if autoSaved, let context = modelContext, enrichingIndices.isEmpty { scheduleAnkiSync(context: context) }
                return
            }
        }
        enrichingIndices = Set(words.indices).subtracting(enrichStarted ? [0] : [])
        let myRun = runID
        let t = Task { @MainActor in
            for (i, w) in words.enumerated() {
                if enrichStarted && i == 0 { continue }
                guard self.runID == myRun else { return }
                do {
                    let e = try await ZhipuService.shared.enrichWord(
                        word: w.word, language: w.language, meaning: w.meaning, sentence: w.contextSentence
                    )
                    enrichments[i] = e
                    applyEnrichmentToSaved(i, e)
                } catch {
                    AppLog.log("[Analysis] enrich '\(w.word)' failed: \(error.localizedDescription)")
                    if enrichments[i] == nil {
                        enrichments[i] = WordEnrichment(meaning: nil, usage: nil, collocations: nil, examples: nil, etymology: nil)   // 停掉加载圈
                    }
                }
                enrichingIndices.remove(i)
            }
            if autoSaved, let context = modelContext {
                scheduleAnkiSync(context: context)
            }
        }
        sideTasks.append(t)
    }

    /// 撤销这次自动保存：新建的条目整个删掉；合并进老词的只删本次新增的语境
    func undoAutoSave() {
        guard let context = modelContext, autoSaved else { return }
        let cutoff = Date().addingTimeInterval(-120)
        for (_, entry) in savedWords {
            if entry.createdAt > cutoff {
                context.delete(entry)
            } else if let newest = entry.sortedContexts.last, newest.createdAt > cutoff, (entry.contexts?.count ?? 0) > 1 {
                context.delete(newest)
            }
        }
        for (_, s) in savedSnippets where s.createdAt > cutoff { context.delete(s) }
        try? context.save()
        AppLog.log("[Analysis] undo autosave: \(savedWords.count) words, \(savedSnippets.count) snippets")
        // 面板留着，切到「未保存」状态：想留再点「保存选中」
        savedWords = [:]
        savedSnippets = [:]
        skippedAsDuplicate = []
        removedWords = []
        removedSnippets = []
        autoSaved = false
        if let result = analysisResult {
            selectedIndices = Set(result.analysis.words.indices)
        }
    }

    // MARK: 单项移除 / 标签编辑

    /// 移除单个已保存的单词（新词整条删；并入老词的只删本次新增语境）
    func removeSavedWord(_ index: Int) {
        guard let context = modelContext, let entry = savedWords[index] else { removedWords.insert(index); return }
        let cutoff = Date().addingTimeInterval(-300)
        if entry.createdAt > cutoff {
            if let nid = entry.ankiNoteId {
                Task { await AnkiService.shared.deleteAnkiNotes(ids: [nid]) }   // 保持 Anki 同步
            }
            context.delete(entry)
        } else if let newest = entry.sortedContexts.last, newest.createdAt > cutoff, (entry.contexts?.count ?? 0) > 1 {
            context.delete(newest)
            entry.syncStatus = .notSynced          // 语境变了，重推 Anki 卡
            scheduleAnkiSync(context: context)
        }
        try? context.save()
        savedWords[index] = nil
        removedWords.insert(index)
        AppLog.log("[Analysis] removed word #\(index) from this capture")
    }

    /// 移除单条已保存的知识片段
    func removeSavedSnippet(_ index: Int) {
        guard let context = modelContext, let s = savedSnippets[index] else { removedSnippets.insert(index); return }
        let title = s.title
        let nid = s.ankiNoteId
        Task { await AnkiService.shared.deleteAnkiNote(forSnippet: nid, title: title) }   // 保持 Anki 同步
        context.delete(s)
        try? context.save()
        savedSnippets[index] = nil
        removedSnippets.insert(index)
        AppLog.log("[Analysis] removed snippet #\(index) from this capture")
    }

    /// 知识片段：添加标签（面板手动输入，或采纳自动生成的）
    func addTag(_ raw: String, toSnippet index: Int) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        var tags = snippetTags[index] ?? []
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        snippetTags[index] = tags
        applyTags(index)
    }

    func removeTag(_ tag: String, fromSnippet index: Int) {
        snippetTags[index] = (snippetTags[index] ?? []).filter { $0 != tag }
        applyTags(index)
    }

    private func applyTags(_ index: Int) {
        guard let s = savedSnippets[index] else { return }
        s.tags = snippetTags[index] ?? []
        s.syncStatus = .notSynced
        try? modelContext?.save()
    }

    /// 手动输入时的补全候选：标签库里前缀/包含匹配
    func tagSuggestions(for text: String) -> [String] {
        guard let context = modelContext else { return [] }
        let all = AnalysisService.allExistingTags(context: context)
        guard !text.isEmpty else { return Array(all.prefix(6)) }
        return all.filter { $0.localizedCaseInsensitiveContains(text) }.prefix(6).map { $0 }
    }

    /// 查词模式下的显式保存
    func saveSelectedResults(context: ModelContext) {
        guard let result = analysisResult else { return }
        do {
            for (index, word) in result.analysis.words.enumerated() where selectedIndices.contains(index) {
                savedWords[index] = try analysisService.saveWord(
                    word, screenshotPath: result.screenshotPath,
                    category: category(id: chosenWordCategory[index]), context: context
                )
            }
            for (index, snippet) in result.analysis.snippets.enumerated() where !removedSnippets.contains(index) {
                let s = try analysisService.saveSnippet(
                    snippet, screenshotPath: result.screenshotPath,
                    category: category(id: chosenSnippetCategory[index]), context: context
                )
                if let tags = snippetTags[index] { s.tags = tags }
                savedSnippets[index] = s
            }
            autoSaved = true
            scheduleAnkiSync(context: context)
            dismissPanel()
        } catch {
            errorMessage = String(localized: "保存失败：\(error.localizedDescription)")
        }
    }

    func saveAllResults(context: ModelContext) {
        guard let result = analysisResult else { return }
        selectedIndices = Set(result.analysis.words.indices)
        saveSelectedResults(context: context)
    }

    /// 保存后自动同步 Anki（Anki 没开就静默跳过，下次再同步）
    private func scheduleAnkiSync(context: ModelContext) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // 给撤销留一点时间，也等发音下载
            await AnkiService.shared.syncEverythingPending(context: context)
        }
    }

    /// 展示用查询次数（老数据兜底到语境数）
    func lookupCountValue(_ entry: WordEntry?) -> Int {
        guard let e = entry else { return 1 }
        return max(e.lookupCount, e.sortedContexts.count, 1)
    }

    func clearError() { errorMessage = nil }

    func dismissPanel() {
        // 结果尚未落库（识别中被 Esc/点外面取消，或查词模式直接关）→ 在途请求全部作废，不查询也不入库
        if !autoSaved {
            analyzeTask?.cancel()
            for t in sideTasks { t.cancel() }
            runID = UUID()
        }
        analyzeTask = nil
        sideTasks = []
        resetGrammar()
        isAnalyzing = false
        resultWindow.dismiss()
        showResultPanel = false
        analysisResult = nil
        selectedIndices = []
        chosenWordCategory = [:]
        chosenSnippetCategory = [:]
        skippedAsDuplicate = []
        // savedWords / savedSnippets / autoSaved 特意保留：
        // 已保存后关面板，后台补全继续跑、写回词条、同步 Anki（下一轮取词开始时才重置）
        errorMessage = nil
    }

    func toggleWordSelection(_ index: Int) {
        if selectedIndices.contains(index) { selectedIndices.remove(index) } else { selectedIndices.insert(index) }
    }
}
