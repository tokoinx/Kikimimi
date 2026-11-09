import Foundation

/// 1 つの区切りに 2 つの言語が混ざっていそうなとき、どこで切り替わるかを探す (whisper の言語判定だけを使う)。
///
/// 1. 区切りの中のいちばん長い間 (最大 2 か所) で分け、それぞれを判定する (間のある切り替わり)
/// 2. 長くて確からしさの低い部分は、先頭と末尾の 4 秒を判定し、違えば 4 秒の窓で二分探索する (間の無い切り替わり)。
///    切り替わりの位置は、探した幅の中で VAD の発話らしさがいちばん低いところ。
///    試作では、間の無い 3 か所の切り替わりを −1.43・−0.01・+1.54 秒の誤差で見つけ、両側とも崩れずに文字にできた。
public enum SwitchSearch {
    private typealias R = MixedLanguageRules

    /// 判定し直した後の、区切りの一部と、その判定
    public struct Part: Hashable, Sendable {
        public var chunk: SpeechChunk
        public var guess: LanguageGuess?
    }

    /// 見つけた切り替わり (診断用)
    public struct Found: Hashable, Sendable, Codable {
        public var start: Double
        public var end: Double
        public var head: String
        public var tail: String
        public var bracketStart: Double
        public var bracketEnd: Double
        public var cut: Double
    }

    public struct Outcome: Hashable, Sendable {
        public var parts: [Part]
        /// 使った判定の回数
        public var detections: Int
        public var switches: [Found]
    }

    /// 二分探索の結果
    public struct Bisection: Hashable, Sendable {
        /// 切り替わりの位置 (見つからなければ nil)
        public var cut: Int?
        public var head: LanguageGuess?
        public var tail: LanguageGuess?
        public var bracket: Range<Int>?
        public var detections: Int
    }

    /// 分けて判定し直すべき区切りか
    public static func needsRefinement(_ guess: LanguageGuess?, speechSeconds: Double) -> Bool {
        guard let guess else { return false }
        return speechSeconds >= R.refineMinSpeechSeconds && guess.confidence < R.refineBelow
    }

    /// 区切りを分けて判定し直す。detect は範囲の言語を判定する (判定できなければ nil)
    public static func refine(_ chunk: SpeechChunk, guess: LanguageGuess?, map: SpeechMap,
                              detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Outcome {
        let pieces = SpeechChunker.pieces(of: chunk)
        var detections = 0
        var guesses: [LanguageGuess?] = []
        if pieces.count == 1 {
            guesses = [guess]
        } else {
            for piece in pieces {
                guesses.append(try detect(piece.range))
                detections += 1
            }
        }
        var parts: [Part] = []
        var switches: [Found] = []
        for (piece, g) in zip(pieces, guesses) {
            if piece.seconds >= R.bisectMinSeconds, (g?.confidence ?? 0) < R.bisectBelow {
                let b = try bisect(piece.range, map: map, detect: detect)
                detections += b.detections
                if let cut = b.cut, let halves = SpeechChunker.split(piece, at: cut) {
                    parts.append(Part(chunk: halves.0, guess: b.head))
                    parts.append(Part(chunk: halves.1, guess: b.tail))
                    if let head = b.head, let tail = b.tail, let bracket = b.bracket {
                        switches.append(Found(start: R.seconds(piece.range.lowerBound), end: R.seconds(piece.range.upperBound),
                                              head: head.language, tail: tail.language,
                                              bracketStart: R.seconds(bracket.lowerBound), bracketEnd: R.seconds(bracket.upperBound),
                                              cut: R.seconds(cut)))
                    }
                    continue
                }
            }
            parts.append(Part(chunk: piece, guess: g))
        }
        return Outcome(parts: parts, detections: detections, switches: switches)
    }

    /// range の中の、間の無い切り替わりを二分探索で探す (refine.py の手順に、端の確かめを足したもの)。
    ///
    /// 先頭と末尾の 4 秒の言語が違えば、そのあいだを 4 秒の窓で探す。同じなら、切り替わりが端から 4 秒以内にあって
    /// 4 秒の窓では多い側の言語に聞こえている場合があるので、先頭と末尾の 2 秒も確かめ、違えばそこから 2 秒の窓で探す
    /// (試作の録音の切り替わりは、どれも端から 4 秒以上離れていたが、区切り方しだいで端に寄る)
    public static func bisect(_ range: Range<Int>, map: SpeechMap,
                              detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Bisection {
        let window = R.samples(R.bisectWindowSeconds)
        let edge = R.samples(R.edgeWindowSeconds)
        guard range.count >= R.samples(R.bisectMinSeconds) else {
            return Bisection(cut: nil, head: nil, tail: nil, bracket: nil, detections: 0)
        }
        let head = try detect(range.lowerBound..<(range.lowerBound + window))
        let tail = try detect((range.upperBound - window)..<range.upperBound)
        var detections = 2
        guard let h = head, let t = tail else {
            return Bisection(cut: nil, head: head, tail: tail, bracket: nil, detections: detections)
        }
        if h.language != t.language {
            return try search(range, from: range.lowerBound + window / 2, h, to: range.upperBound - window / 2, t,
                              window: window, map: map, detections: detections, detect: detect)
        }
        // 両端が同じ言語: 端の 2 秒を確かめる
        if let first = try detect(range.lowerBound..<(range.lowerBound + edge)) {
            detections += 1
            if first.language != h.language {
                return try search(range, from: range.lowerBound + edge / 2, first, to: range.upperBound - window / 2, t,
                                  window: edge, map: map, detections: detections, detect: detect)
            }
        } else {
            detections += 1
        }
        if let last = try detect((range.upperBound - edge)..<range.upperBound) {
            detections += 1
            if last.language != t.language {
                return try search(range, from: range.lowerBound + window / 2, h, to: range.upperBound - edge / 2, last,
                                  window: edge, map: map, detections: detections, detect: detect)
            }
        } else {
            detections += 1
        }
        return Bisection(cut: nil, head: h, tail: t, bracket: nil, detections: detections)
    }

    /// lo (言語 head) と hi (言語 tail) のあいだで、窓 window の言語が切り替わるところを探し、いちばん静かなところで切る
    private static func search(_ range: Range<Int>, from start: Int, _ head: LanguageGuess, to end: Int, _ tail: LanguageGuess,
                               window: Int, map: SpeechMap, detections: Int,
                               detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Bisection {
        var detections = detections
        var lo = start, hi = max(start, end)
        let half = window / 2
        var steps = 0
        let stop = R.samples(R.bisectStopSeconds)
        while hi - lo > stop, steps < R.bisectMaxSteps {
            let mid = (lo + hi) / 2
            let probe = max(range.lowerBound, mid - half)..<min(range.upperBound, mid + half)
            guard let g = try detect(probe) else { break }
            detections += 1
            steps += 1
            if g.language == head.language { lo = mid } else { hi = mid }
        }
        let margin = R.samples(R.cutSearchMarginSeconds)
        let searchStart = max(range.lowerBound + 1, lo - margin)
        let searchEnd = min(range.upperBound - 1, hi + margin)
        let cut = searchStart < searchEnd ? (map.quietestSample(in: searchStart..<searchEnd) ?? (lo + hi) / 2) : (lo + hi) / 2
        return Bisection(cut: cut, head: head, tail: tail, bracket: lo..<hi, detections: detections)
    }
}
