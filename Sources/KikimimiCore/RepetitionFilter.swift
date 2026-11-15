import Foundation

/// Whisper の「繰り返しの暴走」の後始末。
///
/// Whisper は音楽や雑音のところで、同じ文を何度も出し続けることがある。
/// 認識のしかた自体は WhisperContext 側で直しているが、それでも残った分をここで片付ける。
/// 実際に何度か言った言葉 (「help each other」を 3 回、「No, no, no, no, no.」など) は残るよう、条件は控えめにしている。
public enum RepetitionFilter {
    /// 同じ区間がこの回数以上つづいたら暴走とみなし、最初の 1 つだけ残す
    public static let minimumRun = 4
    /// 2〜3 区間の組がこの周回数以上つづいたら暴走とみなし、最初の 1 周だけ残す
    public static let minimumCycles = 3
    /// 繰り返しとみなすのは、次の区間がこの秒数以内に続くときだけ。
    /// 数分おきに同じことを言う場面 (受付の「次の方、どうぞ」など) を消さないため。
    public static let maximumGap: TimeInterval = 30
    /// 1 区間の中で、文字を含むまとまりがこの回数以上つづいたら 1 回にまとめる
    public static let minimumInlineCopies = 6
    /// 数字・記号だけ、または数を表す言葉だけのまとまりは、金額や番号を変えないよう、もっと多く続いたときだけまとめる
    public static let minimumNumericInlineCopies = 10

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

    static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "hundred", "thousand", "million", "billion", "trillion", "ゼロ", "れい", "まる",
    ]
    static let kanjiNumerals = CharacterSet(charactersIn: "〇零一二三四五六七八九十百千万億兆")

    /// 数字・記号だけ、または数を表す言葉だけでできているか
    static func isNumberLike(_ unit: String) -> Bool {
        let words = unit.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        if words.isEmpty { return true }
        return words.allSatisfy { word in
            numberWords.contains(word) || word.unicodeScalars.allSatisfy { kanjiNumerals.contains($0) }
        }
    }

    /// 1 区間の中で、3 文字以上のまとまりが何度もつづいたら 1 回にまとめる。
    /// 例: 「音楽の」が 57 回 →「音楽の」。「どんどんどんどん」(2 文字) や「No, no, no, no, no.」(5 回) は残す。
    /// 「1,000,000,000,000」のような数字は、10 回以上続かない限り縮めない。
    public static func collapseInlineRepeats(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(.{3,40}?)\\1{\(minimumInlineCopies - 1),}",
                                                   options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let ns = NSString(string: text)
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let unitRange = match.range(at: 1)
            guard unitRange.length > 0 else { continue }
            let unit = ns.substring(with: unitRange)
            let copies = match.range.length / unitRange.length
            if isNumberLike(unit), copies < minimumNumericInlineCopies { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += unit
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 区間の並びから、同じ区間 (または 2〜3 区間の組) が間を空けずに延々と続く部分を、最初の 1 回だけにする。
    public static func collapseLoops(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let keys = segments.map { key($0.text) }
        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)
        var i = 0
        while i < segments.count {
            if let end = loopEnd(segments, keys, from: i) {
                out.append(contentsOf: segments[i..<end.firstCycleEnd])
                i = end.loopEnd
            } else {
                out.append(segments[i])
                i += 1
            }
        }
        return out
    }

    /// range の中で隣り合う区間が、どれも maximumGap 以内に続いているか
    private static func closeTogether(_ segments: [TranscriptSegment], _ range: Range<Int>) -> Bool {
        guard range.count > 1 else { return true }
        for k in (range.lowerBound + 1)..<range.upperBound where segments[k].start - segments[k - 1].end > maximumGap {
            return false
        }
        return true
    }

    /// i から暴走が始まっていれば、最初の 1 周の終わりと暴走全体の終わりを返す
    private static func loopEnd(_ segments: [TranscriptSegment], _ keys: [String],
                                from i: Int) -> (firstCycleEnd: Int, loopEnd: Int)? {
        for period in 1...3 {
            guard i + period <= keys.count else { break }
            let unit = Array(keys[i..<(i + period)])
            guard unit.allSatisfy({ !$0.isEmpty }) else { continue }
            // 「A A」のような組は周期 1 として扱う
            if period > 1, Set(unit).count < period { continue }
            guard closeTogether(segments, i..<(i + period)) else { continue }
            var cycles = 1
            var j = i + period
            while j + period <= keys.count,
                  Array(keys[j..<(j + period)]) == unit,
                  closeTogether(segments, (j - 1)..<(j + period)) {
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
    /// 間を空けずに続く同じ区間の 4 回目以降は出さない。最終結果は `clean` でまとめ直す。
    public struct Streaming: Sendable {
        private var lastKey = ""
        private var lastEnd: TimeInterval = -.infinity
        private var run = 0

        public init() {}

        public mutating func accept(_ segment: TranscriptSegment) -> Bool {
            let k = RepetitionFilter.key(segment.text)
            if !k.isEmpty, k == lastKey, segment.start - lastEnd <= RepetitionFilter.maximumGap {
                run += 1
            } else {
                lastKey = k
                run = 1
            }
            lastEnd = segment.end
            return run < RepetitionFilter.minimumRun
        }
    }
}
