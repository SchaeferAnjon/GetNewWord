// WordCardView.swift
// GetNewWord
//
// 单词列表行（方向 A）：两行字，词 + 音标 / 释义；右边灰色等级，下面「德语 · 3 次」。
// 没有语法行、没有同步图标（同步状态在侧栏和详情底部，失败了才在词旁边亮一个红点）。

import SwiftUI

struct WordCardView: View {
    @Environment(\.fontScale) private var fs
    let word: WordEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.word)
                        .font(Theme.font(15, .semibold, scale: fs))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if word.syncStatus == .syncFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(Theme.font(11, scale: fs)).foregroundStyle(Theme.danger)
                            .help("同步失败，下次会重试")
                    }
                    if let phonetic = word.phonetic, !phonetic.isEmpty {
                        Text(TextHighlighter.ipa(phonetic))
                            .font(Theme.mono(11, scale: fs))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                    }
                }
                Text(word.meaning)
                    .font(Theme.font(12, scale: fs))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Tag(text: LocalizedStringKey(word.difficulty.displayName))
                Text(meta)
                    .font(Theme.font(12, scale: fs))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    /// 「德语 · 3 次」：只遇到一次就只写语言
    private var meta: String {
        let n = word.contexts?.count ?? 0
        return n > 1 ? String(localized: "\(word.language.displayName) · \(n) 次") : word.language.displayName
    }
}
