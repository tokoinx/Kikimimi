/// Whisper が扱える言語のうち、メニューに出すもの。
public struct SpokenLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }
}

public enum Languages {
    public static let auto = SpokenLanguage(code: "auto", name: "自動判定")
    /// 日本語と英語が入れ替わる録音向け。区切りごとに、話している言語を日本語か英語かで判定して、その言語で文字にする。
    /// この言語コードは whisper には渡さない (`candidates(for:)` で候補の言語に置き換える)
    public static let japaneseEnglish = SpokenLanguage(code: "ja+en", name: "日本語＋英語")

    public static let all: [SpokenLanguage] = [
        auto,
        japaneseEnglish,
        SpokenLanguage(code: "ja", name: "日本語"),
        SpokenLanguage(code: "en", name: "英語"),
        SpokenLanguage(code: "zh", name: "中国語"),
        SpokenLanguage(code: "ko", name: "韓国語"),
        SpokenLanguage(code: "es", name: "スペイン語"),
        SpokenLanguage(code: "fr", name: "フランス語"),
        SpokenLanguage(code: "de", name: "ドイツ語"),
        SpokenLanguage(code: "it", name: "イタリア語"),
        SpokenLanguage(code: "pt", name: "ポルトガル語"),
        SpokenLanguage(code: "ru", name: "ロシア語"),
        SpokenLanguage(code: "vi", name: "ベトナム語"),
        SpokenLanguage(code: "th", name: "タイ語"),
        SpokenLanguage(code: "id", name: "インドネシア語"),
    ]

    public static func name(for code: String?) -> String {
        guard let code, !code.isEmpty else { return "—" }
        return all.first { $0.code == code }?.name ?? code
    }

    public static func isKnown(_ code: String) -> Bool {
        all.contains { $0.code == code }
    }

    /// 区切りごとに言語を判定するときの候補 (先頭が既定)。1 つの言語に決めて文字にする設定なら nil
    public static func candidates(for code: String) -> [String]? {
        code == japaneseEnglish.code ? ["ja", "en"] : nil
    }
}
