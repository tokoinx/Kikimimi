/// 画面の言語 (メニュー・ボタン・知らせの文)。文字起こしで選べる 13 言語と同じ。
/// 話されている言語 (`SpokenLanguage`) とは別のもの
/// (`@frozen`: このパッケージはいつも全体を一緒に作り直すので、case を足した時は、使う側の switch がコンパイルで止まるほうがよい)
@frozen public enum UILanguage: String, CaseIterable, Sendable, Identifiable {
    case en, ja, zh, ko, es, fr, de, it, pt, ru, vi, th, id

    public var id: String { rawValue }

    /// その言語での、自分の名前 (設定の画面の選ぶ所に出す。どの言語の画面でも同じ)
    public var nativeName: String {
        switch self {
        case .en: return "English"
        case .ja: return "日本語"
        case .zh: return "简体中文"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .pt: return "Português (Brasil)"
        case .ru: return "Русский"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .id: return "Bahasa Indonesia"
        }
    }

    /// macOS に渡す言語の名前 (`AppleLanguages`・Info.plist の `CFBundleLocalizations` と同じ書き方)
    public var localeIdentifier: String {
        switch self {
        case .zh: return "zh-Hans"
        case .pt: return "pt-BR"
        default: return rawValue
        }
    }

    /// 初めて起動した時の言語: macOS の言語の並び (例 `["ja-JP", "en-US"]`) を先頭から見て、
    /// 言語のコード (「-」「_」の前) が 13 の中に在る最初の物。無ければ英語
    public static func initial(preferredLanguages: [String]) -> UILanguage {
        for identifier in preferredLanguages {
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
            if let language = UILanguage(rawValue: code) { return language }
        }
        return .en
    }
}
