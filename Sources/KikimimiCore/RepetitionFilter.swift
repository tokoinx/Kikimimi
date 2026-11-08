import Foundation

/// Whisper の「繰り返しの暴走」の後始末。
///
/// Whisper は音楽や雑音のところで、同じ文を何度も出し続けることがある。
/// 認識のしかた自体は WhisperContext 側で直しているが、それでも残った分をここで片付ける。
/// 実際に何度か言った言葉 (「help each other」を 3 回など) は残るよう、条件は控えめにしている。
public enum RepetitionFilter {
    /// 同じ区間がこの回数以上つづいたら暴走とみなし、最初の 1 つだけ残す
    public static let minimumRun = 4
    /// 2〜3 区間の組がこの周回数以上つづいたら暴走とみなし、最初の 1 周だけ残す
    public static let minimumCycles = 3

    /// 比較用のキー: 互換文字をそろえ (NFKC)、小文字にし、句読点・記号・空白を除く
    static func key(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let scalars = folded.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// 1 区間の中で、3 文字以上のまとまりが 4 回以上つづいたら 1 回にまとめる。
    /// 例: 「音楽の音楽の音楽の音楽の…」→「音楽の」。「どんどんどんどん」のような 2 文字の繰り返しは残す。
    public static func collapseInlineRepeats(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(.{3,40}?)\\1{3,}", options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
    }

    /// 区間の並びから、同じ区間 (または 2〜3 区間の組) が延々と続く部分を、最初の 1 回だけにする。
    public static func collapseLoops(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let keys = segments.map { key($0.text) }
        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)
        var i = 0
        while i < segments.count {
            if let end = loopEnd(keys, from: i) {
                out.append(contentsOf: segments[i..<end.firstCycleEnd])
                i = end.loopEnd
            } else {
                out.append(segments[i])
                i += 1
            }
        }
        return out
    }

    /// i から暴走が始まっていれば、最初の 1 周の終わりと暴走全体の終わりを返す
    private static func loopEnd(_ keys: [String], from i: Int) -> (firstCycleEnd: Int, loopEnd: Int)? {
        for period in 1...3 {
            guard i + period <= keys.count else { break }
            let unit = Array(keys[i..<(i + period)])
            guard unit.allSatisfy({ !$0.isEmpty }) else { continue }
            // 「A A」のような組は周期 1 として扱う
            if period > 1, Set(unit).count < period { continue }
            var cycles = 1
            var j = i + period
            while j + period <= keys.count, Array(keys[j..<(j + period)]) == unit {
                cycles += 1
                j += period
            }
            let needed = period == 1 ? minimumRun : minimumCycles
            if cycles >= needed {
                return (i + period, j)
            }
        }
        return nil
    }

    /// 仕上げ: 各区間の中の繰り返しをまとめ、空になった区間を除き、区間の繰り返しをまとめる
    public static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let inline = segments.compactMap { segment -> TranscriptSegment? in
            var s = segment
            s.text = collapseInlineRepeats(s.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.text.isEmpty ? nil : s
        }
        return collapseLoops(inline)
    }

    /// 認識中に 1 区間ずつ届くものを、その場でふるいにかける (画面への途中表示用)。
    /// 同じ区間の 4 回目以降は出さない。最終結果は `clean` でまとめ直す。
    public struct Streaming: Sendable {
        private var lastKey = ""
        private var run = 0

        public init() {}

        public mutating func accept(_ text: String) -> Bool {
            let k = RepetitionFilter.key(text)
            if !k.isEmpty, k == lastKey {
                run += 1
            } else {
                lastKey = k
                run = 1
            }
            return run < RepetitionFilter.minimumRun
        }
    }
}
