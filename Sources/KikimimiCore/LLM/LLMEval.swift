import Foundation

/// 評価用の場面 (監査): 聞き間違いを含む短い文字起こしと、その正解。
public struct AuditEvalCase: Codable, Hashable, Sendable {
    public var id: String
    /// 行の言語 ("ja" / "en")
    public var language: String
    /// 語彙のヒント (設定で利用者が書くもの)
    public var glossary: String?
    /// 文字起こしの行 (聞き間違い・繰り返しを含む)
    public var lines: [String]
    /// 正しい行 (lines と同じ数。消すべき行は空の文字列)
    public var expected: [String]

    public init(id: String, language: String, glossary: String? = nil, lines: [String], expected: [String]) {
        self.id = id
        self.language = language
        self.glossary = glossary
        self.lines = lines
        self.expected = expected
    }
}

/// 評価用の場面 (翻訳): 訳す行と、訳に残っているべき語 (固有名詞など)。
public struct TranslationEvalCase: Codable, Hashable, Sendable {
    public var id: String
    /// 原文の言語
    public var language: String
    public var glossary: String?
    public var lines: [String]
    /// 訳のどこかに、そのまま出てくるべき語 (例: "Roblox")
    public var keep: [String]?
    /// 訳す先の言語 (無ければ日本語)
    public var target: String?
    /// 人の訳 (lines と同じ数)。在れば chrF を出す
    public var references: [String]?
    /// 文の種類 (例: "speech"・"social")。数えるのには使わない
    public var domain: String?

    public init(id: String, language: String, glossary: String? = nil, lines: [String], keep: [String]? = nil,
                target: String? = nil, references: [String]? = nil, domain: String? = nil) {
        self.id = id
        self.language = language
        self.glossary = glossary
        self.lines = lines
        self.keep = keep
        self.target = target
        self.references = references
        self.domain = domain
    }

    /// 訳す先の言語のコード (13 言語のどれか。無い・知らないコードなら日本語)
    public var targetLanguage: String { TranslationTarget.normalized(target) }
}

/// 評価用の場面のまとまり (JSON のファイル 1 つ)
public struct LLMEvalSet: Codable, Hashable, Sendable {
    public var name: String
    public var audit: [AuditEvalCase]
    public var translation: [TranslationEvalCase]

    public init(name: String, audit: [AuditEvalCase] = [], translation: [TranslationEvalCase] = []) {
        self.name = name
        self.audit = audit
        self.translation = translation
    }

    private enum CodingKeys: String, CodingKey { case name, audit, translation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        audit = try container.decodeIfPresent([AuditEvalCase].self, forKey: .audit) ?? []
        translation = try container.decodeIfPresent([TranslationEvalCase].self, forKey: .translation) ?? []
    }
}

/// 監査の成績。行ごとに数える
public struct AuditEvalScore: Codable, Hashable, Sendable {
    public var cases = 0
    /// 直すべき行 (聞き間違い・消すべき行)
    public var errorLines = 0
    /// 自動で、正解どおりに直した
    public var fixedAutomatically = 0
    /// 提案 (要確認) を反映すれば、正解どおりになる
    public var fixedBySuggestion = 0
    /// 直すべき行を、正解ではない別の文に自動で変えた
    public var wrongFixes = 0
    /// 何もしなかった (提案も外れ)
    public var missed = 0
    /// 正しい行
    public var cleanLines = 0
    /// 正しい行を、自動で変えた・消した (害)
    public var harmed = 0
    /// 正しい行への提案 (反映しなければ害は無い)
    public var falseSuggestions = 0
    public var seconds = 0.0

    public init() {}

    /// 直すべき行のうち、自動で正しく直した割合
    public var recall: Double { errorLines > 0 ? Double(fixedAutomatically) / Double(errorLines) : 0 }
    /// 提案も含めて、正しい直しを出せた割合
    public var recallWithSuggestions: Double {
        errorLines > 0 ? Double(fixedAutomatically + fixedBySuggestion) / Double(errorLines) : 0
    }
    /// 自動で変えた行のうち、正解だった割合
    public var precision: Double {
        let changed = fixedAutomatically + wrongFixes + harmed
        return changed > 0 ? Double(fixedAutomatically) / Double(changed) : 1
    }
    /// 正しい行を自動で壊した割合
    public var harmRate: Double { cleanLines > 0 ? Double(harmed) / Double(cleanLines) : 0 }

    public mutating func add(_ other: AuditEvalScore) {
        cases += other.cases
        errorLines += other.errorLines
        fixedAutomatically += other.fixedAutomatically
        fixedBySuggestion += other.fixedBySuggestion
        wrongFixes += other.wrongFixes
        missed += other.missed
        cleanLines += other.cleanLines
        harmed += other.harmed
        falseSuggestions += other.falseSuggestions
        seconds += other.seconds
    }

    public var summary: String {
        String(format: "audit: %d cases, %d error lines: fixed %d (%.0f%%), by suggestion %d, wrong %d, missed %d | "
               + "%d clean lines: harmed %d (%.1f%%), false suggestions %d | precision %.0f%%, %.1f s",
               cases, errorLines, fixedAutomatically, recall * 100, fixedBySuggestion, wrongFixes, missed,
               cleanLines, harmed, harmRate * 100, falseSuggestions, precision * 100, seconds)
    }
}

/// 翻訳の成績。形の点検 (訳せたか・その言語か・数と語が残ったか・写し・繰り返し) と、人の訳が在れば chrF
public struct TranslationEvalScore: Codable, Hashable, Sendable {
    public var cases = 0
    public var lines = 0
    /// 訳が付いた行 (文ごとにまとめて訳した行も数える)
    public var translated = 0
    /// 訳が、訳す先の言語だった行 (日本語は、かな・漢字があり日本語に無い漢字が無い。ほかは言語の判定。
    /// 短すぎて判定できない訳は、合っていると数える)。古い結果の `japanese` は、これとして読む
    public var inTarget = 0
    /// 原文の数字 (2 桁以上) が、訳にも残っている場面
    public var numbersKept = 0
    public var numbersChecked = 0
    /// 残っているべき語 (固有名詞) が、訳に残っている数
    public var termsKept = 0
    public var termsChecked = 0
    /// 訳が、原文をそのまま写しただけだった行 (原文の言語が訳す先と違う時だけ数える)
    public var copied = 0
    /// 同じ語句の繰り返しが異常に多い訳の行 (決め方は `LLMEval.isRepetitive`)
    public var repeated = 0
    /// chrF の統計 (人の訳の在る行だけ)。無ければ nil
    public var chrFStatistics: ChrF.Statistics?
    /// chrF (コーパスの点、0〜100)。人の訳が無ければ nil
    public var chrF: Double?
    public var seconds = 0.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case cases, lines, translated, inTarget, numbersKept, numbersChecked, termsKept, termsChecked
        case copied, repeated, chrFStatistics, chrF, seconds
    }

    /// 日本語だけを採点していた頃の項目の名前
    private enum LegacyKeys: String, CodingKey { case japanese }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cases = try c.decodeIfPresent(Int.self, forKey: .cases) ?? 0
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? 0
        translated = try c.decodeIfPresent(Int.self, forKey: .translated) ?? 0
        if let value = try c.decodeIfPresent(Int.self, forKey: .inTarget) {
            inTarget = value
        } else {
            inTarget = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int.self, forKey: .japanese) ?? 0
        }
        numbersKept = try c.decodeIfPresent(Int.self, forKey: .numbersKept) ?? 0
        numbersChecked = try c.decodeIfPresent(Int.self, forKey: .numbersChecked) ?? 0
        termsKept = try c.decodeIfPresent(Int.self, forKey: .termsKept) ?? 0
        termsChecked = try c.decodeIfPresent(Int.self, forKey: .termsChecked) ?? 0
        copied = try c.decodeIfPresent(Int.self, forKey: .copied) ?? 0
        repeated = try c.decodeIfPresent(Int.self, forKey: .repeated) ?? 0
        chrFStatistics = try c.decodeIfPresent(ChrF.Statistics.self, forKey: .chrFStatistics)
        chrF = try c.decodeIfPresent(Double.self, forKey: .chrF)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
    }

    public mutating func add(_ other: TranslationEvalScore) {
        cases += other.cases
        lines += other.lines
        translated += other.translated
        inTarget += other.inTarget
        numbersKept += other.numbersKept
        numbersChecked += other.numbersChecked
        termsKept += other.termsKept
        termsChecked += other.termsChecked
        copied += other.copied
        repeated += other.repeated
        if let stats = other.chrFStatistics {
            var sum = chrFStatistics ?? ChrF.Statistics()
            sum.add(stats)
            chrFStatistics = sum
            chrF = sum.score
        }
        seconds += other.seconds
    }

    public var summary: String {
        let points = chrF.map { String(format: "%.2f", $0) } ?? "-"
        return String(format: "translation: %d cases, %d lines: translated %d, in the target language %d, numbers kept %d/%d, "
                      + "terms kept %d/%d, copied %d, repeated %d, ",
                      cases, lines, translated, inTarget, numbersKept, numbersChecked, termsKept, termsChecked, copied, repeated)
            + "chrF \(points), " + String(format: "%.1f s", seconds)
    }
}

/// ローカル LLM の評価ハーネス: 決まった場面で監査役・翻訳役を動かし、成績を数える。
///
/// モデル・プロンプト・学習した直し・追加学習の差分 (LoRA) を変えたときに、良くなったか悪くなったかを同じ物差しで比べる。
/// アプリの `--eval-llm` と、ユニットテスト (偽の LLM) の両方から使う。
public enum LLMEval {
    /// 場面を、文字起こしの区間にする (1 行 3 秒)
    public static func segments(_ lines: [String], language: String?) -> [TranscriptSegment] {
        lines.enumerated().map { index, text in
            TranscriptSegment(start: Double(index) * 3, end: Double(index) * 3 + 2.8, text: text, language: nil)
        }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "\n" }).joined(separator: " ")
    }

    /// 監査の結果を採点する。details には、正解と違った行を書く
    public static func score(_ c: AuditEvalCase, segments: [TranscriptSegment], report: AuditReport) -> (score: AuditEvalScore, details: [String]) {
        var automatic = Transcript(sourceName: c.id, segments: segments, language: c.language)
        automatic.adopt(report)
        var suggested = automatic
        for change in report.changes where !change.isApplied {
            suggested.setChange(change.id, applied: true)
        }
        func texts(_ t: Transcript) -> [UUID: String] {
            Dictionary(t.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        }
        let auto = texts(automatic), all = texts(suggested)
        var score = AuditEvalScore()
        score.cases = 1
        var details: [String] = []
        for (index, segment) in segments.enumerated() where index < c.expected.count {
            let original = normalized(segment.text)
            let expected = normalized(c.expected[index])
            let a = normalized(auto[segment.id] ?? "")
            let s = normalized(all[segment.id] ?? "")
            if original != expected {
                score.errorLines += 1
                if a == expected {
                    score.fixedAutomatically += 1
                } else if s == expected {
                    score.fixedBySuggestion += 1
                    details.append("[\(c.id) \(index + 1)] suggestion only: \(original) -> \(s)")
                } else if a != original {
                    score.wrongFixes += 1
                    details.append("[\(c.id) \(index + 1)] WRONG fix: \(original) -> \(a) (expected \(expected))")
                } else {
                    score.missed += 1
                    details.append("[\(c.id) \(index + 1)] missed: \(original) (expected \(expected))"
                                   + (s != original ? " (suggested \(s))" : ""))
                }
            } else {
                score.cleanLines += 1
                if a != original {
                    score.harmed += 1
                    details.append("[\(c.id) \(index + 1)] HARMED: \(original) -> \(a.isEmpty ? "(deleted)" : a)")
                } else if s != original {
                    score.falseSuggestions += 1
                    details.append("[\(c.id) \(index + 1)] false suggestion: \(original) -> \(s.isEmpty ? "(delete)" : s)")
                }
            }
        }
        return (score, details)
    }

    /// 監査の場面をひと通り動かして採点する。generator が nil なら、規則と学習した直しだけ
    public static func runAudit(_ cases: [AuditEvalCase], generator: (any TextGenerating)?, modelName: String?,
                                ledger: CorrectionLedger? = nil, shouldCancel: () -> Bool = { false },
                                onCase: (_ done: Int, _ total: Int) -> Void = { _, _ in }) throws -> (score: AuditEvalScore, details: [String]) {
        var total = AuditEvalScore()
        var details: [String] = []
        for (done, c) in cases.enumerated() {
            let started = Date()
            let segments = segments(c.lines, language: c.language)
            let glossary = ledger?.glossary(adding: c.glossary) ?? c.glossary
            let report = try Auditor.audit(segments, language: c.language, options: AuditOptions(glossary: glossary, ledger: ledger),
                                           generator: generator, modelName: modelName, shouldCancel: shouldCancel)
            var result = score(c, segments: segments, report: report)
            result.score.seconds = Date().timeIntervalSince(started)
            total.add(result.score)
            details += result.details
            onCase(done + 1, cases.count)
        }
        return (total, details)
    }

    /// 千の区切りに使う字 (4,000・4.000・4 000・4'000。空白は、ふつうの空白・NBSP・狭い NBSP)
    private static let thousandsSeparators: Set<Character> = [",", ".", " ", "'", "\u{00A0}", "\u{202F}"]

    /// 千の区切りを外す (「4,000」→「4000」)。外すのは、1〜3 桁の数の後ろに「区切り + ちょうど 3 桁」が続く所だけ
    /// (「3.14」・「2024 100」は、そのまま)。言語ごとに区切りの書き方が違うので、原文と訳の両方をそろえるのに使う。
    /// ふつうの空白は、区切り (「15 200」= 15200) の時も、2 つの数 (「15 200 人」= 15 と 200) の時も在る。
    /// `joiningSpaces` が false なら、ふつうの空白は区切りと見ない (2 つの読み方は `numbersLost` が比べる)
    static func removingThousandsSeparators(_ text: String, joiningSpaces: Bool = true) -> String {
        let separators = joiningSpaces ? thousandsSeparators : thousandsSeparators.subtracting([" "])
        let chars = Array(text)
        func isDigit(_ k: Int) -> Bool { k >= 0 && k < chars.count && chars[k].isASCII && chars[k].isNumber }
        var out = ""
        var i = 0
        while i < chars.count {
            guard isDigit(i), !isDigit(i - 1) else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i
            while isDigit(j) { j += 1 }
            out.append(contentsOf: chars[i..<j])
            if j - i <= 3 {
                while j < chars.count, separators.contains(chars[j]),
                      isDigit(j + 1), isDigit(j + 2), isDigit(j + 3), !isDigit(j + 4) {
                    out.append(contentsOf: chars[(j + 1)...(j + 3)])
                    j += 4
                }
            }
            i = j
        }
        return out
    }

    /// 2 桁以上の数字の並び (全角は半角にそろえ、千の区切りは外す)
    static func numbers(in text: String, joiningSpaces: Bool = true) -> [String] {
        let half = removingThousandsSeparators(
            text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text, joiningSpaces: joiningSpaces)
        var out: [String] = []
        var current = ""
        for ch in half {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
            } else {
                if current.count >= 2 { out.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { out.append(current) }
        return out
    }

    /// 原文の数のうち、訳に無い物を数える。ふつうの空白を千の区切りと読む・読まないの 2 通りで原文の数を取り、
    /// 訳に無い数の少ないほうを採る (同じなら、区切りと読むほう)。訳の数は、2 通りの読み方を合わせた物
    /// (「15,200」→「15 200」も、「15 200 people」→「15 に 200 人」も、数が消えたと数えない)
    static func numbersLost(sources: [String], translation: String) -> (checked: Int, lost: [String]) {
        let have = Set(numbers(in: translation)).union(numbers(in: translation, joiningSpaces: false))
        var best: (checked: Int, lost: [String])?
        for joiningSpaces in [true, false] {
            let wanted = Set(sources.flatMap { numbers(in: $0, joiningSpaces: joiningSpaces) })
            let lost = wanted.subtracting(have).sorted()
            if let current = best, current.lost.count <= lost.count { continue }
            best = (wanted.count, lost)
        }
        return best ?? (0, [])
    }

    /// 判定に使う文の、文字の数の下限。これより短い訳は判定せず「訳す先の言語だった」と数える (短い語句は判定が外れやすい)
    public static let minimumLettersToDetect = 8
    /// 「繰り返しが異常に多い」の決め方: 空白を除いて、この字数以上の同じ並びが、この回数以上続く
    public static let repetitionMinimumLength = 3
    public static let repetitionMinimumCount = 5
    /// 比べる時、chrF がこれより大きく下がったら「悪くなった」
    public static let chrFTolerance = 1.0

    /// 既定の言語の判定 (Apple の環境では NaturalLanguage。ほかでは無し = 文字の種類で見る)
    public static var defaultLanguageDetector: LanguageDetector? {
        #if canImport(NaturalLanguage)
        return SystemLanguageDetector.detector
        #else
        return nil
        #endif
    }

    /// 同じ語句の繰り返しが異常に多いか (空白を除いて、3 字以上の同じ並びが 5 回以上続く。並びには文字が 1 つ以上在る)。
    /// 空白を除くので、"the the the the the" のように空白で区切った繰り返しも数える
    public static func isRepetitive(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }.map { $0 }
        let minLength = repetitionMinimumLength, times = repetitionMinimumCount
        guard chars.count >= minLength * times else { return false }
        for period in minLength...(chars.count / times) {
            // chars[i] == chars[i + period] が続く長さが period * (times - 1) に届けば、times 回続いている
            var run = 0
            for i in 0..<(chars.count - period) {
                if chars[i] == chars[i + period] {
                    run += 1
                    if run >= period * (times - 1) {
                        let start = i + 1 - run
                        if chars[start..<(start + period)].contains(where: \.isLetter) { return true }
                    }
                } else {
                    run = 0
                }
            }
        }
        return false
    }

    /// 訳が、訳す先の言語か。日本語は今までの検査。ほかは言語の判定 (判定が無ければ文字の種類で見る)
    static func isInTarget(_ text: String, target: String, detector: LanguageDetector?) -> Bool {
        if target == "ja" { return Script.isJapanese(text) && !Script.containsNonJapaneseHan(text) }
        // 文字の種類で分かる言語 (ko・ru・th・zh) は、その言語の文字が在れば合っている。
        // 言語の判定は、固有名詞やハッシュタグの多い訳を別の言語 (ru → kk、ko → en) と判定する事がある
        if hasTargetScript(text, target: target) { return true }
        // 短すぎる訳は判定しない
        guard text.filter(\.isLetter).count >= minimumLettersToDetect else { return true }
        if let detector {
            // 分からない (nil) 時は、外れとは数えない
            guard let detected = detector(text) else { return true }
            return detected.lowercased() == target
        }
        switch target {
        case "ko", "ru", "th", "zh": return false
        default: return true
        }
    }

    /// 訳す先の言語の文字が在るか (ko: ハングル、ru: キリル文字、th: タイ文字、zh: 漢字が在り、かなが無い)。
    /// ほかの言語は、文字の種類では見分けられないので false
    static func hasTargetScript(_ text: String, target: String) -> Bool {
        switch target {
        case "ko", "ru", "th": return Script.hasLetters(text, of: target)
        case "zh": return Script.hasHan(text) && !Script.hasKanaLetters(text)
        default: return false
        }
    }

    /// 1 つの訳 (文ごと): 原文の行の位置 (先頭から順) と、その訳 (訳せなかったら nil)。
    /// asSource は、訳す必要が無い行 (文字の無い行・もう訳す先の言語の行) で、原文をそのまま訳とした物
    public struct TranslationUnit: Hashable, Sendable {
        public var lines: [Int]
        public var text: String?
        public var asSource: Bool

        public init(lines: [Int], text: String?, asSource: Bool = false) {
            self.lines = lines
            self.text = text
            self.asSource = asSource
        }
    }

    /// 1 つの問題の、LLM の訳そのもの (評価の結果に残す。採点の決まりを直した時に、LLM を回さずに採点し直せる)
    public struct TranslationOutput: Codable, Hashable, Sendable {
        /// 訳の単位 (文ごと)
        public struct Unit: Codable, Hashable, Sendable {
            /// 原文の行の番号 (0 始まり、先頭から順)
            public var lines: [Int]
            /// 原文 (いくつかの行をまとめた訳は、その行をつないだ文)
            public var source: String
            /// 訳 (訳せなかった時は無し)
            public var text: String?
            /// 人の訳 (在れば。行をまとめた訳は、その行の人の訳をつないだ文)
            public var reference: String?
            /// 訳す必要が無い行で、原文をそのまま訳とした (true の時だけ書く)
            public var asSource: Bool?

            public init(lines: [Int], source: String, text: String?, reference: String?, asSource: Bool? = nil) {
                self.lines = lines
                self.source = source
                self.text = text
                self.reference = reference
                self.asSource = asSource
            }
        }

        /// 問題の id
        public var id: String
        /// 訳す先の言語
        public var target: String
        /// 原文の言語
        public var language: String
        /// 問題の行の数
        public var lineCount: Int
        public var units: [Unit]
        /// 訳に残っているべき語
        public var keep: [String]?
        /// 用語集 (語彙のヒント)
        public var glossary: String?
        /// 訳すのにかかった秒 (採点し直しても、そのまま使う)
        public var seconds: Double?

        public init(id: String, target: String, language: String, lineCount: Int, units: [Unit], keep: [String]? = nil,
                    glossary: String? = nil, seconds: Double? = nil) {
            self.id = id
            self.target = target
            self.language = language
            self.lineCount = lineCount
            self.units = units
            self.keep = keep
            self.glossary = glossary
            self.seconds = seconds
        }
    }

    /// 問題と訳の単位から、残す訳 (`TranslationOutput`) を作る。問題の行に無い番号は外す。人の訳は、行の数が合う時だけ入れる
    public static func output(_ c: TranslationEvalCase, units: [TranslationUnit], seconds: Double? = nil) -> TranslationOutput {
        let references = c.references.flatMap { $0.count == c.lines.count ? $0 : nil }
        let kept: [TranslationOutput.Unit] = units.compactMap { unit in
            let indices = unit.lines.filter { c.lines.indices.contains($0) }
            guard !indices.isEmpty else { return nil }
            return TranslationOutput.Unit(lines: indices, source: Transcript.join(indices.map { c.lines[$0] }),
                                          text: unit.text,
                                          reference: references.map { r in Transcript.join(indices.map { r[$0] }) },
                                          asSource: unit.asSource ? true : nil)
        }
        return TranslationOutput(id: c.id, target: c.targetLanguage, language: c.language, lineCount: c.lines.count,
                                 units: kept, keep: c.keep, glossary: c.glossary, seconds: seconds)
    }

    /// 翻訳の結果を採点する (translations は、行の順の訳。訳さなかった行は nil。1 行ずつの訳として数える)
    public static func score(_ c: TranslationEvalCase, translations: [String?],
                             detector: LanguageDetector? = nil) -> (score: TranslationEvalScore, details: [String]) {
        let units = c.lines.indices.map { TranslationUnit(lines: [$0], text: $0 < translations.count ? translations[$0] : nil) }
        return score(c, units: units, detector: detector)
    }

    /// 翻訳の結果を採点する (units は、文ごとの訳。いくつかの行をまとめた訳は、その行ぶんの原文・人の訳とつないで比べる)
    public static func score(_ c: TranslationEvalCase, units: [TranslationUnit],
                             detector: LanguageDetector? = nil) -> (score: TranslationEvalScore, details: [String]) {
        var result = score(output(c, units: units), detector: detector)
        if let references = c.references, references.count != c.lines.count {
            result.details.insert("[\(c.id)] references ignored: \(references.count) references for \(c.lines.count) lines", at: 0)
        }
        return result
    }

    /// 残した訳 (`TranslationOutput`) を採点する。問題から採点する時も、採点し直す時も、ここを通る (決め方を 1 つにする)
    public static func score(_ o: TranslationOutput,
                             detector: LanguageDetector? = nil) -> (score: TranslationEvalScore, details: [String]) {
        let target = TranslationTarget.normalized(o.target)
        var score = TranslationEvalScore()
        score.cases = 1
        score.lines = o.lineCount
        score.seconds = o.seconds ?? 0
        var details: [String] = []
        var chrF: ChrF.Statistics?
        var texts: [String] = []
        for unit in o.units {
            let indices = unit.lines
            guard let first = indices.first else { continue }
            let label = "[\(o.id) \(first + 1)\(indices.count > 1 ? "-\(indices[indices.count - 1] + 1)" : "")]"
            let source = unit.source
            let asSource = unit.asSource == true
            // 訳す必要の無い行は、原文をそのまま訳とする (アプリも、原文のまま見せる)
            let text = asSource ? source : unit.text.flatMap { $0.isEmpty ? nil : $0 }
            if let reference = unit.reference {
                var stats = chrF ?? ChrF.Statistics()
                stats.add(ChrF.statistics(hypothesis: text ?? "", reference: reference))
                chrF = stats
            }
            guard let text else { continue }
            texts.append(text)
            score.translated += indices.count
            // 訳す必要の無い行は、訳す先の言語・写し・繰り返しを見ない (原文そのものなので)
            if asSource {
                score.inTarget += indices.count
                continue
            }
            if isInTarget(text, target: target, detector: detector) {
                score.inTarget += indices.count
            } else {
                details.append("\(label) not in \(target): \(source) => \(text)")
            }
            if o.language.lowercased() != target, normalized(text) == normalized(source) {
                score.copied += indices.count
                details.append("\(label) copied: \(text)")
            }
            if isRepetitive(text) {
                score.repeated += indices.count
                details.append("\(label) repeated: \(text)")
            }
        }
        score.chrFStatistics = chrF
        score.chrF = chrF?.score
        // 文ごとにまとめて訳すので、数字と語は場面の訳全体で確かめる
        let joined = texts.joined(separator: "\n")
        let numberCheck = numbersLost(sources: o.units.map(\.source), translation: joined)
        if numberCheck.checked > 0, !joined.isEmpty {
            score.numbersChecked = numberCheck.checked
            score.numbersKept = numberCheck.checked - numberCheck.lost.count
            let lost = numberCheck.lost
            if !lost.isEmpty { details.append("[\(o.id)] numbers lost: \(lost.joined(separator: ", ")) => \(joined)") }
        }
        if let keep = o.keep, !joined.isEmpty {
            score.termsChecked = keep.count
            for term in keep {
                if joined.range(of: term, options: .caseInsensitive) != nil {
                    score.termsKept += 1
                } else {
                    details.append("[\(o.id)] term lost: \(term) => \(joined)")
                }
            }
        }
        return (score, details)
    }

    /// 残した訳を、今の採点の決まりで採点し直す (LLM は使わない)。訳す先ごとにも集計する
    public static func rescore(_ outputs: [TranslationOutput], detector: LanguageDetector? = LLMEval.defaultLanguageDetector)
        -> (score: TranslationEvalScore, byTarget: [String: TranslationEvalScore], details: [String]) {
        var total = TranslationEvalScore()
        var byTarget: [String: TranslationEvalScore] = [:]
        var details: [String] = []
        for o in outputs {
            let result = score(o, detector: detector)
            total.add(result.score)
            byTarget[TranslationTarget.normalized(o.target), default: TranslationEvalScore()].add(result.score)
            details += result.details
        }
        return (total, byTarget, details)
    }

    /// 翻訳の場面をひと通り動かして採点する。場面ごとの訳す先 (`target`) で訳し、訳す先ごとにも集計する
    public static func runTranslation(_ cases: [TranslationEvalCase], generator: any TextGenerating,
                                      ledger: CorrectionLedger? = nil,
                                      detector: LanguageDetector? = LLMEval.defaultLanguageDetector,
                                      shouldCancel: () -> Bool = { false },
                                      onCase: (_ done: Int, _ total: Int) -> Void = { _, _ in })
        throws -> (score: TranslationEvalScore, byTarget: [String: TranslationEvalScore], details: [String],
                   outputs: [TranslationOutput]) {
        var total = TranslationEvalScore()
        var byTarget: [String: TranslationEvalScore] = [:]
        var details: [String] = []
        var outputs: [TranslationOutput] = []
        for (done, c) in cases.enumerated() {
            let started = Date()
            let segments = segments(c.lines, language: c.language)
            var byHead: [UUID: TranslationResult] = [:]
            let glossary = ledger?.glossary(adding: c.glossary) ?? c.glossary
            _ = try Translator.translate(segments, language: c.language, target: c.targetLanguage,
                                         options: TranslationOptions(glossary: glossary),
                                         generator: generator, shouldCancel: shouldCancel) { batch, _, _ in
                for result in batch { byHead[result.head] = result }
            }
            // 文ごとの訳は、先頭の区間に付く。まとめられた後ろの区間も、その訳の行として数える
            let position = Dictionary(segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            var units: [TranslationUnit] = []
            var covered = Set<Int>()
            for result in byHead.values {
                guard let head = position[result.head] else { continue }
                let lines = [head] + result.covers.compactMap { position[$0] }
                units.append(TranslationUnit(lines: lines, text: result.text))
                covered.formUnion(lines)
            }
            // 訳の無い行。訳す必要が無い行 (文字の無い行・もう訳す先の言語の行) は、アプリと同じく原文をそのまま訳とする。
            // ほかは訳せなかった行
            for index in segments.indices where !covered.contains(index) {
                if Translator.needsTranslation(segments[index], transcriptLanguage: c.language, target: c.targetLanguage) {
                    units.append(TranslationUnit(lines: [index], text: nil))
                } else {
                    units.append(TranslationUnit(lines: [index], text: segments[index].text, asSource: true))
                }
            }
            units.sort { ($0.lines.first ?? 0) < ($1.lines.first ?? 0) }
            var result = score(c, units: units, detector: detector)
            let seconds = Date().timeIntervalSince(started)
            result.score.seconds = seconds
            outputs.append(output(c, units: units, seconds: seconds))
            total.add(result.score)
            byTarget[c.targetLanguage, default: TranslationEvalScore()].add(result.score)
            details += result.details
            onCase(done + 1, cases.count)
        }
        return (total, byTarget, details, outputs)
    }

    /// 前の結果と比べて、訳す先ごとに悪くなった所を返す (空なら悪くなっていない)。前の結果に無い訳す先は比べない。
    /// 悪くなった: 訳せた行・その言語だった行・残った数字・残った語のどれかが減った、写し・繰り返しが増えた、
    /// chrF が `chrFTolerance` より大きく下がった。
    /// 問題の数か行の数が違う (別の問題の結果) なら、ほかは比べず「比べられない」の 1 行を返す (悪くなった扱いにして知らせる)
    public static func translationRegressions(_ now: [String: TranslationEvalScore],
                                              baseline before: [String: TranslationEvalScore]) -> [String] {
        var out: [String] = []
        for target in now.keys.sorted() {
            guard let a = now[target], let b = before[target] else { continue }
            guard a.lines == b.lines, a.cases == b.cases else {
                out.append("\(target): not comparable (cases \(b.cases) -> \(a.cases), lines \(b.lines) -> \(a.lines))")
                continue
            }
            func fewer(_ name: String, _ x: Int, _ y: Int) { if x < y { out.append("\(target): \(name) \(y) -> \(x)") } }
            func more(_ name: String, _ x: Int, _ y: Int) { if x > y { out.append("\(target): \(name) \(y) -> \(x)") } }
            fewer("translated", a.translated, b.translated)
            fewer("in the target language", a.inTarget, b.inTarget)
            fewer("numbers kept", a.numbersKept, b.numbersKept)
            fewer("terms kept", a.termsKept, b.termsKept)
            more("copied", a.copied, b.copied)
            more("repeated", a.repeated, b.repeated)
            if let x = a.chrF, let y = b.chrF, x < y - chrFTolerance {
                out.append("\(target): chrF " + String(format: "%.2f -> %.2f", y, x))
            }
        }
        return out
    }

    /// 訳す先ごとの表 (1 行目は見出し)。訳す先・行・訳せた・その言語だった・数・語・写し・繰り返し・chrF・1 行あたりの秒
    public static func translationTable(_ byTarget: [String: TranslationEvalScore]) -> [String] {
        func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }
        let widths = [6, 6, 10, 9, 9, 9, 6, 8, 7, 7]
        func row(_ cells: [String]) -> String { zip(cells, widths).map { pad($0, $1) }.joined(separator: " ") }
        var out = [row(["target", "lines", "translated", "inTarget", "numbers", "terms", "copied", "repeated", "chrF", "s/line"])]
        for target in byTarget.keys.sorted() {
            guard let s = byTarget[target] else { continue }
            out.append(row([target, "\(s.lines)", "\(s.translated)", "\(s.inTarget)", "\(s.numbersKept)/\(s.numbersChecked)",
                            "\(s.termsKept)/\(s.termsChecked)", "\(s.copied)", "\(s.repeated)",
                            s.chrF.map { String(format: "%.2f", $0) } ?? "-",
                            String(format: "%.2f", s.lines > 0 ? s.seconds / Double(s.lines) : 0)]))
        }
        return out
    }
}

/// 評価ハーネス (`--eval-llm`) の結果 (`--report` に書く JSON)。古い結果 (項目の足りない物) も読める
public struct LLMEvalReport: Codable, Sendable {
    public var model: String
    public var adapter: String?
    public var ledgerEntries: Int
    public var sets: [String]
    public var audit: AuditEvalScore
    /// 翻訳の全体の合計
    public var translation: TranslationEvalScore
    /// 翻訳の、訳す先ごとの成績 (鍵は言語のコード)
    public var translationByTarget: [String: TranslationEvalScore]
    public var details: [String]
    /// 翻訳の問題ごとの、LLM の訳そのもの (採点し直しに使う)。古い結果には無い
    public var translationOutputs: [LLMEval.TranslationOutput]?
    /// 採点し直した結果なら、元の結果のファイルの名前
    public var rescoredFrom: String?

    public init(model: String, adapter: String?, ledgerEntries: Int, sets: [String], audit: AuditEvalScore,
                translation: TranslationEvalScore, translationByTarget: [String: TranslationEvalScore], details: [String],
                translationOutputs: [LLMEval.TranslationOutput]? = nil, rescoredFrom: String? = nil) {
        self.model = model
        self.adapter = adapter
        self.ledgerEntries = ledgerEntries
        self.sets = sets
        self.audit = audit
        self.translation = translation
        self.translationByTarget = translationByTarget
        self.details = details
        self.translationOutputs = translationOutputs
        self.rescoredFrom = rescoredFrom
    }

    private enum CodingKeys: String, CodingKey {
        case model, adapter, ledgerEntries, sets, audit, translation, translationByTarget, details
        case translationOutputs, rescoredFrom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        adapter = try c.decodeIfPresent(String.self, forKey: .adapter)
        ledgerEntries = try c.decodeIfPresent(Int.self, forKey: .ledgerEntries) ?? 0
        sets = try c.decodeIfPresent([String].self, forKey: .sets) ?? []
        audit = try c.decode(AuditEvalScore.self, forKey: .audit)
        translation = try c.decodeIfPresent(TranslationEvalScore.self, forKey: .translation) ?? TranslationEvalScore()
        details = try c.decodeIfPresent([String].self, forKey: .details) ?? []
        if let byTarget = try c.decodeIfPresent([String: TranslationEvalScore].self, forKey: .translationByTarget) {
            translationByTarget = byTarget
        } else {
            // 訳す先ごとの成績が無い古い結果は、日本語へ訳す場合だけを採点していた
            translationByTarget = translation.lines > 0 ? ["ja": translation] : [:]
        }
        translationOutputs = try c.decodeIfPresent([LLMEval.TranslationOutput].self, forKey: .translationOutputs)
        rescoredFrom = try c.decodeIfPresent(String.self, forKey: .rescoredFrom)
    }

    /// 翻訳の点を、残した訳から今の採点の決まりで計算し直した結果。監査の点と、監査の細かい所はそのまま。
    /// 訳が残っていなければ (古い結果) nil
    public func rescored(from name: String, detector: LanguageDetector? = LLMEval.defaultLanguageDetector) -> LLMEvalReport? {
        guard let outputs = translationOutputs else { return nil }
        let result = LLMEval.rescore(outputs, detector: detector)
        // 翻訳の細かい所は、計算し直した物にする。翻訳の行は「[問題の id 」か「[問題の id]」で始まる
        // (監査の場面に、翻訳の問題と同じ id が在ると、その監査の行も外れる)
        let ids = Set(outputs.map(\.id))
        let auditDetails = details.filter { line in
            !ids.contains(where: { line.hasPrefix("[\($0) ") || line.hasPrefix("[\($0)]") })
        }
        var out = self
        out.translation = result.score
        out.translationByTarget = result.byTarget
        out.details = auditDetails + result.details
        out.rescoredFrom = name
        return out
    }
}
