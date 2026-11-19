import Foundation

/// 訳の関門 (`TranslationGate`) を、LLM なしで測る道具 (`Kikimimi --eval-llm none --gate …`)。
///
/// - 問題のファイル (`LLMEvalSet`): 人の訳を「訳」と見立てて関門に掛け、検査ごとに誤って印が付く数を数える。
///   さらに人の訳を機械的に壊し、壊した訳に印が付く (拾う) 数を数える。
/// - 結果のファイル (`LLMEvalReport` の `translationOutputs`): LLM の訳に関門を掛け、印の数と、
///   印の有るまとまり・無いまとまりの chrF を比べる (印の付く訳の質が本当に低いかを見る)。
public enum TranslationGateEval {
    /// 壊し方の名前と、拾ったと見る印
    public static let mutations: [(name: String, caughtBy: Set<String>)] = [
        ("number", [TranslationGate.number]),
        ("copied", [TranslationGate.copied]),
        ("language", [TranslationGate.language, TranslationGate.script]),
        ("repeated", [TranslationGate.repeated]),
        ("failed", [TranslationGate.failed]),
        ("short", [TranslationGate.short])
    ]

    /// 「別の言語の文」に使う、決まった文 (言語のコードと文)。訳す先と原文の言語でない物を、順に使う
    public static let otherLanguageSentences: [(language: String, text: String)] = [
        ("de", "Gestern war das Wetter sehr schön, deshalb sind wir lange im Park spazieren gegangen."),
        ("ja", "昨日はとても天気が良かったので、公園を長い時間散歩しました。"), // l10n: keep (測りに使う、別の言語の文)
        ("ru", "Вчера была очень хорошая погода, поэтому мы долго гуляли в парке."),
        ("es", "Ayer hizo muy buen tiempo, así que dimos un largo paseo por el parque."),
        ("ko", "어제는 날씨가 아주 좋아서 공원에서 오랫동안 산책했습니다."),
        ("en", "The weather was very nice yesterday, so we went for a long walk in the park."),
        ("zh", "昨天天气很好，所以我们在公园里散步了很久。"), // l10n: keep (測りに使う、別の言語の文)
        ("fr", "Hier, il faisait très beau, alors nous avons fait une longue promenade dans le parc.")
    ]

    /// 壊した数と、拾った数
    public struct MutationCount: Codable, Hashable, Sendable {
        public var tried = 0
        public var caught = 0

        public init() {}
    }

    /// 人の訳に掛けた結果 (訳す先ごと)
    public struct ReferenceStats: Codable, Hashable, Sendable {
        /// 関門に掛けたまとまりの数
        public var units = 0
        /// 何かの印が付いたまとまりの数
        public var flaggedUnits = 0
        /// 印ごとの、印が付いたまとまりの数 (人の訳なので、どれも誤り)
        public var flags: [String: Int] = [:]
        /// 壊し方ごとの、壊した数と拾った数
        public var mutations: [String: MutationCount] = [:]

        public init() {}

        public mutating func add(_ other: ReferenceStats) {
            units += other.units
            flaggedUnits += other.flaggedUnits
            for (k, v) in other.flags { flags[k, default: 0] += v }
            for (k, v) in other.mutations {
                mutations[k, default: MutationCount()].tried += v.tried
                mutations[k, default: MutationCount()].caught += v.caught
            }
        }
    }

    /// LLM の訳に掛けた結果 (訳す先ごと)
    public struct OutputStats: Codable, Hashable, Sendable {
        /// 関門に掛けたまとまりの数 (訳す必要の無い行 (原文のまま) は数えない)
        public var units = 0
        /// 訳す必要の無い行で、関門に掛けなかったまとまりの数
        public var skippedAsSource = 0
        public var flaggedUnits = 0
        /// 重い印 (`TranslationGate.severe`) が付いたまとまりの数
        public var severeUnits = 0
        public var flags: [String: Int] = [:]
        /// 人の訳の在る、印の有るまとまり・無いまとまりの数
        public var flaggedWithReference = 0
        public var unflaggedWithReference = 0
        /// chrF の統計と点 (コーパスの点)。人の訳の在るまとまりだけ
        public var flaggedChrFStatistics: ChrF.Statistics?
        public var unflaggedChrFStatistics: ChrF.Statistics?
        public var flaggedChrF: Double?
        public var unflaggedChrF: Double?
        /// 印ごとの、その印の付いたまとまりの chrF
        public var chrFStatisticsByFlag: [String: ChrF.Statistics] = [:]
        public var chrFByFlag: [String: Double] = [:]

        public init() {}

        static func sum(_ a: ChrF.Statistics?, _ b: ChrF.Statistics?) -> ChrF.Statistics? {
            guard let b else { return a }
            var out = a ?? ChrF.Statistics()
            out.add(b)
            return out
        }

        public mutating func add(_ other: OutputStats) {
            units += other.units
            skippedAsSource += other.skippedAsSource
            flaggedUnits += other.flaggedUnits
            severeUnits += other.severeUnits
            for (k, v) in other.flags { flags[k, default: 0] += v }
            flaggedWithReference += other.flaggedWithReference
            unflaggedWithReference += other.unflaggedWithReference
            flaggedChrFStatistics = Self.sum(flaggedChrFStatistics, other.flaggedChrFStatistics)
            unflaggedChrFStatistics = Self.sum(unflaggedChrFStatistics, other.unflaggedChrFStatistics)
            flaggedChrF = flaggedChrFStatistics?.score
            unflaggedChrF = unflaggedChrFStatistics?.score
            for (k, v) in other.chrFStatisticsByFlag {
                if let s = Self.sum(chrFStatisticsByFlag[k], v) {
                    chrFStatisticsByFlag[k] = s
                    chrFByFlag[k] = s.score
                }
            }
        }
    }

    /// 印の付いたまとまり (後で人が誤りを数える)
    public struct Example: Codable, Hashable, Sendable {
        /// 読んだファイルの名前
        public var file: String
        /// 問題の id
        public var id: String
        /// 原文の行の番号 (0 始まり)
        public var lines: [Int]
        public var target: String
        /// "reference" (人の訳に付いた印 = 誤り)、"missed:<壊し方>" (壊した訳を拾えなかった)、"output" (LLM の訳に付いた印)
        public var kind: String
        public var source: String
        public var translation: String?
        public var reference: String?
        public var flags: [String]
        public var detail: String?

        public init(file: String, id: String, lines: [Int], target: String, kind: String, source: String,
                    translation: String?, reference: String?, flags: [String], detail: String?) {
            self.file = file
            self.id = id
            self.lines = lines
            self.target = target
            self.kind = kind
            self.source = source
            self.translation = translation
            self.reference = reference
            self.flags = flags
            self.detail = detail
        }
    }

    /// 問題 1 つの、文のまとまり (アプリの翻訳と同じまとめ方)。訳す必要の無い行は入れない
    public struct SetUnit: Hashable, Sendable {
        public var lines: [Int]
        public var source: String
        /// 人の訳 (行の数が合う時だけ)
        public var reference: String?
    }

    /// 問題を、アプリの翻訳 (`Translator.translate`) と同じ決め方で、文のまとまりに分ける
    public static func units(of c: TranslationEvalCase) -> [SetUnit] {
        let segments = LLMEval.segments(c.lines, language: c.language)
        let references = c.references.flatMap { $0.count == c.lines.count ? $0 : nil }
        let pending = Translator.pendingIndices(segments, language: c.language, target: c.targetLanguage)
        return Translator.sentenceUnits(pending, in: segments).map { unit in
            SetUnit(lines: unit, source: Transcript.join(unit.map { c.lines[$0] }),
                    reference: references.map { r in Transcript.join(unit.map { r[$0] }) })
        }
    }

    /// 訳から、原文にも在る数 (2 桁以上) を 1 つ消す (千の区切りを含めて、その数の書かれた所を全部消す)。
    /// 消すと `LLMEval.numbersLost` が「消えた」と見る物だけを返す。消せる数が無ければ nil。
    /// target (訳す先の言語) を渡すと、関門と同じく、言葉で書いた数が残る訳は「消えた」と見ない
    public static func removingNumber(from translation: String, source: String, target: String? = nil) -> String? {
        let wanted = Set(LLMEval.numbers(in: source)).union(LLMEval.numbers(in: source, joiningSpaces: false))
        guard !wanted.isEmpty,
              let regex = try? NSRegularExpression(pattern: "[0-9０-９]+(?:[,.'\u{00A0}\u{202F} ][0-9]{3})*") else { return nil }
        let ns = translation as NSString
        let matches = regex.matches(in: translation, range: NSRange(location: 0, length: ns.length))
        func numbers(_ m: NSTextCheckingResult) -> Set<String> {
            let text = ns.substring(with: m.range)
            return Set(LLMEval.numbers(in: text)).union(LLMEval.numbers(in: text, joiningSpaces: false))
        }
        let candidates = matches.flatMap { numbers($0).intersection(wanted).sorted() }
        var tried = Set<String>()
        for n in candidates where !tried.contains(n) {
            tried.insert(n)
            var out = translation
            // 後ろから消す (前の位置がずれないように)
            for m in matches.reversed() where numbers(m).contains(n) {
                guard let range = Range(m.range, in: out) else { continue }
                out.removeSubrange(range)
            }
            if !LLMEval.numbersLost(sources: [source], translation: out, target: target).lost.isEmpty { return out }
        }
        return nil
    }

    /// 訳す先と原文の言語でない、決まった文 (index で順に選ぶ)
    public static func otherLanguageSentence(target: String, sourceLanguage: String?, index: Int) -> String {
        let usable = otherLanguageSentences.filter { $0.language != target && $0.language != sourceLanguage?.lowercased() }
        return usable[index % usable.count].text
    }

    /// 訳の頭の数文字 (空白でない字が 4 つになるまで) を 6 回繰り返した物
    public static func repeatingHead(_ translation: String) -> String {
        var head = ""
        var count = 0
        for ch in translation.trimmingCharacters(in: .whitespacesAndNewlines) {
            head.append(ch)
            if !ch.isWhitespace { count += 1 }
            if count >= 4 { break }
        }
        return String(repeating: head, count: 6)
    }

    /// 訳の頭の 5 分の 1 だけを残した物
    public static func truncated(_ translation: String) -> String {
        String(translation.prefix(translation.count / 5))
    }

    /// 問題のファイルの人の訳に関門を掛け、壊した訳も掛ける
    public static func checkReferences(_ set: LLMEvalSet, file: String,
                                       detector: LanguageDetector? = LLMEval.defaultLanguageDetector)
        -> (byTarget: [String: ReferenceStats], examples: [Example]) {
        var byTarget: [String: ReferenceStats] = [:]
        var examples: [Example] = []
        var index = 0
        for c in set.translation {
            let target = c.targetLanguage
            let terms = (c.keep ?? []).map { (source: $0, translation: $0) }
            for unit in units(of: c) {
                guard let reference = unit.reference else { continue }
                func assess(_ text: String?) -> TranslationGate.Finding {
                    TranslationGate.assess(source: unit.source, translation: text, sourceLanguage: c.language, target: target,
                                           terms: terms, detector: detector)
                }
                func example(_ kind: String, _ text: String?, _ f: TranslationGate.Finding) -> Example {
                    Example(file: file, id: c.id, lines: unit.lines, target: target, kind: kind, source: unit.source,
                            translation: text, reference: reference, flags: f.flags, detail: f.detail)
                }
                var stats = ReferenceStats()
                stats.units = 1
                let finding = assess(reference)
                if !finding.flags.isEmpty {
                    stats.flaggedUnits = 1
                    for flag in finding.flags { stats.flags[flag, default: 0] += 1 }
                    examples.append(example("reference", reference, finding))
                }
                for mutation in mutations {
                    // 人の訳にもう同じ印が付いている時は、壊しても拾ったか分からないので数えない
                    guard finding.flags.allSatisfy({ !mutation.caughtBy.contains($0) }) else { continue }
                    let broken: String?
                    switch mutation.name {
                    case "number": broken = removingNumber(from: reference, source: unit.source, target: target)
                    case "copied": broken = c.language.lowercased() != target ? unit.source : nil
                    case "language": broken = otherLanguageSentence(target: target, sourceLanguage: c.language, index: index)
                    case "repeated": broken = repeatingHead(reference)
                    case "failed": broken = ""
                    case "short": broken = TranslationGate.weight(unit.source) >= TranslationGate.shortMinimumSourceWeight
                        ? truncated(reference) : nil
                    default: broken = nil
                    }
                    guard let broken else { continue }
                    let f = assess(broken)
                    stats.mutations[mutation.name, default: MutationCount()].tried += 1
                    if f.flags.contains(where: mutation.caughtBy.contains) {
                        stats.mutations[mutation.name, default: MutationCount()].caught += 1
                    } else {
                        examples.append(example("missed:" + mutation.name, broken, f))
                    }
                }
                byTarget[target, default: ReferenceStats()].add(stats)
                index += 1
            }
        }
        return (byTarget, examples)
    }

    /// 結果のファイルに残した LLM の訳に関門を掛ける
    public static func checkOutputs(_ outputs: [LLMEval.TranslationOutput], file: String,
                                    detector: LanguageDetector? = LLMEval.defaultLanguageDetector)
        -> (byTarget: [String: OutputStats], examples: [Example]) {
        var byTarget: [String: OutputStats] = [:]
        var examples: [Example] = []
        for o in outputs {
            let target = TranslationTarget.normalized(o.target)
            let terms = (o.keep ?? []).map { (source: $0, translation: $0) }
            var stats = OutputStats()
            for unit in o.units {
                // 訳す必要の無い行は、原文をそのまま見せるので、関門に掛けない
                if unit.asSource == true {
                    stats.skippedAsSource += 1
                    continue
                }
                // 採点 (`LLMEval.score`) と同じく、空の訳は訳せなかった物とする
                let text = unit.text.flatMap { $0.isEmpty ? nil : $0 }
                let f = TranslationGate.assess(source: unit.source, translation: text, sourceLanguage: o.language,
                                               target: target, terms: terms, detector: detector)
                stats.units += 1
                let flagged = !f.flags.isEmpty
                if flagged {
                    stats.flaggedUnits += 1
                    if f.isSevere { stats.severeUnits += 1 }
                    for flag in f.flags { stats.flags[flag, default: 0] += 1 }
                    examples.append(Example(file: file, id: o.id, lines: unit.lines, target: target, kind: "output",
                                            source: unit.source, translation: unit.text, reference: unit.reference,
                                            flags: f.flags, detail: f.detail))
                }
                if let reference = unit.reference {
                    let s = ChrF.statistics(hypothesis: text ?? "", reference: reference)
                    if flagged {
                        stats.flaggedWithReference += 1
                        stats.flaggedChrFStatistics = OutputStats.sum(stats.flaggedChrFStatistics, s)
                        for flag in f.flags {
                            stats.chrFStatisticsByFlag[flag] = OutputStats.sum(stats.chrFStatisticsByFlag[flag], s)
                        }
                    } else {
                        stats.unflaggedWithReference += 1
                        stats.unflaggedChrFStatistics = OutputStats.sum(stats.unflaggedChrFStatistics, s)
                    }
                }
            }
            // 点は、足し合わせた統計から付け直す
            var total = OutputStats()
            total.add(stats)
            byTarget[target, default: OutputStats()].add(total)
        }
        return (byTarget, examples)
    }

    /// 人の訳に掛けた結果の表 (1 行目は見出し)。印ごとの「誤って付いた数」と、壊し方ごとの「拾った数/壊した数」
    public static func referenceTable(_ byTarget: [String: ReferenceStats]) -> [String] {
        func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }
        var header = ["target", "units", "flagged"] + TranslationGate.all
        header += mutations.map { "+" + $0.name }
        let widths = header.map { max($0.count, 7) }
        func row(_ cells: [String]) -> String { zip(cells, widths).map { pad($0, $1) }.joined(separator: " ") }
        var out = [row(header)]
        var total = ReferenceStats()
        func cells(_ name: String, _ s: ReferenceStats) -> [String] {
            [name, "\(s.units)", "\(s.flaggedUnits)"] + TranslationGate.all.map { "\(s.flags[$0] ?? 0)" }
                + mutations.map { m in s.mutations[m.name].map { "\($0.caught)/\($0.tried)" } ?? "-" }
        }
        for target in byTarget.keys.sorted() {
            guard let s = byTarget[target] else { continue }
            total.add(s)
            out.append(row(cells(target, s)))
        }
        out.append(row(cells("all", total)))
        return out
    }

    /// LLM の訳に掛けた結果の表 (1 行目は見出し)
    public static func outputTable(_ byTarget: [String: OutputStats]) -> [String] {
        func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }
        func points(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "-" }
        let header = ["target", "units", "flagged", "severe"] + TranslationGate.all + ["chrF+flag", "chrF-noflag"]
        let widths = header.map { max($0.count, 7) }
        func row(_ cells: [String]) -> String { zip(cells, widths).map { pad($0, $1) }.joined(separator: " ") }
        var out = [row(header)]
        var total = OutputStats()
        func cells(_ name: String, _ s: OutputStats) -> [String] {
            [name, "\(s.units)", "\(s.flaggedUnits)", "\(s.severeUnits)"] + TranslationGate.all.map { "\(s.flags[$0] ?? 0)" }
                + ["\(points(s.flaggedChrF)) (\(s.flaggedWithReference))", "\(points(s.unflaggedChrF)) (\(s.unflaggedWithReference))"]
        }
        for target in byTarget.keys.sorted() {
            guard let s = byTarget[target] else { continue }
            total.add(s)
            out.append(row(cells(target, s)))
        }
        out.append(row(cells("all", total)))
        return out
    }
}

/// 関門の測り (`--gate`) の結果 (`--report` に書く JSON)
public struct TranslationGateReport: Codable, Sendable {
    /// 読んだファイルの名前
    public var files: [String]
    /// 決めた定数 (後で結果を読む時に、どの決まりで測ったかが分かるように)
    public var shortRatio: Double
    public var shortMinimumSourceWeight: Int
    public var severe: [String]
    /// 人の訳に掛けた結果 (訳す先ごと)。問題のファイルを読んだ時だけ
    public var references: [String: TranslationGateEval.ReferenceStats]
    /// LLM の訳に掛けた結果 (訳す先ごと)。結果のファイルを読んだ時だけ
    public var outputs: [String: TranslationGateEval.OutputStats]
    /// 印の付いたまとまり (人の訳の誤り・拾えなかった壊し方・LLM の訳の印)
    public var examples: [TranslationGateEval.Example]

    public init(files: [String] = [], references: [String: TranslationGateEval.ReferenceStats] = [:],
                outputs: [String: TranslationGateEval.OutputStats] = [:], examples: [TranslationGateEval.Example] = []) {
        self.files = files
        self.shortRatio = TranslationGate.shortRatio
        self.shortMinimumSourceWeight = TranslationGate.shortMinimumSourceWeight
        self.severe = TranslationGate.severe.sorted()
        self.references = references
        self.outputs = outputs
        self.examples = examples
    }
}
