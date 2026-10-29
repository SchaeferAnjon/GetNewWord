// DetailParts.swift
// GetNewWord
//
// 主窗口三栏（design/main-window 方向 A「三栏书房」）共用的小零件：
// 单词动作（详情页按钮和列表右键菜单共用）、截图缩略图、详情区块、编辑框、图标按钮、分组菜单。

import SwiftUI
import SwiftData
import AppKit
import ImageIO

// MARK: - 单词动作

/// 重新讲解、找图、复制：详情页的按钮和列表的右键菜单用同一份，转圈状态也共用
@MainActor
final class WordActions: ObservableObject {
    static let shared = WordActions()

    /// 正在重新讲解的词（详情页据此转圈）
    @Published private(set) var regenerating: Set<UUID> = []

    /// 二段式补全在中途关面板/退出应用时会中断，这里可随时补齐或重新生成
    func regenerate(_ word: WordEntry, context: ModelContext) {
        let id = word.id
        guard !regenerating.contains(id) else { return }
        regenerating.insert(id)
        let w = word.word
        let lang = word.language.rawValue
        let meaning = word.meaning
        let sentence = word.sortedContexts.first?.sentence ?? word.contextSentence
        Task { @MainActor in
            do {
                let e = try await ZhipuService.shared.enrichWord(word: w, language: lang, meaning: meaning, sentence: sentence)
                if !word.isDeleted {
                    if let m = e.meaning, !m.isEmpty { word.meaning = m }   // 释义带上词性分组
                    if let u = e.usage, !u.isEmpty { word.analysisNote = u }
                    if let c = e.collocations, !c.isEmpty { word.collocationsText = c.joined(separator: "\n") }
                    if let ex = e.examples, !ex.isEmpty { word.examplesText = ex.joined(separator: "\n") }
                    if let et = e.etymology, !et.isEmpty { word.etymology = et }
                    word.syncStatus = .notSynced   // 内容变了，Anki 下次同步更新
                    try? context.save()
                    AppLog.log("[Detail] regenerated AI content for '\(w)'")
                }
            } catch {
                AppLog.log("[Detail] regenerate failed for '\(w)': \(error.localizedDescription)")
            }
            regenerating.remove(id)
        }
    }

    /// 浏览器里搜图：多义词消歧，搜「词 + 当前语境义项」
    static func searchImages(for word: WordEntry) {
        let sense = (word.contextMeaning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = sense.isEmpty ? word.word : "\(word.word) \(sense)"
        if let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?tbm=isch&q=\(q)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 截图缩略图

/// 语境截图的小图：后台缩小再显示（原图可能是整屏），点开用预览看大图
struct ScreenshotThumb: View {
    let path: String
    /// 固定宽度放在文字右边；nil 是单独占一行（窄窗口里放在文字下面），高度不超过 maxHeight
    var width: CGFloat? = 120
    var maxHeight: CGFloat = 96
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Group {
                    if let width {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: width)
                    } else {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: maxHeight)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong, lineWidth: 0.5))
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .help("点开看大图")
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            } else if missing {
                EmptyView()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Theme.selected)
                    .frame(width: width, height: (width ?? 160) * 0.6)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        // 换词时这张图跟着换：先回到占位，不留着上一个词的截图
        image = nil
        missing = false
        let p = path, w = width ?? 480
        let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(w * 2),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        image = thumb
        missing = thumb == nil
    }
}

// MARK: - 详情区块

/// 区块：12 号灰字标题 + 内容；标题不再是大写加宽的小字
struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @Environment(\.fontScale) private var fs

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.font(12, .medium, scale: fs)).foregroundStyle(Theme.text2)
            content
        }
    }
}

/// 详情页右上角的图标按钮：28 见方，悬停有底
struct DetailIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color = Theme.text2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(hovering ? Theme.text : tint)
                .frame(width: 28, height: 28)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension TextHighlighter {
    /// 用法、搭配、例句里的词头：只加粗，不上强调色（强调色留给原句里被查的词、这句里的意思和图表）
    static func quietHighlight(_ word: String, in text: String) -> AttributedString {
        var attr = highlight(word, in: text)
        let ranges = attr.runs.filter { $0.foregroundColor != nil }.map(\.range)
        for r in ranges { attr[r].foregroundColor = Theme.text }
        return attr
    }
}

/// 同步状态的小圆点：已同步绿、等着同步黄、失败红
struct SyncDot: View {
    let status: SyncStatus
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
    private var color: Color {
        switch status {
        case .synced: return Theme.ok
        case .syncFailed: return Theme.danger
        case .notSynced: return Theme.warn
        case .archived: return Theme.text3
        }
    }
}

extension SyncStatus {
    /// 详情页底部的整句：「已同步到 Anki」
    var footLabel: LocalizedStringKey {
        switch self {
        case .synced: return "已同步到 Anki"
        case .notSynced: return "等着同步到 Anki"
        case .syncFailed: return "同步失败，下次会重试"
        case .archived: return "已归档"
        }
    }
}

// MARK: - 编辑框

/// 编辑时的输入框：描边白底，圆角 5（不用系统 roundedBorder）
struct EditFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderStrong, lineWidth: 0.5))
    }
}

extension View {
    func editField() -> some View { modifier(EditFieldModifier()) }
}

// MARK: - 分组菜单

/// 列表顶上「按天 ⌄」：改列表怎么分组
struct GroupMenu: View {
    @Binding var mode: CategorySidebar.GroupMode
    let options: [CategorySidebar.GroupMode]
    @Environment(\.fontScale) private var fs
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("分组", selection: $mode) {
                ForEach(options, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(mode.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(Theme.font(12, scale: fs))
            .foregroundStyle(hovering ? Theme.text : Theme.text2)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("列表怎么分组")
    }
}

/// 列表分组标题：「今天 4」，普通小字
struct GroupHeader: View {
    let title: String
    let count: Int
    @Environment(\.fontScale) private var fs

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.font(12, .medium, scale: fs)).foregroundStyle(Theme.text2)
            Text("\(count)").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 空状态：一个图标、一句标题、一句话；一页只放一个
struct EmptyHint: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    @Environment(\.fontScale) private var fs

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.text3)
                .padding(.bottom, 6)
            Text(title).font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text)
            if let message {
                Text(message).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 按天分组：输入已经按时间倒序，一遍扫过去，同一天的归一组；标题每组只格式化一次
/// （几百个词逐个格式化日期，每次点选重算列表都会卡）
func groupByDay<T>(_ items: [T], date: (T) -> Date) -> [(title: String, items: [T])] {
    let cal = Calendar.current
    var result: [(day: Date, items: [T])] = []
    for item in items {
        let day = cal.startOfDay(for: date(item))
        if let last = result.last, last.day == day {
            result[result.count - 1].items.append(item)
        } else {
            result.append((day, [item]))
        }
    }
    return result.map { (dayGroupTitle(for: $0.day), $0.items) }
}

/// 按天分组的标题：今天 / 昨天 / 10月21日 周二（不是今年的带上年）
func dayGroupTitle(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return String(localized: "今天") }
    if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
        return date.formatted(.dateTime.month().day().weekday())
    }
    return date.formatted(.dateTime.year().month().day().weekday())
}
