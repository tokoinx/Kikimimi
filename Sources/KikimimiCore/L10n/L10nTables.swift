/// 言語ごとの訳の表を、1 つにまとめる所。
///
/// - 日本語の表は、担当の範囲ごとのファイル (`ja/JA+<名前>.swift`) に分けてある。
///   ファイルを足したら、`jaParts` に 1 行足す。
/// - ほかの言語の表 (`<コード>/<コード>.swift`) を足したら、`tables` に 1 行足す。
///   表の無い言語は、鍵のまま (英語) が出る。
enum L10nTables {
    /// 日本語の表の部品 (名前は、試験で同じ鍵の訳が食い違った時に、どのファイルかを出すため)
    static let jaParts: [(name: String, table: [String: String])] = [
        ("JA+Core", JA.core),
        ("JA+App", JA.app),
        ("JA+Detail", JA.detail),
        ("JA+Settings", JA.settings),
        ("JA+Views", JA.views),
        ("JA+Chat", JA.chat),
    ]

    /// 言語ごとの表 (鍵 = 英語、値 = その言語の訳)。英語の表は無い (鍵をそのまま出す)
    static let tables: [UILanguage: [String: String]] = [
        .ja: merged(jaParts.map(\.table)),
        .zh: zh,
        .ko: ko,
        .es: es,
        .fr: fr,
        .de: de,
        .it: it,
        .pt: pt,
        .ru: ru,
        .vi: vi,
        .th: th,
        .id: id,
    ]

    /// 部品を 1 つの表にする (同じ鍵は先の物を使う。訳が食い違っていないかは試験が見る)
    static func merged(_ parts: [[String: String]]) -> [String: String] {
        var all: [String: String] = [:]
        for part in parts {
            all.merge(part) { first, _ in first }
        }
        return all
    }
}

/// 日本語の表の置き場 (中身は `ja/JA+<名前>.swift` の extension)
enum JA {}
