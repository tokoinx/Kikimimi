import Foundation

/// 「日本語」「英語」「自動判定」で文字にする前に、日本語と英語が混ざった録音かどうかを確かめる。
///
/// 「日本語＋英語」と同じ VAD と区切りを作り、録音全体から均等に選んだ区切り (発話 3 秒以上、最大 24 個) の言語を、
/// 日本語か英語かで判定する。少ない側の言語が、信じられる判定で 2 個以上、かつ信じられる判定の 10% 以上あれば
/// 「混ざっている」とする (信じられるかどうかは、「日本語＋英語」の区切りの判定と同じ決まり)。
/// 混ざっていれば「日本語＋英語」で文字にし、混ざっていなければ、今までどおり 1 つの言語で文字にする。
public enum MixedProbe {
    private typealias R = MixedLanguageRules

    /// 判定する言語 (「日本語＋英語」の候補と同じ)
    public static let languages = ["ja", "en"]
    /// 判定する区切りの数の上限
    public static let maxProbes = 24
    /// 判定する区切りの、発話の長さの下限 (秒)
    public static let minSpeechSeconds = 3.0
    /// 判定できる区切りがこれより少なければ確かめない (短い録音)
    public static let minProbeableChunks = 4
    /// 少ない側の言語の、信じられる判定の数の下限
    public static let minMinorityChunks = 2
    /// 少ない側の言語の、信じられる判定に占める割合の下限
    public static let minMinorityShare = 0.10

    /// 確かめた結果
    public enum Decision: String, Codable, Hashable, Sendable {
        /// 混ざっている (「日本語＋英語」で文字にする)
        case mixed
        /// 混ざっていない (今までどおり)
        case notMixed
        /// VAD を使えないので確かめなかった (VAD が無いと「日本語＋英語」の区切りが当てにならない)
        case skippedNoVAD
        /// 判定できる区切りが少ない (短い録音) ので確かめなかった
        case skippedTooShort
    }

    /// 判定した区切り 1 つ (診断用。数値は秒)
    public struct Probe: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var speech: Double
        public var detected: String?
        public var confidence: Double?
        public var trusted: Bool
    }

    public struct Result: Codable, Hashable, Sendable {
        public var decision: Decision
        /// 判定できる区切り (発話 3 秒以上) の数
        public var probeableChunks: Int
        /// 判定した区切り
        public var probes: [Probe]
        /// 言語ごとの、信じられる判定の数
        public var trusted: [String: Int]
        /// 「日本語＋英語」で文字にするときの候補 (混ざっていたときだけ。先頭が既定の言語)
        public var candidates: [String]

        public var isMixed: Bool { decision == .mixed }
        public var trustedCount: Int { trusted.values.reduce(0, +) }
        /// 信じられなかった (または判定できなかった) 区切りの数
        public var untrustedCount: Int { probes.count - trustedCount }
    }

    /// 判定する区切りを選ぶ: 発話 3 秒以上の区切りから、録音全体に均等に最大 maxProbes 個
    public static func probeChunks(_ chunks: [SpeechChunk]) -> (probeable: Int, selected: [SpeechChunk]) {
        let usable = chunks.filter { $0.speechSeconds >= minSpeechSeconds }
        guard usable.count > maxProbes else { return (usable.count, usable) }
        var selected: [SpeechChunk] = []
        for i in 0..<maxProbes {
            let index = min(usable.count - 1, Int((Double(i) + 0.5) * Double(usable.count) / Double(maxProbes)))
            selected.append(usable[index])
        }
        return (usable.count, selected)
    }

    /// 判定の結果から決める。preferred は利用者の設定の言語 ("ja" / "en" / "auto")。
    /// 候補は、利用者の言語を先に (自動判定なら、信じられる判定の多い言語を先に。同じ数なら日本語)
    public static func decide(_ probes: [Probe], probeableChunks: Int, preferred: String) -> Result {
        var trusted: [String: Int] = [:]
        for p in probes where p.trusted {
            if let language = p.detected { trusted[language, default: 0] += 1 }
        }
        var result = Result(decision: .notMixed, probeableChunks: probeableChunks, probes: probes, trusted: trusted,
                            candidates: [])
        guard probeableChunks >= minProbeableChunks else {
            result.decision = .skippedTooShort
            return result
        }
        let ja = trusted["ja"] ?? 0, en = trusted["en"] ?? 0
        let total = ja + en
        let minority = min(ja, en)
        if total > 0, minority >= minMinorityChunks, Double(minority) >= minMinorityShare * Double(total) {
            result.decision = .mixed
            let first: String
            if languages.contains(preferred) {
                first = preferred
            } else {
                first = en > ja ? "en" : "ja"
            }
            result.candidates = [first] + languages.filter { $0 != first }
        }
        return result
    }

    /// 確かめる。preferred は利用者の設定の言語 ("ja" / "en" / "auto")。
    /// engine の VAD が使えなければ (speechMap が nil) 確かめない。中止されたら MixedPipelineError.cancelled
    public static func run<Engine: MixedEngine>(samples: [Float], engine: Engine, preferred: String,
                                                 shouldCancel: () -> Bool = { false }) throws -> Result {
        func checkCancel() throws {
            if shouldCancel() { throw MixedPipelineError.cancelled }
        }
        try checkCancel()
        guard !samples.isEmpty, let map = try engine.speechMap(of: samples) else {
            return Result(decision: .skippedNoVAD, probeableChunks: 0, probes: [], trusted: [:], candidates: [])
        }
        try checkCancel()
        // 「日本語＋英語」と同じ区切り (話者の切り替わりは使わない)
        let picked = probeChunks(SpeechChunker.chunks(map))
        guard picked.probeable >= minProbeableChunks else {
            return decide([], probeableChunks: picked.probeable, preferred: preferred)
        }
        var probes: [Probe] = []
        for chunk in picked.selected {
            try checkCancel()
            let guess = try engine.detectLanguage(samples, range: chunk.range, candidates: languages)
                .flatMap { LanguageGuess(probabilities: $0, candidates: languages) }
            probes.append(Probe(start: R.seconds(chunk.range.lowerBound), end: R.seconds(chunk.range.upperBound),
                                speech: chunk.speechSeconds, detected: guess?.language, confidence: guess?.confidence,
                                trusted: LanguagePlanner.isTrusted(guess, speechSeconds: chunk.speechSeconds)))
        }
        try checkCancel()
        return decide(probes, probeableChunks: picked.probeable, preferred: preferred)
    }
}

/// 確かめるときの VAD と判定を覚えておき、続けて「日本語＋英語」で文字にするときに使い回す
/// (同じ音声・同じ範囲・同じ候補なら、whisper は同じ値を返す。2 時間の録音で VAD と 24 回の判定を繰り返さない)
public final class ReusingMixedEngine<Base: MixedEngine>: MixedEngine {
    private let base: Base
    private var map: (count: Int, map: SpeechMap?)?
    private var detections: [String: [Float]?] = [:]

    public init(_ base: Base) {
        self.base = base
    }

    public func speechMap(of samples: [Float]) throws -> SpeechMap? {
        if let map, map.count == samples.count { return map.map }
        let found = try base.speechMap(of: samples)
        map = (samples.count, found)
        return found
    }

    public func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]? {
        let key = "\(samples.count):\(range.lowerBound)-\(range.upperBound):\(candidates.joined(separator: ","))"
        if let known = detections[key] { return known }
        let probs = try base.detectLanguage(samples, range: range, candidates: candidates)
        detections[key] = probs
        return probs
    }

    public func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                       onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment] {
        try base.decode(samples, range: range, language: language, hint: hint, useVAD: useVAD,
                        onProgress: onProgress, onSegment: onSegment)
    }
}
