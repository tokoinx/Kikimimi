import Foundation

/// 種を決めた乱数 (SplitMix64)。同じ種なら、いつも同じ並びになる。
/// でたらめな入力で試す所 (試験の `Monkey`・画面を触る確認 `--selftest-monkey`) は、乱数をここからだけ取る
/// (`Int.random(in:)` をそのまま使うと、失敗した入力・操作を、もう 1 度作れない)
public struct SeededRandom: RandomNumberGenerator, Sendable {
    public let seed: UInt64
    private var state: UInt64

    public init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 並びから 1 つ選ぶ (空の並びは渡さない)
    public mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// かけらを、決めた数だけつないだ文
    public mutating func text(from fragments: [String], pieces: ClosedRange<Int>) -> String {
        var out = ""
        for _ in 0..<int(pieces) { out += pick(fragments) }
        return out
    }
}

/// よく落ちる原因になる値の集まり (試験の `MonkeyPool` と、画面を触る確認 `--selftest-monkey` が、ここから選ぶ)。
/// 足りない値は、ここへ足す (同じ値を 2 か所に書かない)
public enum HostileValues {
    /// 秒数・長さなどの、端の値
    public static let doubles: [Double] = [
        0, -0.0, 0.000_4, 0.999_6, 59.999_6, 3599.999_6, 86_399.5, 359_999.999_6,
        1e9, 9.2e15, 9.3e15, 1e19, 1e300, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude,
        -1, -0.000_1, -1e300, Double.infinity, -Double.infinity, Double.nan
    ]

    /// 文のかけら。空・空白・改行の仲間・区切りの記号・絵文字・向きを変える印・とても長い文
    public static let textFragments: [String] = [
        "", " ", "\n", "\r\n", "\u{2028}", "\t", "\"", ",", "|", "-->", "<b>", "&amp;", "\\",
        "a", "The quick brown fox", "漢字かな", "ｱｲｳ", "e\u{301}", "😀", "👨‍👩‍👧‍👦", "\u{202E}", "\u{200B}", "\u{0}", // l10n: keep (試す値。画面の文ではない)
        String(repeating: "x", count: 5000)
    ]
}
