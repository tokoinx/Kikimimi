import Foundation

/// 音声のどこで話しているか (VAD の結果)。位置はサンプル番号 (16 kHz)。
public struct SpeechMap: Hashable, Sendable {
    /// 発話の区間 (昇順で、重ならない)
    public var spans: [Range<Int>]
    /// `hop` サンプルごとの静かさの目安 (小さいほど静か)。VAD があれば発話らしさ、無ければ音の大きさ (RMS)
    public var levels: [Float]
    public var hop: Int
    public var totalSamples: Int
    /// VAD で発話を探した (false なら、全体を発話とみなしている)
    public var fromVAD: Bool

    public init(spans: [Range<Int>], levels: [Float] = [], hop: Int = 512, totalSamples: Int, fromVAD: Bool = true) {
        self.totalSamples = max(0, totalSamples)
        // 範囲の外・空・重なりを除いて昇順にそろえる
        var cleaned: [Range<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let s = max(0, span.lowerBound)..<min(self.totalSamples, max(span.lowerBound, span.upperBound))
            guard !s.isEmpty else { continue }
            if let last = cleaned.last, s.lowerBound < last.upperBound {
                cleaned[cleaned.count - 1] = last.lowerBound..<max(last.upperBound, s.upperBound)
            } else {
                cleaned.append(s)
            }
        }
        self.spans = cleaned
        self.levels = levels
        self.hop = max(1, hop)
        self.fromVAD = fromVAD
    }

    /// VAD が無いとき: 全体を発話とみなし、音の大きさ (hop ごとの RMS) を静かさの目安にする
    public static func withoutVAD(_ samples: [Float], hop: Int = 512) -> SpeechMap {
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + hop)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            levels.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        return SpeechMap(spans: samples.isEmpty ? [] : [0..<samples.count], levels: levels, hop: hop,
                         totalSamples: samples.count, fromVAD: false)
    }

    /// range と重なる発話の区間 (range の中に切り詰めたもの)
    public func spans(in range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var i = firstSpan(endingAfter: range.lowerBound)
        while i < spans.count, spans[i].lowerBound < range.upperBound {
            let s = max(spans[i].lowerBound, range.lowerBound)..<min(spans[i].upperBound, range.upperBound)
            if !s.isEmpty { out.append(s) }
            i += 1
        }
        return out
    }

    /// range の中で話しているサンプル数
    public func speechSamples(in range: Range<Int>) -> Int {
        spans(in: range).reduce(0) { $0 + $1.count }
    }

    public var totalSpeechSamples: Int { spans.reduce(0) { $0 + $1.count } }

    /// 終わりが position より後ろにある最初の区間 (二分探索)
    private func firstSpan(endingAfter position: Int) -> Int {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].upperBound <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// range の中でいちばん静かなところ (hop の区切りの真ん中)。ほぼ同じ静かさなら target に近いところ。
    /// 目安が無ければ target (無ければ range の真ん中)
    public func quietestSample(in range: Range<Int>, near target: Int? = nil) -> Int? {
        guard !range.isEmpty else { return nil }
        let goal = target ?? (range.lowerBound + range.upperBound) / 2
        let k0 = max(0, range.lowerBound / hop)
        let k1 = min(levels.count, (range.upperBound - 1) / hop + 1)
        guard k0 < k1 else { return min(max(goal, range.lowerBound), range.upperBound - 1) }
        var lowest = Float.infinity
        for k in k0..<k1 { lowest = min(lowest, levels[k]) }
        // VAD の確率は 0.001 刻み程度なので、それより小さな差は同じとみなす
        let tolerance = max(Float(0.001), abs(lowest) * 0.01)
        var best: Int? = nil
        var bestDistance = Int.max
        for k in k0..<k1 where levels[k] <= lowest + tolerance {
            let center = min(max(k * hop + hop / 2, range.lowerBound), range.upperBound - 1)
            let d = abs(center - goal)
            if d < bestDistance {
                best = center
                bestDistance = d
            }
        }
        return best
    }
}

/// 言語を判定する 1 区切り (いくつかの発話のまとまり)
public struct SpeechChunk: Hashable, Sendable {
    /// 最初の発話の始まりから、最後の発話の終わりまで
    public var range: Range<Int>
    /// 中の発話 (range の中に切り詰めたもの)
    public var spans: [Range<Int>]
    /// この区切りの前で、強制的に切った (話者の切り替わり。前の区切りの言語を借りない)
    public var forcedCutBefore: Bool

    public init(range: Range<Int>, spans: [Range<Int>], forcedCutBefore: Bool = false) {
        self.range = range
        self.spans = spans
        self.forcedCutBefore = forcedCutBefore
    }

    public var speechSamples: Int { spans.reduce(0) { $0 + $1.count } }
    public var speechSeconds: Double { MixedLanguageRules.seconds(speechSamples) }
    public var seconds: Double { MixedLanguageRules.seconds(range.count) }
}

/// 発話を、言語を判定する区切りにまとめる
public enum SpeechChunker {
    private typealias R = MixedLanguageRules

    /// 発話を、間を空けずに `maxChunkSeconds` 以内の区切りに詰める。長すぎるまとまりは、いちばん長い間で分ける
    /// (両側に `minSideSeconds` 以上残る間を優先する)。forcedCuts (話者の切り替わり) では必ず切る。
    public static func chunks(_ map: SpeechMap, forcedCuts: [Int] = []) -> [SpeechChunk] {
        let cuts = forcedCuts.sorted()
        let margin = R.samples(R.forcedCutMarginSeconds)
        // 1) 発話の途中にある切れ目で、発話を分ける
        var pieces: [(span: Range<Int>, endsAtCut: Bool)] = []
        for span in map.spans {
            var start = span.lowerBound
            for c in cuts where c > start + margin && c < span.upperBound - margin {
                pieces.append((start..<c, true))
                start = c
            }
            pieces.append((start..<span.upperBound, false))
        }
        guard !pieces.isEmpty else { return [] }
        // 2) 切れ目 (発話の途中、または発話と発話の間) で、まとまりを分ける
        var groups: [[Range<Int>]] = []
        var forcedBefore: [Bool] = []
        var current: [Range<Int>] = [pieces[0].span]
        var currentForced = false
        for k in 1..<pieces.count {
            let previous = pieces[k - 1]
            // 間の中の切れ目と、発話の端のすぐそば (margin 以内。発話は切らなかった) の切れ目は、この間で切る
            let gapStart = previous.span.upperBound, gapEnd = pieces[k].span.lowerBound
            let cutInGap = cuts.contains { $0 >= gapStart - margin && $0 <= gapEnd + margin }
            if previous.endsAtCut || cutInGap {
                groups.append(current)
                forcedBefore.append(currentForced)
                current = [pieces[k].span]
                currentForced = true
            } else {
                current.append(pieces[k].span)
            }
        }
        groups.append(current)
        forcedBefore.append(currentForced)

        // 3) 長すぎるまとまりを分ける
        var chunks: [SpeechChunk] = []
        let maxLength = R.samples(R.maxChunkSeconds)
        let minSide = R.samples(R.minSideSeconds)
        for (group, forced) in zip(groups, forcedBefore) {
            var parts: [[Range<Int>]] = []
            splitGroup(group, maxLength: maxLength, minSide: minSide, into: &parts)
            for (n, part) in parts.enumerated() {
                let range = part[0].lowerBound..<part[part.count - 1].upperBound
                let first = n == 0 && forced
                if range.count <= maxLength {
                    chunks.append(SpeechChunk(range: range, spans: part, forcedCutBefore: first))
                } else {
                    // 1 つの発話が長すぎる: いちばん静かなところで切る
                    for (m, sub) in splitSpan(range, map: map, maxLength: maxLength, minSide: minSide).enumerated() {
                        chunks.append(SpeechChunk(range: sub, spans: [sub], forcedCutBefore: first && m == 0))
                    }
                }
            }
        }
        return chunks
    }

    /// まとまりを、いちばん長い間で分けることを、どれも maxLength 以内になるまでくり返す (pipeline.py の P2 と同じ)。
    /// 2 時間の録音では発話が数千あり、間の長さがそろうと分け方が偏って深くなるので、再帰を使わずに手元の積み上げで進める
    /// (文字起こしのスレッドのスタックは小さい)
    private static func splitGroup(_ group: [Range<Int>], maxLength: Int, minSide: Int, into out: inout [[Range<Int>]]) {
        guard !group.isEmpty else { return }
        var stack: [Range<Int>] = [0..<group.count]   // group の添字の範囲。左から順に取り出す
        while let r = stack.popLast() {
            let first = r.lowerBound, last = r.upperBound - 1
            let length = group[last].upperBound - group[first].lowerBound
            if length <= maxLength || r.count == 1 {
                out.append(Array(group[r]))
                continue
            }
            var best: (ok: Bool, gap: Int)? = nil
            var bestIndex = first
            for i in first..<last {
                let gap = group[i + 1].lowerBound - group[i].upperBound
                let left = group[i].upperBound - group[first].lowerBound
                let right = group[last].upperBound - group[i + 1].lowerBound
                let ok = left >= minSide && right >= minSide
                if let b = best {
                    if (ok && !b.ok) || (ok == b.ok && gap > b.gap) {
                        best = (ok, gap)
                        bestIndex = i
                    }
                } else {
                    best = (ok, gap)
                    bestIndex = i
                }
            }
            // 右を先に積み、左から取り出す (時刻の順に並ぶ)
            stack.append((bestIndex + 1)..<r.upperBound)
            stack.append(first..<(bestIndex + 1))
        }
    }

    /// 長すぎる 1 つの発話を、いちばん静かなところで、できるだけ少ない数に分ける (どれも maxLength 以内)
    private static func splitSpan(_ range: Range<Int>, map: SpeechMap, maxLength: Int, minSide: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxLength {
            let rest = range.upperBound - start
            let parts = (rest + maxLength - 1) / maxLength
            // 左を maxLength 以内にし、右の残りが parts - 1 個に収まる範囲で、両側に minSide を残す
            var lo = max(start + minSide, range.upperBound - (parts - 1) * maxLength)
            var hi = min(range.upperBound - minSide, start + maxLength)
            if lo >= hi {
                lo = start + rest / parts
                hi = lo + 1
            }
            let ideal = start + rest / parts
            let cut = map.quietestSample(in: lo..<hi, near: ideal) ?? ideal
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<range.upperBound)
        return out
    }

    /// VAD が無いとき: `fixedChunkSeconds` ごとに区切り、区切りを前後 `fixedChunkSearchSeconds` の中のいちばん静かなところへずらす
    public static func fixedChunks(_ map: SpeechMap) -> [SpeechChunk] {
        let total = map.totalSamples
        guard total > 0 else { return [] }
        let length = R.samples(R.fixedChunkSeconds)
        let search = R.samples(R.fixedChunkSearchSeconds)
        var chunks: [SpeechChunk] = []
        var start = 0
        while start < total {
            var end = total
            if total - start > length + search {
                let target = start + length
                end = map.quietestSample(in: (target - search)..<(target + search), near: target) ?? target
            }
            chunks.append(SpeechChunk(range: start..<end, spans: [start..<end]))
            start = end
        }
        return chunks
    }

    /// 区切りを、中のいちばん長い間 (最大 2 か所) で分ける。どの部分も `pieceMinSeconds` 以上になる間だけを使う
    /// (refine.py と同じ)。分けられなければ、区切りそのもの 1 つ
    public static func pieces(of chunk: SpeechChunk) -> [SpeechChunk] {
        let spans = chunk.spans
        guard spans.count >= 2 else { return [chunk] }
        let minLength = R.samples(R.pieceMinSeconds)
        let gaps = (0..<(spans.count - 1))
            .map { (gap: spans[$0 + 1].lowerBound - spans[$0].upperBound, index: $0) }
            .sorted { $0.gap != $1.gap ? $0.gap > $1.gap : $0.index > $1.index }
        var cuts: [Int] = []
        for g in gaps {
            if cuts.count == 2 { break }
            let candidate = (cuts + [g.index]).sorted()
            if groups(spans, cutAfter: candidate).allSatisfy({ $0[$0.count - 1].upperBound - $0[0].lowerBound >= minLength }) {
                cuts = candidate
            }
        }
        guard !cuts.isEmpty else { return [chunk] }
        return groups(spans, cutAfter: cuts).enumerated().map { n, group in
            SpeechChunk(range: group[0].lowerBound..<group[group.count - 1].upperBound, spans: group,
                        forcedCutBefore: n == 0 && chunk.forcedCutBefore)
        }
    }

    private static func groups(_ spans: [Range<Int>], cutAfter cuts: [Int]) -> [[Range<Int>]] {
        var out: [[Range<Int>]] = []
        var start = 0
        for c in cuts {
            out.append(Array(spans[start...c]))
            start = c + 1
        }
        out.append(Array(spans[start...]))
        return out
    }

    /// 区切りを position で 2 つに分ける (間の無い切り替わり)。どちらかが空になるなら nil
    public static func split(_ chunk: SpeechChunk, at position: Int) -> (SpeechChunk, SpeechChunk)? {
        guard position > chunk.range.lowerBound, position < chunk.range.upperBound else { return nil }
        let left = chunk.spans.compactMap { s -> Range<Int>? in
            let end = min(s.upperBound, position)
            return s.lowerBound < end ? s.lowerBound..<end : nil
        }
        let right = chunk.spans.compactMap { s -> Range<Int>? in
            let start = max(s.lowerBound, position)
            return start < s.upperBound ? start..<s.upperBound : nil
        }
        return (SpeechChunk(range: chunk.range.lowerBound..<position, spans: left, forcedCutBefore: chunk.forcedCutBefore),
                SpeechChunk(range: position..<chunk.range.upperBound, spans: right))
    }
}
