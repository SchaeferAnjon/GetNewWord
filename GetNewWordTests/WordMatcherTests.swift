// 查词卡片标紫：查的词每次出现都整词标出来，变形、短语也算，别的词里包含它的不算

import Foundation
import SwiftUI
import Testing
@testable import GetNewWord

/// 标出来的地方用 [ ] 括起来，方便一眼对答案
private func marked(_ word: String, _ language: Language, _ text: String, grammar: String? = nil) -> String {
    var out = "", i = text.startIndex
    for r in WordMatcher(word: word, language: language, grammar: grammar).ranges(in: text) {
        out += text[i..<r.lowerBound] + "[" + text[r] + "]"
        i = r.upperBound
    }
    return out + text[i...]
}

struct WordMatcherEnglishTests {
    /// heats 整个词紫（以前只有 heat 紫、s 是黑的），wheat 里的 heat 不算，heater 是另一个词
    @Test func wholeWordsOnly() {
        #expect(marked("heat", .english, "The sun heats the wheat fields; the heater broke.")
                == "The sun [heats] the wheat fields; the heater broke.")
    }

    /// 原形和变形在同一句里：两个都标（以前有原形就不找变形了）
    @Test func baseAndInflectedTogether() {
        #expect(marked("heat", .english, "Heat rises when the sun heated it, heating everything.")
                == "[Heat] rises when the sun [heated] it, [heating] everything.")
        #expect(marked("mitigate", .english, "Measures mitigated the risk, mitigating losses; mitigation helps. Mitigate it!")
                == "Measures [mitigated] the risk, [mitigating] losses; mitigation helps. [Mitigate] it!")
    }

    /// 句首句尾、引号括号、撇号连着的
    @Test func punctuationAround() {
        #expect(marked("heat", .english, "\"Heat,\" she said (heats) — heat's effect. Heat.")
                == "\"[Heat],\" she said ([heats]) — [heat]'s effect. [Heat].")
    }

    /// 不规则：ran → run、went → go、better / best → good
    @Test func irregularForms() {
        #expect(marked("run", .english, "She ran fast. He runs daily; a rerun.")
                == "She [ran] fast. He [runs] daily; a rerun.")
        #expect(marked("go", .english, "He went home; she goes; gone; ago.")
                == "He [went] home; she [goes]; [gone]; ago.")
        #expect(marked("good", .english, "A better idea is the best one. Good luck. Goodness.")
                == "A [better] idea is the [best] one. [Good] luck. Goodness.")
    }

    /// 词尾规则：双写、y → i、f → ves、拉丁复数
    @Test func spellingRules() {
        #expect(marked("stop", .english, "He stopped; stopping; a stopwatch.") == "He [stopped]; [stopping]; a stopwatch.")
        #expect(marked("study", .english, "She studies; he studied; a student.") == "She [studies]; he [studied]; a student.")
        #expect(marked("leaf", .english, "The leaves fell.") == "The [leaves] fell.")
        #expect(marked("analysis", .english, "Two analyses agree.") == "Two [analyses] agree.")
    }

    /// 短语整块标，中心词可以变形；拆开的（gives it up）两段各标；占位的 sth. 不用出现
    @Test func phrases() {
        #expect(marked("give up", .english, "She gave up smoking. Never give up! He gives it up.")
                == "She [gave up] smoking. Never [give up]! He [gives] it [up].")
        #expect(marked("traffic confluence", .english, "Traffic confluences are busy.") == "[Traffic confluences] are busy.")
        #expect(marked("take sth. into account", .english, "We took the costs into account.")
                == "We [took] the costs [into account].")
        // 只出现一半不算；隔着逗号不连
        #expect(marked("give up", .english, "Give, up.") == "Give, up.")
    }

    /// 否定缩写整个词算：Don't 里有 do、won't 里有 will、can't 里有 can；don（穿）不算 Don't，can 不再只紫半个 can't
    @Test func negativeContractions() {
        #expect(marked("do", .english, "Don't do that. He doesn't know, she didn't.")
                == "[Don't] [do] that. He [doesn't] know, she [didn't].")
        #expect(marked("don", .english, "Don't worry, they don the hats.") == "Don't worry, they [don] the hats.")
        #expect(marked("can", .english, "I can't open the can.") == "I [can't] open the [can].")
        #expect(marked("will", .english, "I will go; she won't.") == "I [will] go; she [won't].")
        #expect(marked("win", .english, "They won't win.") == "They won't [win].")
    }

    /// 词头带斜杠、括号：take sb/sth for granted、look (sth) up 按词找；整个就是 and/or、colo(u)r 的原样找
    @Test func optionsInHeadword() {
        #expect(marked("take sb/sth for granted", .english, "She took him for granted.") == "She [took] him [for granted].")
        #expect(marked("look (sth) up", .english, "Look it up in the dictionary.") == "[Look] it [up] in the dictionary.")
        #expect(marked("and/or", .english, "Tea and/or coffee, and more.") == "Tea [and/or] coffee, and more.")
        #expect(marked("colo(u)r", .english, "The colo(u)r, the colour.") == "The [colo(u)r], the colour.")
    }

    /// 中文讲解里夹着的英文词：前后挨着汉字也是边界
    @Test func insideChineseNotes() {
        #expect(marked("mitigate", .english, "mitigate常与 risk 搭配；mitigating circumstances 是法律术语")
                == "[mitigate]常与 risk 搭配；[mitigating] circumstances 是法律术语")
    }
}

struct WordMatcherEuropeanTests {
    /// 德语：变音复数、强变化动词、ß 和 ss、整词比较不放宽变音（schon ≠ schön）
    @Test func german() {
        #expect(marked("Haus", .german, "Die Häuser, des Hauses, die Haustür.") == "Die [Häuser], des [Hauses], die Haustür.")
        #expect(marked("fahren", .german, "Er fährt, wir fuhren, gefahren. Die Fahrer warten.")
                == "Er [fährt], wir [fuhren], [gefahren]. Die Fahrer warten.")
        #expect(marked("Straße", .german, "Die STRASSE, zwei Straßen, die Strasse.")
                == "Die [STRASSE], zwei [Straßen], die [Strasse].")
        #expect(marked("schon", .german, "Das ist schon schön.") == "Das ist [schon] schön.")
        #expect(marked("schön", .german, "Das ist schon schön, am schönsten.") == "Das ist schon [schön], am [schönsten].")
    }

    /// 去掉变音才对得上、系统说是另一个词的不算：schöner 不是 schon 的变形，zählt 不是 zahlen，seit 不是 sein
    @Test func germanUmlautIsAnotherWord() {
        #expect(marked("schon", .german, "Das ist schon ein schöner Tag, die schönen Blumen.")
                == "Das ist [schon] ein schöner Tag, die schönen Blumen.")
        #expect(marked("zahlen", .german, "Ich zahle, er zählt bis zehn.") == "Ich [zahle], er zählt bis zehn.")
        #expect(marked("drucken", .german, "Er druckt, sie drückt den Knopf.") == "Er [druckt], sie drückt den Knopf.")
        #expect(marked("sein", .german, "Er ist seit Jahren hier.") == "Er [ist] seit Jahren hier.")
    }

    /// 变化那行用「·」隔开：hält an、hielt an 各是一小句，可分动词照样认
    @Test func germanGrammarLine() {
        #expect(marked("anhalten", .german, "trennbar · hält an · hielt an · hat angehalten")
                == "trennbar · [hält] [an] · [hielt] [an] · hat [angehalten]")
        #expect(marked("aufstehen", .german, "trennbar • steht auf | stand auf / ist aufgestanden")
                == "trennbar • [steht] [auf] | [stand] [auf] / ist [aufgestanden]")
    }

    /// 模型把可分动词写成了 halten、变化那行写着 trennbar · hält an：anhalten、句末的 an 也标；不可分的照旧
    @Test func germanHeadwordMissingParticle() {
        let g = "trennbar · hält an · hielt an · hat angehalten"
        #expect(marked("halten", .german, g, grammar: g) == "trennbar · [hält] [an] · [hielt] [an] · hat [angehalten]")
        #expect(marked("halten", .german, "Der Bus hält an der Ecke an. Anhalten, halten für.", grammar: g)
                == "Der Bus [hält] an der Ecke [an]. [Anhalten], [halten] für.")
        #expect(marked("sehen", .german, "Er sieht sie an.", grammar: "trennbar · sieht an · sah an · hat angesehen")
                == "Er [sieht] sie [an].")
        #expect(marked("halten", .german, "Er hält an seiner Meinung fest.", grammar: "hält · hielt · hat gehalten")
                == "Er [hält] an seiner Meinung fest.")
        #expect(marked("warten", .german, "Er wartet auf den Bus, wartet auf.", grammar: "wartet auf · wartete · hat gewartet")
                == "Er [wartet] auf den Bus, [wartet] auf.")
    }

    /// 前缀配离它最近的那个变位，und 后面是另一个动词；换序兜底不把 zu Hause 认成 Hause zu；命令式只剩词干
    @Test func germanNearestVerb() {
        #expect(marked("aufhören", .german, "Sie hörte mir zu und hörte auf.") == "Sie hörte mir zu und [hörte] [auf].")
        #expect(marked("zumachen", .german, "Sie macht Musik und hört mir zu. Mach die Tür zu!")
                == "Sie macht Musik und hört mir zu. [Mach] die Tür [zu]!")
        #expect(marked("zu Hause", .german, "Ich bin zu müde, um nach Hause zu gehen. Ich bin zu Hause.")
                == "Ich bin zu müde, um nach Hause zu gehen. Ich bin [zu Hause].")
        #expect(marked("es gibt", .german, "Gibt es hier ein Café?") == "[Gibt es] hier ein Café?")
        #expect(marked("Rücksicht nehmen (auf + A)", .german, "Er nimmt Rücksicht auf sie.") == "Er [nimmt Rücksicht] auf sie.")
    }

    /// 可分动词拆开时动词和前缀都标，中间当介词的 an 不标；短语换了语序也认
    @Test func germanSeparableAndWordOrder() {
        #expect(marked("anhalten", .german, "Der Bus hält an der Ecke an. Sie hat angehalten.")
                == "Der Bus [hält] an der Ecke [an]. Sie hat [angehalten].")
        // 讲解里写成「hält … an」：省略号不断开
        #expect(marked("anhalten", .german, "前缀置于句末（hält ... an）；也写作 hielt … an。")
                == "前缀置于句末（[hält] ... [an]）；也写作 [hielt] … [an]。")
        #expect(marked("in Kauf nehmen", .german, "Er nimmt das Risiko in Kauf.") == "Er [nimmt] das Risiko [in Kauf].")
        #expect(marked("die Vorfahrt", .german, "Vorfahrt achten!") == "[Vorfahrt] achten!")
    }

    /// 法语：重音变了的变位、查表的不规则动词、l'eau 里的 eau、-al → -aux
    @Test func french() {
        #expect(marked("préférer", .french, "Il préfère le café, nous préférons le thé. Préférence.")
                == "Il [préfère] le café, nous [préférons] le thé. Préférence.")
        #expect(marked("aller", .french, "Je vais à Paris, elle est allée, ils iront.")
                == "Je [vais] à Paris, elle est [allée], ils [iront].")
        #expect(marked("eau", .french, "L'eau est froide. Beaucoup d'eaux.") == "L'[eau] est froide. Beaucoup d'[eaux].")
        #expect(marked("cheval", .french, "Les chevaux.") == "Les [chevaux].")
        // 只在 e 上换重音、ç 和 c 互换；sûre 不是 sur
        #expect(marked("commencer", .french, "Nous commençons, il commence.") == "Nous [commençons], il [commence].")
        #expect(marked("sur", .french, "Sur la table, je suis sûre.") == "[Sur] la table, je suis sûre.")
    }

    /// 西语：¿¡ 开头、复数去掉重音、词干变音、不规则表里的 está 不是 esta
    @Test func spanish() {
        #expect(marked("acción", .spanish, "Las acciones suben. ¡Una acción!") == "Las [acciones] suben. ¡Una [acción]!")
        #expect(marked("poder", .spanish, "¿Puedo hacerlo? Pudimos.") == "¿[Puedo] hacerlo? [Pudimos].")
        #expect(marked("estar", .spanish, "Esta casa está aquí.") == "Esta casa [está] aquí.")
        #expect(marked("hablar", .spanish, "Hablo, habló, ¡háblame!") == "[Hablo], [habló], ¡[háblame]!")
        // 只多一个 -s 不挪重音：estás 不是 esta
        #expect(marked("esta", .spanish, "Esta casa, tú estás, estas casas.") == "[Esta] casa, tú estás, [estas] casas.")
    }

    /// 查表的不规则动词后面粘着代词（hazlo、dímelo、ponerse）也认；vale 里的 va 不是 ir
    @Test func spanishClitics() {
        #expect(marked("hacer", .spanish, "Hazlo ya. Hacerlo es fácil. Hágalo.") == "[Hazlo] ya. [Hacerlo] es fácil. [Hágalo].")
        #expect(marked("decir", .spanish, "Dime la verdad. Dímelo.") == "[Dime] la verdad. [Dímelo].")
        #expect(marked("poner", .spanish, "Ponlo aquí. Ponerse el abrigo.") == "[Ponlo] aquí. [Ponerse] el abrigo.")
        #expect(marked("ir", .spanish, "Vete ya. Vale.") == "[Vete] ya. Vale.")
    }
}

struct WordMatcherOtherTests {
    /// 中日韩照旧按子串找
    @Test func cjkSubstring() {
        #expect(marked("学习", .chinese, "我们一起学习，学习很重要。") == "我们一起[学习]，[学习]很重要。")
        #expect(marked("공부", .korean, "공부하다") == "[공부]하다")
    }

    /// 带符号的原样找，两头不能接字母
    @Test func literalAndEmpty() {
        #expect(marked("C++", .english, "C++ code, not C.") == "[C++] code, not C.")
        #expect(marked("  ", .english, "anything") == "anything")
    }
}

struct TextHighlighterTests {
    /// 整个 heats 都是重点色加粗，wheat 一个字都不标；字用 accentText（深色模式亮一档）
    @Test func colorsWholeToken() {
        let attr = TextHighlighter.highlight("heat", in: "wheat heats", language: .english)
        let colored = attr.runs.filter { $0.foregroundColor != nil }.map { String(attr[$0.range].characters) }
        #expect(colored == ["heats"])
        #expect(attr.runs.compactMap(\.foregroundColor) == [Theme.accentText])
        let bold = attr.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.count == 1)
    }

    /// 语法分解的行内 Markdown：代码样式留着，再加粗、标紫
    @Test func keepsMarkdownStyles() throws {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let md = try AttributedString(markdown: "`heats` 是第三人称单数", options: opts)
        let attr = TextHighlighter.mark("heat", in: md, language: .english)
        let run = try #require(attr.runs.first { $0.foregroundColor != nil })
        #expect(String(attr[run.range].characters) == "heats")
        #expect(run.inlinePresentationIntent?.contains(.code) == true)
        #expect(run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    /// 语法分解里模型把加粗写进了反引号（`**Der Bus**`）：不再显示字面的 **，改成加粗的代码样式
    @Test func boldInsideCodeSpan() throws {
        let line = "`**Der Bus**`(主语) / `**hält ... an**`(谓语) / `an der Ecke`"
        #expect(GrammarBreakdownSection.boldInsideCode(line) == "**`Der Bus`**(主语) / **`hält ... an`**(谓语) / `an der Ecke`")
        let attr = GrammarBreakdownSection.inline(line)
        #expect(!String(attr.characters).contains("*"))
        let run = try #require(attr.runs.first { String(attr[$0.range].characters) == "Der Bus" })
        #expect(run.inlinePresentationIntent?.contains(.code) == true)
        #expect(run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        // 代码段中间夹着加粗、没闭合的反引号
        #expect(GrammarBreakdownSection.boldInsideCode("`The sun **heats** it` and `x") == "`The sun `**`heats`**` it` and `x")
    }
}
