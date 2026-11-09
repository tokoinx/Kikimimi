import Foundation

/// whisper が文字にした 1 区間 (フィルタをかける前の文。時刻は音声全体の秒)
public struct DecodedSegment: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// whisper の文 (前後の空白だけ除いたもの)
    public var text: String
    public var noSpeechProbability: Float
    /// 文のトークン (特殊なトークン・時刻のトークンを除く) の数と、その対数確率の平均
    public var tokenCount: Int
    public var meanLogProb: Double?
    /// 文字にしたときに指定した言語
    public var language: String

    public init(start: TimeInterval, end: TimeInterval, text: String, noSpeechProbability: Float = 0,
                tokenCount: Int = 0, meanLogProb: Double? = nil, language: String) {
        self.start = start
        self.end = max(start, end)
        self.text = text
        self.noSpeechProbability = noSpeechProbability
        self.tokenCount = tokenCount
        self.meanLogProb = meanLogProb
        self.language = language
    }
}

/// 点検で見つかる、文字にした結果のおかしなところ
public enum DecodeFlag: String, Hashable, Sendable, Codable, CaseIterable {
    /// 同じ言葉の繰り返し (言語を取り違えたときの暴走に多い)
    case repeating
    /// whisper の自信が、ファイルのほかの区間よりずっと低い (別の言語の音声を訳したような文・崩れた文)
    case lowConfidence
    /// 日本語の文なのに、話した長さのわりに文字が少ない (話した分が抜けている)
    case sparse
    /// 英語の文の文字の量が、話した長さに合わない
    case oddDensity
    /// 英語として文字にしたのに、かなが出た
    case wrongScript
    /// 話しているのに、文字にした区間が無い
    case uncovered
}

/// 文字にした結果を安く点検する。引っかかった区間は言語を判定し直し、別の言語なら、その言語で文字にし直す
/// (点検は文を消さない。引っかかっても、判定が同じ言語なら元の文のまま)。
public struct DecodeCheck: Sendable {
    private typealias R = MixedLanguageRules

    /// VAD の結果 (無ければ、密度と抜けの点検はしない)
    public var speech: SpeechMap?
    public var logProbMedian: Double?
    public var japaneseDensityMedian: Double
    public var latinDensityMedian: Double

    /// segments (ファイル全体の文字起こし) から、中央値を求める
    public init(speech: SpeechMap?, segments: [DecodedSegment]) {
        self.speech = speech?.fromVAD == true ? speech : nil
        let logProbs = segments.compactMap { s -> Double? in
            s.tokenCount >= R.minTokensForLogProb ? s.meanLogProb : nil
        }
        logProbMedian = Self.median(logProbs)
        var japanese: [Double] = [], latin: [Double] = []
        if let map = self.speech {
            for s in segments {
                let sp = Self.speechSeconds(s, map)
                guard sp >= R.densityMedianMinSpeechSeconds else { continue }
                let clean = RepetitionFilter.collapseInlineRepeats(s.text)
                let density = Double(Self.letterCount(clean)) / sp
                switch Self.script(clean) {
                case "ja": japanese.append(density)
                case "en": latin.append(density)
                default: break
                }
            }
        }
        japaneseDensityMedian = japanese.count >= R.densityMedianMinSamples ? (Self.median(japanese) ?? R.defaultJapaneseDensity)
            : R.defaultJapaneseDensity
        latinDensityMedian = latin.count >= R.densityMedianMinSamples ? (Self.median(latin) ?? R.defaultLatinDensity)
            : R.defaultLatinDensity
    }

    /// 1 区間の点検 (抜けの点検は `uncovered(in:segments:)`)
    public func flags(_ s: DecodedSegment) -> Set<DecodeFlag> {
        var flags: Set<DecodeFlag> = []
        let clean = RepetitionFilter.collapseInlineRepeats(s.text)
        if Self.repetition(clean) >= R.repetitionThreshold
            || Double(s.text.count) >= R.shrinkThreshold * Double(max(1, clean.count)) {
            flags.insert(.repeating)
        }
        if s.tokenCount >= R.minTokensForLogProb, let lp = s.meanLogProb, let median = logProbMedian,
           lp < R.lowLogProb, lp < median - R.logProbBelowMedian {
            flags.insert(.lowConfidence)
        }
        if let map = speech {
            let sp = Self.speechSeconds(s, map)
            if sp >= R.densityMinSpeechSeconds {
                let density = Double(Self.letterCount(clean)) / sp
                switch Self.script(clean) {
                case "ja":
                    if density < R.sparseRatio * japaneseDensityMedian { flags.insert(.sparse) }
                case "en":
                    if density < R.lowLatinRatio * latinDensityMedian || density > R.highLatinRatio * latinDensityMedian {
                        flags.insert(.oddDensity)
                    }
                default:
                    // 長く話しているのに文字が無い
                    flags.insert(.sparse)
                }
            }
        }
        if s.language == "en", Script.hasKana(clean) {
            flags.insert(.wrongScript)
        }
        return flags
    }

    /// range の中で、`uncoveredMinSpeechSeconds` 以上話しているのに、文字にした区間が重ならないところ
    public func uncovered(in range: Range<Int>, segments: [DecodedSegment]) -> [Range<Int>] {
        guard let map = speech else { return [] }
        let slack = R.coverSlackSeconds
        var covered: [Range<Int>] = segments.compactMap { s in
            let a = max(range.lowerBound, R.samples(s.start - slack))
            let b = min(range.upperBound, R.samples(s.end + slack))
            return a < b ? a..<b : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        // 重なりをまとめる
        var merged: [Range<Int>] = []
        for c in covered {
            if let last = merged.last, c.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, c.upperBound)
            } else {
                merged.append(c)
            }
        }
        covered = merged
        var gaps: [Range<Int>] = []
        var cursor = range.lowerBound
        for c in covered {
            if c.lowerBound > cursor { gaps.append(cursor..<c.lowerBound) }
            cursor = max(cursor, c.upperBound)
        }
        if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
        let minSpeech = R.samples(R.uncoveredMinSpeechSeconds)
        return gaps.compactMap { gap in
            let spans = map.spans(in: gap)
            guard let first = spans.first, let last = spans.last,
                  spans.reduce(0, { $0 + $1.count }) >= minSpeech else { return nil }
            return first.lowerBound..<last.upperBound
        }
    }

    /// 直した結果のほうが良いか: 引っかかった数が少ない。同じなら、自信 (対数確率の平均) が高い
    public func isBetter(_ new: [DecodedSegment], than old: [DecodedSegment], in range: Range<Int>) -> Bool {
        let a = score(new, in: range), b = score(old, in: range)
        if a.flags != b.flags { return a.flags < b.flags }
        return a.logProb > b.logProb
    }

    /// 引っかかった数 (区間ごとの点検の数 + 抜けの数) と、トークンで重みをつけた対数確率の平均
    public func score(_ segments: [DecodedSegment], in range: Range<Int>) -> (flags: Int, logProb: Double) {
        var flags = uncovered(in: range, segments: segments).count
        var sum = 0.0, tokens = 0
        for s in segments {
            flags += self.flags(s).count
            if let lp = s.meanLogProb, s.tokenCount > 0 {
                sum += lp * Double(s.tokenCount)
                tokens += s.tokenCount
            }
        }
        return (flags, tokens > 0 ? sum / Double(tokens) : -.infinity)
    }

    // MARK: - 文字の数え方 (textchecks.py と同じ)

    /// 比べるための文字: 互換文字をそろえて小文字にし、かな・漢字・英字・数字だけを残す
    static func letters(_ text: String) -> [Unicode.Scalar] {
        text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter { s in
            let v = s.value
            return (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v)
                || (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
                || v == 0x3005 || (0x61...0x7A).contains(v) || (0x30...0x39).contains(v)
        }
    }

    static func letterCount(_ text: String) -> Int { letters(text).count }

    /// 4 文字の並びの重なり (0 = 重なりなし、1 に近いほど同じ並びの繰り返し)
    public static func repetition(_ text: String, n: Int = 4) -> Double {
        let k = letters(text)
        guard k.count >= n + 4 else { return 0 }
        var grams = Set<String>()
        let total = k.count - n + 1
        for i in 0..<total {
            var gram = String.UnicodeScalarView()
            gram.append(contentsOf: k[i..<(i + n)])
            grams.insert(String(gram))
        }
        return 1 - Double(grams.count) / Double(total)
    }

    /// 文の文字の種類: かなを含む・漢字だけ → "ja"、英字 → "en"、文字なし → "none"
    static func script(_ text: String) -> String {
        var kana = 0, han = 0, latin = 0
        for s in text.unicodeScalars {
            let v = s.value
            if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v) {
                kana += 1
            } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) || v == 0x3005 {
                han += 1
            } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                latin += 1
            }
        }
        if kana > 0 || (han > 0 && latin == 0) { return "ja" }
        if latin > 0 { return "en" }
        return "none"
    }

    /// 区間 [start, end] の中で話している秒数
    static func speechSeconds(_ s: DecodedSegment, _ map: SpeechMap) -> Double {
        let a = R.samples(s.start), b = R.samples(s.end)
        return a < b ? R.seconds(map.speechSamples(in: a..<b)) : 0
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// 語彙のヒント (初期プロンプト) を、文字にする言語に合わせる
public enum GlossaryHint {
    /// 日本語にはそのまま渡す。英語には、かな・漢字を含まない語だけを渡す
    /// (日本語のヒントは、英語の音声を日本語の文字のほうへ引っぱるため)
    public static func hint(_ glossary: String?, for language: String) -> String? {
        guard let glossary = glossary?.trimmingCharacters(in: .whitespacesAndNewlines), !glossary.isEmpty else { return nil }
        guard language == "en" else { return glossary }
        let separators = CharacterSet(charactersIn: "、,，;；／\n\r")
        let terms = glossary.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !Script.hasKana($0) && !Script.hasHan($0) }
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }
}
