// 文字起こし中の結果の一覧で、終わりを追いかけている時に、行がまとめて増えたあと、新しい終わりまで
// 小刻みに動かして追いつく (tail catch-up) ための決まり。画面を使わない計算だけを置く (試験できるように)。
//
// 測った値 (CI の macOS 15): 300 行を足したあとに終わりへ 1 回で飛ぶと、位置によって 0〜585 行の body が動き、
// 0.06〜2.2 秒メインが止まる。いっぺんに足してから 10 行ずつ動かす (前の描き直しが済んでから次) と、
// どの位置でも、1 回は 51〜84 ms、合わせて 0.66〜1.06 秒で、メインの待ちは長くて 65 ms ほど。
// 20 行・30 行ずつでは、ときどき 0.2〜0.42 秒の回が出るので、10 行にする。macOS 14 では 1 回で飛んでも軽い。

/// 終わりへ小刻みに追いつく決まり
public enum TailCatchUp {
    /// 1 回に動かす行の数
    public static let step = 10
    /// いっぺんにこれ以上の行が増えた時だけ、小刻みに動かす (これより少なければ、これまでどおり 1 回で終わりへ)
    public static let minimumAdded = 11
    /// 追いついた所から終わりまでが、これより多い行なら、小刻みにせず 1 回で終わりへ (時間がかかりすぎるため)
    public static let maximumDistance = 600

    /// 小刻みに動かすか。added = いっぺんに増えた行の数、distance = 追いついた所から終わりまでの行の数
    public static func usesSteps(added: Int, distance: Int, enabledOnThisOS: Bool) -> Bool {
        enabledOnThisOS && added >= minimumAdded && distance <= maximumDistance
    }

    /// 次に一覧の下の端へ出す行の番号。reached = いま下の端に出している行の番号、lastIndex = 終わりの行の番号。
    /// 終わりに着いていれば nil
    public static func nextIndex(after reached: Int, lastIndex: Int) -> Int? {
        guard reached < lastIndex else { return nil }
        return min(reached + step, lastIndex)
    }

    /// 追いついた所から終わりまでが遠すぎる (小刻みをやめて、1 回で終わりへ飛ぶ)
    public static func isTooFar(reached: Int, lastIndex: Int) -> Bool {
        lastIndex - reached > maximumDistance
    }

    /// 小刻みに動かすのを使うか。ふだんは macOS 15 以降だけ。override は、画面の重さの確認の最中だけ渡す
    /// 環境変数 KIKIMIMI_TAIL_STEPS の値 ("1" なら使う、"0" なら使わない。ほかの値と nil は、ふだんどおり)
    public static func isEnabled(osAtLeast15: Bool, override: String?) -> Bool {
        switch override {
        case "1": return true
        case "0": return false
        default: return osAtLeast15
        }
    }
}
