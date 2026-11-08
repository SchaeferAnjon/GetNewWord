// AnkiUpgrade.swift
// GetNewWord
//
// Anki 卡片升级里要用户点头的那一步：给笔记类型加字段（单词卡的 Fill、知识卡的 Question）和卡片模板（语境填空）。
// 加字段后 Anki 会要求下一次同步选「上传」，如果手机上有还没同步的复习记录，选错了会丢。
// 所以先讲清楚、让用户先在手机上同步，点「继续」才做；点「以后再说」这次启动里不再问，卡片用老样子，同步只写已有的字段。
// 只改样式和模板文字的那部分不在这里，启动后自动做（AnkiService+Cards.swift）。

import Foundation
import SwiftData

@MainActor
final class AnkiUpgrade: ObservableObject {
    static let shared = AnkiUpgrade()

    /// 主窗口和设置页据此弹出询问
    @Published var promptVisible = false
    /// 还有字段没加（用户没点继续）：设置页的 Anki 里显示一行入口
    @Published private(set) var structurePending = false
    private var incompleteModels: Set<String> = []

    /// 用户这次启动里点过「继续」
    var approved = false
    /// 用户这次启动里点过「以后再说」
    var snoozed = false

    private init() {}

    /// AnkiService 发现要加字段时问一下。已经点过继续就放行；没有就挂起询问（不阻塞同步），返回 false
    func allowStructureChange() -> Bool {
        if approved { return true }
        structurePending = true
        if !snoozed { promptVisible = true }
        return false
    }

    /// 点「继续」
    func proceed(context: ModelContext) {
        approved = true
        promptVisible = false
        Task { await AnkiService.shared.upgradeNow(context: context) }
    }

    /// AnkiService 每次核对完一个笔记类型报一下：字段齐不齐
    func report(model: String, complete: Bool) {
        if complete { incompleteModels.remove(model) } else { incompleteModels.insert(model) }
        structurePending = !incompleteModels.isEmpty
    }

    /// 点「以后再说」
    func later() {
        snoozed = true
        promptVisible = false
    }

    /// 设置页里点「升级卡片」
    func askAgain() {
        snoozed = false
        promptVisible = true
    }

    /// 测试用：回到刚启动的状态
    func resetForTesting() {
        approved = false
        snoozed = false
        promptVisible = false
        structurePending = false
        incompleteModels = []
    }
}
