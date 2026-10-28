// StatsDashboardView.swift
// GetNewWord
//
// 统计（方向 A）：占满中栏和右栏，不再有空着的右栏，也不写大标题。
// 上面四个数（词库、这周新词、连续查词、反复遇到），中间半年每天一格（鼠标放上去看那天几次）
// 加「反复遇到的词」（点了跳到单词页），下面难度、语言和分类。只用强调色的深浅，不再是彩虹色。

import SwiftUI
import SwiftData

struct StatsDashboardView: View {
    @Environment(\.fontScale) private var fs
    /// 点「反复遇到的词」：回到单词页并选中它
    var onOpenWord: ((WordEntry) -> Void)? = nil

    @Query private var allWords: [WordEntry]
    @Query private var allSnippets: [KnowledgeSnippet]
    @State private var range: Range = .halfYear

    enum Range: CaseIterable {
        case month, halfYear, all
        var title: LocalizedStringKey {
            switch self {
            case .month: return "近 4 周"
            case .halfYear: return "近半年"
            case .all: return "全部"
            }
        }
    }

    private let cal = Calendar.current

    var body: some View {
        if allWords.isEmpty && allSnippets.isEmpty {
            EmptyHint(symbol: "chart.bar", title: "还没有数据", message: "查了词，这里就会有数字。")
                .background(Theme.bg)
        } else {
            content
        }
    }

    private var content: some View {
        let encounters = encounterCounts
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tiles(encounters)
                // 同一排的卡片等高、间距一律 16
                HStack(alignment: .top, spacing: 16) {
                    heatPanel(encounters)
                    repeatedPanel
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    difficultyPanel
                    languagePanel
                    if !allSnippets.isEmpty { categoryPanel }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("截至今天 \(Date().formatted(.dateTime.month().day()))")
                .font(Theme.font(12, scale: fs))
                .foregroundStyle(Theme.text3)
            Spacer()
            HStack(spacing: 2) {
                ForEach(Range.allCases, id: \.self) { r in
                    Button { range = r } label: {
                        Text(r.title)
                            .font(Theme.font(12, range == r ? .medium : .regular, scale: fs))
                            .foregroundStyle(range == r ? Theme.text : Theme.text2)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(range == r ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(range == r ? 0.12 : 0), radius: 1, y: 0.5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Theme.selected, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: - 数据

    /// 每天遇到的次数：每个词的每条语境算一次；没有语境的旧词按创建那天算一次
    private var encounterCounts: [Date: Int] {
        var result: [Date: Int] = [:]
        for w in allWords {
            let dates = (w.contexts ?? []).map(\.createdAt)
            for d in dates.isEmpty ? [w.createdAt] : dates {
                result[cal.startOfDay(for: d), default: 0] += 1
            }
        }
        return result
    }

    private var weekStart: Date {
        cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
    }

    private var wordsThisWeek: Int { allWords.filter { $0.createdAt >= weekStart }.count }
    private var wordsLastWeek: Int {
        guard let last = cal.date(byAdding: .day, value: -7, to: weekStart) else { return 0 }
        return allWords.filter { $0.createdAt >= last && $0.createdAt < weekStart }.count
    }

    /// 连续查词天数：今天还没查就从昨天往前数
    private func streaks(_ encounters: [Date: Int]) -> (current: Int, longest: Int) {
        let days = encounters.keys.sorted()
        var longest = 0, run = 0
        var prev: Date?
        for d in days {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            longest = max(longest, run)
            prev = d
        }
        var cursor = cal.startOfDay(for: Date())
        if encounters[cursor] == nil, let y = cal.date(byAdding: .day, value: -1, to: cursor) { cursor = y }
        var current = 0
        while encounters[cursor] != nil {
            current += 1
            guard let p = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = p
        }
        return (current, longest)
    }

    /// 遇到两次以上的词，遇到得多的排前面
    private var repeatedWords: [WordEntry] {
        allWords.filter { ($0.contexts?.count ?? 0) >= 2 }
            .sorted { ($0.contexts?.count ?? 0) > ($1.contexts?.count ?? 0) }
    }

    // MARK: - 四个数

    private func tiles(_ encounters: [Date: Int]) -> some View {
        let s = streaks(encounters)
        return HStack(spacing: 16) {
            tile("词库", value: "\(allWords.count)", unit: "个词", note: "另有 \(allSnippets.count) 条知识片段")
            tile("这周新词", value: "\(wordsThisWeek)", unit: "个", note: "上周 \(wordsLastWeek) 个")
            tile("连续查词", value: "\(s.current)", unit: "天", note: "最长 \(s.longest) 天")
            tile("反复遇到", value: "\(repeatedWords.count)", unit: "个词", note: "遇到两次以上")
        }
    }

    private func tile(_ title: LocalizedStringKey, value: String, unit: LocalizedStringKey, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.font(22, .semibold, scale: fs)).foregroundStyle(Theme.text).monospacedDigit()
                Text(unit).font(Theme.font(13, scale: fs)).foregroundStyle(Theme.text2)
            }
            Text(note).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3).padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: - 每天一格

    /// 画几周：近 4 周 / 近半年 26 周 / 全部（从第一个词那周起，最多 52 周）
    private var weekCount: Int {
        switch range {
        case .month: return 4
        case .halfYear: return 26
        case .all:
            guard let first = allWords.map(\.createdAt).min() else { return 4 }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: first), to: Date()).day ?? 0
            return min(max(days / 7 + 1, 4), 52)
        }
    }

    private func heatPanel(_ encounters: [Date: Int]) -> some View {
        let weeks = weekCount
        let first = cal.date(byAdding: .day, value: -(weeks - 1) * 7, to: weekStart) ?? weekStart
        let total = encounters.filter { $0.key >= first }.values.reduce(0, +)
        let maxCount = max(encounters.filter { $0.key >= first }.values.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("每天遇到的生词").font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text)
                Text("含重复遇到").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3)
                Spacer()
                Group {
                    switch range {
                    case .month: Text("近 4 周 \(total) 次")
                    case .halfYear: Text("近半年 \(total) 次")
                    case .all: Text("全部 \(total) 次")
                    }
                }
                .font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3)
            }
            HeatGrid(weeks: weeks, firstDay: first, encounters: encounters, maxCount: maxCount)
            legend
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("少").font(Theme.font(11, scale: fs)).foregroundStyle(Theme.text3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(HeatGrid.color(level: level)).frame(width: 10, height: 10)
            }
            Text("多").font(Theme.font(11, scale: fs)).foregroundStyle(Theme.text3)
        }
    }

    // MARK: - 反复遇到的词

    private var repeatedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("反复遇到的词").font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text)
                Spacer()
                Text("点一下去看").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3)
            }
            if repeatedWords.isEmpty {
                Text("还没有遇到两次以上的词。")
                    .font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(repeatedWords.prefix(6), id: \.id) { w in
                        RepeatedRow(word: w) { onOpenWord?(w) }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    // MARK: - 难度、语言和分类

    private var difficultyPanel: some View {
        let rows: [(String, Int)] = Difficulty.allCases.map { d in (d.displayName, allWords.filter { $0.difficulty == d }.count) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("难度").font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text)
            BarRows(rows: rows)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var languagePanel: some View {
        let langs = Dictionary(grouping: allWords, by: \.language)
            .map { ($0.key.displayName, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            Text("语言").font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text)
            BarRows(rows: langs)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    /// 知识片段的分类（和语言各用各的比例，不放在一张卡里比长短）
    private var categoryPanel: some View {
        let none = String(localized: "未分组")
        let cats = Dictionary(grouping: allSnippets) { $0.category?.displayName ?? none }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            Text("知识片段分类").font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text)
            BarRows(rows: cats)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

// MARK: - 白底描边卡片

private extension View {
    /// 统计页的卡片：白底、发丝描边、圆角 10
    func card() -> some View {
        self.background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - 一行反复遇到的词

private struct RepeatedRow: View {
    let word: WordEntry
    let action: () -> Void
    @Environment(\.fontScale) private var fs
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word.word).font(Theme.font(13, .medium, scale: fs)).foregroundStyle(Theme.text).lineLimit(1)
                Text(word.meaning).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(word.contexts?.count ?? 0) 次").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text3).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -8)
    }
}

// MARK: - 条形

/// 一组横条：名字、条、数字；条只用强调色，长短按这一组里最大的算
private struct BarRows: View {
    let rows: [(String, Int)]
    @Environment(\.fontScale) private var fs

    var body: some View {
        let maxValue = max(rows.map(\.1).max() ?? 1, 1)
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.0).font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2)
                        .lineLimit(1).frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.selected)
                            RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
                                .frame(width: max(row.1 > 0 ? 3 : 0, geo.size.width * CGFloat(row.1) / CGFloat(maxValue)))
                        }
                    }
                    .frame(height: 8)
                    Text("\(row.1)").font(Theme.font(12, scale: fs)).foregroundStyle(Theme.text2)
                        .monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - 每天一格

/// 半年热力图：一列一周、一行一个星期几，颜色是强调色的深浅；鼠标放上去显示那天几次
private struct HeatGrid: View {
    let weeks: Int
    let firstDay: Date
    let encounters: [Date: Int]
    let maxCount: Int
    @Environment(\.fontScale) private var fs

    private let cal = Calendar.current
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 20
    /// 格子是正方形，边长跟着面板宽度走；高度随之变，所以量到宽度后回写
    @State private var height: CGFloat = 16 + 7 * 14 + 6 * 3

    static func color(level: Int) -> Color {
        level == 0 ? Theme.selected : Theme.accent.opacity(0.32 + 0.68 * Double(level) / 4)
    }

    private func cellSize(_ width: CGFloat) -> CGFloat {
        min(18, max(4, (width - labelWidth - gap * CGFloat(weeks)) / CGFloat(weeks)))
    }

    var body: some View {
        GeometryReader { geo in
            let cell = cellSize(geo.size.width)
            HStack(alignment: .top, spacing: 0) {
                weekdayLabels(cell: cell)
                    .frame(width: labelWidth)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<weeks, id: \.self) { w in column(w, cell: cell) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in
                height = 16 + 7 * cellSize(w) + 6 * gap
            }
        }
        .frame(height: height)
    }

    /// 一、三、五、日（星期一在最上面）
    private func weekdayLabels(cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            Color.clear.frame(height: 16)
            ForEach(0..<7, id: \.self) { d in
                Text([0, 2, 4, 6].contains(d) ? weekdayName(d) : "")
                    .font(Theme.font(10, scale: fs)).foregroundStyle(Theme.text3)
                    .frame(height: cell, alignment: .center)
            }
        }
    }

    private func weekdayName(_ d: Int) -> String {
        let symbols = cal.veryShortStandaloneWeekdaySymbols   // 从周日开始
        return symbols[(d + 1) % 7]
    }

    private func column(_ w: Int, cell: CGFloat) -> some View {
        let start = cal.date(byAdding: .day, value: w * 7, to: firstDay) ?? firstDay
        let prevMonth = w > 0 ? cal.date(byAdding: .day, value: (w - 1) * 7, to: firstDay).map { cal.component(.month, from: $0) } : nil
        let month = cal.component(.month, from: start)
        return VStack(alignment: .leading, spacing: gap) {
            Text(showMonth(w, month: month, prevMonth: prevMonth) ? start.formatted(.dateTime.month(.abbreviated)) : "")
                .font(Theme.font(10, scale: fs)).foregroundStyle(Theme.text3)
                .fixedSize().frame(width: cell, height: 16, alignment: .leading)
            ForEach(0..<7, id: \.self) { d in
                dayCell(start: start, d: d, cell: cell)
            }
        }
    }

    /// 月份标签：每个新月份的第一列写一次；第一列和下一个月份只隔 1 到 2 列时不写（会挤在一起）
    private func showMonth(_ w: Int, month: Int, prevMonth: Int?) -> Bool {
        if w == 0 {
            guard weeks > 3 else { return true }
            let nextMonthSoon = [1, 2].contains { k in
                let a = cal.date(byAdding: .day, value: k * 7, to: firstDay).map { cal.component(.month, from: $0) }
                let b = cal.date(byAdding: .day, value: (k - 1) * 7, to: firstDay).map { cal.component(.month, from: $0) }
                return a != b
            }
            return !nextMonthSoon
        }
        return prevMonth != month
    }

    @ViewBuilder
    private func dayCell(start: Date, d: Int, cell: CGFloat) -> some View {
        let day = cal.date(byAdding: .day, value: d, to: start) ?? start
        if day > Date() {
            Color.clear.frame(width: cell, height: cell)
        } else {
            let n = encounters[cal.startOfDay(for: day)] ?? 0
            let level = n == 0 ? 0 : max(1, Int((4 * Double(n) / Double(maxCount)).rounded(.up)))
            RoundedRectangle(cornerRadius: 3)
                .fill(Self.color(level: level))
                .frame(width: cell, height: cell)
                .help("\(day.formatted(.dateTime.month().day())) · \(n) 次")
        }
    }
}
