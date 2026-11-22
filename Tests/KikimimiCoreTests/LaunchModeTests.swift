import Foundation
import XCTest
@testable import KikimimiCore

/// 起動の種類の分け方と、設定に書く口が 1 つである事を見る。
/// ソースを読む試験は、「確認用の起動かどうか」を LaunchMode のほかで決めている所と、
/// SettingsWriter を通らずに設定 (UserDefaults) に書く所を見つける (次に設定を足す時の抜けを止める)
final class LaunchModeTests: XCTestCase {
    // MARK: 分け方

    func testClassifiesArguments() {
        let bin = "/Applications/Kikimimi.app/Contents/MacOS/Kikimimi"
        XCTAssertEqual(LaunchMode(arguments: [bin]), .app)
        XCTAssertEqual(LaunchMode(arguments: []), .app)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--selftest-ui-load", "3000"]), .selfTest)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--selftest-chat", "m.gguf"]), .selfTest)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--selftest-launch", "5", "--restore-windows"]), .selfTest)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--eval-llm"]), .tool)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--export-training"]), .tool)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--export-translation-eval"]), .tool)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--export-translation-training"]), .tool)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--version"]), .tool)
        // 設定の引数だけ・言語の指定だけは、ふつうの起動
        XCTAssertEqual(LaunchMode(arguments: [bin, "-uiLanguage", "en"]), .app)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--ui-language", "de"]), .app)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--restore-windows"]), .app)
        // 確認用の引数は、道具の引数より先に見る (KikimimiMain も、確認用を先に見る)
        XCTAssertEqual(LaunchMode(arguments: [bin, "--version", "--selftest-llm", "m.gguf"]), .selfTest)
        // 前に「--selftest-」が付かない引数は、確認用ではない
        XCTAssertEqual(LaunchMode(arguments: [bin, "x--selftest-ui-load"]), .app)
    }

    func testFlags() {
        XCTAssertTrue(LaunchMode.app.writesSettings)
        XCTAssertFalse(LaunchMode.selfTest.writesSettings)
        XCTAssertFalse(LaunchMode.tool.writesSettings)
        XCTAssertTrue(LaunchMode.selfTest.isSelfTest)
        XCTAssertFalse(LaunchMode.app.isSelfTest)
        XCTAssertFalse(LaunchMode.tool.isSelfTest)
    }

    /// 確認用の起動がライブラリを開くのは、起動の確認に、一時フォルダを環境変数で渡した時だけ。
    /// 本物の置き場は、どの形でも開かない
    func testHandCheckLibraryPath() {
        let bin = "/Applications/Kikimimi.app/Contents/MacOS/Kikimimi"
        let temp = ["KIKIMIMI_LIBRARY_DIR": "/private/tmp/kikimimi-hand-check/library"]
        XCTAssertEqual(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "60"], environment: temp),
                       "/private/tmp/kikimimi-hand-check/library")
        // 環境変数が無い・空
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "60"], environment: [:]))
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "60"],
                                                     environment: ["KIKIMIMI_LIBRARY_DIR": ""]))
        // ふつうの起動・ほかの確認用の起動・道具の起動
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin], environment: temp))
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-ui-load", "3000"], environment: temp))
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "5", "--selftest-chat", "m.gguf"],
                                                     environment: temp))
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--version"], environment: temp))
        // 本物の置き場 (Application Support の Kikimimi) と、その中は、開かない
        let real = LibraryStore.defaultRoot(environment: [:])
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "60"],
                                                     environment: ["KIKIMIMI_LIBRARY_DIR": real.path]))
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "60"],
                                                     environment: ["KIKIMIMI_LIBRARY_DIR": real.deletingLastPathComponent().path]))
        XCTAssertNil(LaunchMode.handCheckLibraryPath(arguments: [bin, "--selftest-launch", "60"],
                                                     environment: ["KIKIMIMI_LIBRARY_DIR": real.path + "/../Library/x"]))
    }

    // MARK: 書く口

    /// ふつうの起動だけが書き・消す。確認用・道具の起動は、何もしない
    func testWriterWritesOnlyInAppMode() throws {
        let name = "local.kikimimi.tests.settings-writer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsWriter.set(1, forKey: "a", mode: .selfTest, defaults: defaults)
        SettingsWriter.set(1, forKey: "a", mode: .tool, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "a"))
        SettingsWriter.set(2, forKey: "a", mode: .app, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "a"), 2)
        SettingsWriter.remove(forKey: "a", mode: .selfTest, defaults: defaults)
        SettingsWriter.remove(forKey: "a", mode: .tool, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "a"), 2)
        SettingsWriter.remove(forKey: "a", mode: .app, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "a"))
    }

    /// この起動だけの値は、読む時に見え、起動の引数を消さない
    func testSetForThisLaunchKeepsArguments() {
        let defaults = UserDefaults.standard
        let name = UserDefaults.argumentDomain
        let before = defaults.volatileDomain(forName: name)
        defer {
            defaults.removeVolatileDomain(forName: name)
            defaults.setVolatileDomain(before, forName: name)
        }
        let key = "kikimimiTestOnlyForThisLaunch"
        SettingsWriter.setForThisLaunch([key: true], defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: key))
        let after = defaults.volatileDomain(forName: name)
        for oldKey in before.keys { XCTAssertNotNil(after[oldKey], oldKey) }
    }

    // MARK: ソースを読む試験

    func testNoSelfTestCheckOutsideLaunchMode() throws {
        let found = try LaunchSourceScan.run().selfTestChecks
        XCTAssertEqual(found, [], "decide whether this is a self-test launch only in KikimimiCore/LaunchMode.swift: use LaunchMode.current.isSelfTest (or LaunchMode(arguments:).isSelfTest)")
    }

    func testNoSettingsWritesOutsideSettingsWriter() throws {
        let found = try LaunchSourceScan.run().settingsWrites
        XCTAssertEqual(found, [], "write UserDefaults only through SettingsWriter (KikimimiCore/SettingsWriter.swift): use SettingsWriter.set / remove / setForThisLaunch")
    }

    /// 見る所そのものが、抜けの形を見分ける
    func testScannerItself() {
        var scan = LaunchSourceScan()
        scan.collect("Kikimimi/X.swift", """
            let a = args.contains { $0.hasPrefix("--selftest-") }
            let b = args.contains("--selftest-llm")
            UserDefaults.standard.set(1, forKey: "x")
            UserDefaults.standard
                .removeObject(forKey: "x")
            let d = UserDefaults.standard
            let v = d.string(forKey: "x")
            d.set(2, forKey: "y")
            func f(store: UserDefaults) { store.setValue(3, forKey: "z") }
            UserDefaults(suiteName: "s")?.set(4, forKey: "w")
            x.setPersistentDomain([:], forName: "n")
            @AppStorage("k") var k = 1
            // UserDefaults.standard.set(1, forKey: "in a comment")
            let s = "--selftest"
            """)
        XCTAssertEqual(scan.selfTestChecks, ["Kikimimi/X.swift:1", "Kikimimi/X.swift:14"])
        XCTAssertEqual(scan.settingsWrites, [
            "Kikimimi/X.swift:3", "Kikimimi/X.swift:4", "Kikimimi/X.swift:8", "Kikimimi/X.swift:9",
            "Kikimimi/X.swift:10", "Kikimimi/X.swift:11", "Kikimimi/X.swift:12"
        ])
        // 許したファイルは見ない
        var allowed = LaunchSourceScan()
        allowed.collect("KikimimiCore/SettingsWriter.swift", "defaults.set(value, forKey: key)\nlet d = UserDefaults.standard\nd.set(1, forKey: \"x\")")
        allowed.collect("KikimimiCore/LaunchMode.swift", "arguments.contains(where: { $0.hasPrefix(\"--selftest-\") })")
        XCTAssertEqual(allowed.selfTestChecks, [])
        XCTAssertEqual(allowed.settingsWrites, [])
    }
}

/// Sources の下の .swift を読み、確認用の起動の判定と、設定に書く所を集める
struct LaunchSourceScan {
    /// 見つけた所 (「ファイル:行」)
    var selfTestChecks: [String] = []
    var settingsWrites: [String] = []

    /// 確認用の起動の判定を書いてよいファイル (理由つき)。パスは Sources からの相対
    static let selfTestCheckAllowed: [(path: String, reason: String)] = [
        ("KikimimiCore/LaunchMode.swift", "the one place that decides the launch mode")
    ]
    /// 設定に書いてよいファイル (理由つき)
    static let settingsWriteAllowed: [(path: String, reason: String)] = [
        ("KikimimiCore/SettingsWriter.swift", "the one place that writes UserDefaults")
    ]

    /// 「--selftest-」で始まるかの判定に使う文字列 (引数の名前そのもの "--selftest-llm" などはよい)
    private static let selfTestPrefixLiteral = try! NSRegularExpression(pattern: #""-{0,2}selftest-?""#)
    /// 書く・消す呼び出し (UserDefaults に入れた名前の後に付く物)
    private static let writeCall = #"\s*\.\s*(set|setValue|removeObject|setPersistentDomain|removePersistentDomain|setVolatileDomain|removeVolatileDomain|setValuesForKeys)\s*\("#
    /// 名前を問わず、領域ごと書き換える呼び出し
    private static let domainCall = try! NSRegularExpression(
        pattern: #"\.\s*(setPersistentDomain|removePersistentDomain|setVolatileDomain|removeVolatileDomain)\s*\("#)
    /// UserDefaults を直に呼ぶ形 (UserDefaults.standard.… と UserDefaults(suiteName:)?.…)
    private static let directCall = try! NSRegularExpression(
        pattern: #"UserDefaults\s*(\.\s*standard|\([^)]*\)\s*[?!]?)"# + writeCall)
    /// 書く時に自動で保存する部品
    private static let appStorage = try! NSRegularExpression(pattern: #"@AppStorage\b"#)
    /// UserDefaults を入れた名前 (let d = UserDefaults.standard / var d: UserDefaults / 仮引数 store: UserDefaults)
    private static let aliasBinding = try! NSRegularExpression(
        pattern: #"\b(\w+)\s*(?::\s*UserDefaults\b|=\s*UserDefaults\s*[.(])"#)

    static func run() throws -> LaunchSourceScan {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var scan = LaunchSourceScan()
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
        // 行の注釈 (// の後) を外す。文字列の中の // は、ここで見る形には出てこないので気にしない
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }
        // 改行をまたぐ呼び出し (UserDefaults.standard の次の行に .set( など) も拾うため、
        // 行を空白でつないだ文で探し、見つけた所を行に戻す
        let joined = lines.joined(separator: "\n")
        let ns = joined as NSString
        let all = NSRange(location: 0, length: ns.length)
        func lineNumber(_ location: Int) -> Int {
            ns.substring(to: location).components(separatedBy: "\n").count
        }
        if !Self.selfTestCheckAllowed.contains(where: { $0.path == path }) {
            for match in Self.selfTestPrefixLiteral.matches(in: joined, range: all) {
                selfTestChecks.append("\(path):\(lineNumber(match.range.location))")
            }
        }
        guard !Self.settingsWriteAllowed.contains(where: { $0.path == path }) else { return }
        var found = Set<Int>()
        for regex in [Self.directCall, Self.domainCall, Self.appStorage] {
            for match in regex.matches(in: joined, range: all) {
                found.insert(lineNumber(match.range.location))
            }
        }
        // UserDefaults を入れた名前に、書く呼び出しが付いている所
        var names = Set<String>()
        for match in Self.aliasBinding.matches(in: joined, range: all) {
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let regex = try? NSRegularExpression(pattern: #"\b"# + escaped + Self.writeCall) else { continue }
            for match in regex.matches(in: joined, range: all) {
                found.insert(lineNumber(match.range.location))
            }
        }
        settingsWrites += found.sorted().map { "\(path):\($0)" }
    }
}
