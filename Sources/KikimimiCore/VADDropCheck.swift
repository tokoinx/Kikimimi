import Foundation

/// 無音を飛ばす機能 (VAD) が、声ではない音と見なして、大事な音まで飛ばしたらしいかを決める。
///
/// VAD (silero) は話し声のための物で、伴奏つきの歌を声と見なさない事がある (153.9 秒の歌で、4 秒ぶんしか残らなかった)。
/// その時は、ずっと音が鳴っているのに、文字起こしの結果の区間が少ない。
/// 反対に、講演の間・長い無音・話の少ない静かな録音では、飛ばされた所が静かなので、飛ばされても困らない。
/// そこで、結果の区間に入らなかった所のうち、結果の区間と同じくらい大きな音の所が、音の長さの半分以上あるかを見る。
public enum VADDropCheck {
    /// これより短い音は確かめない (秒)。短い録音では、間の割合が大きくぶれる
    public static let minimumSeconds = 20.0
    /// 音を切るコマの長さ (秒)
    public static let frameSeconds = 0.5
    /// 結果の区間に、コマの長さのこの割合以上かかるコマを「残った所」とする
    public static let keptOverlap = 0.5
    /// 結果が空の時、全部のコマの RMS のこの順位 (パーセンタイル) を、基準の大きさにする
    public static let fallbackPercentile = 0.9
    /// 基準の大きさのこの倍以上 (約 −10 dB) の、飛ばされたコマを「大きな音なのに飛ばされた所」と数える
    public static let loudRatio: Float = 0.3
    /// RMS がこれより小さいコマ (約 −50 dBFS) は、基準が何であっても数えない (全体がほぼ無音の録音を拾わないため)
    public static let quietFloor: Float = 0.003
    /// 「大きな音なのに飛ばされた所」が、音の長さのこの割合以上なら、飛ばし過ぎと見る
    public static let droppedShare = 0.5

    /// 確かめた結果 (診断の表示にも使う)
    public struct Assessment: Sendable, Equatable {
        /// 音の長さ (秒)
        public var totalSeconds: Double
        /// 結果の区間に入った所の長さ (秒。コマの数 × コマの長さ)
        public var keptSeconds: Double
        /// 大きな音なのに、結果の区間に入らなかった所の長さ (秒)
        public var loudDroppedSeconds: Double
        /// 大事な音まで飛ばしたらしい
        public var looksDropped: Bool

        public init(totalSeconds: Double, keptSeconds: Double, loudDroppedSeconds: Double, looksDropped: Bool) {
            self.totalSeconds = totalSeconds
            self.keptSeconds = keptSeconds
            self.loudDroppedSeconds = loudDroppedSeconds
            self.looksDropped = looksDropped
        }
    }

    /// VAD が大事な音まで飛ばしたらしいか。
    /// - Parameters:
    ///   - samples: 音 (モノラル)
    ///   - sampleRate: 1 秒あたりのサンプルの数
    ///   - segments: 文字起こしの結果の区間の、始めと終わりの秒
    public static func looksDropped(samples: [Float], sampleRate: Int, segments: [ClosedRange<Double>]) -> Bool {
        assess(samples: samples, sampleRate: sampleRate, segments: segments).looksDropped
    }

    /// looksDropped と同じ決め方で、長さも返す
    public static func assess(samples: [Float], sampleRate: Int, segments: [ClosedRange<Double>]) -> Assessment {
        let total = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        let frameLength = Int((frameSeconds * Double(sampleRate)).rounded())
        guard total >= minimumSeconds, frameLength > 0 else {
            return Assessment(totalSeconds: total, keptSeconds: 0, loudDroppedSeconds: 0, looksDropped: false)
        }
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else {
            return Assessment(totalSeconds: total, keptSeconds: 0, loudDroppedSeconds: 0, looksDropped: false)
        }

        // コマごとの大きさ (RMS)
        var rms = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for i in 0..<frameCount {
                var sum: Float = 0
                let base = i * frameLength
                for j in base..<(base + frameLength) {
                    let v = buffer[j]
                    sum += v * v
                }
                rms[i] = (sum / Float(frameLength)).squareRoot()
            }
        }

        // 結果の区間を、重なりをまとめて時刻の順にする
        let merged = merge(segments)
        var kept = [Bool](repeating: false, count: frameCount)
        var cursor = 0
        for i in 0..<frameCount {
            let a = Double(i) * frameSeconds
            let b = a + frameSeconds
            // このコマより前に終わる区間は、もう見ない
            while cursor < merged.count, merged[cursor].upperBound <= a { cursor += 1 }
            var overlap = 0.0
            var k = cursor
            while k < merged.count, merged[k].lowerBound < b {
                overlap += max(0, min(b, merged[k].upperBound) - max(a, merged[k].lowerBound))
                k += 1
            }
            kept[i] = overlap >= frameSeconds * keptOverlap
        }

        let keptLevels = zip(rms, kept).filter { $0.1 }.map(\.0)
        let reference: Float
        if keptLevels.isEmpty {
            reference = percentile(rms, fallbackPercentile)
        } else {
            reference = percentile(keptLevels, 0.5)
        }
        let threshold = reference * loudRatio
        var loudDropped = 0
        for i in 0..<frameCount where !kept[i] {
            if rms[i] >= quietFloor && rms[i] >= threshold { loudDropped += 1 }
        }
        let keptCount = kept.filter { $0 }.count
        return Assessment(totalSeconds: total,
                          keptSeconds: Double(keptCount) * frameSeconds,
                          loudDroppedSeconds: Double(loudDropped) * frameSeconds,
                          looksDropped: Double(loudDropped) >= Double(frameCount) * droppedShare)
    }

    /// 結果の文字の数 (空白を除いた、全区間の文字の合計)。やり直した結果と比べる時に使う
    public static func letterCount(of segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { sum, segment in
            sum + segment.text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        }
    }

    /// やり直した結果を採る条件: やり直した結果の文字の数が、初めの結果のこの倍以上、かつ、この字数以上多い。
    /// 静かな話し声に続く雑音が在る録音では、判定 (`assess`) が誤って働く事がある。その時、VAD なしの結果が
    /// 雑音から少し文字を足しただけで採られないようにする (実機の歌では 7 字 → 209 字だったので、これで採られる)
    public static let retryMinimumRatio = 1.5
    public static let retryMinimumExtraLetters = 20

    /// やり直した結果を採るか (文字の数が、はっきり多い時だけ。決め方は `retryMinimumRatio`・`retryMinimumExtraLetters`)
    public static func prefersRetry(first: [TranscriptSegment], retry: [TranscriptSegment]) -> Bool {
        let a = letterCount(of: first), b = letterCount(of: retry)
        return Double(b) >= Double(a) * retryMinimumRatio && b >= a + retryMinimumExtraLetters
    }

    private static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite }
            .sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Double>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// values の p (0〜1) の順位の値 (近い順位の値を使う)
    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(0, index), sorted.count - 1)]
    }
}
