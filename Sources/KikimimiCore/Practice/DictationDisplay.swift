import Foundation

/// 書き取りの答え合わせの結果を、画面に並べる形にしたもの (色はアプリの側で付ける)
public enum DictationDisplay {
    /// 並べる 1 つ分の文字の見え方
    public enum Style: Hashable, Sendable {
        /// 合っている語 (ふつうの色)
        case correct
        /// 打ち違えた語・余計に打った語 (赤で、取り消し線)
        case typedWrong
        /// 打ち違えたところの、正しい語 (緑)
        case expected
        /// 打っていない語 (オレンジで、[ ] で囲む)
        case missing
    }

    public struct Span: Hashable, Sendable {
        public var text: String
        public var style: Style

        public init(_ text: String, _ style: Style) {
            self.text = text
            self.style = style
        }
    }

    /// 結果を、並べる順の文字の集まりにする。語ごとのときは間に空白 (" ") を入れ、1 文字ずつのときは入れない。
    /// 空白も、ふつうの見え方の Span として入る
    public static func spans(_ result: DictationCheck.Result) -> [Span] {
        let separator = result.mode == .words ? " " : ""
        var spans: [Span] = []
        func add(_ span: Span) {
            if !spans.isEmpty, !separator.isEmpty { spans.append(Span(separator, .correct)) }
            spans.append(span)
        }
        for piece in result.pieces {
            switch piece {
            case .correct(let word):
                add(Span(word, .correct))
            case .wrong(let expected, let typed):
                add(Span(typed, .typedWrong))
                if !separator.isEmpty { spans.append(Span(separator, .correct)) }
                spans.append(Span(expected, .expected))
            case .missing(let word):
                add(Span("[" + word + "]", .missing))
            case .extra(let word):
                add(Span(word, .typedWrong))
            }
        }
        return spans
    }

    /// 結果のまとめ: すべて合っていれば「全部合っています」、ほかは「12 / 14 語」(1 文字ずつのときは「字」)
    public static func summary(_ result: DictationCheck.Result) -> String {
        if result.isPerfect { return "全部合っています" }
        let unit = result.mode == .words ? "語" : "字"
        return "\(result.correctCount) / \(result.expectedCount) \(unit)"
    }
}
