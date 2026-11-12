import Foundation

/// 書き取り (聞いた文を打つ) の答え合わせ。打った文と行の文を、語ごとに比べる。
///
/// 比べ方:
/// - 語は空白で区切る。語の前後の記号 (。,!?"' など) は取って比べる。大文字と小文字は区別しない。
///   引用符・アポストロフィの形 (’ ‘ ` ´ と ') は区別しない。全角の英数字は半角とみなす。記号だけの語は数えない。
/// - "don't" は 1 語のまま。数は打ったとおりに比べる ("3" と "three" は違う)。
/// - 語の中のハイフン (-, ‐, ‑ と – —) は区切りとみなし、前と後を別の語として比べる。だから "well-known" に
///   "well known" と打っても、"well known" に "well-known" と打っても合う。結果でも 2 語として出る。
/// - 2 つの語の並びは、直す手間がいちばん少なくなるように合わせる (編集距離。入れ替え・抜け・余計 はどれも 1)。
///   手間が同じなら、前から見て 入れ替え、抜け、余計 の順に選ぶ ("wellknown" は "well" の打ち違いで、"known" が抜け)。
/// - 行の文にラテン文字が 1 つもなく、ほかの文字があるとき (日本語など、空白で語を区切らない文) は、
///   語ではなく 1 文字ずつ比べる (空白と記号は数えない)。
///
/// 結果の語は、記号を取ったあとの、書いてあるとおり (大文字もそのまま) の形。
public enum DictationCheck {
    /// 何で比べたか
    public enum Mode: Hashable, Sendable {
        /// 語ごと (結果を並べるときは空白で区切る)
        case words
        /// 1 文字ずつ (結果を並べるときは区切らない)
        case characters
    }

    /// 結果の 1 つ
    public enum Piece: Hashable, Sendable {
        /// 合っている (行の語)
        case correct(String)
        /// 違う語を打った
        case wrong(expected: String, typed: String)
        /// 行にある語を打っていない
        case missing(String)
        /// 行にない語を打った
        case extra(String)
    }

    /// 答え合わせの結果
    public struct Result: Hashable, Sendable {
        /// 行の順に並んだ結果 (余計な語は、打った場所に入る)
        public var pieces: [Piece]
        public var mode: Mode
        /// 合っている語の数
        public var correctCount: Int
        /// 行の語の数
        public var expectedCount: Int
        /// 余計に打った語の数
        public var extraCount: Int

        public init(pieces: [Piece], mode: Mode) {
            self.pieces = pieces
            self.mode = mode
            var correct = 0, expected = 0, extra = 0
            for p in pieces {
                switch p {
                case .correct:
                    correct += 1
                    expected += 1
                case .wrong, .missing:
                    expected += 1
                case .extra:
                    extra += 1
                }
            }
            self.correctCount = correct
            self.expectedCount = expected
            self.extraCount = extra
        }

        /// すべて合っていて、余計な語もない
        public var isPerfect: Bool { correctCount == expectedCount && extraCount == 0 }

        /// 合っている割合 (0〜1): 合っている語の数 ÷ (行の語の数 + 余計な語の数)。
        /// 余計な語も割合を下げる。行が空で何も打っていなければ 1
        public var accuracy: Double {
            let total = expectedCount + extraCount
            guard total > 0 else { return 1 }
            return Double(correctCount) / Double(total)
        }
    }

    /// 打った文 typed を、行の文 expected と比べる
    public static func check(typed: String, expected: String) -> Result {
        let mode = mode(for: expected)
        let a = units(expected, mode: mode)
        let b = units(typed, mode: mode)
        return Result(pieces: align(a, b), mode: mode)
    }

    /// 比べ方を決める: 行の文にラテン文字がなく、ほかの文字 (かな・漢字など) があれば 1 文字ずつ。数と記号だけなら語ごと
    public static func mode(for expected: String) -> Mode {
        var hasLetter = false
        for scalar in expected.unicodeScalars {
            if isLatinLetter(scalar) { return .words }
            if scalar.properties.isAlphabetic { hasLetter = true }
        }
        return hasLetter ? .characters : .words
    }

    /// 比べる単位 (語、または 1 文字) に分けたもの。前後の記号を取った、書いてあるとおりの形
    public static func tokens(_ text: String, mode: Mode = .words) -> [String] {
        units(text, mode: mode).map(\.text)
    }

    // MARK: 中のしくみ

    private struct Unit {
        var text: String
        var key: String
    }

    /// 全角の英字・ラテン文字の拡張も含めて、ラテン文字か
    private static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        guard s.properties.isAlphabetic else { return false }
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true
        default: return false
        }
    }

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}",
                                                  "\u{2015}"]

    /// 前後から取る記号かどうか
    private static func isEdgeMark(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            CharacterSet.punctuationCharacters.contains(s) || CharacterSet.symbols.contains(s)
        }
    }

    private static func units(_ text: String, mode: Mode) -> [Unit] {
        switch mode {
        case .words:
            var result: [Unit] = []
            for word in text.split(whereSeparator: { $0.isWhitespace }) {
                for part in word.split(whereSeparator: { hyphens.contains($0) }) {
                    let core = trimmed(part)
                    guard !core.isEmpty else { continue }
                    result.append(Unit(text: core, key: key(core)))
                }
            }
            return result
        case .characters:
            return text.compactMap { c in
                guard !c.isWhitespace, !isEdgeMark(c) else { return nil }
                let s = String(c)
                return Unit(text: s, key: key(s))
            }
        }
    }

    /// 前後の記号を取る
    private static func trimmed(_ part: Substring) -> String {
        var s = part[...]
        while let c = s.first, isEdgeMark(c) { s = s.dropFirst() }
        while let c = s.last, isEdgeMark(c) { s = s.dropLast() }
        return String(s)
    }

    /// 比べるための形: 全角を半角に、アポストロフィの形をそろえ、小文字に
    private static func key(_ s: String) -> String {
        var k = s.precomposedStringWithCompatibilityMapping
        for mark in ["\u{2019}", "\u{2018}", "\u{02BC}", "`", "\u{00B4}", "\u{2032}"] {
            k = k.replacingOccurrences(of: mark, with: "'")
        }
        return k.lowercased()
    }

    /// 編集距離で 2 つの並びを合わせる (時間と場所は 行の語の数 × 打った語の数)。
    /// 後ろから手間を数え、前からたどる (手間が同じなら、前のほうで 入れ替え・抜け・余計 の順に選ぶ)
    private static func align(_ a: [Unit], _ b: [Unit]) -> [Piece] {
        let n = a.count, m = b.count
        let width = m + 1
        // cost[i * width + j]: a の i 個目から後と、b の j 個目から後を合わせる手間
        var cost = [Int](repeating: 0, count: (n + 1) * width)
        for j in 0...m { cost[n * width + j] = m - j }
        var i = n - 1
        while i >= 0 {
            cost[i * width + m] = n - i
            var j = m - 1
            while j >= 0 {
                let same = a[i].key == b[j].key
                let diagonal = cost[(i + 1) * width + j + 1] + (same ? 0 : 1)
                let down = cost[(i + 1) * width + j] + 1
                let right = cost[i * width + j + 1] + 1
                cost[i * width + j] = min(diagonal, down, right)
                j -= 1
            }
            i -= 1
        }
        // 前からたどる
        var pieces: [Piece] = []
        pieces.reserveCapacity(max(n, m))
        i = 0
        var j = 0
        while i < n || j < m {
            let here = cost[i * width + j]
            if i < n && j < m {
                let same = a[i].key == b[j].key
                if here == cost[(i + 1) * width + j + 1] + (same ? 0 : 1) {
                    pieces.append(same ? .correct(a[i].text) : .wrong(expected: a[i].text, typed: b[j].text))
                    i += 1
                    j += 1
                    continue
                }
            }
            if i < n && here == cost[(i + 1) * width + j] + 1 {
                pieces.append(.missing(a[i].text))
                i += 1
            } else {
                pieces.append(.extra(b[j].text))
                j += 1
            }
        }
        return pieces
    }
}
