// WordMatcher.swift
// GetNewWord
//
// 查词卡片里标紫用：在一段文字里找出查的那个词每次出现在哪儿。
// - 只认整个词：wheat 里的 heat 不算；变形整个词都算（heats、heated、heating，ran → run，Häuser → Haus）
// - 词形先问系统的 NaturalLanguage（macOS 上有英语、德语的词元），对不上再按这门语言的词尾规则认；
//   法语、西语系统不给词元，最常用的不规则动词（être、aller、ser、ir…）查表
// - 大小写不分，ß 当 ss；重音和变音只在认词尾变化时放宽（Häuser → Haus、préfère → préférer），
//   整个词比较时不放宽：schon 不是 schön，esta 不是 está
// - 短语按短语找，每个词都可以变形（gave up、traffic confluences）；中间夹了几个词的（picks it up）、
//   德语换了语序的（nimmt das in Kauf）、可分动词拆开的（hält … an）也认
// - 德语词头是 halten、变化那行写的是「trennbar · hält an」：模型把可分动词 anhalten 写成了 halten，anhalten 的各种写法也标
// - 英语否定缩写整个词算：don't 里有 do、can't 里有 can、won't 里有 will；don（穿）不算 Don't
// - 查的是中日韩的词：照旧按子串找

import Foundation
import NaturalLanguage
import os

struct WordMatcher: Sendable {
    let language: Language
    private let mode: Mode

    private enum Mode: Sendable {
        case none
        /// 中日韩：子串
        case substring(String)
        /// 带符号的（C++、e.g.）：原样找，两头不能接着别的字母
        case literal(String)
        /// 按词：短语是几段；德语可分动词另外认拆开的；also 是也算这个词的另一个词头（halten 的变化那行说它可分时的 anhalten）
        case words([Part], separable: Separable?, also: Part?)
    }

    /// 查的词里的一个词
    struct Part: Sendable {
        /// 大小写折叠（ß → ss），重音保留
        let exact: String
        /// 再去掉重音和变音，认词尾变化用
        let loose: String
        /// 查表的不规则变化；有表就不再按词尾规则猜
        let forms: Set<String>
        /// 西语查表的动词后面能粘代词的写法（不定式、副动词、命令式，已去掉重音）：hacerlo、hazlo、dímelo
        let hosts: Set<String>
        /// 德语短语里能挪位置的词（动词、代词）：主句里动词跑到前面（in Kauf nehmen → nimmt … in Kauf）；
        /// 介词、冠词、名词不挪（zu Hause 不会写成 Hause zu）
        var movable = false

        init(_ token: String, language: Language) {
            exact = WordMatcher.fold(token)
            loose = WordMatcher.loosen(token)
            forms = Irregular.forms(of: exact, language: language)
            hosts = language == .spanish ? Irregular.encliticHosts(of: exact) : []
        }
    }

    /// 德语可分动词 anhalten = an + halten：句子里写成「hält … an」
    struct Separable: Sendable {
        let particle: String
        let verb: Part
    }

    /// grammar：词头下面变化那行（德语「trennbar · hält an · hielt an · hat angehalten」），用来认出模型把可分动词写成了不带前缀的词头
    init(word: String, language: Language, grammar: String? = nil) {
        self.language = language
        var mode = Self.mode(for: word.trimmingCharacters(in: .whitespacesAndNewlines), language: language)
        if language == .german, case .words(let parts, separable: .none, also: .none) = mode, parts.count == 1,
           let grammar, let particle = Self.particle(of: parts[0], in: grammar) {
            mode = .words(parts, separable: Separable(particle: particle, verb: parts[0]),
                          also: Part(particle + parts[0].exact, language: language))
        }
        self.mode = mode
    }

    private static let articles: [String: Set<String>] = [
        Language.english.rawValue: ["a", "an", "the"],
        Language.german.rawValue: ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines"],
        Language.french.rawValue: ["le", "la", "les", "l", "un", "une", "des", "du"],
        Language.spanish.rawValue: ["el", "la", "los", "las", "un", "una", "unos", "unas"],
    ]

    private static func isSymbol(_ c: Character) -> Bool { !isWordChar(c) && !c.isWhitespace && !joiners.contains(c) }

    private static func mode(for raw: String, language: Language) -> Mode {
        guard !raw.isEmpty else { return .none }
        if raw.unicodeScalars.contains(where: isCJK) { return .substring(raw) }
        var w = raw
        if w.contains(where: isSymbol) {
            // 括号里是可选、补充的（look (sth) up、Rücksicht nehmen (auf + A)），斜杠是几选一（take sb/sth for granted、in/on time）
            let simplified = simplifyOptions(w)
            if simplified != w, !simplified.isEmpty, !simplified.contains(where: isSymbol) { w = simplified }
        }
        var source = w
        if w.contains(where: isSymbol) {
            // 短语里占位的 sth. / etw. 去掉后没别的符号了，还按词找；e.g.、C++ 原样找
            let stripped = stripPlaceholders(w)
            if stripped == w || stripped.isEmpty || stripped.contains(where: isSymbol) { return .literal(raw) }
            source = stripped
        }
        var tokens = tokenize(source).map { String(source[$0.range]) }
        if tokens.count > 1 {
            let stripped = stripPlaceholders(source)
            let kept = tokenize(stripped).map { String(stripped[$0.range]) }
            if !kept.isEmpty { tokens = kept }
            // 反身代词在句子里换位置：sich erholen → er erholt sich；se lever → il se lève
            let reflexive: Set<String> = language == .german ? ["sich"] : language == .french ? ["se", "s"] : []
            let rest = tokens.filter { !reflexive.contains(fold($0)) }
            if !rest.isEmpty { tokens = rest }
        }
        // 模型偶尔把冠词、不定式的 to 也带上（die Vorfahrt、to mitigate）：句子里常常没有，去掉
        if tokens.count > 1, articles[language.rawValue]?.contains(fold(tokens[0])) == true {
            tokens.removeFirst()
        } else if tokens.count == 2, language == .english, fold(tokens[0]) == "to" {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return .none }
        var parts = tokens.map { Part($0, language: language) }
        if language == .german, parts.count > 1 {
            for (i, t) in tokens.enumerated() where t.first?.isLowercase == true && !germanFixed.contains(parts[i].exact) {
                parts[i].movable = true
            }
        }
        var separable: Separable?
        if language == .german, parts.count == 1, let s = Self.separable(parts[0].exact) {
            separable = Separable(particle: s.particle, verb: Part(s.verb, language: language))
        }
        return .words(parts, separable: separable, also: nil)
    }

    /// 德语短语里不会挪到前面去的小词：介词、冠词、zu、nicht
    private static let germanFixed: Set<String> = ["zu", "zum", "zur", "in", "im", "ins", "an", "am", "ans", "auf", "aufs", "aus", "bei", "beim",
                                                   "mit", "nach", "von", "vom", "vor", "über", "unter", "um", "durch", "für", "gegen",
                                                   "ohne", "bis", "seit", "ab", "der", "die", "das", "den", "dem", "des", "ein", "eine",
                                                   "einen", "einem", "einer", "eines", "nicht", "kein", "keine"]

    /// 去掉括号（连同括号里的字），斜杠几选一留第一个不是占位词的；sb/sth 这种全是占位词的整段去掉。
    /// 整个词头就是一组斜杠（and/or）的不动，原样找
    private static func simplifyOptions(_ w: String) -> String {
        // 词里面的括号（colo(u)r）不动
        let noParens = w.replacingOccurrences(of: #"(?<![\p{L}\p{N}])(\([^()]*\)|\[[^\[\]]*\])(?![\p{L}\p{N}])"#, with: " ",
                                              options: .regularExpression)
        let chunks = noParens.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !(chunks.count == 1 && chunks[0].contains("/")) else { return noParens.trimmingCharacters(in: .whitespaces) }
        return chunks.compactMap { c -> String? in
            guard c.contains("/") else { return c }
            return c.split(separator: "/").map(String.init).first { !stripPlaceholders($0).isEmpty }
        }.joined(separator: " ")
    }

    // MARK: - 找

    /// 每处出现的范围，从前往后、不重叠
    func ranges(in text: String) -> [Range<String.Index>] { find(in: text).ranges }

    /// complete = 系统词元用上了（或这门语言本来就没有）；主线程上词元模型还没读完时是 false，这次的结果不该缓存
    private func find(in text: String) -> (ranges: [Range<String.Index>], complete: Bool) {
        switch mode {
        case .none:
            return ([], true)
        case .substring(let needle):
            return (Self.occurrences(of: needle, in: text, wholeWord: false), true)
        case .literal(let needle):
            return (Self.occurrences(of: needle, in: text, wholeWord: true), true)
        case .words(let parts, let separable, let also):
            var tokens = Self.tokenize(text)
            guard !tokens.isEmpty else { return ([], true) }
            if language == .english { tokens = Self.joiningNegations(tokens, in: text) }
            let (tagged, complete) = Self.lemmas(of: text, tokens: tokens, language: language)
            let lemmas = tokens.indices.map { tokens[$0].lemma ?? tagged[$0] }
            func hit(_ i: Int, _ p: Part) -> Bool { matches(tokens[i], lemma: lemmas[i], part: p) }
            var found: [Range<String.Index>] = []
            if parts.count == 1 {
                for i in tokens.indices where hit(i, parts[0]) || also.map({ hit(i, $0) }) == true { found.append(tokens[i].range) }
                if let separable { found += separated(separable, tokens: tokens, lemmas: lemmas, text: text) }
            } else {
                found = phrase(parts, tokens: tokens, lemmas: lemmas, text: text)
            }
            return (Self.tidy(found), complete)
        }
    }

    /// 一个词对不对得上查的词里的某一段：原样、查表、系统给的词元、词尾规则
    private func matches(_ t: Token, lemma: String?, part: Part) -> Bool {
        if t.exact == part.exact || part.forms.contains(t.exact) { return true }
        if let lemma, lemma == part.exact { return true }
        // 查表的西语动词后面粘着代词：hazlo、dímelo、hacerlo、ponerse
        if !part.hosts.isEmpty, Inflection.withoutClitics(t.loose).contains(where: part.hosts.contains) { return true }
        guard part.forms.isEmpty else { return false }
        // 先按保留重音、变音的写法套词尾规则
        if Inflection.matches(t.exact, base: part.exact, language: language) { return true }
        // 只有去掉重音、变音才对得上的：系统认出它是另一个词（schöner → schön、zählt → zählen、drückt → drücken）就不算
        if let lemma, lemma != t.exact { return false }
        switch language {
        case .french:
            // 法语变位只在 e 上换重音（préfère → préférer），ç 和 c 互换（commençons）；sûre 不是 sur 的变形
            return Inflection.matches(Self.frenchLoose(t.exact), base: Self.frenchLoose(part.exact), language: language)
        case .spanish:
            // 只多一个 -s 不挪重音：estás 不是 esta 的复数
            if t.loose == part.loose + "s" { return false }
            return Inflection.matches(t.loose, base: part.loose, language: language)
        default:
            return Inflection.matches(t.loose, base: part.loose, language: language)
        }
    }

    private static func frenchLoose(_ s: String) -> String {
        String(s.map { c -> Character in "éèêë".contains(c) ? "e" : c == "ç" ? "c" : c })
    }

    /// 短语：按顺序找，两段之间最多夹 3 个词、不跨句子和逗号；挨着的几段连成一整块标
    private func phrase(_ parts: [Part], tokens: [Token], lemmas: [String?], text: String) -> [Range<String.Index>] {
        func hit(_ i: Int, _ p: Part) -> Bool { matches(tokens[i], lemma: lemmas[i], part: p) }
        var out: [Range<String.Index>] = []
        var claimed = Set<Int>()
        var i = 0
        while i < tokens.count {
            guard !claimed.contains(i), hit(i, parts[0]) else { i += 1; continue }
            var picks = [i]
            for p in parts.dropFirst() {
                let last = picks[picks.count - 1]
                var m = last + 1, next: Int?
                while m < tokens.count, m - last - 1 <= 3, !Self.breaksClause(text[tokens[m - 1].range.upperBound..<tokens[m].range.lowerBound]) {
                    if hit(m, p) { next = m; break }
                    m += 1
                }
                guard let next else { picks = []; break }
                picks.append(next)
            }
            if picks.isEmpty { i += 1; continue }
            claimed.formUnion(picks)
            out += Self.joined(picks, tokens: tokens, text: text)
            i = picks[picks.count - 1] + 1
        }
        // 德语主句里动词跑到前面（in Kauf nehmen → nimmt … in Kauf）：同一小句里每段都有就都标。
        // 只有动词、代词能挪，别的几段要照原来的先后（um nach Hause zu gehen 里没有 zu Hause）
        if language == .german, parts.contains(where: \.movable) {
            for clause in Self.clauses(tokens, text: text) where clause.count <= 24 && !clause.contains(where: claimed.contains) {
                var picks: [Int] = [], lastFixed = -1
                for p in parts {
                    guard let k = clause.first(where: { !picks.contains($0) && (p.movable || $0 > lastFixed) && hit($0, p) }) else {
                        picks = []; break
                    }
                    if !p.movable { lastFixed = k }
                    picks.append(k)
                }
                if !picks.isEmpty { out += Self.joined(picks.sorted(), tokens: tokens, text: text) }
            }
        }
        return out
    }

    /// 德语可分动词拆开：小句里有这个动词的变位，小句最后一个词是前缀（Der Bus hält an der Ecke an.）；
    /// 讲解里常写成「hält … an」，省略号不算断句。und / oder 后面是另一个动词的小句（Sie hörte mir zu und hörte auf.），
    /// 前缀配离它最近的那个变位。命令式只剩词干（Mach die Tür zu!），句末有前缀时也认
    private func separated(_ s: Separable, tokens: [Token], lemmas: [String?], text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        let v = s.verb.loose
        let stem = v.hasSuffix("en") ? String(v.dropLast(2)) : String(v.dropLast())
        func isVerb(_ k: Int) -> Bool { matches(tokens[k], lemma: lemmas[k], part: s.verb) || (stem.count >= 3 && tokens[k].loose == stem) }
        for clause in Self.clauses(tokens, text: text, ellipsisJoins: true) {
            for sub in clause.split(whereSeparator: { ["und", "oder"].contains(tokens[$0].exact) }) where sub.count >= 2 && sub.count <= 24 {
                guard let last = sub.last, tokens[last].exact == s.particle, let k = sub.dropLast().last(where: isVerb) else { continue }
                out += [tokens[k].range, tokens[last].range]
            }
        }
        return out
    }

    /// 变化那行说这个德语动词可分：「trennbar · hält an · hielt an · hat angehalten」里的 an。
    /// 认三种写法：前缀 + ge + 词干（angehalten、zugehört）、前缀 + zu + 原形（anzuhalten）；
    /// 写明了 trennbar（可分）时再认变位后面紧跟前缀、小句到此为止的（hält an）
    static func particle(of verb: Part, in grammar: String) -> String? {
        let v = verb.loose
        guard v.count >= 4, v.hasSuffix("n"), separable(verb.exact) == nil else { return nil }
        let stem = v.hasSuffix("en") ? String(v.dropLast(2)) : String(v.dropLast())
        guard stem.count >= 2 else { return nil }
        let tokens = tokenize(grammar)
        let saysSeparable = tokens.indices.contains { i in
            ["trennbar", "separable"].contains(tokens[i].exact) && (i == 0 || tokens[i - 1].exact != "nicht")
        } || grammar.replacingOccurrences(of: "不可分", with: "").contains("可分")
        for (i, t) in tokens.enumerated() {
            for p in separablePrefixes where t.exact.hasPrefix(p) && t.exact.count > p.count {
                let rest = loosen(String(t.exact.dropFirst(p.count)))
                if (rest.hasPrefix("ge") && rest.dropFirst(2).hasPrefix(stem)) || rest == "zu" + v { return p }
            }
            if saysSeparable, i > 0, separablePrefixes.contains(t.exact),
               i == tokens.count - 1 || breaksClause(grammar[t.range.upperBound..<tokens[i + 1].range.lowerBound]),
               !breaksClause(grammar[tokens[i - 1].range.upperBound..<t.range.lowerBound]),
               tokens[i - 1].loose.hasPrefix(String(stem.prefix(3))) {
                return t.exact
            }
        }
        return nil
    }

    // MARK: - 切词

    struct Token {
        let range: Range<String.Index>
        let exact: String
        let loose: String
        /// 自己定的词元（合起来的否定缩写：doesn't → do）；nil 就问系统
        var lemma: String? = nil
    }

    /// 字母、数字连成一个词；中日韩字、空格、标点、连字符、撇号都是边界（l'eau 里能找到 eau，heat's 里能找到 heat）
    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard isWordChar(s[i]) else { i = s.index(after: i); continue }
            var j = s.index(after: i)
            while j < s.endIndex, isWordChar(s[j]) { j = s.index(after: j) }
            let w = String(s[i..<j])
            out.append(Token(range: i..<j, exact: fold(w), loose: loosen(w)))
            i = j
        }
        return out
    }

    /// 英语否定缩写在撇号处切成了 don + t：合回一个词，按去掉 n't 的那个词比（doesn't → does，词元 do）；
    /// won't → will、can't → can。只认这些助动词，don（穿）、Don（人名）后面没有 't 的照常
    private static let negations: [String: (word: String, lemma: String?)] = [
        "don": ("do", "do"), "doesn": ("does", "do"), "didn": ("did", "do"),
        "isn": ("is", "be"), "aren": ("are", "be"), "wasn": ("was", "be"), "weren": ("were", "be"), "ain": ("ain", "be"),
        "hasn": ("has", "have"), "haven": ("have", "have"), "hadn": ("had", "have"),
        "won": ("will", "will"), "shan": ("shall", "shall"), "can": ("can", "can"), "couldn": ("could", nil),
        "wouldn": ("would", nil), "shouldn": ("should", nil), "mustn": ("must", nil), "needn": ("need", "need"),
        "mightn": ("might", nil), "daren": ("dare", "dare"), "oughtn": ("ought", nil),
    ]

    static func joiningNegations(_ tokens: [Token], in text: String) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count, tokens[i + 1].exact == "t", let n = negations[tokens[i].exact],
               text[tokens[i].range.upperBound..<tokens[i + 1].range.lowerBound].allSatisfy({ "'’ʼ".contains($0) }),
               tokens[i].range.upperBound < tokens[i + 1].range.lowerBound {
                out.append(Token(range: tokens[i].range.lowerBound..<tokens[i + 1].range.upperBound, exact: n.word,
                                 loose: n.word, lemma: n.lemma))
                i += 2
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    static func isWordChar(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, !isCJK(s) else { return false }
        return c.isLetter || c.isNumber
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isIdeographic { return true }
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,   // 假名
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:   // 谚文
            return true
        default:
            return false
        }
    }

    /// 两个词之间只隔这些（和空格）算挨着：well-known、aujourd'hui
    static let joiners: Set<Character> = ["-", "‐", "‑", "–", "'", "’", "ʼ"]

    /// 隔着这些就不是同一小句了；· • | / 是变化那行的分隔（trennbar · hält an · hielt an）
    private static func breaksClause(_ gap: Substring, ellipsisJoins: Bool = false) -> Bool {
        let g = ellipsisJoins ? Substring(gap.replacingOccurrences(of: "...", with: " ").replacingOccurrences(of: "…", with: " ")) : gap
        return g.contains { ".,;:!?…。，；：！？、()[]{}«»‹›\"“”„「」『』—\n·•|/".contains($0) || isCJKCharacter($0) }
    }

    private static func isCJKCharacter(_ c: Character) -> Bool { c.unicodeScalars.first.map(isCJK) ?? false }

    /// 按标点切成小句，每句是一串词的下标
    private static func clauses(_ tokens: [Token], text: String, ellipsisJoins: Bool = false) -> [[Int]] {
        var out: [[Int]] = [], cur: [Int] = []
        for i in tokens.indices {
            if i > 0, breaksClause(text[tokens[i - 1].range.upperBound..<tokens[i].range.lowerBound], ellipsisJoins: ellipsisJoins) {
                out.append(cur); cur = []
            }
            cur.append(i)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 选中的几个词：挨着的连成一块（中间只有空格、连字符），隔开的各标各的
    private static func joined(_ picks: [Int], tokens: [Token], text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start = picks[0], end = picks[0]
        for k in picks.dropFirst() {
            let gap = text[tokens[end].range.upperBound..<tokens[k].range.lowerBound]
            if k == end + 1, gap.allSatisfy({ $0.isWhitespace || joiners.contains($0) }) {
                end = k
            } else {
                out.append(tokens[start].range.lowerBound..<tokens[end].range.upperBound)
                start = k; end = k
            }
        }
        out.append(tokens[start].range.lowerBound..<tokens[end].range.upperBound)
        return out
    }

    private static func tidy(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound < last.upperBound {
                if r.upperBound > last.upperBound { out[out.count - 1] = last.lowerBound..<r.upperBound }
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static func occurrences(of needle: String, in text: String, wholeWord: Bool) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: needle, options: [.caseInsensitive], range: from..<text.endIndex) {
            var edgeOK = true
            if wholeWord {
                if let f = needle.first, isWordChar(f), r.lowerBound > text.startIndex,
                   isWordChar(text[text.index(before: r.lowerBound)]) { edgeOK = false }
                if let l = needle.last, isWordChar(l), r.upperBound < text.endIndex, isWordChar(text[r.upperBound]) { edgeOK = false }
            }
            if edgeOK { out.append(r) }
            from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
        }
        return out
    }

    // MARK: - 折叠

    /// 大小写折叠，ß → ss；先统一成组合好的写法，é 和 e + ´ 是同一个
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// 再去掉重音和变音（Häuser → hauser，préfère → prefere）
    static func loosen(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// 短语里占位的 sb / sth / one's / etw / jdn / qn / qch / alguien / algo
    private static func stripPlaceholders(_ s: String) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}])(sb's|sth's|someone's|somebody's|one's|oneself|sth|sb|smth|smb|someone|somebody|something|etw|jdn|jdm|jds|jmdn|jmdm|jmds|qn|qch|qc|alguien|algo)\.?(?![\p{L}\p{N}])|\.{3}|…|~"#
        let out = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - 德语可分动词

    /// 能拆开的前缀（um、durch、über、unter 两种都有，不算）；长的先认
    private static let separablePrefixes = ["zusammen", "zurück", "weiter", "vorbei", "voraus", "voran", "nieder", "hinunter",
                                            "hinein", "hinaus", "hinauf", "herunter", "herum", "herein", "heraus", "herauf",
                                            "heran", "herab", "entgegen", "empor", "statt", "teil", "fest", "fort", "frei",
                                            "hoch", "weg", "vor", "nach", "mit", "los", "hin", "her", "ein", "dar", "bei",
                                            "aus", "auf", "an", "ab", "zu"]

    /// verb 已去掉变音时，前缀也去掉（zurück → zuruck）
    private static func loosenIfNeeded(_ verb: String) -> (String) -> String {
        verb == loosen(verb) ? { loosen($0) } : { $0 }
    }

    static func separable(_ verb: String) -> (particle: String, verb: String)? {
        guard verb.hasSuffix("n") else { return nil }
        for p in separablePrefixes.map(loosenIfNeeded(verb)) where verb.hasPrefix(p) {
            let rest = String(verb.dropFirst(p.count))
            if rest.count >= 4, rest.hasSuffix("en") || rest.hasSuffix("ern") || rest.hasSuffix("eln") { return (p, rest) }
        }
        return nil
    }

    // MARK: - 系统词元

    private static func nlLanguage(_ l: Language) -> NLLanguage? {
        switch l {
        case .english: return .english
        case .german: return .german
        case .french: return .french
        case .spanish: return .spanish
        default: return nil
        }
    }

    /// 每门语言的词元模型读完没有、有没有词元（macOS 15 上英语、德语有；法语、西语没有，试一次也要 0.1 秒）。
    /// 启动时在后台读（warmUp）；读完之前主线程不等它，按没有词元算，这次的结果也不缓存
    private static let lemmaState = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// 每个词的词元（大小写折叠）；系统没给、或切词和我们的对不上的是 nil。complete = false：主线程上模型还没读完，没问系统
    private static func lemmas(of text: String, tokens: [Token], language: Language) -> (lemmas: [String?], complete: Bool) {
        let none = [String?](repeating: nil, count: tokens.count)
        guard let nl = nlLanguage(language) else { return (none, true) }
        switch lemmaState.withLock({ $0[language.rawValue] }) {
        case false?: return (none, true)
        case nil where Thread.isMainThread: return (none, false)
        default: break
        }
        return (tag(text, tokens: tokens, language: nl), true)
    }

    private static func tag(_ text: String, tokens: [Token], language: NLLanguage) -> [String?] {
        var out = [String?](repeating: nil, count: tokens.count)
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var byStart: [String.Index: (end: String.Index, lemma: String)] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            if let tag, !tag.rawValue.isEmpty { byStart[r.lowerBound] = (r.upperBound, fold(tag.rawValue)) }
            return true
        }
        for (i, t) in tokens.enumerated() {
            if let hit = byStart[t.range.lowerBound], hit.end == t.range.upperBound { out[i] = hit.lemma }
        }
        return out
    }

    /// 把词元模型读进来（第一次：英语约 0.15 秒、德语约 0.07 秒），顺便记下哪门语言有词元。会卡住调用它的线程，放后台调
    static func warmUp() {
        let samples: [(String, Language)] = [("The sun heats the water.", .english), ("Der Bus hält an.", .german),
                                             ("Il préfère le café.", .french), ("Ella prefiere el café.", .spanish)]
        for (text, lang) in samples {
            guard let nl = nlLanguage(lang) else { continue }
            let has = tag(text, tokens: tokenize(text), language: nl).contains { $0 != nil }
            lemmaState.withLock { $0[lang.rawValue] = has }
        }
    }

    // MARK: - 缓存

    /// 卡片每重画一次都要标一遍（语法分解流式时一秒几十次）；同一个词、同一段字只算一次
    private static let cache = OSAllocatedUnfairLock(initialState: [String: [Range<Int>]]())

    /// 按字符数算的位置（AttributedString 的字符和 String 的 Character 一一对应）。grammar 只对德语有用（认可分动词）
    static func spans(of word: String, language: Language, in text: String, grammar: String? = nil) -> [Range<Int>] {
        let g = language == .german ? grammar ?? "" : ""
        let key = language.rawValue + "\u{1}" + word + "\u{1}" + g + "\u{1}" + text
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let (ranges, complete) = WordMatcher(word: word, language: language, grammar: g.isEmpty ? nil : g).find(in: text)
        var spans: [Range<Int>] = []
        var pos = 0, idx = text.startIndex
        for r in ranges {
            pos += text.distance(from: idx, to: r.lowerBound)
            let len = text.distance(from: r.lowerBound, to: r.upperBound)
            spans.append(pos..<(pos + len))
            pos += len
            idx = r.upperBound
        }
        guard complete else { return spans }
        let result = spans
        cache.withLock { c in
            if c.count > 600 { c.removeAll(keepingCapacity: true) }
            c[key] = result
        }
        return result
    }
}

// MARK: - 词尾规则（系统给不了词元、或给的对不上时用）

enum Inflection {
    /// t、base 都已去掉大小写和重音；t 和 base 一样的不算（整词比较在外面做，schon 和 schön 在这里会一样）
    static func matches(_ t: String, base e: String, language: Language) -> Bool {
        guard t != e, !e.isEmpty else { return false }
        switch language {
        case .english: return english(t, e)
        case .german: return german(t, e)
        case .french: return french(t, e)
        case .spanish: return spanish(t, e)
        default: return generic(t, e)
        }
    }

    private static func suffixed(_ t: String, _ base: String, _ suffixes: Set<String>, min: Int) -> Bool {
        base.count >= min && t.count > base.count && t.hasPrefix(base) && suffixes.contains(String(t.dropFirst(base.count)))
    }

    private static func isConsonant(_ c: Character) -> Bool { c.isLetter && !"aeiouy".contains(c) }

    // 英语：短词（run、cat）的变形系统都认得，规则只管 4 个字母以上的；比较级（faster、happier）也交给系统，
    // 不然 heater 会被当成 heat 的变形
    private static func english(_ t: String, _ e: String) -> Bool {
        if suffixed(t, e, ["s", "es", "ed", "ing"], min: 4) { return true }   // heats heated heating boxes
        if e.hasSuffix("e") {
            if suffixed(t, e, ["d", "s"], min: 4) { return true }               // mitigated mitigates
            if suffixed(t, String(e.dropLast()), ["ing", "ed"], min: 4) { return true }   // mitigating
        }
        if let last = e.last, isConsonant(last), !"wxy".contains(last), e.count >= 3,
           suffixed(t, e + String(last), ["ed", "ing"], min: 4) { return true }   // stopped planning
        if e.hasSuffix("y"), e.count >= 4, suffixed(t, String(e.dropLast()) + "i", ["es", "ed"], min: 4) { return true }   // studies studied
        if e.hasSuffix("ie"), t == String(e.dropLast(2)) + "ying" { return true }   // lying
        if e.hasSuffix("fe"), t == String(e.dropLast(2)) + "ves" { return true }    // knives
        if e.hasSuffix("f"), t == String(e.dropLast()) + "ves" { return true }      // leaves
        let latin: [(String, String)] = [("is", "es"), ("us", "i"), ("um", "a"), ("on", "a"), ("ix", "ices"), ("ex", "ices")]
        for (from, to) in latin where e.hasSuffix(from) && e.count >= 5 {
            if t == String(e.dropLast(from.count)) + to { return true }   // analyses stimuli media criteria indices
        }
        return false
    }

    private static let germanNominal: Set<String> = ["e", "em", "en", "er", "es", "n", "s", "nen", "ern", "ere", "erem", "eren",
                                                     "erer", "eres", "st", "ste", "stem", "sten", "ster", "stes", "este",
                                                     "estem", "esten", "ester", "estes"]
    private static let germanVerbal: Set<String> = ["e", "est", "st", "et", "t", "en", "end", "ende", "enden", "ender", "endes",
                                                    "te", "test", "ten", "tet", "tete", "teten", "ete", "etest", "eten", "etet"]

    // 德语：变音已经去掉（Häuser → hauser），复数、格、比较级是词尾；动词看去掉 -en 的词干，过去分词 ge…t。
    // sein、tun 这种只以 -n 结尾的不猜（sei + t 会认成 seit），它们的变位系统词元都认
    private static func german(_ t: String, _ e: String) -> Bool {
        if suffixed(t, e, germanNominal, min: 4) { return true }   // Kinder Häuser Fahrers größer
        var stem: String?
        if e.hasSuffix("ern") || e.hasSuffix("eln") { stem = String(e.dropLast()) }
        else if e.hasSuffix("en") { stem = String(e.dropLast(2)) }
        guard let stem, stem.count >= 3 else { return false }
        if suffixed(t, stem, germanVerbal, min: 3) { return true }   // macht machte machend
        if t.hasPrefix("ge"), suffixed(String(t.dropFirst(2)), stem, ["t", "et", "en"], min: 3) { return true }   // gemacht
        if let s = WordMatcher.separable(e) {
            let rest = s.verb
            let restStem = rest.hasSuffix("en") ? String(rest.dropLast(2)) : String(rest.dropLast())
            if t == s.particle + "zu" + rest { return true }   // anzuhalten
            if t.hasPrefix(s.particle + "ge"),
               suffixed(String(t.dropFirst(s.particle.count + 2)), restStem, ["t", "et", "en"], min: 3) { return true }   // aufgemacht
        }
        return false
    }

    private static let frenchER: Set<String> = ["e", "es", "ent", "ons", "ez", "ais", "ait", "aient", "ions", "iez", "ai", "as", "a",
                                                "ames", "ates", "erent", "erai", "eras", "era", "erons", "erez", "eront", "erais",
                                                "erait", "erions", "eriez", "eraient", "ee", "ees", "ant", "asse", "asses", "at",
                                                "assions", "assiez", "assent", "eons", "eant", "eais", "eait", "eaient"]
    private static let frenchIR: Set<String> = ["is", "it", "issons", "issez", "issent", "issais", "issait", "issaient", "issions",
                                                "issiez", "i", "ie", "ies", "irai", "iras", "ira", "irons", "irez", "iront", "irais",
                                                "irait", "irions", "iriez", "iraient", "isse", "isses", "issant", "imes", "ites", "irent"]
    private static let frenchRE: Set<String> = ["s", "ons", "ez", "ent", "ais", "ait", "aient", "ions", "iez", "u", "ue", "us", "ues",
                                                "rai", "ras", "ra", "rons", "rez", "ront", "rais", "rait", "rions", "riez", "raient",
                                                "e", "es", "ant", "it", "is", "imes", "ites", "irent"]

    // 法语：名词形容词 -s / -x / -e / -es（-al → -aux）；-er / -ir / -re 动词按词干接词尾（重音已去掉：préfère → prefere）
    private static func french(_ t: String, _ e: String) -> Bool {
        if suffixed(t, e, ["s", "x", "e", "es"], min: 3) { return true }   // chats beaux grande
        if e.hasSuffix("al"), t == String(e.dropLast(2)) + "aux" { return true }   // chevaux
        if e.hasSuffix("ail"), t == String(e.dropLast(3)) + "aux" { return true }  // travaux
        if e.hasSuffix("if"), [String(e.dropLast()) + "ve", String(e.dropLast()) + "ves"].contains(t) { return true }   // active
        if e.hasSuffix("eux"), [String(e.dropLast()) + "se", String(e.dropLast()) + "ses"].contains(t) { return true }  // heureuse
        if let last = e.last, "nlts".contains(last), [e + String(last) + "e", e + String(last) + "es"].contains(t) { return true }   // ancienne
        guard e.count >= 4 else { return false }
        let stem = String(e.dropLast(2))
        if e.hasSuffix("er") {
            if suffixed(t, stem, frenchER, min: 3) { return true }   // préfère préférons mangé
            if let l = stem.last, isConsonant(l), suffixed(t, stem + String(l), ["e", "es", "ent", "era", "erai", "eras", "erons", "erez", "eront", "erait", "eraient"], min: 3) { return true }   // appelle jette
        } else if e.hasSuffix("ir") {
            if suffixed(t, stem, frenchIR, min: 3) { return true }   // finissons fini
        } else if e.hasSuffix("re") {
            if suffixed(t, stem, frenchRE, min: 3) || (stem.count >= 4 && t == stem) { return true }   // vendons, il vend
        }
        return false
    }

    private static let spanishAR: Set<String> = ["o", "as", "a", "amos", "ais", "an", "e", "aste", "asteis", "aron", "aba", "abas",
                                                 "abamos", "abais", "aban", "are", "aras", "ara", "aremos", "areis", "aran", "aria",
                                                 "arias", "ariamos", "ariais", "arian", "es", "emos", "eis", "en", "aramos", "arais",
                                                 "ase", "ases", "asemos", "aseis", "asen", "ado", "ada", "ados", "adas", "ando", "ad"]
    private static let spanishER: Set<String> = ["o", "es", "e", "emos", "eis", "en", "i", "iste", "io", "imos", "isteis", "ieron",
                                                 "ia", "ias", "iamos", "iais", "ian", "ere", "eras", "era", "eremos", "ereis", "eran",
                                                 "eria", "erias", "eriamos", "eriais", "erian", "a", "as", "amos", "ais", "an", "iera",
                                                 "ieras", "ieramos", "ierais", "ieran", "iese", "ieses", "iesen", "ido", "ida", "idos",
                                                 "idas", "iendo", "ed"]
    private static let spanishIR: Set<String> = ["o", "es", "e", "imos", "is", "en", "i", "iste", "io", "isteis", "ieron", "ia", "ias",
                                                 "iamos", "iais", "ian", "ire", "iras", "ira", "iremos", "ireis", "iran", "iria",
                                                 "irias", "iriamos", "iriais", "irian", "a", "as", "amos", "ais", "an", "iera", "ieras",
                                                 "ieramos", "ierais", "ieran", "iese", "ieses", "iesen", "ido", "ida", "idos", "idas",
                                                 "iendo", "id"]
    private static let clitics = ["los", "las", "les", "nos", "lo", "la", "le", "me", "te", "se", "os"]

    /// 西语去掉后面粘着的一两个代词（dímelo → díme → dí），剩下至少两个字母；不含原词
    static func withoutClitics(_ t: String) -> [String] {
        var out: [String] = [], round = [t]
        for _ in 0..<2 {
            round = round.flatMap { c in clitics.filter { c.hasSuffix($0) && c.count >= $0.count + 2 }.map { String(c.dropLast($0.count)) } }
            out += round
        }
        return out
    }

    // 西语：名词形容词 -s / -es / -ces，-o ↔ -a；-ar / -er / -ir 动词接词尾，词干变音（poder → puedo）、拼写变化（buscar → busqué）、
    // 后面粘着代词（hacerlo、levantarse）
    private static func spanish(_ t: String, _ e: String) -> Bool {
        if suffixed(t, e, ["s", "es"], min: 3) { return true }   // casas acciones
        if e.hasSuffix("z"), t == String(e.dropLast()) + "ces" { return true }   // luces
        if e.hasSuffix("o"), e.count >= 4, ["a", "os", "as"].map({ String(e.dropLast()) + $0 }).contains(t) { return true }   // nueva
        if e.hasSuffix("or"), ["a", "as"].map({ e + $0 }).contains(t) { return true }   // trabajadora
        var verb = e
        if e.hasSuffix("se"), ["ar", "er", "ir"].contains(where: { e.dropLast(2).hasSuffix($0) }) { verb = String(e.dropLast(2)) }
        guard verb.count >= 4, let ending = ["ar", "er", "ir"].first(where: { verb.hasSuffix($0) }) else { return false }
        let set = ending == "ar" ? spanishAR : ending == "er" ? spanishER : spanishIR
        let stem = String(verb.dropLast(2))
        var stems = [stem]
        if let v = stem.lastIndex(where: { "eou".contains($0) }) {
            let head = stem[..<v], tail = stem[stem.index(after: v)...]
            switch stem[v] {
            case "o", "u": stems.append(String(head) + "ue" + tail)
            case "e": stems += [String(head) + "ie" + tail, String(head) + "i" + tail]
            default: break
            }
        }
        let lead = String(stem.dropLast())
        if stem.hasSuffix("c") { stems.append(lead + "qu") }
        if stem.hasSuffix("g") { stems += [lead + "gu", lead + "j"] }
        if stem.hasSuffix("z") { stems.append(lead + "c") }
        // 粘着的代词去掉一两个再比：hazlo → haz，dándoselo → dando
        var candidates = [t]
        for _ in 0..<2 {
            for c in candidates {
                for cl in clitics where c.hasSuffix(cl) && c.count > cl.count + 2 { candidates.append(String(c.dropLast(cl.count))) }
            }
        }
        for c in Set(candidates) {
            if c == verb { return true }   // hacerlo
            for s in stems where suffixed(c, s, set, min: 2) { return true }
        }
        return false
    }

    // 别的语言：去掉最后两个字母当词干，后面最多再多三个字母
    private static func generic(_ t: String, _ e: String) -> Bool {
        guard e.count >= 5 else { return false }
        let stem = String(e.prefix(e.count - 2))
        return t.hasPrefix(stem) && t.count <= e.count + 3
    }
}

// MARK: - 不规则变化表（系统给不了法语、西语的词元；英语的比较级系统常不认）

enum Irregular {
    static func forms(of lemma: String, language: Language) -> Set<String> {
        guard let table = tables[language.rawValue], let list = table[lemma] else { return [] }
        return list
    }

    /// 西语查表的动词：后面能粘代词的写法（不定式、副动词、肯定命令式），去掉重音（dímelo、hágalo 的重音是粘上代词才加的）。
    /// di、ve、ven 单独出现时也是 dar、ver 的变位，不放进上面的表，只在粘着代词时认（dime、vete）
    static func encliticHosts(of lemma: String) -> Set<String> {
        guard let forms = tables[Language.spanish.rawValue]?[lemma] else { return [] }
        let hosts = [lemma] + forms.filter { $0.hasSuffix("ndo") } + (spanishImperatives[lemma] ?? [])
        return Set(hosts.map(WordMatcher.loosen))
    }

    private static let spanishImperatives: [String: [String]] = build([
        "hacer": "haz haced haga hagan", "decir": "di decid diga digan", "poner": "pon poned ponga pongan",
        "tener": "ten tened tenga tengan", "venir": "ven venid venga vengan", "ir": "ve id vaya vayan",
        "ver": "ve ved vea vean", "dar": "da dad dé den", "saber": "sé sabed sepa sepan", "ser": "sé sed sea sean",
        "estar": "está estad esté estén", "querer": "quiere quered quiera quieran", "poder": "puede poded pueda puedan",
        "haber": "he habed haya hayan",
    ]).mapValues { Array($0) }

    private static let tables: [String: [String: Set<String>]] = [
        Language.english.rawValue: build([
            "good": "better best", "well": "better best", "bad": "worse worst", "badly": "worse worst", "ill": "worse worst",
            "far": "farther further farthest furthest", "many": "more most", "much": "more most", "little": "less least",
            "be": "am is are was were been being",
        ]),
        Language.french.rawValue: build([
            "être": "suis es est sommes êtes sont étais était étions étiez étaient été serai seras sera serons serez seront serais serait serions seriez seraient fus fut fûmes fûtes furent sois soit soyons soyez soient fût étant",
            "avoir": "ai as a avons avez ont avais avait avions aviez avaient eu eue eus eues aurai auras aura aurons aurez auront aurais aurait aurions auriez auraient eut eûmes eûtes eurent aie aies ait ayons ayez aient eût ayant",
            "aller": "vais vas va allons allez vont allais allait allions alliez allaient allé allée allés allées irai iras ira irons irez iront irais irait irions iriez iraient allai alla allâmes allèrent aille ailles aillent allant",
            "faire": "fais fait faisons faites font faisais faisait faisions faisiez faisaient faite faits ferai feras fera ferons ferez feront ferais ferait ferions feriez feraient fis fit fîmes fîtes firent fasse fasses fassions fassiez fassent faisant",
            "pouvoir": "peux peut pouvons pouvez peuvent pouvais pouvait pouvions pouviez pouvaient pu pourrai pourras pourra pourrons pourrez pourront pourrais pourrait pourrions pourriez pourraient pus put pûmes purent puisse puisses puissions puissiez puissent pouvant",
            "vouloir": "veux veut voulons voulez veulent voulais voulait voulions vouliez voulaient voulu voulue voulus voudrai voudras voudra voudrons voudrez voudront voudrais voudrait voudrions voudriez voudraient voulut voulurent veuille veuilles veuillent voulant",
            "savoir": "sais sait savons savez savent savais savait savions saviez savaient su sue sus sues saurai sauras saura saurons saurez sauront saurais saurait saurions sauriez sauraient sut surent sache saches sachions sachiez sachent sachant",
            "venir": "viens vient venons venez viennent venais venait venions veniez venaient venu venue venus venues viendrai viendras viendra viendrons viendrez viendront viendrais viendrait viendrions viendriez viendraient vins vint vînmes vinrent vienne viennes venant",
            "prendre": "prends prend prenons prenez prennent prenais prenait prenions preniez prenaient pris prise prises prendrai prendras prendra prendrons prendrez prendront prendrais prendrait prendrions prendriez prendraient prit prîmes prirent prenne prennes prenant",
            "dire": "dis dit disons dites disent disais disait disions disiez disaient dite dits dirai diras dira dirons direz diront dirais dirait dirions diriez diraient dîmes dirent dise dises disant",
            "voir": "vois voit voyons voyez voient voyais voyait voyions voyiez voyaient vu vue vus vues verrai verras verra verrons verrez verront verrais verrait verrions verriez verraient vis vit vîmes virent voie voies voyant",
            "devoir": "dois doit devons devez doivent devais devait devions deviez devaient dû due dus dues devrai devras devra devrons devrez devront devrais devrait devrions devriez devraient dut durent doive doives",
            "mettre": "mets met mettons mettez mettent mettais mettait mettions mettiez mettaient mis mise mises mettrai mettras mettra mettrons mettrez mettront mettrais mettrait mettrions mettriez mettraient mit mîmes mirent mette mettes mettant",
        ]),
        Language.spanish.rawValue: build([
            "ser": "soy eres es somos sois son era eras éramos erais eran fui fuiste fue fuimos fuisteis fueron seré serás será seremos seréis serán sería serías seríamos seríais serían sea seas seamos seáis sean fuera fueras fuéramos fuerais fueran fuese fuesen sido siendo",
            "estar": "estoy estás está estamos estáis están estaba estabas estábamos estabais estaban estuve estuviste estuvo estuvimos estuvisteis estuvieron estaré estarás estará estaremos estaréis estarán estaría estarías estaríamos estaríais estarían esté estés estemos estéis estén estuviera estuvieras estuviéramos estuvierais estuvieran estado estando",
            "ir": "voy vas va vamos vais van iba ibas íbamos ibais iban fui fuiste fue fuimos fuisteis fueron iré irás irá iremos iréis irán iría irías iríamos iríais irían vaya vayas vayamos vayáis vayan fuera fueras fuéramos fuerais fueran ido yendo id",
            "tener": "tengo tienes tiene tenemos tenéis tienen tenía tenías teníamos teníais tenían tuve tuviste tuvo tuvimos tuvisteis tuvieron tendré tendrás tendrá tendremos tendréis tendrán tendría tendrías tendríamos tendríais tendrían tenga tengas tengamos tengáis tengan tuviera tuvieras tuviéramos tuvierais tuvieran tenido teniendo ten tened",
            "hacer": "hago haces hace hacemos hacéis hacen hacía hacías hacíamos hacíais hacían hice hiciste hizo hicimos hicisteis hicieron haré harás hará haremos haréis harán haría harías haríamos haríais harían haga hagas hagamos hagáis hagan hiciera hicieras hiciéramos hicierais hicieran hecho hecha hechos hechas haciendo haz haced",
            "poder": "puedo puedes puede podemos podéis pueden podía podías podíamos podíais podían pude pudiste pudo pudimos pudisteis pudieron podré podrás podrá podremos podréis podrán podría podrías podríamos podríais podrían pueda puedas podamos podáis puedan pudiera pudieras pudiéramos pudierais pudieran podido pudiendo",
            "decir": "digo dices dice decimos decís dicen decía decías decíamos decíais decían dije dijiste dijo dijimos dijisteis dijeron diré dirás dirá diremos diréis dirán diría dirías diríamos diríais dirían diga digas digamos digáis digan dijera dijeras dijéramos dijerais dijeran dicho dicha dichos dichas diciendo decid",
            "ver": "veo ves ve vemos veis ven veía veías veíamos veíais veían vi viste vio vimos visteis vieron veré verás verá veremos veréis verán vería verías veríamos veríais verían vea veas veamos veáis vean viera vieras viéramos vierais vieran visto vista vistos vistas viendo",
            "dar": "doy das da damos dais dan daba dabas dábamos dabais daban di diste dio dimos disteis dieron daré darás dará daremos daréis darán daría darías daríamos daríais darían dé des demos deis den diera dieras diéramos dierais dieran dado dada dados dadas dando",
            "haber": "he has ha hemos habéis han había habías habíamos habíais habían hube hubiste hubo hubimos hubisteis hubieron habré habrás habrá habremos habréis habrán habría habrías habríamos habríais habrían haya hayas hayamos hayáis hayan hubiera hubieras hubiéramos hubierais hubieran habido habiendo hay",
            "saber": "sé sabes sabe sabemos sabéis saben sabía sabías sabíamos sabíais sabían supe supiste supo supimos supisteis supieron sabré sabrás sabrá sabremos sabréis sabrán sabría sabrías sabríamos sabríais sabrían sepa sepas sepamos sepáis sepan supiera supieras supiéramos supierais supieran sabido sabiendo",
            "querer": "quiero quieres quiere queremos queréis quieren quería querías queríamos queríais querían quise quisiste quiso quisimos quisisteis quisieron querré querrás querrá querremos querréis querrán querría querrías querríamos querríais querrían quiera quieras queramos queráis quieran quisiera quisieras quisiéramos quisierais quisieran querido queriendo",
            "venir": "vengo vienes viene venimos venís vienen venía venías veníamos veníais venían vine viniste vino vinimos vinisteis vinieron vendré vendrás vendrá vendremos vendréis vendrán vendría vendrías vendríamos vendríais vendrían venga vengas vengamos vengáis vengan viniera vinieras viniéramos vinierais vinieran venido viniendo venid",
            "poner": "pongo pones pone ponemos ponéis ponen ponía ponías poníamos poníais ponían puse pusiste puso pusimos pusisteis pusieron pondré pondrás pondrá pondremos pondréis pondrán pondría pondrías pondríamos pondríais pondrían ponga pongas pongamos pongáis pongan pusiera pusieras pusiéramos pusierais pusieran puesto puesta puestos puestas poniendo pon poned",
        ]),
    ]

    private static func build(_ raw: [String: String]) -> [String: Set<String>] {
        raw.reduce(into: [:]) { out, kv in
            out[WordMatcher.fold(kv.key)] = Set(kv.value.split(separator: " ").map { WordMatcher.fold(String($0)) })
        }
    }
}
