import Foundation

/// 訳の点 chrF (文字の n-gram の一致で、人の訳にどれだけ近いかを 0〜100 で表す)。
///
/// sacreBLEU の `CHRF()` の既定と同じ値を出す: 文字の n-gram は 1〜6、語の n-gram は使わない、β = 2、
/// 空白は n-gram に入れない、大文字と小文字は区別する。仮説と参照の両方に n-gram が在る次数だけで、
/// 精度と再現率を平均し、その平均から F を出す (sacreBLEU の `eff:yes`)。文字は Unicode のコードポイント単位。
///
/// 1 文の点は揺れが大きいので、当てにしない。比べる時は、文ごとの統計を足し合わせて 1 回計算する、コーパスの点を使う。
public enum ChrF {
    /// 文字の n-gram の長さの上限
    public static let characterOrder = 6
    /// 再現率の重み (β)
    public static let beta = 2.0

    /// 文ごとの統計 (次数ごとの「仮説の n-gram の数・参照の n-gram の数・一致の数」)。足し合わせられる
    public struct Statistics: Codable, Hashable, Sendable {
        /// 仮説 (訳) の n-gram の数。添字 0 が 1 文字、5 が 6 文字。参照にその次数の n-gram が無ければ 0
        public var hypothesis: [Int]
        /// 参照 (人の訳) の n-gram の数
        public var reference: [Int]
        /// 一致した n-gram の数
        public var matches: [Int]

        public init() {
            hypothesis = Array(repeating: 0, count: ChrF.characterOrder)
            reference = Array(repeating: 0, count: ChrF.characterOrder)
            matches = Array(repeating: 0, count: ChrF.characterOrder)
        }

        public init(hypothesis: [Int], reference: [Int], matches: [Int]) {
            self.hypothesis = hypothesis
            self.reference = reference
            self.matches = matches
        }

        public mutating func add(_ other: Statistics) {
            func sum(_ a: [Int], _ b: [Int]) -> [Int] {
                var out = Array(repeating: 0, count: max(a.count, b.count))
                for (i, x) in a.enumerated() { out[i] += x }
                for (i, x) in b.enumerated() { out[i] += x }
                return out
            }
            hypothesis = sum(hypothesis, other.hypothesis)
            reference = sum(reference, other.reference)
            matches = sum(matches, other.matches)
        }

        /// この統計の chrF (0〜100)
        public var score: Double {
            let eps = 1e-16
            let factor = ChrF.beta * ChrF.beta
            var effectiveOrder = 0
            var averagePrecision = 0.0, averageRecall = 0.0
            for i in 0..<ChrF.characterOrder {
                let nHyp = i < hypothesis.count ? hypothesis[i] : 0
                let nRef = i < reference.count ? reference[i] : 0
                let nMatch = i < matches.count ? matches[i] : 0
                averagePrecision += nHyp > 0 ? Double(nMatch) / Double(nHyp) : eps
                averageRecall += nRef > 0 ? Double(nMatch) / Double(nRef) : eps
                if nHyp > 0 && nRef > 0 { effectiveOrder += 1 }
            }
            guard effectiveOrder > 0 else { return 0 }
            averagePrecision /= Double(effectiveOrder)
            averageRecall /= Double(effectiveOrder)
            guard averagePrecision + averageRecall > 0 else { return 0 }
            return 100 * (1 + factor) * averagePrecision * averageRecall / (factor * averagePrecision + averageRecall)
        }
    }

    /// 空白か (Python の `str.split()` が区切りにする文字にそろえる)
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// 次数ごとの n-gram と、その数 (空白を除いてから作る)
    private static func ngrams(_ text: String) -> [[String: Int]] {
        let scalars: [Unicode.Scalar] = Array(text.unicodeScalars.filter { !isSpace($0) })
        var out: [[String: Int]] = []
        for n in 1...characterOrder {
            var counts: [String: Int] = [:]
            if scalars.count >= n {
                for start in 0...(scalars.count - n) {
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[start..<(start + n)])
                    counts[String(view), default: 0] += 1
                }
            }
            out.append(counts)
        }
        return out
    }

    /// 1 文の統計
    public static func statistics(hypothesis: String, reference: String) -> Statistics {
        let hyp = ngrams(hypothesis), ref = ngrams(reference)
        var stats = Statistics()
        for i in 0..<characterOrder {
            var hypCount = 0, matchCount = 0
            for (gram, count) in hyp[i] {
                hypCount += count
                if let r = ref[i][gram] { matchCount += min(count, r) }
            }
            // 参照にその次数の n-gram が無ければ、仮説の数も数えない (sacreBLEU と同じ)
            stats.hypothesis[i] = ref[i].isEmpty ? 0 : hypCount
            stats.reference[i] = ref[i].values.reduce(0, +)
            stats.matches[i] = matchCount
        }
        return stats
    }

    /// 1 文の点 (揺れが大きいので、比べる時はコーパスの点を使う)
    public static func sentence(hypothesis: String, reference: String) -> Double {
        statistics(hypothesis: hypothesis, reference: reference).score
    }

    /// コーパスの点: 文ごとの統計を足し合わせてから 1 回計算する (文の点の平均ではない)
    public static func corpus(hypotheses: [String], references: [String]) -> Double {
        var total = Statistics()
        for (h, r) in zip(hypotheses, references) {
            total.add(statistics(hypothesis: h, reference: r))
        }
        return total.score
    }
}
