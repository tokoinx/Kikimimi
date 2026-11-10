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
    public var language: String
    public var glossary: String?
    public var lines: [String]
    /// 訳のどこかに、そのまま出てくるべき語 (例: "Roblox")
    public var keep: [String]?

    public init(id: String, language: String, glossary: String? = nil, lines: [String], keep: [String]? = nil) {
        self.id = id
        self.language = language
        self.glossary = glossary
        self.lines = lines
        self.keep = keep
    }
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

/// 翻訳の成績 (形の点検だけ。訳の良し悪しは、人が読むか、追加学習の前後で比べる)
public struct TranslationEvalScore: Codable, Hashable, Sendable {
    public var cases = 0
    public var lines = 0
    /// 訳が付いた行 (文ごとにまとめて訳した行も数える)
    public var translated = 0
    /// 日本語の文になっている (かな・漢字があり、日本語に無い漢字が無い)
    public var japanese = 0
    /// 原文の数字 (2 桁以上) が、訳にも残っている場面
    public var numbersKept = 0
    public var numbersChecked = 0
    /// 残っているべき語 (固有名詞) が、訳に残っている数
    public var termsKept = 0
    public var termsChecked = 0
    public var seconds = 0.0

    public init() {}

    public mutating func add(_ other: TranslationEvalScore) {
        cases += other.cases
        lines += other.lines
        translated += other.translated
        japanese += other.japanese
        numbersKept += other.numbersKept
        numbersChecked += other.numbersChecked
        termsKept += other.termsKept
        termsChecked += other.termsChecked
        seconds += other.seconds
    }

    public var summary: String {
        String(format: "translation: %d cases, %d lines: translated %d, Japanese %d, numbers kept %d/%d, terms kept %d/%d, %.1f s",
               cases, lines, translated, japanese, numbersKept, numbersChecked, termsKept, termsChecked, seconds)
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

    /// 翻訳の結果を採点する (translations は、区間の順の訳。訳さなかった区間は nil)
    public static func score(_ c: TranslationEvalCase, translations: [String?]) -> (score: TranslationEvalScore, details: [String]) {
        var score = TranslationEvalScore()
        score.cases = 1
        score.lines = c.lines.count
        var details: [String] = []
        let joined = translations.compactMap { $0 }.joined(separator: "\n")
        for (index, line) in c.lines.enumerated() {
            guard index < translations.count, let translation = translations[index] else { continue }
            score.translated += 1
            if Script.isJapanese(translation), !Script.containsNonJapaneseHan(translation) {
                score.japanese += 1
            } else {
                details.append("[\(c.id) \(index + 1)] not Japanese: \(line) => \(translation)")
            }
        }
        // 文ごとにまとめて訳すので、数字と語は場面の訳全体で確かめる
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

    /// 翻訳の場面をひと通り動かして採点する
    public static func runTranslation(_ cases: [TranslationEvalCase], generator: any TextGenerating,
                                      ledger: CorrectionLedger? = nil, shouldCancel: () -> Bool = { false },
                                      onCase: (_ done: Int, _ total: Int) -> Void = { _, _ in }) throws -> (score: TranslationEvalScore, details: [String]) {
        var total = TranslationEvalScore()
        var details: [String] = []
        for (done, c) in cases.enumerated() {
            let started = Date()
            let segments = segments(c.lines, language: c.language)
            var byHead: [UUID: TranslationResult] = [:]
            let glossary = ledger?.glossary(adding: c.glossary) ?? c.glossary
            _ = try Translator.translate(segments, language: c.language, options: TranslationOptions(glossary: glossary),
                                         generator: generator, shouldCancel: shouldCancel) { batch, _, _ in
                for result in batch { byHead[result.head] = result }
            }
            // 文ごとの訳は、先頭の区間に付く。まとめられた後ろの区間は「訳済み」として数える
            var translations = [String?](repeating: nil, count: segments.count)
            let position = Dictionary(segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            for (head, result) in byHead {
                guard let index = position[head] else { continue }
                translations[index] = result.text
                for covered in result.covers {
                    if let k = position[covered] { translations[k] = "" }
                }
            }
            var result = score(c, translations: translations.map { $0 == "" ? nil : $0 })
            result.score.translated = translations.filter { $0 != nil }.count
            result.score.seconds = Date().timeIntervalSince(started)
            total.add(result.score)
            details += result.details
            onCase(done + 1, cases.count)
        }
        return (total, details)
    }
}
