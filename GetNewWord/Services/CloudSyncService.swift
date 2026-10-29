// CloudSyncService.swift
// GetNewWord
//
// 词库多设备同步（设计见 docs/sync-design.md）：登录共用账号后，把 SwiftData 里的分类 / 单词 / 语境 / 知识片段
// 与 Supabase schema getnewword 双向同步。
// - 不改本地模型：用「上次同步时的内容哈希」检测本地增改，用「已知但本地不存在」检测本地删除（推墓碑）。
// - 一轮：拉远端增量并应用（远端优先）→ 确定性去重收敛 → 应用远端墓碑 → 推本地变更。
// - 音频 / 截图路径是本机文件，不同步也不被远端覆盖。
// - 多台 Mac 同步只给会员：每轮之前问 Supabase 的 getnewword.sync_allowed()（四张表上的限制性 RLS 用的就是它，
//   由会员后台签名写入，改 app 绕不过）；不让同步就不拉不推，本机词库照常用。见 supabase/getnewword-sync-access.sql。

import Foundation
import AppKit
import SwiftData
import CryptoKit

// MARK: - 云端行（字段名 camelCase，编解码时自动转 snake_case 对应表列）

protocol CloudRow: Codable {
    static var table: String { get }
    static var columns: String { get }
    var id: String { get }
    var updatedAt: String? { get set }
    var deletedAt: String? { get set }
    /// 用于内容比较的规范化副本（去掉服务端字段、统一日期格式）
    func normalized() -> Self
}

struct CategoryRow: CloudRow {
    static let table = "categories"
    static let columns = "id,name,icon,color_hex,parent_id,deleted_at"
    var id: String
    var name: String
    var icon: String
    var colorHex: String
    var parentId: String?
    var updatedAt: String? = nil
    var deletedAt: String? = nil

    func normalized() -> CategoryRow {
        var r = self; r.updatedAt = nil; r.deletedAt = nil; return r
    }
}

struct WordRow: CloudRow {
    static let table = "words"
    static let columns = "id,word,phonetic,language,meaning,context_meaning,context_sentence,context_translation,translation_keyword,lookup_count,analysis_note,grammar,collocations_text,examples_text,mnemonic,etymology,difficulty,tags,created_at,review_count,anki_note_id,sync_status,is_archived,category_id,deleted_at"
    var id: String
    var word: String
    var phonetic: String?
    var language: String
    var meaning: String
    var contextMeaning: String?
    var contextSentence: String
    var contextTranslation: String
    var translationKeyword: String?
    var lookupCount: Int
    var analysisNote: String
    var grammar: String?
    var collocationsText: String?
    var examplesText: String?
    var mnemonic: String?
    var etymology: String?
    var difficulty: String
    var tags: [String]
    var createdAt: String
    var reviewCount: Int
    var ankiNoteId: Int?
    var syncStatus: String
    var isArchived: Bool
    var categoryId: String?
    var updatedAt: String? = nil
    var deletedAt: String? = nil

    func normalized() -> WordRow {
        var r = self; r.updatedAt = nil; r.deletedAt = nil; r.createdAt = CloudDate.normalize(createdAt); return r
    }
}

struct ContextRow: CloudRow {
    static let table = "contexts"
    static let columns = "id,word_id,sentence,translation,note,created_at,deleted_at"
    var id: String
    var wordId: String?
    var sentence: String
    var translation: String
    var note: String
    var createdAt: String
    var updatedAt: String? = nil
    var deletedAt: String? = nil

    func normalized() -> ContextRow {
        var r = self; r.updatedAt = nil; r.deletedAt = nil; r.createdAt = CloudDate.normalize(createdAt); return r
    }
}

struct SnippetRow: CloudRow {
    static let table = "snippets"
    static let columns = "id,title,content,source_context,tags,domain,created_at,is_archived,sync_status,anki_note_id,category_id,related_word_ids,deleted_at"
    var id: String
    var title: String
    var content: String
    var sourceContext: String
    var tags: [String]
    var domain: String
    var createdAt: String
    var isArchived: Bool
    var syncStatus: String
    var ankiNoteId: Int?
    var categoryId: String?
    var relatedWordIds: [String]
    var updatedAt: String? = nil
    var deletedAt: String? = nil

    func normalized() -> SnippetRow {
        var r = self; r.updatedAt = nil; r.deletedAt = nil; r.createdAt = CloudDate.normalize(createdAt)
        r.relatedWordIds = relatedWordIds.map { $0.lowercased() }.sorted()
        return r
    }
}

enum CloudDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func format(_ d: Date) -> String { fractional.string(from: d) }

    /// Postgres 返回 `2026-09-14T10:00:00.123456+00:00`：先截到毫秒再解析
    static func parse(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }

    static func normalize(_ s: String) -> String { parse(s).map(format) ?? s }
}

enum CloudSyncError: LocalizedError {
    case http(Int, String)
    /// RLS 拦了（403 / 42501）：这个账号的同步没开
    case denied
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return String(localized: "同步服务 HTTP \(code)：\(body)")
        case .denied: return CloudSyncService.deniedText
        }
    }
}

/// 这个账号现在能不能多台 Mac 同步
enum SyncAccess: Equatable {
    /// 还没问过，或者问不到（断网）：照常试，Supabase 的 RLS 最后说了算
    case unknown
    case allowed
    /// 不是会员（或会员到期）：不拉不推
    case denied

    /// getnewword.sync_allowed() 的回话 → 能不能同步。404 = Supabase 上还没加这个函数（会员限制还没上线），照旧同步
    static func from(status: Int, body: Data) -> SyncAccess {
        if status == 404 { return .allowed }
        guard (200..<300).contains(status) else { return .unknown }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "true": return .allowed
        case "false": return .denied
        default: return .unknown
        }
    }

    /// PostgREST 的报错是不是 RLS 拦了写：403，或 body 里的错误码 42501
    static func isRLSDenial(status: Int, body: Data) -> Bool {
        status == 403 || String(decoding: body.prefix(300), as: UTF8.self).contains("42501")
    }
}

// MARK: - 服务

@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastResult = ""
    @Published private(set) var access: SyncAccess = .unknown
    private var accessCheckedAt: Date?
    private var accessUser: String?
    /// 会员后台说能同步、Supabase 还没打开时，请后台再推一次（10 分钟一次）
    private var relinkedAt: Date?

    nonisolated static var deniedText: String { String(localized: "多台 Mac 同步是会员功能，本机词库不受影响。") }

    /// 旁路同步状态（按账号分文件）
    private struct State: Codable {
        /// 服务端 updated_at 游标（只由拉取推进）
        var cursor: String?
        /// "<表>/<id>" → 上次与云端一致时的内容哈希
        var known: [String: String] = [:]
        /// 从云端拉来、本机 Anki 还没见过的 note id：反向清理时不能当成「用户在 Anki 删了卡」
        var unconfirmedAnki: Set<Int> = []
    }

    private var context: ModelContext?
    private var state = State()
    private var stateUserId: String?
    private var timer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var rerunRequested = false
    private var applyingRemote = false
    private var observers: [NSObjectProtocol] = []
    private let realtime = CloudRealtime()

    private let pollInterval: TimeInterval = 60
    private let pageSize = 1000
    private let pushChunk = 200

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()
    private static let hashEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    private init() {}

    /// App 启动时挂上：本地保存后防抖同步、回到前台同步、每分钟兜底。未登录时全部空转。
    func start(context: ModelContext) {
        self.context = context
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = [
            NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.applyingRemote else { return }
                    self.scheduleSync(after: 3)
                }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 1) }
            },
            // 成了会员、到期、刚绑好同步账号：重新问一次能不能同步
            NotificationCenter.default.addObserver(forName: .memberStatusChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.accessCheckedAt = nil
                    self?.scheduleSync(after: 1)
                }
            },
        ]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        // 另一台设备改动 → Realtime 通知 → 1 秒后拉取；轮询只做兜底
        realtime.onChange = { [weak self] in self?.scheduleSync(after: 1) }
        realtime.start()
        scheduleSync(after: 2)
    }

    func scheduleSync(after seconds: Double) {
        guard SupabaseAuth.shared.session != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // 另起任务：之后的 cancel 只取消「还在等」的防抖，不会把进行中的请求取消成 -999
            Task { @MainActor in await self.syncNow() }
        }
    }

    func syncNow() async {
        guard let context, let session = SupabaseAuth.shared.session else { return }
        if isSyncing { rerunRequested = true; return }
        isSyncing = true
        loadState(userId: session.userId)
        guard await syncAllowed(session) else {
            realtime.stop()
            lastResult = Self.deniedText
            isSyncing = false
            return
        }
        do {
            let pulled = try await pull(context: context)
            let pushed = try await push(context: context)
            lastSyncAt = Date()
            lastResult = pulled + pushed == 0 ? String(localized: "已是最新") : String(localized: "拉取 \(pulled) 条，上传 \(pushed) 条")
            if pulled + pushed > 0 { AppLog.log("[Cloud] sync: pulled \(pulled), pushed \(pushed)") }
            realtime.start()   // 刚登录时启动实时订阅；已连着则无操作
        } catch SupabaseAuthError.notSignedIn {
            realtime.stop()
            lastResult = String(localized: "登录已失效，请重新登录")
        } catch CloudSyncError.denied {
            // RLS 拦了：会员到期了，或者后台还没把这个账号打开。停同步、查一次会员状态
            realtime.stop()
            access = .denied
            accessCheckedAt = Date()
            lastResult = Self.deniedText
            AppLog.log("[Cloud] sync denied by RLS")
            Task { await MemberService.shared.refresh() }
        } catch {
            lastResult = String(localized: "同步失败：\(error.localizedDescription)")
            AppLog.log("[Cloud] ✗ sync: \(error)")
        }
        saveState()
        isSyncing = false
        if rerunRequested {
            rerunRequested = false
            scheduleSync(after: 1)
        }
    }

    // MARK: - 能不能同步（会员才有）

    /// 问 Supabase 这个账号能不能同步，10 分钟内问过就用上次的。不让同步、会员后台又说这张授权是会员时：
    /// 没绑过，或绑的就是这个账号（推送还没到 Supabase），请后台再推一次；绑的是别的账号不动，等人在「账号与同步」里点了才换
    private func syncAllowed(_ session: SupabaseSession) async -> Bool {
        let userId = session.userId
        if accessUser != userId { accessUser = userId; accessCheckedAt = nil; access = .unknown }
        if let at = accessCheckedAt, Date().timeIntervalSince(at) < 600 { return access != .denied }
        access = await askAccess()
        accessCheckedAt = Date()
        if access == .denied, let link = MemberService.shared.status?.sync, link.allowed,
           Self.shouldAskPushAgain(link: link, email: session.email),
           (relinkedAt.map { Date().timeIntervalSince($0) > 600 } ?? true) {
            relinkedAt = Date()
            AppLog.log("[Cloud] member says sync allowed but Supabase not yet; asking the member server to push again")
            await MemberService.shared.linkSync()
            access = await askAccess()
        }
        if access == .denied { AppLog.log("[Cloud] sync not allowed for this account (not a member)") }
        return access != .denied
    }

    /// 会员后台说能同步、Supabase 还不让时，要不要请后台再推：没绑过，或绑的就是这个账号
    nonisolated static func shouldAskPushAgain(link: MemberStatus.Sync, email: String?) -> Bool {
        !link.linked || MemberService.sameEmail(link.email, email)
    }

    private func askAccess() async -> SyncAccess {
        do {
            let token = try await SupabaseAuth.shared.validAccessToken()
            var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("rest/v1/rpc/sync_allowed"))
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.setValue(SupabaseConfig.schema, forHTTPHeaderField: "Content-Profile")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let result = SyncAccess.from(status: status, body: data)
            if status == 404 { AppLog.log("[Cloud] sync_allowed() not in Supabase yet: syncing as before") }
            else if result == .unknown { AppLog.log("[Cloud] sync_allowed HTTP \(status)") }
            return result
        } catch {
            AppLog.log("[Cloud] sync_allowed failed: \((error as? URLError)?.code.rawValue.description ?? String(describing: type(of: error)))")
            return .unknown
        }
    }

    /// 刚登录、刚成了会员：马上重新问
    func recheckAccess() {
        accessCheckedAt = nil
        scheduleSync(after: 1)
    }

    /// 登出：丢掉该账号的同步状态；本地数据保留
    func signOut() async {
        debounceTask?.cancel()
        realtime.stop()
        if let uid = SupabaseAuth.shared.session?.userId {
            try? FileManager.default.removeItem(at: stateURL(userId: uid))
        }
        state = State()
        stateUserId = nil
        lastSyncAt = nil
        lastResult = ""
        access = .unknown
        accessCheckedAt = nil
        accessUser = nil
        await SupabaseAuth.shared.signOut()
    }

    // MARK: - Anki 反向清理保护

    func isUnconfirmedAnkiNote(_ id: Int) -> Bool { state.unconfirmedAnki.contains(id) }

    /// 本机 Anki 已查到这些卡：之后在 Anki 里删掉就可以正常反向清理
    func confirmAnkiNotes(_ ids: [Int]) {
        let before = state.unconfirmedAnki.count
        state.unconfirmedAnki.subtract(ids)
        if state.unconfirmedAnki.count != before { saveState() }
    }

    // MARK: - 拉取

    private func pull(context: ModelContext) async throws -> Int {
        let since = state.cursor.flatMap(CloudDate.parse)?.addingTimeInterval(-5)
        let catRows: [CategoryRow] = try await fetchChanged(since: since)
        let wordRows: [WordRow] = try await fetchChanged(since: since)
        let ctxRows: [ContextRow] = try await fetchChanged(since: since)
        let snipRows: [SnippetRow] = try await fetchChanged(since: since)

        applyingRemote = true
        defer { applyingRemote = false }

        var cats = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Category>())) ?? []).map { (key($0.id), $0) })
        var words = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<WordEntry>())) ?? []).map { (key($0.id), $0) })
        var ctxs = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<WordContext>())) ?? []).map { (key($0.id), $0) })
        var snips = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<KnowledgeSnippet>())) ?? []).map { (key($0.id), $0) })
        var applied = 0

        // 1. 增改（先父后子，关系按 id 解析）
        for r in catRows where r.deletedAt == nil {
            switch pullAction(r, local: cats[r.id].map(Self.row)) {
            case .unchanged: markKnown(r); continue
            case .keepLocal: continue
            case .applyRemote: break
            }
            guard let uuid = UUID(uuidString: r.id) else { continue }
            let c = cats[r.id] ?? { let n = Category(id: uuid, name: r.name); context.insert(n); cats[r.id] = n; return n }()
            c.name = r.name; c.icon = r.icon; c.colorHex = r.colorHex
            markKnown(r); applied += 1
        }
        for r in catRows where r.deletedAt == nil {
            cats[r.id]?.parent = r.parentId.flatMap { cats[$0.lowercased()] }
        }

        var insertedWords = false
        for r in wordRows where r.deletedAt == nil {
            switch pullAction(r, local: words[r.id].map(Self.row)) {
            case .unchanged: markKnown(r); continue
            case .keepLocal: continue
            case .applyRemote: break
            }
            guard let uuid = UUID(uuidString: r.id) else { continue }
            let w = words[r.id] ?? {
                let n = WordEntry(id: uuid, word: r.word, meaning: r.meaning, contextSentence: r.contextSentence,
                                  contextTranslation: r.contextTranslation, analysisNote: r.analysisNote)
                context.insert(n); words[r.id] = n; insertedWords = true; return n
            }()
            if let nid = r.ankiNoteId, w.ankiNoteId != nid { state.unconfirmedAnki.insert(nid) }
            w.word = r.word; w.phonetic = r.phonetic; w.languageRaw = r.language; w.meaning = r.meaning
            w.contextMeaning = r.contextMeaning; w.contextSentence = r.contextSentence; w.contextTranslation = r.contextTranslation
            w.translationKeyword = r.translationKeyword; w.lookupCount = r.lookupCount; w.analysisNote = r.analysisNote
            w.grammar = r.grammar; w.collocationsText = r.collocationsText; w.examplesText = r.examplesText
            w.mnemonic = r.mnemonic; w.etymology = r.etymology; w.difficultyRaw = r.difficulty; w.tags = r.tags
            w.createdAt = CloudDate.parse(r.createdAt) ?? w.createdAt; w.reviewCount = r.reviewCount
            w.ankiNoteId = r.ankiNoteId; w.syncStatusRaw = r.syncStatus; w.isArchived = r.isArchived
            w.category = r.categoryId.flatMap { cats[$0.lowercased()] }
            markKnown(r); applied += 1
        }

        for r in ctxRows where r.deletedAt == nil {
            switch pullAction(r, local: ctxs[r.id].map(Self.row)) {
            case .unchanged: markKnown(r); continue
            case .keepLocal: continue
            case .applyRemote: break
            }
            guard let uuid = UUID(uuidString: r.id) else { continue }
            let c = ctxs[r.id] ?? {
                let n = WordContext(id: uuid, sentence: r.sentence, translation: r.translation)
                context.insert(n); ctxs[r.id] = n; return n
            }()
            c.sentence = r.sentence; c.translation = r.translation; c.note = r.note
            c.createdAt = CloudDate.parse(r.createdAt) ?? c.createdAt
            c.word = r.wordId.flatMap { words[$0.lowercased()] }
            markKnown(r); applied += 1
        }

        for r in snipRows where r.deletedAt == nil {
            switch pullAction(r, local: snips[r.id].map(Self.row)) {
            case .unchanged: markKnown(r); continue
            case .keepLocal: continue
            case .applyRemote: break
            }
            guard let uuid = UUID(uuidString: r.id) else { continue }
            let s = snips[r.id] ?? {
                let n = KnowledgeSnippet(id: uuid, title: r.title, content: r.content, sourceContext: r.sourceContext, domain: r.domain)
                context.insert(n); snips[r.id] = n; return n
            }()
            if let nid = r.ankiNoteId, s.ankiNoteId != nid { state.unconfirmedAnki.insert(nid) }
            s.title = r.title; s.content = r.content; s.sourceContext = r.sourceContext; s.tags = r.tags; s.domain = r.domain
            s.createdAt = CloudDate.parse(r.createdAt) ?? s.createdAt; s.isArchived = r.isArchived
            s.syncStatusRaw = r.syncStatus; s.ankiNoteId = r.ankiNoteId
            s.category = r.categoryId.flatMap { cats[$0.lowercased()] }
            s.relatedWords = r.relatedWordIds.compactMap { words[$0.lowercased()] }
            markKnown(r); applied += 1
        }

        // 2. 收敛：两台各自新建的同名分类 / 同词条目，用两边一致的确定性规则合并（被合并掉的会作为本地删除推墓碑）
        mergeDuplicateCategories(context: context)
        AnalysisService.shared.mergeDuplicateWords(context: context)

        // 3. 墓碑（先子后父，避免级联删掉刚被改挂到别处的记录）
        for r in snipRows where r.deletedAt != nil {
            if let s = snips.removeValue(forKey: r.id), s.modelContext != nil { context.delete(s); applied += 1 }
            state.known.removeValue(forKey: knownKey(r))
        }
        for r in ctxRows where r.deletedAt != nil {
            if let c = ctxs.removeValue(forKey: r.id), c.modelContext != nil { context.delete(c); applied += 1 }
            state.known.removeValue(forKey: knownKey(r))
        }
        for r in wordRows where r.deletedAt != nil {
            if let w = words.removeValue(forKey: r.id), w.modelContext != nil { context.delete(w); applied += 1 }
            state.known.removeValue(forKey: knownKey(r))
        }
        for r in catRows where r.deletedAt != nil {
            if let c = cats.removeValue(forKey: r.id), c.modelContext != nil { context.delete(c); applied += 1 }
            state.known.removeValue(forKey: knownKey(r))
        }

        if context.hasChanges { try context.save() }

        // 游标只由拉取推进（推送返回的时间可能越过别的设备刚提交的行）
        let stamps = catRows.map(\.updatedAt) + wordRows.map(\.updatedAt) + ctxRows.map(\.updatedAt) + snipRows.map(\.updatedAt)
        if let maxStamp = stamps.compactMap({ $0.flatMap(CloudDate.parse) }).max(),
           maxStamp > (state.cursor.flatMap(CloudDate.parse) ?? .distantPast) {
            state.cursor = CloudDate.format(maxStamp)
        }
        if insertedWords { AnalysisService.shared.backfillAudio(context: context) }
        return applied
    }

    /// 同父同名的分类只留 uuid 最小的一个，其余的单词 / 片段 / 子分类改挂过去后删除
    private func mergeDuplicateCategories(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<Category>()) else { return }
        func path(_ c: Category) -> String {
            var names = [c.name]
            var p = c.parent
            var guardDepth = 0
            while let cur = p, guardDepth < 16 { names.append(cur.name); p = cur.parent; guardDepth += 1 }
            return names.reversed().joined(separator: "/")
        }
        let groups = Dictionary(grouping: all, by: path)
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { key($0.id) < key($1.id) }
            let keeper = sorted[0]
            for dup in sorted.dropFirst() {
                for w in dup.words { w.category = keeper }
                for s in dup.snippets { s.category = keeper }
                for child in dup.children { child.parent = keeper }
                context.delete(dup)
            }
        }
    }

    // MARK: - 推送

    private func push(context: ModelContext) async throws -> Int {
        let cats = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let words = (try? context.fetch(FetchDescriptor<WordEntry>())) ?? []
        let ctxs = (try? context.fetch(FetchDescriptor<WordContext>())) ?? []
        let snips = (try? context.fetch(FetchDescriptor<KnowledgeSnippet>())) ?? []

        var count = 0
        count += try await pushTable(cats.map(Self.row))
        count += try await pushTable(words.map(Self.row))
        count += try await pushTable(ctxs.filter { $0.word != nil }.map(Self.row))
        count += try await pushTable(snips.map(Self.row))

        // 本地已不存在但云端认识的记录 → 墓碑（先子后父）
        count += try await pushTombstones(table: SnippetRow.table, alive: Set(snips.map { key($0.id) }))
        count += try await pushTombstones(table: ContextRow.table, alive: Set(ctxs.filter { $0.word != nil }.map { key($0.id) }))
        count += try await pushTombstones(table: WordRow.table, alive: Set(words.map { key($0.id) }))
        count += try await pushTombstones(table: CategoryRow.table, alive: Set(cats.map { key($0.id) }))
        return count
    }

    private func pushTable<T: CloudRow>(_ rows: [T]) async throws -> Int {
        let changed = rows.filter { state.known[knownKey($0)] != hash($0) }
        guard !changed.isEmpty else { return 0 }
        for start in stride(from: 0, to: changed.count, by: pushChunk) {
            let chunk = Array(changed[start..<min(start + pushChunk, changed.count)])
            _ = try await rest("POST", T.table,
                               query: [URLQueryItem(name: "on_conflict", value: "id"), URLQueryItem(name: "columns", value: T.columns)],
                               body: try encoder.encode(chunk),
                               prefer: "resolution=merge-duplicates,return=minimal")
            for r in chunk { markKnown(r) }
            saveState()
        }
        return changed.count
    }

    private func pushTombstones(table: String, alive: Set<String>) async throws -> Int {
        let prefix = table + "/"
        let gone = state.known.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.filter { !alive.contains($0) }
        guard !gone.isEmpty else { return 0 }
        let body = try JSONSerialization.data(withJSONObject: ["deleted_at": CloudDate.format(Date())])
        for start in stride(from: 0, to: gone.count, by: 100) {
            let chunk = Array(gone[start..<min(start + 100, gone.count)])
            // 要回改到的行（只要 id）：RLS 不让改时 PATCH 不报错、只是改了 0 行，不看回话就会把没推上去的删除当成推好了
            let data = try await rest("PATCH", table,
                                      query: [URLQueryItem(name: "id", value: "in.(\(chunk.joined(separator: ",")))"),
                                              URLQueryItem(name: "select", value: "id")],
                                      body: body, prefer: "return=representation")
            if Self.updatedRows(data) == 0 {
                // 一行都没改到：先问能不能同步。不让就是 RLS 拦了；问不到这一轮先不算推好，下一轮再推
                switch await askAccess() {
                case .denied: throw CloudSyncError.denied
                case .unknown: throw CloudSyncError.http(0, "tombstones not confirmed")
                case .allowed: break   // 云端真的没有这几行了
                }
            }
            for id in chunk { state.known.removeValue(forKey: prefix + id) }
            saveState()
        }
        return gone.count
    }

    /// PATCH（return=representation）回了几行；读不懂回 nil
    nonisolated static func updatedRows(_ data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count
    }

    // MARK: - 拉到的一行怎么处理

    enum PullAction: Equatable {
        /// 和本地一样：只记下这一版已经对上
        case unchanged
        /// 云端还是本机上次同步时的那一版（多半是自己刚推上去的回声），本地之后又改过（如 Anki 刚写回卡号）：
        /// 本地有没推上去的改动，保留本地，交给随后的 push 上传
        case keepLocal
        /// 本地没有，或者云端真的变了：用云端的（远端优先）
        case applyRemote
    }

    /// 四张表同一套规则。参数都是内容哈希：local 本地这一行（本地没有为 nil），remote 云端这一行，known 上次同步时对上的那一版
    static func pullAction(local: String?, remote: String, known: String?) -> PullAction {
        if local == remote { return .unchanged }
        if local != nil, known == remote { return .keepLocal }
        return .applyRemote
    }

    private func pullAction<T: CloudRow>(_ remote: T, local: T?) -> PullAction {
        Self.pullAction(local: local.map(hash), remote: hash(remote), known: state.known[knownKey(remote)])
    }

    // MARK: - 本地模型 → 云端行

    static func row(_ c: Category) -> CategoryRow {
        CategoryRow(id: key(c.id), name: c.name, icon: c.icon, colorHex: c.colorHex, parentId: c.parent.map { key($0.id) })
    }

    static func row(_ w: WordEntry) -> WordRow {
        WordRow(id: key(w.id), word: w.word, phonetic: w.phonetic, language: w.languageRaw, meaning: w.meaning,
                contextMeaning: w.contextMeaning, contextSentence: w.contextSentence, contextTranslation: w.contextTranslation,
                translationKeyword: w.translationKeyword, lookupCount: w.lookupCount, analysisNote: w.analysisNote,
                grammar: w.grammar, collocationsText: w.collocationsText, examplesText: w.examplesText,
                mnemonic: w.mnemonic, etymology: w.etymology, difficulty: w.difficultyRaw, tags: w.tags,
                createdAt: CloudDate.format(w.createdAt), reviewCount: w.reviewCount, ankiNoteId: w.ankiNoteId,
                syncStatus: w.syncStatusRaw, isArchived: w.isArchived, categoryId: w.category.map { key($0.id) })
    }

    static func row(_ c: WordContext) -> ContextRow {
        ContextRow(id: key(c.id), wordId: c.word.map { key($0.id) }, sentence: c.sentence, translation: c.translation,
                   note: c.note, createdAt: CloudDate.format(c.createdAt))
    }

    static func row(_ s: KnowledgeSnippet) -> SnippetRow {
        SnippetRow(id: key(s.id), title: s.title, content: s.content, sourceContext: s.sourceContext, tags: s.tags,
                   domain: s.domain, createdAt: CloudDate.format(s.createdAt), isArchived: s.isArchived,
                   syncStatus: s.syncStatusRaw, ankiNoteId: s.ankiNoteId, categoryId: s.category.map { key($0.id) },
                   relatedWordIds: s.relatedWords.map { key($0.id) })
    }

    // MARK: - 工具

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func key(_ id: UUID) -> String { Self.key(id) }
    private func knownKey<T: CloudRow>(_ r: T) -> String { "\(T.table)/\(r.id.lowercased())" }
    private func markKnown<T: CloudRow>(_ r: T) { state.known[knownKey(r)] = hash(r) }

    private func hash<T: CloudRow>(_ r: T) -> String { Self.contentHash(r) }

    /// 规范化后的内容哈希：updated_at、deleted_at 不算，日期统一成毫秒，片段关联的词 id 不分大小写和顺序
    static func contentHash<T: CloudRow>(_ r: T) -> String {
        let data = (try? hashEncoder.encode(r.normalized())) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fetchChanged<T: CloudRow>(since: Date?) async throws -> [T] {
        var all: [T] = []
        while true {
            var q = [URLQueryItem(name: "select", value: "*"),
                     URLQueryItem(name: "order", value: "updated_at.asc,id.asc"),
                     URLQueryItem(name: "limit", value: String(pageSize)),
                     URLQueryItem(name: "offset", value: String(all.count))]
            if let since { q.append(URLQueryItem(name: "updated_at", value: "gt." + CloudDate.format(since))) }
            let page = try decoder.decode([T].self, from: try await rest("GET", T.table, query: q))
            all += page
            if page.count < pageSize { return all }
        }
    }

    private func rest(_ method: String, _ table: String, query: [URLQueryItem], body: Data? = nil, prefer: String? = nil) async throws -> Data {
        let token = try await SupabaseAuth.shared.validAccessToken()
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue(SupabaseConfig.schema, forHTTPHeaderField: method == "GET" ? "Accept-Profile" : "Content-Profile")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if SyncAccess.isRLSDenial(status: status, body: data) { throw CloudSyncError.denied }
            throw CloudSyncError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    // MARK: - 状态文件

    private func stateURL(userId: String) -> URL {
        AppVariant.supportDirectory.appendingPathComponent("sync-state-\(userId).json")
    }

    private func loadState(userId: String) {
        guard stateUserId != userId else { return }
        stateUserId = userId
        if let data = try? Data(contentsOf: stateURL(userId: userId)),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State()
        }
    }

    private func saveState() {
        guard let uid = stateUserId, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL(userId: uid), options: .atomic)
    }
}
