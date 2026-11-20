import Foundation
import XCTest
@testable import KikimimiCore

/// 設定の定義の表 (SettingKey) と、読む口 (SettingsReader) を見る。
/// ソースを読む試験は、設定の鍵の文字列を定義のほかに書いた所・読む口を通らずに設定を読んだ所・
/// 読むか書くかを忘れた設定を見つける (次に設定を足す時の抜けを止める)
final class SettingsGuardTests: XCTestCase {
    // MARK: 定義の中身

    func testKeys() {
        XCTAssertEqual(SettingKey.allCases.count, 22)
        XCTAssertEqual(SettingKey.allCases.map(\.rawValue), [
            "uiLanguage", "languageCode", "modelID", "preferAccuracy", "useVAD", "autoVADOff",
            "filterHallucinations", "autoMixedLanguage", "livePreview", "initialPrompt", "llmModelID",
            "autoAudit", "translationLanguage", "autoTranslate", "useLedger", "reuseTranslationMemory",
            "useAdapter", "showBilingual", "showNotes", "notesWidth", "practice", "practiceDictation"
        ])
    }

    func testDefinitions() {
        let toggles: [SettingKey: Bool] = [
            .preferAccuracy: true, .useVAD: true, .autoVADOff: true, .filterHallucinations: true,
            .autoMixedLanguage: true, .livePreview: true, .autoAudit: true, .autoTranslate: true,
            .useLedger: true, .reuseTranslationMemory: true, .useAdapter: true, .showBilingual: true,
            .showNotes: false, .practiceDictation: false
        ]
        for (key, value) in toggles {
            XCTAssertEqual(key.definition.kind, .toggle, key.rawValue)
            XCTAssertEqual(key.definition.defaultValue, .bool(value), key.rawValue)
        }
        XCTAssertEqual(SettingKey.uiLanguage.definition, SettingDefinition(kind: .choice(.uiLanguages), defaultValue: nil, selfTestValue: .string("ja")))
        XCTAssertEqual(SettingKey.languageCode.definition, SettingDefinition(kind: .choice(.spokenLanguages), defaultValue: .string("ja")))
        XCTAssertEqual(SettingKey.modelID.definition, SettingDefinition(kind: .choice(.whisperModels), defaultValue: .string(ModelCatalog.defaultModelID)))
        XCTAssertEqual(SettingKey.llmModelID.definition, SettingDefinition(kind: .choice(.llmModels), defaultValue: .string(LLMCatalog.defaultModelID)))
        XCTAssertEqual(SettingKey.translationLanguage.definition, SettingDefinition(kind: .choice(.translationTargets), defaultValue: nil, selfTestValue: .string("ja")))
        XCTAssertEqual(SettingKey.initialPrompt.definition, SettingDefinition(kind: .text, defaultValue: .string("")))
        XCTAssertEqual(SettingKey.notesWidth.definition, SettingDefinition(kind: .number(220...520), defaultValue: .double(320)))
        XCTAssertEqual(SettingKey.practice.definition, SettingDefinition(kind: .json, defaultValue: nil))
        // 確認用の起動で決まった値を持つのは、この 3 つだけ
        let fixed = SettingKey.allCases.filter { $0.definition.selfTestValue != nil }
        XCTAssertEqual(fixed, [.uiLanguage, .translationLanguage, .reuseTranslationMemory])
        XCTAssertEqual(SettingKey.reuseTranslationMemory.definition.selfTestValue, .bool(true))
        // 選択肢の出所
        XCTAssertEqual(SettingChoices.uiLanguages.values, UILanguage.allCases.map(\.rawValue))
        XCTAssertEqual(SettingChoices.spokenLanguages.values, Languages.all.map(\.code))
        XCTAssertEqual(SettingChoices.whisperModels.values, ModelCatalog.all.map(\.id))
        XCTAssertEqual(SettingChoices.llmModels.values, LLMCatalog.all.map(\.id))
        XCTAssertEqual(SettingChoices.translationTargets.values, TranslationTarget.all)
    }

    // MARK: チャットの一覧

    func testChatCatalogComesFromTheDefinitions() {
        let items = ChatSettingsCatalog.items()
        XCTAssertEqual(items.map(\.key), [
            "uiLanguage", "languageCode", "modelID", "preferAccuracy", "useVAD", "autoVADOff",
            "filterHallucinations", "autoMixedLanguage", "livePreview", "initialPrompt", "llmModelID",
            "autoAudit", "translationLanguage", "autoTranslate", "useLedger", "reuseTranslationMemory",
            "useAdapter", "showBilingual", "showNotes", "practiceDictation"
        ])
        XCTAssertEqual(ChatSettingsCatalog.excludedKeys, ["chatResearch", "notesWidth", "practice"])
        // チャットに出す物は、どれも一覧に入る (数と JSON の設定には、出し方を付けない)
        XCTAssertEqual(SettingKey.allCases.filter { $0.chatPresentation != nil }.map(\.rawValue), items.map(\.key))
        for item in items {
            guard let key = SettingKey(rawValue: item.key) else { return XCTFail(item.key) }
            switch (key.definition.kind, item.kind) {
            case (.toggle, .toggle), (.text, .text):
                break
            case (.choice(let source), .choice(let choices)):
                let expected = source == .llmModels ? source.values.filter { !$0.hasPrefix("file:") } : source.values
                XCTAssertEqual(choices.map(\.value), expected, item.key)
            default:
                XCTFail("kind differs: \(item.key)")
            }
        }
    }

    /// --selftest-chat の始めの値 (前に直書きしていた物と同じ)
    func testSelfTestValues() {
        XCTAssertEqual(ChatSettingsCatalog.selfTestValues(), [
            "uiLanguage": "ja", "languageCode": "ja", "modelID": ModelCatalog.defaultModelID,
            "preferAccuracy": "on", "useVAD": "on", "autoVADOff": "on", "filterHallucinations": "on",
            "autoMixedLanguage": "on", "livePreview": "on", "initialPrompt": "",
            "llmModelID": LLMCatalog.defaultModelID, "autoAudit": "on", "translationLanguage": "ja",
            "autoTranslate": "on", "useLedger": "on", "reuseTranslationMemory": "on", "useAdapter": "on",
            "showBilingual": "on", "showNotes": "off", "practiceDictation": "off"
        ])
    }

    // MARK: 読む口

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "local.kikimimi.tests.settings-reader.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testReaderDefaults() throws {
        try withDefaults { d in
            let r = SettingsReader(defaults: d, mode: .app)
            XCTAssertTrue(r.bool(.useVAD))
            XCTAssertFalse(r.bool(.showNotes))
            XCTAssertFalse(r.bool(.practiceDictation))
            XCTAssertEqual(r.string(.languageCode), "ja")
            XCTAssertEqual(r.string(.modelID), ModelCatalog.defaultModelID)
            XCTAssertEqual(r.string(.llmModelID), LLMCatalog.defaultModelID)
            XCTAssertEqual(r.string(.initialPrompt), "")
            XCTAssertNil(r.string(.translationLanguage))
            XCTAssertNil(r.string(.uiLanguage))
            XCTAssertNil(r.string(.practice))
            XCTAssertEqual(r.double(.notesWidth), 320)
        }
    }

    func testReaderFixesStoredValues() throws {
        try withDefaults { d in
            let r = SettingsReader(defaults: d, mode: .app)
            // 一覧に無いモデルは既定に戻る。在るモデルはそのまま
            d.set("no-such-model", forKey: "modelID")
            XCTAssertEqual(r.string(.modelID), ModelCatalog.defaultModelID)
            d.set(ModelCatalog.all[1].id, forKey: "modelID")
            XCTAssertEqual(r.string(.modelID), ModelCatalog.all[1].id)
            // 型の違う保存値は既定になる
            d.set(["a"], forKey: "modelID")
            XCTAssertEqual(r.string(.modelID), ModelCatalog.defaultModelID)
            d.set("yes please", forKey: "useVAD")
            XCTAssertTrue(r.bool(.useVAD))
            d.set(false, forKey: "useVAD")
            XCTAssertFalse(r.bool(.useVAD))
            d.set("wide", forKey: "notesWidth")
            XCTAssertEqual(r.double(.notesWidth), 320)
            // 幅は範囲に収まる
            d.set(10.0, forKey: "notesWidth")
            XCTAssertEqual(r.double(.notesWidth), 220)
            d.set(9999.0, forKey: "notesWidth")
            XCTAssertEqual(r.double(.notesWidth), 520)
            d.set(400.0, forKey: "notesWidth")
            XCTAssertEqual(r.double(.notesWidth), 400)
            // 話す言語は、知らなければ "ja"
            d.set("xx", forKey: "languageCode")
            XCTAssertEqual(r.string(.languageCode), "ja")
            d.set("ja+en", forKey: "languageCode")
            XCTAssertEqual(r.string(.languageCode), "ja+en")
            // LLM は直さない (手元の GGUF)
            d.set("file:mine.gguf", forKey: "llmModelID")
            XCTAssertEqual(r.string(.llmModelID), "file:mine.gguf")
            // 訳す先は TranslationTarget.normalized
            d.set("KO", forKey: "translationLanguage")
            XCTAssertEqual(r.string(.translationLanguage), "ko")
            d.set("zz", forKey: "translationLanguage")
            XCTAssertEqual(r.string(.translationLanguage), TranslationTarget.fallback)
            // 画面の言語は、知らなければ nil (macOS の言語から決める)
            d.set("zz", forKey: "uiLanguage")
            XCTAssertNil(r.string(.uiLanguage))
            d.set("de", forKey: "uiLanguage")
            XCTAssertEqual(r.string(.uiLanguage), "de")
            d.set("{\"rate\":1}", forKey: "practice")
            XCTAssertEqual(r.string(.practice), "{\"rate\":1}")
        }
    }

    /// 保存してあった文が直されたか (AppModel が、一覧に無い話す言語を "ja" に直して保存し直すため)
    func testSavedStringIsFixed() throws {
        try withDefaults { d in
            let r = SettingsReader(defaults: d, mode: .app)
            XCTAssertFalse(r.savedStringIsFixed(.languageCode))
            d.set("ja+en", forKey: "languageCode")
            XCTAssertFalse(r.savedStringIsFixed(.languageCode))
            d.set("xx", forKey: "languageCode")
            XCTAssertTrue(r.savedStringIsFixed(.languageCode))
            // 数は文として読まれる (UserDefaults.string(forKey:) の決まり)。一覧に無いので直る
            d.set(5, forKey: "languageCode")
            XCTAssertTrue(r.savedStringIsFixed(.languageCode))
            d.set(["ja"], forKey: "languageCode")
            XCTAssertFalse(r.savedStringIsFixed(.languageCode))
            d.set("zz", forKey: "translationLanguage")
            XCTAssertTrue(r.savedStringIsFixed(.translationLanguage))
            XCTAssertFalse(SettingsReader(defaults: d, mode: .selfTest).savedStringIsFixed(.translationLanguage))
        }
    }

    func testReaderSelfTestValues() throws {
        try withDefaults { d in
            d.set("ko", forKey: "translationLanguage")
            d.set(false, forKey: "reuseTranslationMemory")
            d.set("de", forKey: "uiLanguage")
            d.set(false, forKey: "useVAD")
            let selfTest = SettingsReader(defaults: d, mode: .selfTest)
            XCTAssertEqual(selfTest.string(.translationLanguage), "ja")
            XCTAssertTrue(selfTest.bool(.reuseTranslationMemory))
            XCTAssertEqual(selfTest.string(.uiLanguage), "ja")
            // 決まった値の無い物は、確認用の起動でも、ふつうに読む
            XCTAssertFalse(selfTest.bool(.useVAD))
            for mode in [LaunchMode.app, .tool] {
                let r = SettingsReader(defaults: d, mode: mode)
                XCTAssertEqual(r.string(.translationLanguage), "ko")
                XCTAssertFalse(r.bool(.reuseTranslationMemory))
                XCTAssertEqual(r.string(.uiLanguage), "de")
            }
        }
    }

    // MARK: ソースを読む試験

    func testNoSettingKeyStringsOutsideTheDefinition() throws {
        let found = try SettingsSourceScan.run().keyStrings
        XCTAssertEqual(found, [], "write setting keys only in KikimimiCore/Settings/SettingKey.swift: use SettingKey.<name> (or .rawValue)")
    }

    func testNoSettingsReadsOutsideTheReader() throws {
        let found = try SettingsSourceScan.run().settingsReads
        XCTAssertEqual(found, [], "read UserDefaults only through SettingsReader (KikimimiCore/Settings/SettingsReader.swift)")
    }

    func testEverySettingIsReadAndWrittenInTheApp() throws {
        let scan = try SettingsSourceScan.run()
        let notRead = SettingKey.allCases.filter { !scan.readKeys.contains($0) }.map(\.rawValue)
        let notWritten = SettingKey.allCases.filter { !scan.writtenKeys.contains($0) }.map(\.rawValue)
        XCTAssertEqual(notRead, [], "read each setting in Sources/Kikimimi with SettingsReader.bool / string / double(.<name>)")
        XCTAssertEqual(notWritten, [], "save each setting in Sources/Kikimimi with save(value, .<name>) or SettingsWriter.set(value, for: .<name>)")
    }

    /// 見る所そのものが、抜けの形を見分ける
    func testScannerItself() {
        var scan = SettingsSourceScan()
        scan.collect("Kikimimi/X.swift", """
            let a = d.object(forKey: "useVAD") as? Bool ?? true
            let d = UserDefaults.standard
            let b = d.string(forKey: "x")
            let c = UserDefaults.standard.bool(forKey: "y")
            func f(store: UserDefaults) { _ = store.object(forKey: "z") }
            let e = UserDefaults(suiteName: "s")?.array(forKey: "w")
            let g = UserDefaults.standard
                .persistentDomain(forName: "n")
            useVAD = reader.bool(.useVAD)
            save(useVAD, .useVAD)
            SettingsWriter.set(x, for: SettingKey.practice)
            let p = reader.string(SettingKey.practiceDictation)
            // UserDefaults.standard.string(forKey: "in a comment")
            let s = ["notesWidth": 1]
            """)
        XCTAssertEqual(scan.keyStrings, ["Kikimimi/X.swift:1", "Kikimimi/X.swift:14"])
        XCTAssertEqual(scan.settingsReads, [
            "Kikimimi/X.swift:1", "Kikimimi/X.swift:3", "Kikimimi/X.swift:4", "Kikimimi/X.swift:5",
            "Kikimimi/X.swift:6", "Kikimimi/X.swift:7"
        ])
        XCTAssertEqual(scan.readKeys, [.useVAD, .practiceDictation])
        XCTAssertEqual(scan.writtenKeys, [.useVAD, .practice])
        // 許したファイルと、理由つきの例外は見ない。読み書きの数えは Kikimimi のファイルだけ
        var allowed = SettingsSourceScan()
        allowed.collect("KikimimiCore/Settings/SettingKey.swift", "case \"useVAD\"")
        allowed.collect("KikimimiCore/Settings/SettingsReader.swift", "let d = UserDefaults.standard\nd.object(forKey: key.rawValue)")
        allowed.collect("Kikimimi/KikimimiApp.swift",
                        "if let keep = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[\"NSQuitAlwaysKeepsWindows\"] {")
        allowed.collect("KikimimiCore/Other.swift", "save(useVAD, .useVAD)\nr.bool(.useVAD)")
        XCTAssertEqual(allowed.keyStrings, [])
        XCTAssertEqual(allowed.settingsReads, [])
        XCTAssertEqual(allowed.readKeys, [])
        XCTAssertEqual(allowed.writtenKeys, [])
    }
}

/// Sources の下の .swift を読み、設定の鍵の文字列・設定の読み・設定ごとの読み書きを集める
struct SettingsSourceScan {
    /// 見つけた所 (「ファイル:行」)
    var keyStrings: [String] = []
    var settingsReads: [String] = []
    /// Sources/Kikimimi の中で、読む口で読まれた設定・保存された設定
    var readKeys = Set<SettingKey>()
    var writtenKeys = Set<SettingKey>()

    /// 設定の鍵の文字列を書いてよいファイル (理由つき)。パスは Sources からの相対
    static let keyStringAllowed: [(path: String, reason: String)] = [
        ("KikimimiCore/Settings/SettingKey.swift", "the one table of setting definitions")
    ]
    /// 設定の鍵の文字列の、どうしても要る例外 (ファイルと、その行に在る文。理由つき)。今は無い
    static let keyStringExceptions: [(path: String, line: String, reason: String)] = []
    /// UserDefaults を読んでよいファイル (理由つき)
    static let readAllowed: [(path: String, reason: String)] = [
        ("KikimimiCore/Settings/SettingsReader.swift", "the one place that reads settings"),
        ("KikimimiCore/SettingsWriter.swift", "reads the argument domain only to add values to it")
    ]
    /// UserDefaults の読みの例外 (ファイルと、その行に在る文。理由つき)
    static let readExceptions: [(path: String, line: String, reason: String)] = [
        ("Kikimimi/KikimimiApp.swift", "NSQuitAlwaysKeepsWindows",
         "reads the macOS global domain (a system key, not one of the app's settings)")
    ]

    /// 鍵の文字列 ("useVAD" のように引用符で囲んだ形)
    private static let keyLiteral = try! NSRegularExpression(
        pattern: "\"(" + SettingKey.allCases.map(\.rawValue).joined(separator: "|") + ")\"")
    /// 読む呼び出し (UserDefaults に入れた名前の後に付く物)
    private static let readCall = #"\s*\.\s*(string|object|bool|integer|double|float|array|dictionary|data|stringArray|url|value|persistentDomain|volatileDomain|dictionaryRepresentation)\s*\("#
    /// UserDefaults を直に呼ぶ形 (UserDefaults.standard.… と UserDefaults(suiteName:)?.…)
    private static let directRead = try! NSRegularExpression(
        pattern: #"UserDefaults\s*(\.\s*standard|\([^)]*\)\s*[?!]?)"# + readCall)
    /// UserDefaults を入れた名前 (let d = UserDefaults.standard / var d: UserDefaults / 仮引数 store: UserDefaults)
    private static let aliasBinding = try! NSRegularExpression(
        pattern: #"\b(\w+)\s*(?::\s*UserDefaults\b|=\s*UserDefaults\s*[.(])"#)
    /// 読む口で読む形: reader.bool(.useVAD) / .string(SettingKey.modelID) / .double(.notesWidth)
    private static let keyRead = try! NSRegularExpression(
        pattern: #"\.(bool|string|double)\(\s*(?:SettingKey)?\.(\w+)\s*\)"#)
    /// 保存する形: save(値, .useVAD) / SettingsWriter.set(値, for: .practice)
    private static let keyWrite = try! NSRegularExpression(
        pattern: #"\b(?:save|SettingsWriter\s*\.\s*set)\s*\(.*,\s*(?:for:\s*)?(?:SettingKey)?\.(\w+)\s*\)"#)

    static func run() throws -> SettingsSourceScan {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var scan = SettingsSourceScan()
        var count = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(sources.path.count + 1))
            scan.collect(path, try String(contentsOf: url, encoding: .utf8))
            count += 1
        }
        guard count > 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return scan
    }

    mutating func collect(_ path: String, _ text: String) {
        let rawLines = text.components(separatedBy: "\n")
        // 鍵の文字列は、注釈の中も見る (鍵の文字列が出る所を、定義の 1 か所にするため)
        if !Self.keyStringAllowed.contains(where: { $0.path == path }) {
            for (index, line) in rawLines.enumerated() {
                let ns = line as NSString
                guard Self.keyLiteral.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
                if Self.keyStringExceptions.contains(where: { $0.path == path && line.contains($0.line) }) { continue }
                keyStrings.append("\(path):\(index + 1)")
            }
        }
        // ほかは、行の注釈 (// の後) を外して見る
        let lines = rawLines.map { line -> String in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }
        if path.hasPrefix("Kikimimi/") {
            for line in lines {
                let ns = line as NSString
                let all = NSRange(location: 0, length: ns.length)
                for match in Self.keyRead.matches(in: line, range: all) {
                    if let key = SettingKey(rawValue: ns.substring(with: match.range(at: 2))) { readKeys.insert(key) }
                }
                for match in Self.keyWrite.matches(in: line, range: all) {
                    if let key = SettingKey(rawValue: ns.substring(with: match.range(at: 1))) { writtenKeys.insert(key) }
                }
            }
        }
        guard !Self.readAllowed.contains(where: { $0.path == path }) else { return }
        // 改行をまたぐ呼び出し (UserDefaults.standard の次の行に .string( など) も拾うため、
        // 行をつないだ文で探し、見つけた所を行に戻す
        let joined = lines.joined(separator: "\n")
        let ns = joined as NSString
        let all = NSRange(location: 0, length: ns.length)
        func lineNumber(_ location: Int) -> Int {
            ns.substring(to: location).components(separatedBy: "\n").count
        }
        var found = Set<Int>()
        for match in Self.directRead.matches(in: joined, range: all) {
            found.insert(lineNumber(match.range.location))
        }
        var names = Set<String>()
        for match in Self.aliasBinding.matches(in: joined, range: all) {
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let regex = try? NSRegularExpression(pattern: #"\b"# + escaped + Self.readCall) else { continue }
            for match in regex.matches(in: joined, range: all) {
                found.insert(lineNumber(match.range.location))
            }
        }
        let exceptions = Self.readExceptions.filter { $0.path == path }
        settingsReads += found.sorted().filter { number in
            !exceptions.contains { lines[number - 1].contains($0.line) }
        }.map { "\(path):\($0)" }
    }
}
