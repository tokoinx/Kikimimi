import Foundation
import XCTest
@testable import KikimimiCore

/// 設定の画面とチャットが食い違わない事を見る (設定の画面が元。チャットが合わせる)。
/// ソースを読む試験は、片方だけを変えた時に落ちる
final class ChatSettingsLabelGuardTests: XCTestCase {
    override func tearDown() {
        L10n.language = .en
        super.tearDown()
    }

    /// リポジトリの根 (Tests/KikimimiCoreTests/この.swift から 3 つ上)
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 画面のコード (Sources/Kikimimi/Views/ の全部と KikimimiApp.swift)。
    /// チャットの窓 (ChatView.swift) は除く (チャットの文が在るので、そこに在っても設定の画面と同じとは言えない)
    static func screenSources() throws -> String {
        let views = root.appendingPathComponent("Sources/Kikimimi/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ChatView.swift" }
        XCTAssertFalse(files.isEmpty)
        var text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        text += "\n" + (try read("Sources/Kikimimi/KikimimiApp.swift"))
        return text
    }

    // MARK: 食い違い 1: ラベル

    /// チャットに出す設定のラベルの鍵と、タブの名前の鍵が、画面のコードに文字列として在る (設定の画面と同じ文)。
    /// 訳す先の名前が入る文 (自動の翻訳) は、下の試験で見る
    func testChatLabelsAreTheSettingsScreenLabels() throws {
        let screen = try Self.screenSources()
        var missing: [String] = []
        for key in SettingKey.allCases {
            guard let presentation = key.chatPresentation, presentation.labelKey != SettingLabels.autoTranslateKey else { continue }
            if !screen.contains("\"" + presentation.labelKey + "\"") { missing.append("\(key.rawValue): \(presentation.labelKey)") }
        }
        for page in ChatSettingsPage.allCases where !screen.contains("\"" + page.labelKey + "\"") {
            missing.append("tab \(page.rawValue): \(page.labelKey)")
        }
        XCTAssertEqual(missing, [], "a chat label must be the same text as the label in Settings (or on the result screen). Change the chat label (SettingKey.chatPresentation) to the key the screen uses")
    }

    /// 訳す先の名前が入る文は、設定の画面のスイッチも、チャットの札も、同じ関数 (SettingLabels.autoTranslate) で作る
    func testAutoTranslateLabelIsBuiltInOnePlace() throws {
        let settings = try Self.read("Sources/Kikimimi/Views/SettingsView.swift")
        let chatView = try Self.read("Sources/Kikimimi/Views/ChatView.swift")
        XCTAssertTrue(settings.contains("Toggle(SettingLabels.autoTranslate(target: model.translationLanguage), isOn: $model.autoTranslate)"),
                      "the auto-translate switch in Settings must use SettingLabels.autoTranslate(target:)")
        XCTAssertTrue(chatView.contains("item.label(translationLanguage: model.translationLanguage)"),
                      "the chat card must make its label with ChatSettingItem.label(translationLanguage:)")
        // アプリの側で、同じ文を別に組み立てていない
        let app = try Self.appSources()
        XCTAssertFalse(app.contains("\"Translate segments that are not in %1$@ into %2$@\""),
                       "build this label only with SettingLabels.autoTranslate(target:) (KikimimiCore)")
        // 札のラベルは、その関数の文と同じ。訳す先を変えると、文も変わる
        let item = try XCTUnwrap(ChatSettingsCatalog.items().first { $0.key == "autoTranslate" })
        for language in [UILanguage.ja, .en] {
            L10n.language = language
            for target in TranslationTarget.all {
                XCTAssertEqual(item.label(translationLanguage: target), SettingLabels.autoTranslate(target: target))
            }
        }
        L10n.language = .ja
        XCTAssertEqual(item.label(translationLanguage: "ja"), "日本語以外の区間を、日本語に翻訳する")
        XCTAssertEqual(item.label(translationLanguage: "ko"), "韓国語以外の区間を、韓国語に翻訳する")
    }

    /// 札のラベル: 文字起こしのモデルは「Model」、LLM は訳さない「LLM」
    func testRenamedLabels() throws {
        let items = ChatSettingsCatalog.items()
        L10n.language = .ja
        XCTAssertEqual(items.first { $0.key == "modelID" }?.label(translationLanguage: "ja"), L("Model"))
        XCTAssertEqual(items.first { $0.key == "llmModelID" }?.label(translationLanguage: "ja"), "LLM")
        let settings = try Self.read("Sources/Kikimimi/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("Picker(L(\"Model\"), selection: $model.modelID)"))
        XCTAssertTrue(settings.contains("Picker(\"LLM\", selection: $model.llmModelID)"))
    }

    static func appSources() throws -> String {
        let folder = root.appendingPathComponent("Sources/Kikimimi")
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var text = ""
        for case let url as URL in walker where url.pathExtension == "swift" {
            text += try String(contentsOf: url, encoding: .utf8) + "\n"
        }
        return text
    }

    // MARK: 食い違い 3: 変えられない時

    /// 設定を止める物ではない `.disabled(` (取り込み中のボタン・空の欄の「追加」など)。中身は空白を 1 つにつめた形
    static let notSettingDisables: [String] = [
        "model.isBusy",
        "model.importingLLM",
        "model.importingAdapter",
        "newTermSource.trimmingCharacters(in: .whitespaces).isEmpty || newTermTranslation.trimmingCharacters(in: .whitespaces).isEmpty",
        "newWrong.trimmingCharacters(in: .whitespaces).isEmpty || newRight.trimmingCharacters(in: .whitespaces).isEmpty"
    ]
    /// 設定の部品を止める形 (AppModel の 1 つの関数を通す)
    static let availabilityDisable = try! NSRegularExpression(pattern: #"^model\.unavailableReason\(for: \.(\w+)\) != nil$"#)

    /// `.disabled(` の中身を集める (括弧の対を数え、行をまたいでもよい。行の注釈は外す)
    static func disabledArguments(in source: String) -> [String] {
        let text = source.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
        var found: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: ".disabled(") {
            var depth = 1
            var index = start.upperBound
            var inner = ""
            while index < rest.endIndex {
                let c = rest[index]
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1 }
                if depth == 0 { break }
                inner.append(c)
                index = rest.index(after: index)
            }
            found.append(inner.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " "))
            rest = index < rest.endIndex ? rest[rest.index(after: index)...] : rest[rest.endIndex...]
        }
        return found
    }

    func testSettingsViewDisablesSettingsOnlyThroughTheAvailabilityFunction() throws {
        let source = try Self.read("Sources/Kikimimi/Views/SettingsView.swift")
        var unknown: [String] = []
        var throughFunction: [String] = []
        for argument in Self.disabledArguments(in: source) {
            let ns = argument as NSString
            if let match = Self.availabilityDisable.firstMatch(in: argument, range: NSRange(location: 0, length: ns.length)) {
                throughFunction.append(ns.substring(with: match.range(at: 1)))
            } else if !Self.notSettingDisables.contains(argument) {
                unknown.append(argument)
            }
        }
        XCTAssertEqual(unknown, [], "a new .disabled( in SettingsView.swift. If it stops a setting's control, use model.unavailableReason(for: .<setting>) != nil (AppModel+Chat.swift), so the chat card follows it too. If it does not stop a setting, add it to ChatSettingsLabelGuardTests.notSettingDisables")
        XCTAssertEqual(Set(throughFunction), ["autoVADOff", "useAdapter"])
        for name in throughFunction { XCTAssertNotNil(SettingKey(rawValue: name), name) }
    }

    func testDisabledScannerItself() {
        let sample = """
            Toggle("a", isOn: $x)
                .disabled(model.unavailableReason(for: .useVAD) != nil)
            Button("b") {}
                .disabled(a.isEmpty
                          || f(b).isEmpty) // .disabled(not this)
            """
        XCTAssertEqual(Self.disabledArguments(in: sample), ["model.unavailableReason(for: .useVAD) != nil", "a.isEmpty || f(b).isEmpty"])
    }

    func testUnavailableReasonMessages() {
        L10n.language = .ja
        XCTAssertEqual(SettingUnavailableReason.needsOn(.useVAD).message, "先に「無音を飛ばす (VAD)」をオンにしてください。")
        XCTAssertEqual(SettingUnavailableReason.noAdapter.message, "差分が入っていません。先に設定で差分を追加してください。")
        L10n.language = .en
        XCTAssertEqual(SettingUnavailableReason.needsOn(.useVAD).message, "Turn on “Skip silence (VAD)” first.")
    }

    // MARK: 食い違い 2: 語彙のヒントの決まり

    func testInitialPromptRuleIsInTheDefinition() throws {
        let rule = try XCTUnwrap(SettingKey.initialPrompt.textRule)
        XCTAssertEqual(rule.maxLength, 400)
        XCTAssertEqual(ChatSettingsCatalog.initialPromptMaxLength, 400)
        let item = try XCTUnwrap(ChatSettingsCatalog.items().first { $0.key == "initialPrompt" })
        XCTAssertEqual(item.kind, .text(rule))
        XCTAssertNil(SettingKey.useVAD.textRule)
    }

    func testTextRuleForTheChat() throws {
        let rule = SettingTextRule(maxLength: 5)
        XCTAssertTrue(rule.accepts(""))
        XCTAssertTrue(rule.accepts("abcde"))
        XCTAssertTrue(rule.accepts("ききみみ語"))
        XCTAssertFalse(rule.accepts("abcdef"))
        XCTAssertFalse(rule.accepts("a\nb"))
        XCTAssertFalse(rule.accepts("a\tb"))
        XCTAssertFalse(rule.accepts("a\u{202E}b"))
        // 数え方は String.count (結合した 1 文字は 1)
        XCTAssertTrue(rule.accepts("e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}"))
        let real = try XCTUnwrap(SettingKey.initialPrompt.textRule)
        XCTAssertTrue(real.accepts(String(repeating: "あ", count: 400)))
        XCTAssertFalse(real.accepts(String(repeating: "あ", count: 401)))
    }

    func testTextRuleForTheSettingsField() {
        let rule = SettingTextRule(maxLength: 5)
        // ふつうの入力は、そのまま
        XCTAssertEqual(rule.fieldValue(new: "abc", old: "ab"), "abc")
        XCTAssertEqual(rule.fieldValue(new: "abcde", old: "abcd"), "abcde")
        // 制御文字は空白 1 つに替える
        XCTAssertEqual(rule.fieldValue(new: "a\nb", old: "a"), "a b")
        XCTAssertEqual(rule.fieldValue(new: "a\tb\u{7}", old: ""), "a b ")
        // 上限を超えて長くなる入力は受けない (前の文のまま)
        XCTAssertEqual(rule.fieldValue(new: "abcdef", old: "abcde"), "abcde")
        XCTAssertEqual(rule.fieldValue(new: "abcdefgh", old: "ab"), "ab")
        // 替えた後で上限を超える物も
        XCTAssertEqual(rule.fieldValue(new: "abc\nde", old: "abc"), "abc")
        // 前から上限を超えている値: 短くする編集は受ける。長くする入力は受けない。同じ長さも受ける
        XCTAssertEqual(rule.fieldValue(new: "abcdefg", old: "abcdefgh"), "abcdefg")
        XCTAssertEqual(rule.fieldValue(new: "abcdefghi", old: "abcdefgh"), "abcdefgh")
        XCTAssertEqual(rule.fieldValue(new: "xbcdefgh", old: "abcdefgh"), "xbcdefgh")
        // 返した文を入れ直した後の 2 回目 (old と new が入れ替わる) は、そのまま返る (繰り返さない)
        XCTAssertEqual(rule.fieldValue(new: "abcde", old: "abcdef"), "abcde")
    }

    func testSettingsFieldUsesTheRuleOnChange() throws {
        let settings = try Self.read("Sources/Kikimimi/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains(".onChange(of: model.initialPrompt) { old, new in"))
        XCTAssertTrue(settings.contains("rule.fieldValue(new: new, old: old)"))
        XCTAssertTrue(settings.contains("if kept != new { model.initialPrompt = kept }"))
        // 保存の時・読む時には切らない
        let model = try Self.read("Sources/Kikimimi/AppModel.swift")
        XCTAssertTrue(model.contains("var initialPrompt: String { didSet { save(initialPrompt, .initialPrompt) } }"))
    }

    // MARK: 食い違い 5: 確認用の起動の画面の言語

    func testSelfTestUILanguageComesFromTheDefinition() throws {
        let language = try XCTUnwrap(UILanguage.selfTest, "SettingKey.uiLanguage selfTestValue must be one of the 13 UI languages")
        XCTAssertTrue(UILanguage.allCases.contains(language))
        guard case .string(let code)? = SettingKey.uiLanguage.definition.selfTestValue else { return XCTFail() }
        XCTAssertEqual(language.rawValue, code)
        let source = try Self.read("Sources/Kikimimi/UILanguageSetting.swift")
        XCTAssertTrue(source.contains("UILanguage.selfTest"))
        XCTAssertFalse(source.contains(".ja"), "read the self-test language from SettingKey.uiLanguage (UILanguage.selfTest)")
    }
}
