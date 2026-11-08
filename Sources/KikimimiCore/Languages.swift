/// Whisper が扱える言語のうち、メニューに出すもの。
public struct SpokenLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }
}

public enum Languages {
    public static let auto = SpokenLanguage(code: "auto", name: "自動判定")

    public static let all: [SpokenLanguage] = [
        auto,
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
}
