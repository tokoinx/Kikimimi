import Foundation

/// Whisper が無音や BGM のところで出しがちな「定番の誤認識」を取り除く。
///
/// 区間の本文が丸ごと定番フレーズで、かつ「発話なし」の確率がそれなりに高いときだけ除去する。
/// 実際にそう話している場合を消さないよう、条件は控えめにしている。
public enum HallucinationFilter {
    static let phrases: [String] = [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "最後までご視聴いただきありがとうございました",
        "チャンネル登録よろしくお願いします",
        "チャンネル登録お願いします",
        "おやすみなさい",
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
    ]

    /// 句読点・記号・空白を落として小文字化
    static func normalize(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// 文字が 1 つも無い (記号・音符・括弧書きだけ) か
    static func isOnlyNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // 「(音楽)」「[拍手]」「♪」のような括弧書き・記号だけの区間
        if let first = trimmed.first, let last = trimmed.last,
           "([（【「♪".contains(first), ")]）】」♪".contains(last), trimmed.count <= 12 {
            return true
        }
        return normalize(trimmed).isEmpty
    }

    /// 無音や BGM のところで Whisper が出しがちな、定番の文か (発話の有無は見ない)
    public static func isStockPhrase(_ text: String) -> Bool {
        let n = normalize(text)
        return !n.isEmpty && phrases.contains { normalize($0) == n }
    }

    public static func shouldDrop(text: String, noSpeechProbability: Float) -> Bool {
        if isOnlyNoise(text) { return true }
        let n = normalize(text)
        let isStockPhrase = phrases.contains { normalize($0) == n }
        return isStockPhrase && noSpeechProbability >= 0.15
    }
}
