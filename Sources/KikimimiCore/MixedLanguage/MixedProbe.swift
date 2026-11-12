import Foundation

/// 「日本語」「英語」「自動判定」で文字にする前に、日本語と英語が混ざった録音かどうかを確かめる。
///
/// 「日本語＋英語」と同じ VAD と区切りを作り、録音全体から均等に選んだ区切り (発話 3 秒以上、最大 24 個) の言語を、
/// 日本語か英語かで判定する。判定の確率の合計が多い側を「多い側の言語」とし、もう一方の言語の確率が 0.25 以上の区切りを
/// 「もう一方の言語がある区切り」と数える (もう一方の言語と判定された区切りと、どちらか確かでない区切りの両方)。
/// これが 2 個以上、かつ判定できた区切りの 10% 以上あれば「混ざっている」とする。
/// 1 つの言語だけの録音では、区切りの判定は確か (日本語の話で 0.977 以上、英語で 0.998 以上) なので数に入らない。
/// 英語の講師と日本語の通訳が短く交代する講演では、ほとんどの区切りに両方の言語が入って判定が確かでなくなり、
/// どちらかの言語と確かに判定される区切りが少ないので、確かでない区切りも混ざっている証として数える。
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
    /// 「もう一方の言語がある区切り」とする、多い側でない言語の確率の下限
    public static let minOtherProbability = 0.25
    /// 「もう一方の言語がある区切り」の数の下限
    public static let minEvidenceChunks = 2
    /// 「もう一方の言語がある区切り」の、判定できた区切りに占める割合の下限
    public static let minEvidenceShare = 0.10

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

        /// language の確率 (日本語と英語の 2 つで判定するので、判定されなかった側は 1 − 確からしさ)。判定できなかったら nil
        public func probability(of language: String) -> Double? {
            guard let detected, let confidence else { return nil }
            return detected == language ? confidence : 1 - confidence
        }
    }

    public struct Result: Codable, Hashable, Sendable {
        public var decision: Decision
        /// 判定できる区切り (発話 3 秒以上) の数
        public var probeableChunks: Int
        /// 判定した区切り
        public var probes: [Probe]
        /// 言語ごとの、信じられる判定の数 (診断用。決めるのには使わない)
        public var trusted: [String: Int]
        /// 多い側の言語 (判定の確率の合計が多い側。判定できた区切りが無ければ nil)
        public var majority: String?
        /// 判定できた区切りの数
        public var detectedCount: Int
        /// 「もう一方の言語がある区切り」の数 (多い側でない言語の確率が 0.25 以上)
        public var evidence: Int
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
    /// 多い側の言語は、判定の確率の合計が多い側 (同じなら利用者の言語。自動判定なら日本語)。
    /// 候補は、利用者の言語を先に (自動判定なら、多い側の言語を先に)
    public static func decide(_ probes: [Probe], probeableChunks: Int, preferred: String) -> Result {
        var trusted: [String: Int] = [:]
        for p in probes where p.trusted {
            if let language = p.detected { trusted[language, default: 0] += 1 }
        }
        let detected = probes.filter { $0.detected != nil && $0.confidence != nil }
        var sums: [String: Double] = [:]
        for p in detected {
            for language in languages { sums[language, default: 0] += p.probability(of: language) ?? 0 }
        }
        var majority: String?
        if !detected.isEmpty {
            let ja = sums["ja"] ?? 0, en = sums["en"] ?? 0
            // 同じ (足す順の誤差は無視する)
            if abs(ja - en) < 1e-9 {
                majority = languages.contains(preferred) ? preferred : "ja"
            } else {
                majority = en > ja ? "en" : "ja"
            }
        }
        var evidence = 0
        if let majority {
            let other = languages.filter { $0 != majority }
            for p in detected where other.contains(where: { (p.probability(of: $0) ?? 0) >= minOtherProbability }) {
                evidence += 1
            }
        }
        var result = Result(decision: .notMixed, probeableChunks: probeableChunks, probes: probes, trusted: trusted,
                            majority: majority, detectedCount: detected.count, evidence: evidence, candidates: [])
        guard probeableChunks >= minProbeableChunks else {
            result.decision = .skippedTooShort
            return result
        }
        if let majority, evidence >= minEvidenceChunks, Double(evidence) >= minEvidenceShare * Double(detected.count) {
            result.decision = .mixed
            let first = languages.contains(preferred) ? preferred : majority
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
            return Result(decision: .skippedNoVAD, probeableChunks: 0, probes: [], trusted: [:], majority: nil,
                          detectedCount: 0, evidence: 0, candidates: [])
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
