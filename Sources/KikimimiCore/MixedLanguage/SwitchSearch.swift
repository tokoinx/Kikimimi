import Foundation

/// 1 つの区切りに 2 つの言語が混ざっていそうなとき、どこで切り替わるかを探す (whisper の言語判定だけを使う)。
///
/// 1. 区切りの中のいちばん長い間 (最大 2 か所) で分け、それぞれを判定する (間のある切り替わり)
/// 2. 確からしさの低い部分は、先頭と末尾の窓 (4 秒、短い部分は 2 秒) を判定し、違えば二分探索する (間の無い切り替わり)。
///    切り替わりの位置は、探した幅の中で VAD の発話らしさがいちばん低いところ。
///    試作では、間の無い 3 か所の切り替わりを −1.43・−0.01・+1.54 秒の誤差で見つけ、両側とも崩れずに文字にできた。
/// 3. 両端が同じ言語なら、中ほどに別の言語が挟まっているかもしれない (英語 → 日本語 → 英語)。島として探す (`islands`)
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
        /// "switch" (二分探索で見つけた切り替わり) か "island" (中ほどに挟まった別の言語。cut から bracketEnd まで)
        public var kind: String = "switch"
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

    /// 島 (中ほどに挟まった別の言語) を探すべき区切りか。threshold は、別の言語の確率のしきい値 (ファイルに合わせて決める)
    public static func needsIslandSearch(_ guess: LanguageGuess?, speechSeconds: Double, threshold: Double) -> Bool {
        guard let guess, R.islandHosts.contains(guess.language) else { return false }
        return speechSeconds >= R.refineMinSpeechSeconds && 1 - guess.confidence >= threshold
    }

    /// 区切りを分けて判定し直す。detect は範囲の言語を判定する (判定できなければ nil)
    /// islandThreshold: その言語の部分で島を探す、別の言語の確率のしきい値 (探さない言語は nil)。
    /// 確からしい部分 (0.97 以上) でも、別の言語の確率がしきい値以上なら、中ほどの島を探す
    /// (11 秒の区切りの最後の 1.1 秒の相づちが、5.4 秒の部分の 0.974 に埋もれていた)
    public static func refine(_ chunk: SpeechChunk, guess: LanguageGuess?, map: SpeechMap,
                              islandThreshold: (String) -> Double? = { _ in nil },
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
                let found = try locate(piece, guess: g, map: map, detect: detect)
                detections += found.detections
                parts += found.parts
                switches += found.switches
            } else if let g, let threshold = islandThreshold(g.language), 1 - g.confidence >= threshold,
                      piece.speechSeconds >= 2 * R.minDetectSpeechSeconds {
                let found = try islands(piece, host: g, map: map, floor: threshold, detect: detect)
                detections += found.detections
                parts += found.parts
                switches += found.switches
            } else {
                parts.append(Part(chunk: piece, guess: g))
            }
        }
        return Outcome(parts: parts, detections: detections, switches: switches)
    }

    /// 言語の混ざっていそうな部分の中で、切り替わり (二分探索) を探し、無ければ、中ほどに挟まった別の言語 (島) を探す。
    /// 見つからなければ、部分そのもの 1 つ
    public static func locate(_ piece: SpeechChunk, guess: LanguageGuess?, map: SpeechMap,
                              detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Outcome {
        let b = try bisect(piece.range, map: map, detect: detect)
        var detections = b.detections
        if let cut = b.cut, let halves = SpeechChunker.split(piece, at: cut) {
            var switches: [Found] = []
            if let head = b.head, let tail = b.tail, let bracket = b.bracket {
                switches.append(Found(start: R.seconds(piece.range.lowerBound), end: R.seconds(piece.range.upperBound),
                                      head: head.language, tail: tail.language,
                                      bracketStart: R.seconds(bracket.lowerBound), bracketEnd: R.seconds(bracket.upperBound),
                                      cut: R.seconds(cut)))
            }
            return Outcome(parts: [Part(chunk: halves.0, guess: b.head), Part(chunk: halves.1, guess: b.tail)],
                           detections: detections, switches: switches)
        }
        // 両端が同じ言語なのに部分全体の判定が揺れる: 中ほどに別の言語が挟まっているかもしれない
        if let h = b.head, let t = b.tail, h.language == t.language, piece.range.count > R.samples(R.islandMaxSeconds) {
            let host = guess.flatMap { $0.language == h.language ? $0 : nil } ?? h
            let found = try islands(piece, host: host, map: map, detect: detect)
            detections += found.detections
            if found.parts.contains(where: { $0.guess?.language != h.language }) {
                return Outcome(parts: found.parts, detections: detections, switches: found.switches)
            }
        }
        return Outcome(parts: [Part(chunk: piece, guess: guess)], detections: detections, switches: [])
    }

    /// range の中の、間の無い切り替わりを二分探索で探す (refine.py の手順に、端の確かめと短い部分の扱いを足したもの)。
    ///
    /// 先頭と末尾の窓 (6 秒以上の部分は 4 秒、4〜6 秒の部分は 2 秒) の言語が違えば、そのあいだを探す。
    /// 6 秒以上で同じなら、切り替わりが端から 4 秒以内にあって 4 秒の窓では多い側の言語に聞こえている場合があるので、
    /// 先頭と末尾の 2 秒も確かめ、違えばそこから 2 秒の窓で探す (区切り方しだいで、切り替わりは端に寄る)
    public static func bisect(_ range: Range<Int>, map: SpeechMap,
                              detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Bisection {
        guard range.count >= R.samples(R.bisectMinSeconds) else {
            return Bisection(cut: nil, head: nil, tail: nil, bracket: nil, detections: 0)
        }
        let long = range.count >= R.samples(R.bisectLongSeconds)
        let edge = R.samples(R.edgeWindowSeconds)
        let window = long ? R.samples(R.bisectWindowSeconds) : edge
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
        guard long else {
            return Bisection(cut: nil, head: h, tail: t, bracket: nil, detections: detections)
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

    /// lo (言語 head) と hi (言語 tail) のあいだで、窓の言語が切り替わるところを探し、いちばん静かなところで切る。
    /// 窓の判定の確からしさが低いときは、その窓に両方の言語が入っている (切り替わりは窓の中): 幅を窓まで狭め、
    /// 2 秒の窓でさらに絞る (確からしさの低い判定のほうへ幅を動かすと、切り替わりを幅の外へ追い出してしまう)
    private static func search(_ range: Range<Int>, from start: Int, _ head: LanguageGuess, to end: Int, _ tail: LanguageGuess,
                               window: Int, map: SpeechMap, detections: Int,
                               detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Bisection {
        var detections = detections
        var lo = start, hi = max(start, end)
        var window = window
        let edge = R.samples(R.edgeWindowSeconds)
        var steps = 0
        let stop = R.samples(R.bisectStopSeconds)
        while hi - lo > stop, steps < R.bisectMaxSteps {
            let half = window / 2
            let mid = (lo + hi) / 2
            let probe = max(range.lowerBound, mid - half)..<min(range.upperBound, mid + half)
            guard let g = try detect(probe) else { break }
            detections += 1
            steps += 1
            if g.confidence < R.uncertainProbe {
                lo = max(lo, probe.lowerBound)
                hi = min(hi, probe.upperBound)
                if window > edge {
                    window = edge
                    continue
                }
                break
            }
            if g.language == head.language { lo = mid } else { hi = mid }
        }
        let margin = R.samples(R.cutSearchMarginSeconds)
        let searchStart = max(range.lowerBound + 1, lo - margin)
        let searchEnd = min(range.upperBound - 1, hi + margin)
        let cut = searchStart < searchEnd ? (map.quietestSample(in: searchStart..<searchEnd) ?? (lo + hi) / 2) : (lo + hi) / 2
        return Bisection(cut: cut, head: head, tail: tail, bracket: lo..<max(lo, hi), detections: detections)
    }

    /// 区切りの中ほどに挟まった、別の言語の短い発話 (英語の講義の中の、日本語の相づちや一言) を探す。
    ///
    /// whisper は、区切りの 2〜3 割までの別の言語をほとんど聞き取らず (多い側を 0.96〜0.99 と判定する)、英語で文字にすると、
    /// 日本語の部分を訳さずに飛ばす (点検にも何も残らない)。そこで、範囲を中ほどの 3 分の 1 のいちばん静かなところで
    /// 半分にし、両方を判定して、別の言語の確率が少しでもある側をさらに半分にしていく。4 秒以下になったら判定のとおりにし、
    /// 別の言語だと信じられる部分だけを分け出す。英日の朗読の試作では、1〜3 秒の日本語の差し込みを取り戻し、
    /// 英語だけの部分を日本語と取り違えることはなかった (英語の 4 秒以下の部分は、どれも英語 0.993 以上)
    /// floor: 半分を詳しく見る、別の言語の確率の下限
    public static func islands(_ chunk: SpeechChunk, host: LanguageGuess, map: SpeechMap, floor: Double = MixedLanguageRules.islandFloor,
                               detect: (Range<Int>) throws -> LanguageGuess?) rethrows -> Outcome {
        let maxIsland = R.samples(R.islandMaxSeconds)
        let minSpeech = R.samples(R.minDetectSpeechSeconds)
        let trimEdge = R.samples(R.islandTrimEdgeSeconds)
        var detections = 0
        var leaves: [(range: Range<Int>, island: LanguageGuess?)] = []
        func other(_ g: LanguageGuess) -> Double { g.language == host.language ? 1 - g.confidence : g.confidence }

        // (範囲, その範囲の判定, 4 秒以下になってから、もう一度だけ分けたものか)。深さは高々 4〜5 段
        var stack: [(range: Range<Int>, guess: LanguageGuess?, trimmed: Bool)] = [(chunk.range, host, false)]
        while let node = stack.popLast() {
            let range = node.range
            let speech = map.speechSamples(in: range)
            if range.count <= maxIsland || speech < 2 * minSpeech {
                if let g = node.guess, g.language != host.language,
                   LanguagePlanner.isTrusted(g, speechSeconds: R.seconds(speech)) {
                    leaves.append((range, g))
                } else if !node.trimmed, let g = node.guess, other(g) >= R.islandTrimOther, speech >= 2 * minSpeech,
                          range.count > 2 * trimEdge {
                    // 別の言語がかなり混ざっているが、信じられるほどではない (島が半分に割れた・端に寄っている):
                    // いちばん静かなところで 1 回だけ分けて、もう一度確かめる
                    let mid = (range.lowerBound + range.upperBound) / 2
                    let cut = map.quietestSample(in: (range.lowerBound + trimEdge)..<(range.upperBound - trimEdge), near: mid) ?? mid
                    for half in [range.lowerBound..<cut, cut..<range.upperBound] {
                        guard map.speechSamples(in: half) >= minSpeech else {
                            leaves.append((half, nil))
                            continue
                        }
                        let h = try detect(half)
                        detections += 1
                        if let h { stack.append((half, h, true)) } else { leaves.append((half, nil)) }
                    }
                } else {
                    leaves.append((range, nil))
                }
                continue
            }
            let third = range.count / 3
            let mid = (range.lowerBound + range.upperBound) / 2
            let cut = map.quietestSample(in: (range.lowerBound + third)..<(range.upperBound - third), near: mid) ?? mid
            for half in [range.lowerBound..<cut, cut..<range.upperBound] {
                guard map.speechSamples(in: half) >= minSpeech else {
                    leaves.append((half, nil))
                    continue
                }
                let g = try detect(half)
                detections += 1
                if let g, other(g) >= max(R.islandFloor, floor) {
                    stack.append((half, g, false))
                } else {
                    leaves.append((half, nil))
                }
            }
        }

        // 並べ直し、つながった同じ言語の部分をまとめる
        var groups: [(range: Range<Int>, island: LanguageGuess?)] = []
        for leaf in leaves.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = groups.last, last.island?.language == leaf.island?.language {
                let island: LanguageGuess? = {
                    guard let a = last.island, let b = leaf.island else { return nil }
                    return a.confidence >= b.confidence ? a : b
                }()
                groups[groups.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, leaf.range.upperBound), island)
            } else {
                groups.append(leaf)
            }
        }
        var parts: [Part] = []
        var found: [Found] = []
        for group in groups {
            let spans = map.spans(in: group.range)
            guard let first = spans.first, let last = spans.last else { continue }
            let piece = SpeechChunk(range: first.lowerBound..<last.upperBound, spans: spans,
                                    forcedCutBefore: parts.isEmpty && chunk.forcedCutBefore)
            if let island = group.island {
                parts.append(Part(chunk: piece, guess: island))
                found.append(Found(start: R.seconds(chunk.range.lowerBound), end: R.seconds(chunk.range.upperBound),
                                   head: host.language, tail: island.language,
                                   bracketStart: R.seconds(group.range.lowerBound), bracketEnd: R.seconds(group.range.upperBound),
                                   cut: R.seconds(piece.range.lowerBound), kind: "island"))
            } else {
                parts.append(Part(chunk: piece, guess: host))
            }
        }
        if parts.isEmpty { parts = [Part(chunk: chunk, guess: host)] }
        return Outcome(parts: parts, detections: detections, switches: found)
    }
}
