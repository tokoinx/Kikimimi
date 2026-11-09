import Foundation

/// 言語の判定の結果 (候補の中で、いちばんらしい言語と、その確からしさ)
public struct LanguageGuess: Hashable, Sendable, Codable {
    public var language: String
    /// 候補の確率の合計に対する割合 (0.5〜1)
    public var confidence: Double

    public init(language: String, confidence: Double) {
        self.language = language
        self.confidence = confidence
    }

    /// probabilities は candidates と同じ順の確率 (whisper の言語判定の値。候補以外の言語は数えない)
    public init?(probabilities: [Float], candidates: [String]) {
        guard probabilities.count == candidates.count, !candidates.isEmpty else { return nil }
        let total = probabilities.reduce(0, +)
        guard total > 0, total.isFinite else { return nil }
        var best = 0
        for i in probabilities.indices where probabilities[i] > probabilities[best] { best = i }
        language = candidates[best]
        confidence = Double(probabilities[best] / total)
    }
}

/// 同じ言語で、1 回で文字にする範囲
public struct DecodeRun: Hashable, Sendable {
    /// 文字にする範囲 (区切りと区切りの間の真ん中で区切る。最初は 0 から、最後は音声の終わりまで)
    public var range: Range<Int>
    public var language: String
    /// 中の区切り
    public var chunks: [Range<Int>]
    /// 中の発話のサンプル数
    public var speechSamples: Int
}

/// 区切りごとの判定から、区切りの言語を決め、同じ言語の区切りをつないで文字にする範囲を作る。
///
/// 区切りは時刻の順に 1 つずつ渡す。言語が決まって閉じた範囲から返すので、判定と文字起こしを交互に進められる
/// (始めのほうの文字が、ファイル全体の判定を待たずに出る)。
public struct LanguagePlanner: Sendable {
    private typealias R = MixedLanguageRules

    /// 区切りごとの決め方 (診断用)
    public struct Decision: Hashable, Sendable, Codable {
        public var start: Double
        public var end: Double
        public var speech: Double
        public var detected: String?
        public var confidence: Double?
        public var trusted: Bool
        public var language: String
    }

    public let candidates: [String]
    public let totalSamples: Int
    public private(set) var decisions: [Decision] = []

    /// 判定を信じられず、次に信じられる区切りを待っている区切り
    private var pending: [(chunk: SpeechChunk, guess: LanguageGuess?)] = []
    /// 最後に信じられた言語
    private var lastTrusted: String?
    /// 言語が決まった最後の区切りの終わり (間の長さを測る)
    private var lastResolvedEnd: Int?
    /// まだ閉じていない範囲
    private var open: (start: Int, language: String, chunks: [Range<Int>], speech: Int, lastEnd: Int)?

    public init(candidates: [String], totalSamples: Int) {
        self.candidates = candidates.isEmpty ? ["ja"] : candidates
        self.totalSamples = totalSamples
    }

    /// 判定を信じてよいか (短い発話ほど高い確からしさが要る。1 秒未満は判定しない)
    public static func isTrusted(_ guess: LanguageGuess?, speechSeconds: Double) -> Bool {
        guard let guess else { return false }
        if speechSeconds >= R.trustedSpeechSeconds { return guess.confidence >= R.trustedConfidence }
        if speechSeconds >= R.minDetectSpeechSeconds { return guess.confidence >= R.shortTrustedConfidence }
        return false
    }

    /// 区切りを 1 つ足す (時刻の順)。閉じた範囲 (もう変わらない) を返す。
    /// majority: 混ざっていて分けて判定し直した部分 (確からしさが低くても、発話が 2 秒以上あれば判定のとおりにする)
    public mutating func add(_ chunk: SpeechChunk, guess: LanguageGuess?, majority: Bool = false) -> [DecodeRun] {
        var out: [DecodeRun] = []
        let candidateGuess = guess.flatMap { candidates.contains($0.language) ? $0 : nil }
        // 話者の切り替わりの後ろへは、前の言語を借りない (待っている区切りは、切り替わりの前の言語に決める)
        if chunk.forcedCutBefore, !pending.isEmpty {
            resolvePending(next: nil, into: &out)
        }
        let trusted = Self.isTrusted(candidateGuess, speechSeconds: chunk.speechSeconds)
            || (majority && candidateGuess != nil && chunk.speechSeconds >= R.majorityMinSpeechSeconds)
        if trusted, let g = candidateGuess {
            resolvePending(next: g.language, into: &out)
            resolve(chunk, guess: g, trusted: true, language: g.language, into: &out)
            lastTrusted = g.language
        } else {
            pending.append((chunk, candidateGuess))
        }
        return out
    }

    /// 最後まで足したら呼ぶ。残りの範囲を返す (最後の範囲は音声の終わりまで)
    public mutating func finish() -> [DecodeRun] {
        var out: [DecodeRun] = []
        resolvePending(next: nil, into: &out)
        if let o = open {
            out.append(DecodeRun(range: o.start..<max(o.start, totalSamples), language: o.language,
                                 chunks: o.chunks, speech: o.speech))
            open = nil
        }
        return out
    }

    /// 待っている区切りの言語を決める。前の区切りとの間が短いあいだは前の言語、長い間が来たら (それ以降は) 次の言語。
    /// next が nil (ファイルの終わり・話者の切り替わり) なら前の言語。どちらも無ければ最初の候補
    private mutating func resolvePending(next: String?, into out: inout [DecodeRun]) {
        guard !pending.isEmpty else { return }
        let waiting = pending
        pending = []
        var useNext = lastTrusted == nil
        for item in waiting {
            if item.chunk.forcedCutBefore {
                // 話者の切り替わりの直後: 前の言語は借りない
                useNext = true
            } else if next != nil, !useNext {
                let pause = lastResolvedEnd.map { R.seconds(item.chunk.range.lowerBound - $0) } ?? .infinity
                if pause >= R.borrowPreviousBelowPauseSeconds { useNext = true }
            }
            let language: String
            if !useNext, let previous = lastTrusted {
                language = previous
            } else if let next {
                language = next
            } else if item.chunk.forcedCutBefore, let own = item.guess?.language {
                // 前後のどちらにも借りられる言語が無い: 信じられないが、その区切りの判定を使う
                language = own
            } else {
                // ファイルの終わりは前の言語。信じられる判定が 1 つも無ければ最初の候補
                language = lastTrusted ?? candidates[0]
            }
            resolve(item.chunk, guess: item.guess, trusted: false, language: language, into: &out)
        }
    }

    private mutating func resolve(_ chunk: SpeechChunk, guess: LanguageGuess?, trusted: Bool, language: String,
                                  into out: inout [DecodeRun]) {
        decisions.append(Decision(start: R.seconds(chunk.range.lowerBound), end: R.seconds(chunk.range.upperBound),
                                  speech: chunk.speechSeconds, detected: guess?.language, confidence: guess?.confidence,
                                  trusted: trusted, language: language))
        lastResolvedEnd = chunk.range.upperBound
        let maxRun = R.samples(R.maxRunSeconds)
        if var o = open {
            if o.language == language, chunk.range.upperBound - o.start <= maxRun {
                o.chunks.append(chunk.range)
                o.speech += chunk.speechSamples
                o.lastEnd = chunk.range.upperBound
                open = o
                return
            }
            // 言語が変わった (または長くなりすぎた): 前の区切りの終わりと、この区切りの始まりの真ん中で閉じる
            let edge = (o.lastEnd + chunk.range.lowerBound) / 2
            out.append(DecodeRun(range: o.start..<edge, language: o.language, chunks: o.chunks, speech: o.speech))
            open = (edge, language, [chunk.range], chunk.speechSamples, chunk.range.upperBound)
        } else {
            open = (0, language, [chunk.range], chunk.speechSamples, chunk.range.upperBound)
        }
    }
}

extension DecodeRun {
    init(range: Range<Int>, language: String, chunks: [Range<Int>], speech: Int) {
        self.init(range: range, language: language, chunks: chunks, speechSamples: speech)
    }
}
