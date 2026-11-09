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

    /// 監査の答え: 問題のある行だけを番号の小さい順に 1 回ずつ (`[k] DEL 理由` / `[k] FIX 誤 => 正`)、最後に `END`。
    /// 同じ行をくり返したり、一覧を何周も出したりできない形にしてある (小さなモデルはそうしがち)。
    public static func auditActions(count: Int) -> String {
        precondition(count > 0)
        var rules = ["root ::= " + (1...count).map { "i\($0)?" }.joined(separator: " ") + " " + literal("END\n")]
        for k in 1...count {
            rules.append("i\(k) ::= \(literal("[\(k)] ")) action \(literal("\n"))")
        }
        rules.append("action ::= \(literal("DEL")) note? | \(literal("FIX ")) phrase \(literal(" => ")) phrase")
        // 語句と理由は短く縛る (行まるごとの書き換えや、答えの途中で考え込むのを防ぐ)
        rules.append("note ::= \(literal(" ")) [^\\r\\n]{1,60}")
        rules.append("phrase ::= [^\\r\\n=>]{1,40}")
        return rules.joined(separator: "\n")
    }

    /// 2 つのうちどちらかを選ばせる (`1` か `2`)
    public static let choice = "root ::= \"1\" | \"2\""
}
