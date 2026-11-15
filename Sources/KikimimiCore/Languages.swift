/// Whisper が扱える言語のうち、メニューに出すもの。
public struct SpokenLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    /// 名前の鍵 (英語)。名前は読む時に、今の画面の言語で引く (言語を切り替えたら変わるように)
    let nameKey: String
    public var id: String { code }

    init(code: String, nameKey: String) {
        self.code = code
        self.nameKey = nameKey
    }

    /// 画面に出す名前 (今の画面の言語)
    public var name: String { L10n.lookup(nameKey) }
}

public enum Languages {
    public static let auto = SpokenLanguage(code: "auto", nameKey: LKey("Auto-detect"))
    /// 日本語と英語が入れ替わる録音向け。区切りごとに、話している言語を日本語か英語かで判定して、その言語で文字にする。
    /// この言語コードは whisper には渡さない (`candidates(for:)` で候補の言語に置き換える)
    public static let japaneseEnglish = SpokenLanguage(code: "ja+en", nameKey: LKey("Japanese + English"))

    public static let all: [SpokenLanguage] = [
        auto,
        japaneseEnglish,
        SpokenLanguage(code: "ja", nameKey: LKey("Japanese")),
        SpokenLanguage(code: "en", nameKey: LKey("English")),
        SpokenLanguage(code: "zh", nameKey: LKey("Chinese")),
        SpokenLanguage(code: "ko", nameKey: LKey("Korean")),
        SpokenLanguage(code: "es", nameKey: LKey("Spanish")),
        SpokenLanguage(code: "fr", nameKey: LKey("French")),
        SpokenLanguage(code: "de", nameKey: LKey("German")),
        SpokenLanguage(code: "it", nameKey: LKey("Italian")),
        SpokenLanguage(code: "pt", nameKey: LKey("Portuguese")),
        SpokenLanguage(code: "ru", nameKey: LKey("Russian")),
        SpokenLanguage(code: "vi", nameKey: LKey("Vietnamese")),
        SpokenLanguage(code: "th", nameKey: LKey("Thai")),
        SpokenLanguage(code: "id", nameKey: LKey("Indonesian")),
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
