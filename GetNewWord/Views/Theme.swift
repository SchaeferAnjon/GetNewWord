// Theme.swift
// GetNewWord
//
// 设计 token 与基础组件（Linear / Raycast 气质）：发丝线分隔、单色图标、单一强调色、快捷键提示。
// 颜色全部是「动态色」：跟随系统/用户选择的浅色或深色自动切换。
// 字号：所有视图通过 @Environment(\.fontScale) 取缩放系数，Theme.font(_:) 统一出字体。

import SwiftUI
import AppKit

// MARK: - 字号缩放

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// 用户字号缩放（0.85 … 1.6），根视图从 AppStorage 注入
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    /// 动态色：浅色 / 深色各一套
    private static func dyn(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    // MARK: 颜色
    static let bg        = dyn(light: rgb(250, 250, 251), dark: rgb(22, 23, 26))
    static let surface   = dyn(light: rgb(244, 244, 246), dark: rgb(28, 29, 32))
    static let elevated  = dyn(light: rgb(255, 255, 255), dark: rgb(35, 36, 40))
    static let hover     = dyn(light: rgb(0, 0, 0, 0.04), dark: rgb(255, 255, 255, 0.04))
    static let selected  = dyn(light: rgb(0, 0, 0, 0.07), dark: rgb(255, 255, 255, 0.07))
    static let border    = dyn(light: rgb(0, 0, 0, 0.09), dark: rgb(255, 255, 255, 0.08))
    static let borderStrong = dyn(light: rgb(0, 0, 0, 0.16), dark: rgb(255, 255, 255, 0.14))

    static let text      = dyn(light: rgb(24, 25, 28), dark: rgb(237, 237, 239))
    static let text2     = dyn(light: rgb(95, 99, 108), dark: rgb(140, 145, 155))
    static let text3     = dyn(light: rgb(150, 154, 162), dark: rgb(92, 99, 112))

    static let accent    = dyn(light: rgb(84, 96, 210), dark: rgb(94, 106, 210))   // Linear indigo
    static let accentSoft = accent.opacity(0.18)
    static let warn      = dyn(light: rgb(205, 125, 20), dark: rgb(242, 158, 64))
    static let danger    = dyn(light: rgb(200, 60, 60), dark: rgb(230, 92, 92))
    static let ok        = dyn(light: rgb(40, 150, 90), dark: rgb(92, 194, 133))

    // MARK: 几何
    static let radius: CGFloat = 6
    static let radiusLg: CGFloat = 10
    static let gutter: CGFloat = 14

    // MARK: 字体（带缩放）
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, scale: CGFloat) -> Font {
        .system(size: size * scale, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular, scale: CGFloat) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    /// 难度等级颜色：低饱和，靠明度区分
    static func levelColor(_ d: Difficulty) -> Color {
        switch d {
        case .a1, .a2: return ok
        case .b1, .b2: return accent
        case .c1, .c2: return warn
        }
    }
}

// MARK: - 组件

/// 单色描边小标签（等级 / 语言 / 领域）
struct Chip: View {
    enum Tone { case neutral, accent, custom(Color) }
    let text: String
    var tone: Tone = .neutral
    var mono = true
    @Environment(\.fontScale) private var fs

    var body: some View {
        let color: Color = {
            switch tone {
            case .neutral: return Theme.text2
            case .accent: return Theme.accent
            case .custom(let c): return c
            }
        }()
        Text(text)
            .font(mono ? Theme.mono(10, .medium, scale: fs) : Theme.font(10.5, .medium, scale: fs))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.35), lineWidth: 0.5))
    }
}

/// 快捷键提示 ⌘⇧A
struct Kbd: View {
    let keys: String
    @Environment(\.fontScale) private var fs
    var body: some View {
        Text(keys)
            .font(Theme.mono(10, .medium, scale: fs))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 0.5))
    }
}

/// 区块标题：小号、字距拉开、次级色
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    @Environment(\.fontScale) private var fs
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(Theme.font(10, .semibold, scale: fs))
                .tracking(1.2)
                .foregroundStyle(Theme.text3)
            Spacer()
            if let trailing {
                Text(trailing).font(Theme.mono(10, .medium, scale: fs)).foregroundStyle(Theme.text3)
            }
        }
    }
}

/// 发丝线
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 0.5) }
}

/// 左侧竖线引用块（语境句）
struct QuoteBlock<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.7)).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) { content }
        }
        .padding(.vertical, 2)
    }
}

/// 图标按钮（工具栏 / 详情页动作）
struct IconButton: View {
    let symbol: String
    let help: String
    var kbd: String? = nil
    var tint: Color = Theme.text2
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.fontScale) private var fs

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(Theme.font(12, .medium, scale: fs))
                if let kbd { Kbd(keys: kbd) }
            }
            .foregroundStyle(hovering ? Theme.text : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 行级 hover 背景
struct RowHover: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHover(selected: Bool) -> some View { modifier(RowHover(selected: selected)) }
}

// MARK: - 语境句关键词高亮

enum TextHighlighter {
    /// 把句中出现的目标词（大小写不敏感；找不到完整词就按 4 字符以上共同前缀近似匹配词形变化）
    /// 标成 accent 色 + semibold
    static func highlight(_ word: String, in sentence: String) -> AttributedString {
        var attr = AttributedString(sentence)
        let target = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return attr }

        var matched = false
        // 1) 完整出现（可多处）
        var searchStart = attr.startIndex
        let lowerSentence = sentence.lowercased()
        let lowerTarget = target.lowercased()
        var offset = lowerSentence.startIndex
        while let r = lowerSentence.range(of: lowerTarget, range: offset..<lowerSentence.endIndex) {
            let lower = lowerSentence.distance(from: lowerSentence.startIndex, to: r.lowerBound)
            let length = lowerSentence.distance(from: r.lowerBound, to: r.upperBound)
            if let start = attr.index(attr.startIndex, offsetByCharacters: lower) as AttributedString.Index?,
               let end = attr.index(start, offsetByCharacters: length) as AttributedString.Index? {
                attr[start..<end].foregroundColor = Theme.accent
                attr[start..<end].inlinePresentationIntent = .stronglyEmphasized   // 加粗但不改字号
                matched = true
            }
            offset = r.upperBound
        }
        _ = searchStart
        if matched { return attr }

        // 2) 词形变化：句子里找与目标词共享 ≥4 字符前缀的词
        let stem = String(lowerTarget.prefix(max(4, lowerTarget.count - 2)))
        guard stem.count >= 4 else { return attr }
        var idx = lowerSentence.startIndex
        var charPos = 0
        while idx < lowerSentence.endIndex {
            // 找到一个词的起点
            if lowerSentence[idx].isLetter {
                var end = idx
                while end < lowerSentence.endIndex, lowerSentence[end].isLetter { end = lowerSentence.index(after: end) }
                let token = String(lowerSentence[idx..<end])
                if token.hasPrefix(stem) {
                    let length = token.count
                    if let s = attr.index(attr.startIndex, offsetByCharacters: charPos) as AttributedString.Index?,
                       let e = attr.index(s, offsetByCharacters: length) as AttributedString.Index? {
                        attr[s..<e].foregroundColor = Theme.accent
                        attr[s..<e].inlinePresentationIntent = .stronglyEmphasized
                    }
                }
                charPos += lowerSentence.distance(from: idx, to: end)
                idx = end
            } else {
                idx = lowerSentence.index(after: idx)
                charPos += 1
            }
        }
        return attr
    }

    /// 音标只套一层斜杠：模型有时自己带了 /…/ 或 […]
    static func ipa(_ phonetic: String) -> String {
        "/" + phonetic.trimmingCharacters(in: CharacterSet(charactersIn: "/[] ")) + "/"
    }

    /// 义项拆成几段，每段再给一个去掉结尾「的 / 地 / 得」的版本（「复利的」→「复利」，译文里常是后者）
    private static func senseParts(_ sense: String?) -> [String] {
        let parts = (sense ?? "").components(separatedBy: CharacterSet(charactersIn: "，,、；;／/ "))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.flatMap { p -> [String] in
            guard p.count > 2, let last = p.last, "的地得".contains(last) else { return [p] }
            return [p, String(p.dropLast())]
        }
    }

    /// 译文高亮：优先模型标注的 translationKeyword（逐字摘抄）；无效再退回义项匹配。
    /// 关键词太短时（一个字）会撞上别的词：「复」先命中「更复杂」而不是「复利」——有包含它、也出现在译文里的更长义项就标那个
    static func emphasizeTranslation(_ keyword: String?, sense: String?, in text: String) -> AttributedString {
        let parts = senseParts(sense)
        if let k = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty, text.contains(k) {
            let longer = parts.filter { $0.count > k.count && $0.contains(k) && text.contains($0) }
                .max { $0.count < $1.count }
            return emphasizeMeaning(longer ?? k, in: text)
        }
        if let hit = parts.filter({ text.contains($0) }).max(by: { $0.count < $1.count }) {
            return emphasizeMeaning(hit, in: text)
        }
        return emphasizeMeaning(sense, in: text)
    }

    /// 释义/译文里强调「当前语境义项」：整串优先；没命中就拆子义项（"包括，涉及" → 包括 / 涉及）逐个标
    static func emphasizeMeaning(_ contextMeaning: String?, in meaning: String) -> AttributedString {
        var attr = AttributedString(meaning)
        guard let target = contextMeaning?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else { return attr }
        func mark(_ sub: String) -> Bool {
            guard !sub.isEmpty, let range = meaning.range(of: sub) else { return false }
            let lower = meaning.distance(from: meaning.startIndex, to: range.lowerBound)
            if let s = attr.index(attr.startIndex, offsetByCharacters: lower) as AttributedString.Index?,
               let e = attr.index(s, offsetByCharacters: sub.count) as AttributedString.Index? {
                attr[s..<e].foregroundColor = Theme.accent
                attr[s..<e].inlinePresentationIntent = .stronglyEmphasized
            }
            return true
        }
        if mark(target) { return attr }
        for p in target.components(separatedBy: CharacterSet(charactersIn: "，,、；;／/ ")) {
            _ = mark(p.trimmingCharacters(in: .whitespaces))
        }
        return attr
    }
}
