import Foundation
import XCTest
@testable import KikimimiCore

/// 画面の言語の仕組み (UILanguage・L・LPlural) と、訳の表がソースと合っているか
final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.language = .en
        super.tearDown()
    }

    // MARK: 初めの言語

    func testInitialLanguageFollowsMacOS() {
        XCTAssertEqual(UILanguage.initial(preferredLanguages: ["ja-JP", "en-US"]), .ja)
        XCTAssertEqual(UILanguage.initial(preferredLanguages: ["zh-Hant-TW"]), .zh)
        XCTAssertEqual(UILanguage.initial(preferredLanguages: ["pt-PT"]), .pt)
        XCTAssertEqual(UILanguage.initial(preferredLanguages: ["sv-SE", "de-DE"]), .de)
        XCTAssertEqual(UILanguage.initial(preferredLanguages: ["sv-SE"]), .en)
        XCTAssertEqual(UILanguage.initial(preferredLanguages: []), .en)
    }

    func testThirteenLanguagesInTheTranscriptionOrder() {
        XCTAssertEqual(UILanguage.allCases.map(\.rawValue),
                       ["en", "ja", "zh", "ko", "es", "fr", "de", "it", "pt", "ru", "vi", "th", "id"])
        // 文字起こしで選べる言語 (自動判定・日本語＋英語を除く) と同じ
        let spoken = Set(Languages.all.map(\.code)).subtracting(["auto", "ja+en"])
        XCTAssertEqual(Set(UILanguage.allCases.map(\.rawValue)), spoken)
        XCTAssertEqual(UILanguage.zh.localeIdentifier, "zh-Hans")
        XCTAssertEqual(UILanguage.pt.localeIdentifier, "pt-BR")
        XCTAssertEqual(UILanguage.ja.localeIdentifier, "ja")
        XCTAssertTrue(UILanguage.allCases.allSatisfy { !$0.nativeName.isEmpty })
    }

    // MARK: L と LPlural

    func testLookupFollowsTheLanguage() {
        L10n.language = .ja
        XCTAssertEqual(L("Japanese"), "日本語")
        XCTAssertEqual(L("Could not save: %@", "x"), "保存できませんでした: x")
        L10n.language = .en
        XCTAssertEqual(L("Japanese"), "Japanese")
        XCTAssertEqual(L("Could not save: %@", "x"), "Could not save: x")
        // 表に無い鍵は、どの言語でも鍵のまま
        L10n.language = .ja
        XCTAssertEqual(L("No such key in any table"), "No such key in any table")
        // 言語を指定して引く。表に無い鍵は、どの言語でも鍵 (英語) のまま
        XCTAssertEqual(L10n.text("Japanese", in: .fr), "Japonais")
        XCTAssertEqual(L10n.text("Japanese", in: .ja), "日本語")
        XCTAssertEqual(L10n.text("No such key in any table", in: .fr), "No such key in any table")
    }

    /// 13 言語すべてに表が在る (英語は鍵そのもの)
    func testEveryLanguageHasATable() {
        for language in UILanguage.allCases where language != .en {
            XCTAssertNotEqual(L10n.text("Cancel", in: language), "Cancel", "no translation of “Cancel” in \(language.rawValue)")
        }
        XCTAssertEqual(L10n.text("Cancel", in: .en), "Cancel")
    }

    func testPositionalArguments() {
        XCTAssertEqual(L("%2$d before %1$@", "words", 3), "3 before words")
        L10n.language = .ja
        XCTAssertEqual(L("“%1$@” → “%2$@”", "a", "b"), "「a」→「b」")
        XCTAssertEqual(L("The text for the LLM is too long (%1$d / %2$d tokens).", 10, 8),
                       "LLM に渡す文が長すぎます (10 / 8 トークン)。")
    }

    func testPlural() {
        XCTAssertEqual(LPlural(1, one: "%d segment could not be translated. Click “Translate” again to translate only the rest.",
                               other: "%d segments could not be translated. Click “Translate” again to translate only the rest."),
                       "1 segment could not be translated. Click “Translate” again to translate only the rest.")
        XCTAssertEqual(LPlural(2, one: "and %d more", other: "and %d more"), "and 2 more")
        L10n.language = .ja
        XCTAssertEqual(LPlural(3, one: "and %d more", other: "and %d more"), "ほか 3 件")
    }

    /// 作った時に文を持つ値 (言語・モデルの名前) は、読む時に今の言語で引く
    func testNamesFollowTheLanguageWhenRead() {
        let spec = ModelCatalog.spec(id: "large-v3-turbo-q5_0")
        XCTAssertEqual(Languages.name(for: "ja"), "Japanese")
        XCTAssertEqual(spec?.displayName, "Large v3 Turbo (light)")
        L10n.language = .ja
        XCTAssertEqual(Languages.name(for: "ja"), "日本語")
        XCTAssertEqual(spec?.displayName, "Large v3 Turbo (軽量版)")
        XCTAssertEqual(LLMCatalog.spec(id: "qwen3.5-9b")?.displayName, "Qwen3.5 9B (高精度)")
    }

    /// 英語の画面の、言語の名前と書き出しの見出し
    func testEnglishNamesAndExportHeadings() {
        L10n.language = .en
        XCTAssertEqual(Languages.japaneseEnglish.name, "Japanese + English")
        XCTAssertEqual(Languages.name(for: "auto"), "Auto-detect")
        let t = Transcript(sourceName: "Meeting",
                           segments: [TranscriptSegment(start: 0, end: 1, text: "Hello", language: "en"),
                                      TranscriptSegment(start: 1, end: 2, text: "こんにちは", language: "ja")],
                           language: "ja+en", model: "tiny", duration: 2)
        XCTAssertEqual(t.languageLabel, "English + Japanese")
        let md = Exporter.markdown(t, content: .bilingual)
        XCTAssertTrue(md.contains("Language: English + Japanese / Length: "), md)
        XCTAssertTrue(md.contains("| Time | Original | Japanese translation |"), md)
        XCTAssertEqual(ExportFormat.txt.displayName, "Text (.txt)")
        XCTAssertEqual(ExportContent.bilingual.displayName(target: "ja"), "Bilingual (original + Japanese)")
    }

    // MARK: 表とソース

    /// 日本語の表の部品で、同じ鍵の訳が食い違っていない
    func testJapanesePartsAgree() {
        var seen: [String: (part: String, value: String)] = [:]
        var conflicts: [String] = []
        for part in L10nTables.jaParts {
            for (key, value) in part.table {
                if let first = seen[key], first.value != value {
                    conflicts.append("“\(key)”: \(first.part) “\(first.value)” / \(part.name) “\(value)”")
                } else if seen[key] == nil {
                    seen[key] = (part.name, value)
                }
            }
        }
        XCTAssertEqual(conflicts, [], "the same key has different Japanese in two files")
    }

    /// コードで使う鍵が全部、日本語の表に在る。表に、使っていない鍵が無い
    func testJapaneseTableMatchesTheSource() throws {
        let scan = try SourceScan.run()
        XCTAssertEqual(scan.unparseable, [], "L / LPlural / LKey written in a way this test cannot read (use a single string literal)")
        XCTAssertGreaterThan(scan.keys.count, 200)
        let ja = try XCTUnwrap(L10nTables.tables[.ja])
        let missing = scan.keys.subtracting(ja.keys).sorted()
        XCTAssertEqual(missing, [], "keys used in the code but missing in the Japanese table")
        let unused = Set(ja.keys).subtracting(scan.keys).sorted()
        XCTAssertEqual(unused, [], "keys in the Japanese table that the code does not use")
    }

    /// 表のある言語すべてで: 鍵が日本語の表と同じ・置き換えの印が鍵と同じ・訳が空でない
    func testEveryTableIsComplete() throws {
        let ja = try XCTUnwrap(L10nTables.tables[.ja])
        for (language, table) in L10nTables.tables {
            XCTAssertEqual(Set(table.keys).symmetricDifference(ja.keys).sorted(), [],
                           "\(language.rawValue): the keys differ from the Japanese table")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language.rawValue): empty translation for “\(key)”")
                XCTAssertEqual(Placeholders.of(value), Placeholders.of(key),
                               "\(language.rawValue): placeholders differ for “\(key)” → “\(value)”")
            }
        }
        XCTAssertNil(L10nTables.tables[.en], "English needs no table (the keys are English)")
    }

    /// 鍵の置き換えの印の書き方: 2 つ以上なら、順の番号を付ける (`%1$@`)
    func testKeysWithSeveralArgumentsAreNumbered() throws {
        let scan = try SourceScan.run()
        let bad = scan.keys.filter { key in
            let marks = Placeholders.marks(key)
            return marks.count >= 2 && marks.contains { $0.position == nil }
        }.sorted()
        XCTAssertEqual(bad, [], "use %1$@ / %2$d when a key has two or more placeholders")
    }

    /// ソースを読む所そのものが、鍵・読めない書き方・日本語のリテラルを見分ける
    func testScannerItself() {
        var scan = SourceScan()
        scan.collectKeys("x.swift", """
            let a = L("Hello “%@”", n)
            let b = LPlural(n, one: "%d item", other: "%d items")
            let c = L(name)
            // L("only in a comment")
            let d = LPlural(rows.count - 1,
                            one: "%d row", other: "%d rows")
            let e = LKey("Say \\"hi\\"")
            let f = L("Bad \\(x)")
            let g = URL(string: "x")
            """)
        XCTAssertEqual(scan.keys, ["Hello “%@”", "%d item", "%d items", "%d row", "%d rows", "Say \"hi\""])
        XCTAssertEqual(scan.unparseable.count, 2, "\(scan.unparseable)")
        scan.keys.insert("Turn on “ききみみ”")
        scan.collectJapanese("x.swift", """
            let a = "日本語"
            let b = "判定の語" // l10n: keep
            // "コメント"
            let c = L("Turn on “ききみみ”")
            let d = \"\"\"
              例文
            \"\"\"
            let e = "English only"
            """)
        XCTAssertEqual(scan.japaneseLiterals, ["x.swift:1 \"日本語\"", "x.swift:6 (multi-line literal)"])
    }

    /// `L(` を通らない日本語の文字列リテラルが、画面のコードに残っていない (訳さない物は、除く一覧か `// l10n: keep`)
    func testNoJapaneseLiteralsOutsideL() throws {
        let scan = try SourceScan.run()
        XCTAssertEqual(scan.japaneseLiterals, [],
                       "Japanese string literals that do not go through L(…). Make them L(\"English\") keys, or list the reason in SourceScan.keepFiles / mark the line with // l10n: keep")
    }
}

/// 置き換えの印 (`%@`・`%d`・`%1$@`・`%.1f` など)
enum Placeholders {
    struct Mark: Hashable {
        let position: Int?
        let type: Character
    }

    static func marks(_ text: String) -> [Mark] {
        let pattern = #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let type = ns.substring(with: match.range(at: 2))
            guard type != "%" else { return nil }
            let position = match.range(at: 1).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 1)))
            return Mark(position: position, type: Character(type))
        }
    }

    /// 比べるための形: 番号の無い印は、出てくる順に番号を振る。番号ごとの種類を、番号の順に並べる
    static func of(_ text: String) -> [String] {
        marks(text).enumerated().map { index, mark in "\(mark.position ?? index + 1):\(mark.type)" }.sorted()
    }
}

/// ソースを読んで、鍵と、L( を通らない日本語のリテラルを集める
struct SourceScan {
    var keys: Set<String> = []
    var unparseable: [String] = []
    var japaneseLiterals: [String] = []

    /// 日本語のリテラルを見ない物 (理由つき)。パスは Sources からの相対
    static let keepFiles: [(path: String, reason: String)] = [
        // 漢字の表・誤認識の語の一覧・数の語の一覧 (判定に使う語なので訳さない)
        ("KikimimiCore/LLM/JapaneseKanji.swift", "kanji table"),
        ("KikimimiCore/HallucinationFilter.swift", "list of common misrecognitions"),
        ("KikimimiCore/RepetitionFilter.swift", "list of number words"),
        // LLM への指示文 (プロンプト) とその例文
        ("KikimimiCore/LLM/Translator.swift", "LLM prompt"),
        // 翻訳の手本 (LLM に見せる、訳す先の言語ごとの依頼と答えの例。画面には出ない)
        ("KikimimiCore/LLM/TranslationExamples.swift", "LLM translation examples"),
        // チャットの測りの問題 (LLM に渡す利用者の発言の例。画面には出ない)
        ("KikimimiCore/Chat/ChatEvalCases.swift", "chat eval utterances"),
    ]

    /// 鍵も日本語も見ないファイル: 訳の表そのものと、確認用の実行・診断の出力
    /// (画面の重さの確認は、UILoadSelfTest.swift から分けた Kikimimi/UILoad〜.swift の全部)
    static func skipsEntirely(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.contains("/L10n/") || path.hasPrefix("KikimimiCore/L10n/")
            || name.hasSuffix("SelfTest.swift") || path.hasPrefix("Kikimimi/UILoad")
            || name == "LLMEvalRunner.swift" || name == "TrainingExport.swift"
    }

    static func run() throws -> SourceScan {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [(path: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(sources.path.count + 1))
            guard !skipsEntirely(path) else { continue }
            files.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        guard !files.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        var scan = SourceScan()
        for file in files { scan.collectKeys(file.path, file.text) }
        for file in files where !keepFiles.contains(where: { file.path.hasPrefix($0.path) }) {
            scan.collectJapanese(file.path, file.text)
        }
        // モデルの一覧のデータ (Swift のファイルでなく JSON に在る、名前と説明)
        let catalog = sources.appendingPathComponent(catalogPath)
        try scan.collectCatalog(catalogPath, Data(contentsOf: catalog))
        return scan
    }

    /// モデルの一覧の JSON (Sources からの相対)
    static let catalogPath = "KikimimiCore/Catalog/models.json"

    /// 一覧の JSON の「訳す鍵」(displayNameKey・summaryKey) を鍵として集め、
    /// 「訳さない名前」(displayName) に日本語が入っていれば、日本語のリテラルとして数える
    mutating func collectCatalog(_ path: String, _ data: Data) throws {
        let catalog = try ModelCatalogData.decode(data)
        keys.formUnion(catalog.translationKeys)
        for name in catalog.untranslatedNames where Self.hasJapanese(name) {
            japaneseLiterals.append("\(path) displayName \"\(name)\" (use displayNameKey for a name to translate)")
        }
    }

    // MARK: 鍵

    private static let literal = #""((?:[^"\\\n]|\\.)*)""#
    private static let call = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(L|LKey|LPlural)\("#)
    private static let simple = try! NSRegularExpression(pattern: #"\G\s*"# + literal)
    private static let plural = try! NSRegularExpression(
        pattern: #"\G[^"()]*(?:\([^"()]*\)[^"()]*)*,\s*one:\s*"# + literal + #"\s*,\s*other:\s*"# + literal)

    /// コメントだけの行を消す (説明の中の `L("…")` を鍵と数えないように)
    private static func withoutCommentLines(_ text: String) -> String {
        text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0
        }.joined(separator: "\n")
    }

    mutating func collectKeys(_ path: String, _ text: String) {
        let code = Self.withoutCommentLines(text)
        let ns = code as NSString
        for match in Self.call.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let after = match.range.location + match.range.length
            let rest = NSRange(location: after, length: ns.length - after)
            let line = ns.substring(to: match.range.location).components(separatedBy: "\n").count
            let found: [String]?
            if name == "LPlural" {
                found = Self.plural.firstMatch(in: code, options: .anchored, range: rest).map {
                    [ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2))]
                }
            } else {
                found = Self.simple.firstMatch(in: code, options: .anchored, range: rest).map {
                    [ns.substring(with: $0.range(at: 1))]
                }
            }
            guard let found else {
                unparseable.append("\(path):\(line) \(name)(")
                continue
            }
            for raw in found {
                guard let key = Self.unescape(raw) else {
                    unparseable.append("\(path):\(line) \(name)( with an interpolation \\( in the key")
                    continue
                }
                keys.insert(key)
            }
        }
    }

    /// Swift のリテラルの中身を、実際の文字列にする (`\"`・`\\`・`\n`・`\t`)。`\(` (埋め込み) が在れば nil
    static func unescape(_ raw: String) -> String? {
        var out = ""
        var escaping = false
        for c in raw {
            if escaping {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "(": return nil
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: 日本語のリテラル

    private static let japanese = try! NSRegularExpression(pattern: #"[\p{Hiragana}\p{Katakana}\p{Han}]"#)
    private static let anyLiteral = try! NSRegularExpression(pattern: literal)

    private static func hasJapanese(_ s: String) -> Bool {
        japanese.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    mutating func collectJapanese(_ path: String, _ text: String) {
        var inBlock = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let quotes = line.components(separatedBy: "\"\"\"").count - 1
            if inBlock || quotes > 0 {
                // 複数行のリテラル ("""): 行のすべてを、リテラルの中として見る
                if quotes % 2 == 1 { inBlock.toggle() }
                if Self.hasJapanese(line), !line.contains("// l10n: keep"), !trimmed.hasPrefix("//") {
                    japaneseLiterals.append("\(path):\(index + 1) (multi-line literal)")
                }
                continue
            }
            guard !trimmed.hasPrefix("//"), !line.contains("// l10n: keep") else { continue }
            let ns = line as NSString
            for match in Self.anyLiteral.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: match.range(at: 1))
                guard Self.hasJapanese(raw) else { continue }
                // 鍵 (英語の文に、アプリの名前「ききみみ」などが入っている物) は数えない
                if let key = Self.unescape(raw), keys.contains(key) { continue }
                japaneseLiterals.append("\(path):\(index + 1) \"\(raw)\"")
            }
        }
    }
}
