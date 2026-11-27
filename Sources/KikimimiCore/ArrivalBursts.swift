import Foundation

/// 文字起こしの途中の区間が、どれだけまとまって届いたかを数える (診断 --selftest-whisper で使う)
public enum ArrivalBursts {
    /// 幅 window 秒のどの区切りにも入る、届いた数の最大 (times は届いた時刻の秒。並びは問わない)。
    /// 区切りは [t, t + window) とする
    public static func mostWithin(_ window: Double, times: [Double]) -> Int {
        let sorted = times.sorted()
        var best = 0
        var first = 0
        for (i, t) in sorted.enumerated() {
            while sorted[first] <= t - window { first += 1 }
            best = max(best, i - first + 1)
        }
        return best
    }

    /// 続けて届いた 2 つの間の、いちばん長い間 (秒)。2 つ未満なら 0
    public static func longestGap(times: [Double]) -> Double {
        let sorted = times.sorted()
        var gap = 0.0
        for i in sorted.indices.dropFirst() {
            gap = max(gap, sorted[i] - sorted[i - 1])
        }
        return gap
    }
}
