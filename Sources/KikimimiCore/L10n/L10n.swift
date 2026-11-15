import Foundation
import os

/// 画面の文を、今の画面の言語に置き換える仕組み。
///
/// - 鍵は英語の文そのもの (`L("Open…")`)。英語の画面では鍵をそのまま出す。
/// - ほかの言語は、言語ごとの表 (`L10nTables`) で引く。表に無い鍵は、英語のまま出す。
/// - 置き換えの印は `%@` (文字列)・`%d` (整数)・`%.1f` (小数) など。2 つ以上の時は、
///   言語で順を変えられるように `%1$@`・`%2$d` の形で書く。
/// - 手順と決まりは `docs/L10N.md` に在る。
public enum L10n {
    /// 今の画面の言語 (どのスレッドからも読めるように、ロックで守る)
    private static let current = OSAllocatedUnfairLock(initialState: UILanguage.en)

    /// 今の画面の言語。アプリは、起動の一番初め (画面や文を作る前) と、設定で変えた時に入れる
    public static var language: UILanguage {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    /// `language` の表で鍵を引く。表に鍵が在ればその訳、無ければ鍵 (英語) を返す
    public static func text(_ key: String, in language: UILanguage) -> String {
        guard language != .en, let table = L10nTables.tables[language] else { return key }
        return table[key] ?? key
    }

    /// 覚えておいた鍵 (`LKey` で印を付けた物) を、今の言語で引く。
    /// 鍵がリテラルでない時だけ使う (リテラルなら `L` を使う。試験が鍵を集められるように)
    public static func lookup(_ key: String) -> String {
        text(key, in: language)
    }
}

/// 今の画面の言語で文を引く。`args` が在れば、引いた文の印 (`%@`・`%1$d` など) に入れる。
/// 鍵は、文字列のリテラルで書く (試験がソースを読んで鍵を集める)
public func L(_ key: String, _ args: CVarArg...) -> String {
    let text = L10n.text(key, in: L10n.language)
    return args.isEmpty ? text : String(format: text, arguments: args)
}

/// 数で形が変わる文。`count == 1` なら `one`、ほかは `other` の鍵で引き、`count` を `%d` に入れる
public func LPlural(_ count: Int, one: String, other: String) -> String {
    String(format: L10n.text(count == 1 ? one : other, in: L10n.language), count)
}

/// 後で引く鍵に印を付ける (そのまま返す)。作った時に文を持つ値 (モデルの名前など) は、鍵を覚えておき、
/// 読む時に `L10n.lookup` で引く。言語を切り替えた時に変わるように
public func LKey(_ key: String) -> String {
    key
}
