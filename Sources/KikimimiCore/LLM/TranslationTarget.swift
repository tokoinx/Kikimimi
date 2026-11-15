import Foundation

/// 訳す先の言語。言語のコードの文字列 ("ja"・"en"・…) で持つ。
/// 選べるのは画面の言語 (`UILanguage`) と同じ 13 言語。zh は簡体字、pt はブラジルのポルトガル語
public enum TranslationTarget {
    /// 選べる言語のコード (`UILanguage` と同じ順)
    public static let all: [String] = UILanguage.allCases.map(\.rawValue)

    /// 決まっていない時・知らないコードの時の言語 (これまでの翻訳は日本語だけだったので、日本語)
    public static let fallback = "ja"

    /// 13 言語のどれか。無ければ日本語
    public static func normalized(_ code: String?) -> String {
        guard let code = code?.lowercased(), all.contains(code) else { return fallback }
        return code
    }

    /// LLM への指示文に入れる名前 (英語)
    public static func englishName(for code: String) -> String {
        switch code.lowercased() {
        case "ja": return "Japanese"
        case "en": return "English"
        case "zh": return "Simplified Chinese"
        case "ko": return "Korean"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Brazilian Portuguese"
        case "ru": return "Russian"
        case "vi": return "Vietnamese"
        case "th": return "Thai"
        case "id": return "Indonesian"
        default: return englishName(for: fallback)
        }
    }

    /// 画面に出す名前 (今の画面の言語での、その言語の名前)
    public static func displayName(for code: String) -> String {
        Languages.name(for: code)
    }
}
