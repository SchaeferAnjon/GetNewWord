// 词库同步拉到云端一行时怎么合并（CloudSyncService.pullAction）：
// 本地有没推上去的改动时保留本地，云端真的变了才用云端的；内容哈希不受日期写法、id 大小写影响

import Foundation
import SwiftData
import Testing
@testable import GetNewWord

@MainActor
struct CloudSyncMergeTests {
    private func hash<T: CloudRow>(_ r: T) -> String { CloudSyncService.contentHash(r) }

    @Test func rules() {
        typealias S = CloudSyncService
        #expect(S.pullAction(local: "a", remote: "a", known: nil) == .unchanged)
        #expect(S.pullAction(local: "a", remote: "a", known: "old") == .unchanged)
        #expect(S.pullAction(local: nil, remote: "a", known: nil) == .applyRemote)
        // 本地删了又被别的设备改过：没有本地这行就照云端的建
        #expect(S.pullAction(local: nil, remote: "a", known: "a") == .applyRemote)
        #expect(S.pullAction(local: "b", remote: "a", known: "a") == .keepLocal)
        #expect(S.pullAction(local: "b", remote: "c", known: "a") == .applyRemote)
        #expect(S.pullAction(local: "b", remote: "c", known: nil) == .applyRemote)
    }

    /// 真实场景：同步后 Anki 写回卡号（本地改了），随后拉到的是自己刚推上去的那一版 → 保留本地，卡号不被冲掉
    @Test func ankiNoteIdWrittenAfterSyncIsKept() throws {
        let context = try makeLibrary()
        let word = WordEntry(word: "confluence", language: .english, meaning: "n. 汇合处", contextSentence: "At the confluence.",
                             contextTranslation: "在交汇处。", analysisNote: "")
        context.insert(word)
        try context.save()

        let pushed = CloudSyncService.row(word)          // 上次推到云端、也记作 known 的那一版
        let known = hash(pushed)
        word.ankiNoteId = 1_700_000_000_123               // 之后 Anki 写回卡号
        let local = hash(CloudSyncService.row(word))
        #expect(local != known)

        // 云端回声：还是推上去的那一版，服务端补了 updated_at
        var echo = pushed
        echo.updatedAt = "2026-10-28T09:00:00.123456+00:00"
        #expect(CloudSyncService.pullAction(local: local, remote: hash(echo), known: known) == .keepLocal)

        // 另一台设备真的改了释义 → 用云端的
        var edited = pushed
        edited.meaning = "n. 汇合处；汇流"
        #expect(CloudSyncService.pullAction(local: local, remote: hash(edited), known: known) == .applyRemote)
    }

    /// Postgres 返回微秒和 +00:00，本地写的是毫秒和 Z：同一时刻算同一版
    @Test func dateFormatsHashTheSame() throws {
        let context = try makeLibrary()
        let created = try #require(CloudDate.parse("2026-09-14T10:00:00.123Z"))
        let word = WordEntry(word: "Vorfahrt", language: .german, meaning: "n. 优先通行权", contextSentence: "Vorfahrt achten.",
                             contextTranslation: "注意让行。", analysisNote: "", createdAt: created)
        context.insert(word)
        let local = CloudSyncService.row(word)
        var remote = local
        remote.createdAt = "2026-09-14T10:00:00.123456+00:00"
        remote.updatedAt = "2026-10-01T08:00:00.5+00:00"
        remote.deletedAt = nil
        #expect(hash(local) == hash(remote))

        remote.createdAt = "2026-09-14T10:00:01.123+00:00"
        #expect(hash(local) != hash(remote))
    }

    @Test func snippetRelatedWordsIgnoreOrderAndCase() {
        let a = SnippetRow(id: "s1", title: "右侧优先", content: "c", sourceContext: "", tags: [], domain: "驾驶",
                           createdAt: "2026-09-14T10:00:00.000Z", isArchived: false, syncStatus: "synced", ankiNoteId: nil,
                           categoryId: nil, relatedWordIds: ["BBB", "aaa"])
        var b = a
        b.relatedWordIds = ["aaa", "bbb"]
        #expect(hash(a) == hash(b))
        b.relatedWordIds = ["aaa"]
        #expect(hash(a) != hash(b))
    }

    @Test func rowsUseLowercaseIds() throws {
        let context = try makeLibrary()
        let parent = Category(name: "语言学习")
        let child = Category(name: "英语", parent: parent)
        let word = WordEntry(word: "run", language: .english, meaning: "v. 跑", contextSentence: "Run.", contextTranslation: "跑。",
                             analysisNote: "", category: child)
        let ctx = WordContext(sentence: "Run.", translation: "跑。", word: word)
        [parent, child].forEach(context.insert)
        context.insert(word)
        context.insert(ctx)
        try context.save()

        #expect(CloudSyncService.row(child).parentId == parent.id.uuidString.lowercased())
        #expect(CloudSyncService.row(word).id == word.id.uuidString.lowercased())
        #expect(CloudSyncService.row(word).categoryId == child.id.uuidString.lowercased())
        #expect(CloudSyncService.row(ctx).wordId == word.id.uuidString.lowercased())
    }

    @Test func cloudDateParsing() {
        #expect(CloudDate.parse("2026-09-14T10:00:00+00:00") != nil)
        #expect(CloudDate.parse("2026-09-14T10:00:00.123456+00:00") == CloudDate.parse("2026-09-14T10:00:00.123Z"))
        #expect(CloudDate.parse("gestern") == nil)
        #expect(CloudDate.normalize("gestern") == "gestern")
    }
}
