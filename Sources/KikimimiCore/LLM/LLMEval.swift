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

    /// 2 桁以上の数字の並び (全角は半角にそろえる)
    static func numbers(in text: String) -> [String] {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
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
        // 短すぎる訳は判定しない
        guard text.filter(\.isLetter).count >= minimumLettersToDetect else { return true }
        if let detector {
            // 分からない (nil) 時は、外れとは数えない
            guard let detected = detector(text) else { return true }
            return detected.lowercased() == target
        }
        switch target {
        case "ko", "ru", "th": return Script.hasLetters(text, of: target)
        case "zh": return Script.hasHan(text) && !Script.hasKana(text)
        default: return true
        }
    }

    /// 1 つの訳 (文ごと): 原文の行の位置 (先頭から順) と、その訳 (訳せなかったら nil)
    public struct TranslationUnit: Hashable, Sendable {
        public var lines: [Int]
        public var text: String?

        public init(lines: [Int], text: String?) {
            self.lines = lines
            self.text = text
        }
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
        let target = c.targetLanguage
        var score = TranslationEvalScore()
        score.cases = 1
        score.lines = c.lines.count
        var details: [String] = []
        let references = c.references.flatMap { $0.count == c.lines.count ? $0 : nil }
        if c.references != nil, references == nil {
            details.append("[\(c.id)] references ignored: \(c.references?.count ?? 0) references for \(c.lines.count) lines")
        }
        var chrF: ChrF.Statistics?
        var texts: [String] = []
        for unit in units {
            let indices = unit.lines.filter { c.lines.indices.contains($0) }
            guard let first = indices.first else { continue }
            let label = "[\(c.id) \(first + 1)\(indices.count > 1 ? "-\(indices[indices.count - 1] + 1)" : "")]"
            let source = Transcript.join(indices.map { c.lines[$0] })
            let text = unit.text.flatMap { $0.isEmpty ? nil : $0 }
            if let references {
                var stats = chrF ?? ChrF.Statistics()
                stats.add(ChrF.statistics(hypothesis: text ?? "", reference: Transcript.join(indices.map { references[$0] })))
                chrF = stats
            }
            guard let text else { continue }
            texts.append(text)
            score.translated += indices.count
            if isInTarget(text, target: target, detector: detector) {
                score.inTarget += indices.count
            } else {
                details.append("\(label) not in \(target): \(source) => \(text)")
            }
            if c.language.lowercased() != target, normalized(text) == normalized(source) {
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
        let wanted = Set(c.lines.flatMap(numbers(in:)))
        if !wanted.isEmpty, !joined.isEmpty {
            score.numbersChecked = wanted.count
            let have = Set(numbers(in: joined))
            score.numbersKept = wanted.filter(have.contains).count
            let lost = wanted.subtracting(have).sorted()
            if !lost.isEmpty { details.append("[\(c.id)] numbers lost: \(lost.joined(separator: ", ")) => \(joined)") }
        }
        if let keep = c.keep, !joined.isEmpty {
            score.termsChecked = keep.count
            for term in keep {
                if joined.range(of: term, options: .caseInsensitive) != nil {
                    score.termsKept += 1
                } else {
                    details.append("[\(c.id)] term lost: \(term) => \(joined)")
                }
            }
        }
        return (score, details)
    }

    /// 翻訳の場面をひと通り動かして採点する。場面ごとの訳す先 (`target`) で訳し、訳す先ごとにも集計する
    public static func runTranslation(_ cases: [TranslationEvalCase], generator: any TextGenerating,
                                      ledger: CorrectionLedger? = nil,
                                      detector: LanguageDetector? = LLMEval.defaultLanguageDetector,
                                      shouldCancel: () -> Bool = { false },
                                      onCase: (_ done: Int, _ total: Int) -> Void = { _, _ in })
        throws -> (score: TranslationEvalScore, byTarget: [String: TranslationEvalScore], details: [String]) {
        var total = TranslationEvalScore()
        var byTarget: [String: TranslationEvalScore] = [:]
        var details: [String] = []
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
            // 訳の無い行 (訳せなかった・訳す要が無かった)
            for index in segments.indices where !covered.contains(index) {
                units.append(TranslationUnit(lines: [index], text: nil))
            }
            units.sort { ($0.lines.first ?? 0) < ($1.lines.first ?? 0) }
            var result = score(c, units: units, detector: detector)
            result.score.seconds = Date().timeIntervalSince(started)
            total.add(result.score)
            byTarget[c.targetLanguage, default: TranslationEvalScore()].add(result.score)
            details += result.details
            onCase(done + 1, cases.count)
        }
        return (total, byTarget, details)
    }

    /// 前の結果と比べて、訳す先ごとに悪くなった所を返す (空なら悪くなっていない)。前の結果に無い訳す先は比べない。
    /// 悪くなった: 訳せた行・その言語だった行・残った数字・残った語のどれかが減った、写し・繰り返しが増えた、
    /// chrF が `chrFTolerance` より大きく下がった
    public static func translationRegressions(_ now: [String: TranslationEvalScore],
                                              baseline before: [String: TranslationEvalScore]) -> [String] {
        var out: [String] = []
        for target in now.keys.sorted() {
            guard let a = now[target], let b = before[target] else { continue }
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
