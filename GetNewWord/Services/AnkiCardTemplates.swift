// AnkiCardTemplates.swift
// GetNewWord
//
// Anki 卡片的样式和模板（方向 B「句子在前」，design/anki-cards/proto-b.html 的原文）。
// 卡片上的固定文字（「这句里的」「用法和例句」…）不是字段，写在模板里，所以按界面语言在写入 Anki 时代入；
// 换了界面语言，下次同步发现 CSS 第二行的语言标记对不上，就把模板重写一遍（只改文字，不加字段）。
// 恢复词库只读字段，不读模板，所以这些文字怎么变都不影响恢复。

import Foundation

enum AnkiCardTemplates {
    /// CSS 第一行。升级时靠它判断卡片是不是已经是这一版
    static let versionMarker = "/* GetNewWord card · v2 */"
    private static let labelsPrefix = "/* labels: "

    /// 卡片模板里的固定文字
    struct Labels: Equatable {
        /// 界面语言代码：zh-Hans / en / de
        let language: String
        let which: String
        let foldUsage: String
        let foldUsageHint: String
        let foldAll: String
        let foldShot: String
        let foldSource: String
        let fillTag: String

        /// bundle 默认是应用自己；测试和渲染传入某个 xx.lproj 的 bundle 看别的语言
        init(bundle: Bundle = .main) {
            let code = (bundle.bundleURL.pathExtension == "lproj" ? bundle.bundleURL.deletingPathExtension().lastPathComponent
                        : bundle.preferredLocalizations.first) ?? "zh-Hans"
            language = ["en", "de"].contains(code) ? code : "zh-Hans"
            which = String(localized: "这句里的", bundle: bundle)
            foldUsage = String(localized: "用法和例句", bundle: bundle)
            foldUsageHint = String(localized: "用法 · 搭配 · 例句 · 词源", bundle: bundle)
            foldAll = String(localized: "每次遇到的句子", bundle: bundle)
            foldShot = String(localized: "当时的画面", bundle: bundle)
            foldSource = String(localized: "原文", bundle: bundle)
            fillTag = String(localized: "填空", bundle: bundle)
        }
    }

    // MARK: - CSS

    /// 两个笔记类型共用一份。第一行版本号，第二行是模板文字用的语言
    static func css(_ l: Labels) -> String {
        "\(versionMarker)\n\(labelsPrefix)\(l.language) */\n" + cssBody
    }

    /// 从 Anki 里读到的 CSS 看：是不是 v2、模板文字是哪种语言
    static func isCurrentVersion(css: String) -> Bool { css.hasPrefix(versionMarker) }
    static func labelLanguage(css: String) -> String? {
        let lines = css.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count > 1, lines[1].hasPrefix(labelsPrefix) else { return nil }
        return lines[1].dropFirst(labelsPrefix.count).replacingOccurrences(of: " */", with: "")
    }

    private static let cssBody = #"""
.card {
  --bg: #FFFFFF; --surface: #F4F4F6; --text: #18191C; --text2: #5F636C; --text3: #969AA2;
  --border: rgba(0,0,0,.09); --accent: #5460D2; --accent-soft: rgba(84,96,210,.10);
  --sans: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", "Microsoft YaHei UI", "Noto Sans CJK SC", system-ui, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
  margin: 0; padding: 28px 24px 56px; background: var(--bg); color: var(--text);
  font-family: var(--sans); font-size: 16px; line-height: 1.6; text-align: left;
  -webkit-font-smoothing: antialiased; font-kerning: normal; text-autospace: normal; letter-spacing: 0;
}
.card.nightMode, .nightMode .card, .card.night_mode, .night_mode .card {
  --bg: #16171A; --surface: rgba(255,255,255,.055); --text: #EDEDEF; --text2: #9A9FA8; --text3: #6E7480;
  --border: rgba(255,255,255,.09); --accent: #8A93EA; --accent-soft: rgba(138,147,234,.16);
}
@media (max-width: 520px) { .card { padding: 20px 16px 48px; font-size: 15px; } }

.gnw { max-width: 620px; margin: 0 auto; }
.gnw img { max-width: 100%; height: auto; display: block; border-radius: 8px; border: 1px solid var(--border); }
.meta { font-size: 12px; color: var(--text3); }
.ipa { font-family: var(--mono); font-size: 14px; color: var(--text2); }
.gram { font-size: 14px; color: var(--text2); }
hr#answer, hr.divider { border: 0; border-top: 1px solid var(--border); margin: 24px auto; max-width: 620px; }

/* 取景框：原句里的那个词套四个角（和查词面板同一个记号） */
.pairs .ctx .kw, .fill .ctx .kw {
  --c: var(--accent); --l: .34em; --w: 1.5px;
  padding: 0 .16em; margin: 0 .03em;
  background:
    linear-gradient(var(--c),var(--c)) left top / var(--l) var(--w) no-repeat,
    linear-gradient(var(--c),var(--c)) left top / var(--w) var(--l) no-repeat,
    linear-gradient(var(--c),var(--c)) right top / var(--l) var(--w) no-repeat,
    linear-gradient(var(--c),var(--c)) right top / var(--w) var(--l) no-repeat,
    linear-gradient(var(--c),var(--c)) left bottom / var(--l) var(--w) no-repeat,
    linear-gradient(var(--c),var(--c)) left bottom / var(--w) var(--l) no-repeat,
    linear-gradient(var(--c),var(--c)) right bottom / var(--l) var(--w) no-repeat,
    linear-gradient(var(--c),var(--c)) right bottom / var(--w) var(--l) no-repeat;
  -webkit-box-decoration-break: clone; box-decoration-break: clone;
}
/* 译文里对应的字：下划线 */
.ctx-tr .kw { color: var(--text); box-shadow: inset 0 -2px var(--accent); }

/* 语境：Context 和 ContextTranslation 两个字段按顺序配成对（第 n 句下面是第 n 句译文） */
.pairs { display: flex; flex-direction: column; }
.pairs .ctxs, .pairs .trs { display: contents; }
.ctxs .ctx:nth-child(1) { order: 1; } .trs .ctx-tr:nth-child(1) { order: 2; }
.ctxs .ctx:nth-child(2) { order: 3; } .trs .ctx-tr:nth-child(2) { order: 4; }
.ctxs .ctx:nth-child(3) { order: 5; } .trs .ctx-tr:nth-child(3) { order: 6; }
.ctxs .ctx:nth-child(4) { order: 7; } .trs .ctx-tr:nth-child(4) { order: 8; }
.ctxs .ctx:nth-child(5) { order: 9; } .trs .ctx-tr:nth-child(5) { order: 10; }
.ctxs .ctx:nth-child(6) { order: 11; } .trs .ctx-tr:nth-child(6) { order: 12; }
.pairs .ctx-tr { color: var(--text2); font-size: 15px; margin: 2px 0 14px; }
.pairs .ctx-tr:last-child { margin-bottom: 0; }
/* 只要最近遇到的那一句 */
.latest .ctx:not(:last-child), .latest .ctx-tr:not(:last-child) { display: none; }

/* 释义：按词性一组一行；这句里的义项是 <b> */
.meaning .sep { display: none; }
.meaning .pos-group + .pos-group { margin-top: 4px; }
.meaning .pos { display: inline-block; min-width: 2.4em; font-size: 13px; color: var(--text3); }
.meaning b { font-weight: 500; color: var(--text) !important; }

/* 发音按钮（Anki 把 [sound:…] 画成 .replay-button） */
.replay-button { display: inline-flex; vertical-align: middle; text-decoration: none; }
.replay-button svg { width: 28px; height: 28px; }
.replay-button svg circle { fill: var(--surface); stroke: none; }
.replay-button svg path { fill: var(--text2); transform: scale(.62); transform-origin: 32px 32px; }

/* 折叠 */
details > summary { list-style: none; cursor: pointer; }
details > summary::-webkit-details-marker { display: none; }

/* ===== 方向 B：句子在前 ===== */
.b.front { min-height: 52vh; display: flex; flex-direction: column; justify-content: center; }
.answer-side .b.front { min-height: 0; }
.b .meta { margin-bottom: 14px; }
.b .scene .ctx { font-size: 24px; line-height: 1.5; }
.b .which { display: none; margin-top: 12px; font-size: 13px; color: var(--text3); }
.b .scene:not(:has(.kw)) + .which { display: block; }
.b .solo { font-size: 36px; font-weight: 600; line-height: 1.2; }
.b .q { font-size: 24px; line-height: 1.45; font-weight: 600; }

/* 翻面：译文接在原句下面，再是答案 */
.b .tr-latest { margin-top: 10px; }
.b .tr-latest .ctx-tr { font-size: 16px; }
.b .sense { font-size: 0; line-height: 0; }
.b .sense .pos, .b .sense .sep { display: none; }
.b .sense b { font-size: 30px; line-height: 1.3; font-weight: 600; color: var(--text) !important; }
.b .sense:not(:has(b)) { display: none; }
.b .hwline { display: flex; align-items: center; flex-wrap: wrap; gap: 4px 10px; margin-top: 8px; }
.b .hwline .hw { font-size: 17px; font-weight: 600; }
.b.back .meaning { margin-top: 14px; font-size: 15px; color: var(--text2); }
.b.back .meaning b { color: var(--text) !important; box-shadow: inset 0 -2px var(--accent); }

/* 细节都收进折叠：手机上一屏看完答案 */
.b details.fold { border-top: 1px solid var(--border); }
.b details.fold:first-of-type { margin-top: 22px; }
.b details.fold > summary { display: flex; align-items: center; gap: 10px; padding: 13px 0; font-size: 14px; font-weight: 500; }
.b details.fold > summary::before { content: ""; width: 6px; height: 6px; margin: 0 2px; border-right: 1.5px solid var(--text3); border-bottom: 1.5px solid var(--text3); transform: rotate(-45deg); transition: transform .15s; }
.b details.fold[open] > summary::before { transform: rotate(45deg); }
.b details.fold > summary .hint { margin-left: auto; font-size: 12px; font-weight: 400; color: var(--text3); }
.b details.fold > .body { padding: 0 0 18px 20px; }
.b .more:not(:has(.ctx:nth-child(2))) { display: none; }
.b .more .ctx { font-size: 16px; }

.b .an .lbl { font-size: 12px; font-weight: 500; color: var(--text3); margin: 16px 0 4px; }
.b .an .lbl:first-child { margin-top: 0; }
.b .an .usage, .b .an .sec { font-size: 15px; }
.b .an .sec .ctx { margin-bottom: 8px; }
.b .an .sec .ctx:last-child { margin-bottom: 0; }
.b .an .zh { font-size: 14px; color: var(--text2); }
.b .an .kw { color: var(--accent); font-weight: 500; }

.b .content { font-size: 17px; }
.pts { list-style: none; margin: 0; padding: 0; counter-reset: p; }
.pts li { position: relative; counter-increment: p; padding-left: 30px; margin-bottom: 12px; }
.pts li:last-child { margin-bottom: 0; }
.pts li::before { content: counter(p); position: absolute; left: 0; top: .2em; width: 20px; height: 20px; border-radius: 5px; background: var(--surface); color: var(--text2); font-size: 12px; line-height: 20px; text-align: center; font-variant-numeric: tabular-nums; }
.b .topic { font-size: 12px; color: var(--text3); margin-bottom: 8px; }
.b .src { font-size: 15px; color: var(--text2); }

/* 语境填空（可选） */
.b.fill .ctx { font-size: 24px; line-height: 1.5; }
.b.fill .pairs .ctx-tr { margin-top: 12px; font-size: 16px; }
.fill.front .ctx .kw { color: transparent !important; display: inline-block; min-width: 3em; line-height: 1.25; user-select: none; }
.fill.front .ctx .kw::first-letter { color: var(--text3); }

@media (max-width: 520px) {
  .b .scene .ctx, .b.fill .ctx { font-size: 21px; }
  .b .q { font-size: 21px; }
  .b .sense b { font-size: 26px; }
  /* 英文、德文的折叠标题和提示合在一行放不下：手机上只留标题（展开后每段自己有小标题） */
  .b details.fold > summary .hint { display: none; }
}
"""#

    // MARK: - 单词卡「正面」

    static func wordFront(_ l: Labels) -> String {
        #"""
<div class="gnw b word front">
  <div class="meta">{{Language}}{{#Difficulty}} · {{Difficulty}}{{/Difficulty}}</div>
  {{#Context}}<div class="scene pairs latest"><div class="ctxs">{{Context}}</div></div>
  <div class="which">\#(l.which) {{Front}}</div>{{/Context}}
  {{^Context}}<div class="solo">{{Front}}</div>{{/Context}}
</div>
"""#
    }

    static func wordBack(_ l: Labels) -> String {
        #"""
<div class="answer-side">{{FrontSide}}</div>
<div class="gnw b back">
  {{#ContextTranslation}}<div class="tr-latest pairs latest"><div class="trs">{{ContextTranslation}}</div></div>{{/ContextTranslation}}
  <hr id="answer">
  <div class="sense">{{Back}}</div>
  <div class="hwline"><span class="hw">{{Front}}</span>{{Audio}}{{#Phonetic}}<span class="ipa">{{Phonetic}}</span>{{/Phonetic}}{{#Grammar}}<span class="gram">{{Grammar}}</span>{{/Grammar}}</div>
  <div class="meaning">{{Back}}</div>
  {{#Analysis}}<details class="fold"><summary>\#(l.foldUsage)<span class="hint">\#(l.foldUsageHint)</span></summary><div class="body an">{{Analysis}}</div></details>{{/Analysis}}
  <details class="fold more"><summary>\#(l.foldAll)</summary><div class="body pairs"><div class="ctxs">{{Context}}</div><div class="trs">{{ContextTranslation}}</div></div></details>
  {{#Screenshot}}<details class="fold"><summary>\#(l.foldShot)</summary><div class="body">{{Screenshot}}</div></details>{{/Screenshot}}
</div>
"""#
    }

    // MARK: - 知识卡「知识」

    /// hasQuestion 为假时是还没加 Question 字段的老笔记类型：正面用标题，模板里不能写 {{Question}}
    static func noteFront(_ l: Labels, hasQuestion: Bool) -> String {
        hasQuestion ? #"""
<div class="gnw b note front">
  <div class="meta">{{Domain}}</div>
  <div class="q">{{#Question}}{{Question}}{{/Question}}{{^Question}}{{Title}}{{/Question}}</div>
</div>
"""# : #"""
<div class="gnw b note front">
  <div class="meta">{{Domain}}</div>
  <div class="q">{{Title}}</div>
</div>
"""#
    }

    static func noteBack(_ l: Labels, hasQuestion: Bool) -> String {
        let topic = hasQuestion ? "  {{#Question}}<div class=\"topic\">{{Title}}</div>{{/Question}}\n" : ""
        return #"""
<div class="answer-side">{{FrontSide}}</div>
<hr id="answer">
<div class="gnw b back">
\#(topic)  <div class="content">{{Content}}</div>
  {{#Source}}<details class="fold"><summary>\#(l.foldSource)</summary><div class="body src">{{Source}}</div></details>{{/Source}}
  {{#Screenshot}}<details class="fold"><summary>\#(l.foldShot)</summary><div class="body">{{Screenshot}}</div></details>{{/Screenshot}}
</div>
"""#
    }

    // MARK: - 单词卡「语境填空」（可选）

    static func fillFront(_ l: Labels) -> String {
        #"""
{{#Fill}}<div class="gnw b fill front">
  <div class="meta">{{Language}} · \#(l.fillTag)</div>
  <div class="pairs latest"><div class="ctxs">{{Context}}</div><div class="trs">{{ContextTranslation}}</div></div>
</div>{{/Fill}}
"""#
    }

    static func fillBack(_ l: Labels) -> String {
        #"""
{{#Fill}}<div class="gnw b fill back">
  <div class="meta">{{Language}} · \#(l.fillTag)</div>
  <div class="pairs latest"><div class="ctxs">{{Context}}</div><div class="trs">{{ContextTranslation}}</div></div>
  <hr id="answer">
  <div class="hwline"><span class="hw" style="font-size:22px">{{Front}}</span>{{Audio}}{{#Phonetic}}<span class="ipa">{{Phonetic}}</span>{{/Phonetic}}</div>
  {{#Grammar}}<div class="gram" style="margin-top:4px">{{Grammar}}</div>{{/Grammar}}
</div>{{/Fill}}
"""#
    }
}
