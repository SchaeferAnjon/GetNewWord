// StudyCard.swift
// GetNewWord
//
// 写问答卡的三个软件（ChatCards、Ask Free、GetNewWord 的知识片段）共用的笔记类型「学习卡 · 问答」。
// 规范在 DESIGN.md「往 Anki 里加卡」；下面这段和另外两个仓库里的一字不差。

import Foundation

/// 写问答卡的软件（ChatCards、Ask Free、GetNewWord 的知识片段）共用的笔记类型「学习卡 · 问答」。
/// 规范在 DESIGN.md「往 Anki 里加卡」：九个英文字段、顺序固定；样式是「卡片家族」，CSS 第一行写版本号，只往新的换。
/// 三个软件里的这份定义要一字不差：改了就三个仓库一起改，版本号加一。
public enum StudyCard {
    public static let name = "学习卡 · 问答"
    /// 同名的笔记类型不是我们的（字段对不上）就改用这个名字，不碰你的
    static let otherName = "学习卡 · 问答 2"
    public static let fields = ["Question", "Answer", "More", "Quote", "Image", "Label", "Source", "Link", "ID"]
    static let templateName = "问答"
    public static let version = 3

    /// CSS 第一行：`/* 卡片家族 v3 */`；不是这个格式就说明你在 Anki 里改过
    public static func version(ofCSS css: String) -> Int? {
        let first = (css.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let head = "/* 卡片家族 v", tail = " */"
        guard first.hasPrefix(head), first.hasSuffix(tail), first.count > head.count + tail.count else { return nil }
        return Int(first.dropFirst(head.count).dropLast(tail.count))
    }

    /// 截图：Ask Free 写成 `<img class="lead">`，放在问题下面；别的软件的截图收进纸底「当时的画面」
    static let top = """
    <div class="top">{{#Label}}<div class="meta">{{Label}}</div>{{/Label}}<div class="q">{{Question}}</div>{{#Image}}<div class="shot">{{Image}}</div>{{/Image}}</div>
    """

    public static let front = """
    <div class="fam">
    \(top)
    </div>
    """

    /// 不用 {{FrontSide}}：纸要把问题和答案包在同一个元素里；也不用 id="answer"，翻面时问题不跳
    public static let back = """
    <div class="fam back">
    \(top)
    <div class="ans"><div class="a">{{Answer}}</div>{{#More}}<div class="more">{{More}}</div>{{/More}}</div>
    <div class="foot"><div class="src">{{#Source}}<span>{{Source}}</span>{{/Source}}{{#Link}}<a class="open" href="{{text:Link}}">打开原文</a>{{/Link}}</div>{{#Quote}}<details><summary>原文</summary><div class="body">{{Quote}}</div></details>{{/Quote}}{{#Image}}<details class="pic"><summary>当时的画面</summary><div class="body">{{Image}}</div></details>{{/Image}}</div>
    </div>
    """

    public static let css = """
    /* 卡片家族 v3 */
    .card {
      --bg: #FFFFFF; --surface: #F4F4F6;
      --text: #18191C; --text2: #5F636C; --text3: #969AA2;
      --border: rgba(0,0,0,.09); --accent: #5460D2;
      --backdrop: #F2F2F4; --sheet: #FFFFFF; --band: #F8F8FA;
      --shadow: 0 1px 2px rgba(0,0,0,.04), 0 12px 32px -12px rgba(0,0,0,.10);
      --sans: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", "Microsoft YaHei UI", "Noto Sans CJK SC", system-ui, sans-serif;
      --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
      margin: 0; padding: 40px 24px 64px; background: var(--backdrop); color: var(--text);
      font-family: var(--sans); font-size: 17px; line-height: 1.6; text-align: left;
      letter-spacing: 0; font-kerning: normal; text-autospace: normal;
      -webkit-font-smoothing: antialiased; overflow-wrap: break-word;
    }
    .card.nightMode, .nightMode .card, .card.night_mode, .night_mode .card {
      --bg: #16171A; --surface: rgba(255,255,255,.07);
      --text: #EDEDEF; --text2: #9A9FA8; --text3: #6E7480;
      --border: rgba(255,255,255,.09); --accent: #8A94F5;
      --backdrop: #0F1012; --sheet: #1B1C1F; --band: #202125; --shadow: none;
    }
    .card code { font-family: var(--mono); font-size: .88em; padding: .08em .36em; border-radius: 5px; background: var(--surface); overflow-wrap: anywhere; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
    .card pre { font-family: var(--mono); font-size: 14px; line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; background: var(--surface); padding: 12px 14px; border-radius: 8px; margin: 8px 0; }
    .card pre code { padding: 0; background: none; font-size: inherit; }
    .card .code-h, .card .copy { display: none; }
    .card .scrollx { overflow-x: auto; }
    .card b, .card strong { font-weight: 600; }
    .card a { color: var(--accent); text-decoration: none; }
    .card img { max-width: 100%; height: auto; border-radius: 8px; border: 1px solid var(--border); display: block; }

    /* 纸：四种卡都一样 */
    .fam { max-width: 620px; margin: 0 auto; background: var(--sheet); border: 1px solid var(--border); border-radius: 12px; box-shadow: var(--shadow); overflow: hidden; }
    .fam .top { padding: 28px 32px 30px; }
    .fam .meta { font-size: 12px; line-height: 1.5; color: var(--text2); margin-bottom: 8px; }
    .fam .q { font-size: 24px; line-height: 1.45; font-weight: 600; text-wrap: pretty; }
    .fam.back .q { color: var(--text2); }
    .fam .shot { margin-top: 16px; }
    .fam .ans { padding: 24px 32px 28px; border-top: 1px solid var(--border); }
    .fam .a { font-size: 24px; line-height: 1.45; font-weight: 600; text-wrap: pretty; }
    .fam .a code { font-size: .84em; }
    .fam .more { margin-top: 14px; font-size: 16px; line-height: 1.65; color: var(--text2); text-wrap: pretty; }
    .fam .more ul { list-style: none; margin: 0; padding: 0; }
    .fam .more li { position: relative; padding-left: 16px; }
    .fam .more li + li { margin-top: 6px; }
    .fam .more li::before { content: ""; position: absolute; left: 3px; top: .74em; width: 5px; height: 5px; border-radius: 50%; background: var(--text3); }
    /* 答案本身是几条要点（知识片段、Ask Free 的老卡）：正文字号，编号方块 */
    .fam .a ol { list-style: none; margin: 0; padding: 0; counter-reset: p; font-size: 17px; font-weight: 400; line-height: 1.6; }
    .fam .a ol li { position: relative; counter-increment: p; padding-left: 30px; }
    .fam .a ol li + li { margin-top: 10px; }
    .fam .a ol li::before { content: counter(p); position: absolute; left: 0; top: .2em; width: 20px; height: 20px; border-radius: 5px; background: var(--surface); color: var(--text2); font-size: 12px; line-height: 20px; text-align: center; font-variant-numeric: tabular-nums; }
    /* 截图：带 class="lead" 的放在问题下面，别的收进「当时的画面」 */
    .fam .shot:not(:has(img.lead)) { display: none; }
    .fam details.pic:has(img.lead) { display: none; }

    /* 纸底一条：出处在左，「打开原文」在右，折叠在下 */
    .fam .foot { padding: 14px 32px 16px; border-top: 1px solid var(--border); background: var(--band); }
    .fam .foot:not(:has(.src > *, details:not(.pic), img:not(.lead))) { display: none; }
    .fam .src { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0 16px; font-size: 13px; line-height: 1.6; color: var(--text2); }
    .fam .src:empty { display: none; }
    .fam .src .open { margin-left: auto; font-weight: 500; white-space: nowrap; }
    .fam .src + details { margin-top: 6px; }
    .fam details > summary { display: inline-flex; align-items: center; gap: 8px; list-style: none; cursor: pointer; font-size: 13px; font-weight: 500; color: var(--text2); padding: 2px 0; }
    .fam details > summary::-webkit-details-marker { display: none; }
    .fam details > summary::before { content: ""; width: 5px; height: 5px; margin: 0 2px; border-right: 1.5px solid var(--text3); border-bottom: 1.5px solid var(--text3); transform: rotate(-45deg); transition: transform .15s; }
    .fam details[open] > summary::before { transform: rotate(45deg); }
    .fam details .body { margin: 6px 0 4px 17px; font-size: 15px; line-height: 1.6; color: var(--text2); text-wrap: pretty; }

    /* 单词卡：句子在前 */
    .fam .ctx { font-size: 24px; line-height: 1.5; text-wrap: pretty; }
    .fam .kw { --c: var(--accent); --l: .34em; --w: 1.5px; padding: 0 .16em; margin: 0 .03em;
      background: linear-gradient(var(--c),var(--c)) left top / var(--l) var(--w) no-repeat, linear-gradient(var(--c),var(--c)) left top / var(--w) var(--l) no-repeat,
      linear-gradient(var(--c),var(--c)) right top / var(--l) var(--w) no-repeat, linear-gradient(var(--c),var(--c)) right top / var(--w) var(--l) no-repeat,
      linear-gradient(var(--c),var(--c)) left bottom / var(--l) var(--w) no-repeat, linear-gradient(var(--c),var(--c)) left bottom / var(--w) var(--l) no-repeat,
      linear-gradient(var(--c),var(--c)) right bottom / var(--l) var(--w) no-repeat, linear-gradient(var(--c),var(--c)) right bottom / var(--w) var(--l) no-repeat; }
    .fam .tr { margin-top: 10px; font-size: 16px; color: var(--text2); }
    .fam .tr u { text-decoration: none; color: var(--text); box-shadow: inset 0 -2px var(--accent); }
    .fam .sense { font-size: 30px; line-height: 1.3; font-weight: 600; }
    .fam .hw { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; margin-top: 8px; font-size: 14px; color: var(--text2); }
    .fam .hw b { font-size: 17px; font-weight: 600; color: var(--text); }
    .fam .hw .ipa { font-family: var(--mono); }
    .fam .mean { margin-top: 12px; font-size: 15px; color: var(--text2); }

    @media (max-width: 520px) {
      .card { padding: 0; background: var(--sheet); font-size: 16px; }
      .fam { max-width: none; border: 0; border-radius: 0; box-shadow: none; }
      .fam .top, .fam .ans { padding: 20px 16px 22px; }
      .fam .foot { padding: 12px 16px 16px; }
      .fam .q, .fam .a, .fam .ctx { font-size: 20px; }
      .fam .sense { font-size: 26px; }
      .fam .more { font-size: 15px; }
      .fam details > summary { padding: 8px 0; margin: -6px 0; }
    }
    """
}
