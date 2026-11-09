import Foundation

/// llama.cpp の GBNF 文法を組み立てる。
///
/// 小さなモデルでも出力の形が崩れないよう、行の番号や数まで文法で縛る
/// (番号が飛んだり、余計な説明が付いたりしない)。
public enum GBNF {
    /// GBNF の文字列リテラル ("...") に直す
    public static func literal(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// `[1] …` から `[count] …` まで、ちょうど count 行を出させる (各行は改行で終わる)。
    public static func numberedLines(count: Int) -> String {
        precondition(count > 0)
        let items = (1...count).map { "\(literal("[\($0)] ")) line \(literal("\n"))" }
        return """
        root ::= \(items.joined(separator: " "))
        line ::= [^\\r\\n]+
        """
    }

    /// 監査の答え: 問題が無ければ `OK`、あれば `[k] DEL 理由` / `[k] FIX 直した文` の行を 1 つ以上。
    public static func auditActions(count: Int) -> String {
        precondition(count > 0)
        let ids = (1...count).map { literal("\($0)") }.joined(separator: " | ")
        return """
        root ::= \(literal("OK\n")) | item+
        item ::= \(literal("[")) id \(literal("] ")) action \(literal("\n"))
        action ::= \(literal("DEL")) note? | \(literal("FIX ")) text
        note ::= \(literal(" ")) text
        id ::= \(ids)
        text ::= [^\\r\\n]+
        """
    }
}
