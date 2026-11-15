import Foundation

/// 訳の関門: 訳 1 つ (文のまとまり 1 つ) を点検して、気になる所に印を付ける。
///
/// 小さな LLM の訳に「要確認」の印を付けるために使う (翻訳の流れ `Translator.translateSummarizing` と、評価ハーネスの測り)。
/// 印は文字列の符号で持つ。保存した後で符号を足したり外したりしても、知らない符号のせいで全体が読めなくならないように、
/// enum にはしない。決まりは採点 (`LLMEval.score`) と翻訳役 (`Translator.isPlausible`) の物を、そのまま使う
/// (決まりを 1 か所で直せば、採点と関門の両方が変わる)。
public enum TranslationGate {
    /// 訳が無い・空
    public static let failed = "failed"
    /// 文字の種類が訳す先の言語に合わない (`Translator.isPlausible` の文字の検査)
    public static let script = "script"
    /// 長すぎる (`Translator.isPlausible` の長さの決まり)
    public static let long = "long"
    /// 同じ語句の繰り返しが異常に多い (`LLMEval.isRepetitive`)
    public static let repeated = "repeated"
    /// 原文をそのまま写しただけ (`LLMEval.isCopy`)
    public static let copied = "copied"
    /// 言語の判定が、訳す先の言語でない (`LLMEval.isInTarget`。短い文は判定しない)
    public static let language = "language"
    /// 原文の数 (2 桁以上) が訳に無い (`LLMEval.numbersLost`)
    public static let number = "number"
    /// 訳語の対の訳語が訳に無い (原文に、対の原語が在る時だけ見る)
    public static let term = "term"
    /// 短すぎる (原文の重さの `shortRatio` 倍に届かない)
    public static let short = "short"

    /// 全部の符号 (この順に並べて返す)
    public static let all: [String] = [failed, script, long, repeated, copied, language, number, term, short]

    /// 重い印: 訳を出さない物 (`Translator.isPlausible` が落とす範囲と同じ。空・文字の種類・長すぎ)。
    /// ほかの印は、訳を出したうえで印だけを付ける。繰り返し・写しは重い印にしない
    /// (「No.」→「No.」、名前だけの行、歌の繰り返しは、正しい訳の事が在る)
    public static let severe: Set<String> = [failed, script, long]

    /// 利用者の判定から学んで、訳す先ごとに止めてよい検査 (印だけの検査)。重い印 (`severe`) は止めない
    /// (訳を出さない検査なので、止めると壊れた訳がそのまま出る)。学び方は `TranslationMemory.suppressedChecks(target:)`
    public static let learnable: Set<String> = [number, language, copied, repeated, short, term]

    /// 短い文の重さの上限 (`weight` がこれより小さい文を「短い文」と見る)。2 つの所で使う:
    /// - 写しの印 (`copied`) を付けない: 名前だけの行・相づち (「No.」「Roblox Studio」) は、写しが正しい訳の事が多い
    /// - 訳の記憶を引かない (`TranslationMemoryLookup.minimumSourceWeight`): 短い文は、場面で訳が変わる
    public static let shortSentenceWeight = 16

    /// 「短すぎる」の決まり: 訳の重さが、原文の重さのこの倍に届かない。
    /// 13 言語の問題の人の訳 (390 行) では、いちばん小さい比が 0.56 (en → zh) だったので、その半分ほどにした
    public static let shortRatio = 0.3
    /// 「短すぎる」を見る原文の重さの下限 (これより短い原文は見ない。「Yes. → はい。」のような短い文は、比が揺れる)
    public static let shortMinimumSourceWeight = 20
    /// 漢字・かな・ハングルの 1 字の重さ (ほかの文字と数字は 1)。1 字に詰まる意味が多いので、ラテン文字より重く数える
    public static let wideCharacterWeight = 2

    /// 点検の結果
    public struct Finding: Codable, Hashable, Sendable {
        /// 付いた印 (符号。`all` の順)。空なら印なし
        public var flags: [String]
        /// 消えた数・語など (画面の言語に依らない形。例 "number: 4000, 15; term: Roblox")
        public var detail: String?

        public init(flags: [String] = [], detail: String? = nil) {
            self.flags = flags
            self.detail = detail
        }

        /// 重い印が在るか
        public var isSevere: Bool { flags.contains(where: TranslationGate.severe.contains) }

        /// 検査 checks の印 (と、その説明の部分 "符号: …") を外した結果。外すのは `learnable` の検査だけ
        /// (重い印は、checks に在っても残す)
        public func removing(_ checks: Set<String>) -> Finding {
            let drop = checks.intersection(TranslationGate.learnable)
            guard !drop.isEmpty, flags.contains(where: drop.contains) else { return self }
            let parts = (detail ?? "").components(separatedBy: "; ").filter { part in
                !part.isEmpty && !drop.contains(where: { part.hasPrefix($0 + ": ") })
            }
            return Finding(flags: flags.filter { !drop.contains($0) },
                           detail: parts.isEmpty ? nil : parts.joined(separator: "; "))
        }
    }

    /// 文の重さ: 文字と数字の数。漢字・かな・ハングルは `wideCharacterWeight` と数える (記号・空白は数えない)
    static func weight(_ text: String) -> Int {
        let kept = CharacterSet.letters.union(.decimalDigits)
        var total = 0
        for scalar in text.unicodeScalars where kept.contains(scalar) {
            let v = scalar.value
            let wide = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v)
                || (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
            total += wide ? wideCharacterWeight : 1
        }
        return total
    }

    /// 訳が短すぎるか (原文が `shortMinimumSourceWeight` 以上の重さの時だけ見る)
    static func isTooShort(_ translation: String, source: String) -> Bool {
        let s = weight(source)
        guard s >= shortMinimumSourceWeight else { return false }
        return Double(weight(translation)) < Double(s) * shortRatio
    }

    /// 1 つの文のまとまり (原文 1 つと訳 1 つ) を点検する。
    /// - sourceLanguage: 原文の言語 (分からなければ nil。写しの検査は「違う言語」と見て行う)
    /// - target: 訳す先の言語のコード
    /// - terms: 訳語の対 (原語と訳語)。原文に原語が在るのに、訳に訳語が無ければ `term` (大文字と小文字は区別しない)。
    ///   説明は "term: X → Y" (原語と訳語が同じなら "term: Y")
    public static func assess(source: String, translation: String?, sourceLanguage: String?, target: String,
                              terms: [(source: String, translation: String)] = [],
                              detector: LanguageDetector? = LLMEval.defaultLanguageDetector) -> Finding {
        let target = TranslationTarget.normalized(target)
        let t = (translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return Finding(flags: [failed]) }
        var flags = Set<String>()
        var details: [String] = []
        if Translator.hasWrongScript(t, source: source, target: target) { flags.insert(script) }
        if Translator.isTooLong(t, source: source, target: target) { flags.insert(long) }
        if LLMEval.isRepetitive(t) { flags.insert(repeated) }
        // 短い原文の写しには印を付けない (`shortSentenceWeight` を見る)
        if weight(source) >= shortSentenceWeight,
           LLMEval.isCopy(t, source: source, sourceLanguage: sourceLanguage, target: target) { flags.insert(copied) }
        if !LLMEval.isInTarget(t, target: target, detector: detector) { flags.insert(language) }
        let lost = LLMEval.numbersLost(sources: [source], translation: t).lost
        if !lost.isEmpty {
            flags.insert(number)
            details.append("number: " + lost.joined(separator: ", "))
        }
        // 訳語の対: 原語の当て方は指示文と同じ (`TermPair.occurs`。語の切れ目)。
        // 訳語の当て方は、語の形が変わる言語のために緩める (`TermPair.kept`)
        var lostTerms: [String] = []
        for pair in terms where !pair.source.isEmpty && !pair.translation.isEmpty {
            guard TermPair.occurs(pair.source, in: source) else { continue }
            let label = TermPair(source: pair.source, translation: pair.translation, target: target).label
            if !TermPair.kept(pair.translation, in: t, target: target), !lostTerms.contains(label) {
                lostTerms.append(label)
            }
        }
        if !lostTerms.isEmpty {
            flags.insert(term)
            details.append("term: " + lostTerms.joined(separator: ", "))
        }
        if isTooShort(t, source: source) { flags.insert(short) }
        return Finding(flags: all.filter(flags.contains), detail: details.isEmpty ? nil : details.joined(separator: "; "))
    }
}
