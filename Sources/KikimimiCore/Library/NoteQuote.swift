import Foundation

/// 「メモに引用」でメモに足す文。
public enum NoteQuote {
    /// `> [02:22] Have you ever ...` と改行。時刻は mm:ss (1 時間からは h:mm:ss)。文の中の改行は空白にする
    public static func line(time: TimeInterval, text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return "> [\(TimeFormat.short(time))] \(flat)\n"
    }

    /// メモの終わりに引用を足す。メモが改行で終わっていなければ改行を足し、
    /// メモが空でなければ、引用の前に空の行を 1 つ入れる
    public static func appending(_ quote: String, to notes: String) -> String {
        guard !notes.isEmpty else { return quote }
        var result = notes
        if !result.hasSuffix("\n") { result += "\n" }
        if !result.hasSuffix("\n\n") && result != "\n" { result += "\n" }
        return result + quote
    }
}
