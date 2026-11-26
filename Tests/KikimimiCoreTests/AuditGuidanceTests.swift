import Foundation
import XCTest
@testable import KikimimiCore

/// LLM が無い時の監査の文の選び方 (AuditGuidance) の試験。
/// 画面の側 (ボタンの説明・青い帯・監査の後の知らせ) が、この決め方を呼んでいる事も、ソースを読んで見る
final class AuditGuidanceTests: XCTestCase {
    override func tearDown() {
        L10n.language = .en
        super.tearDown()
    }

    /// 学習した直しを使うか (true / false) で変わる 3 つの文 (LLM が無い時)
    private func ledgerDependentTexts(usesLedger: Bool) -> [String] {
        [AuditGuidance.buttonHelp(llmInstalled: false, usesLedger: usesLedger),
         AuditGuidance.bannerHeadline(usesLedger: usesLedger),
         AuditGuidance.noLLMNote(usesLedger: usesLedger)]
    }

    /// 日本語の画面: 学習した直しを使う時の 3 つの文は「学習した直し」を言い、使わない時は言わない。
    /// LLM が在る時のボタンの説明は、学習した直しの有無で変わらない
    func testJapaneseTextsFollowTheLedgerSetting() {
        L10n.language = .ja
        for text in ledgerDependentTexts(usesLedger: true) {
            XCTAssertTrue(text.contains("学習した直し"), text)
        }
        for text in ledgerDependentTexts(usesLedger: false) {
            XCTAssertFalse(text.contains("学習した直し"), text)
        }
        let withLLM = AuditGuidance.buttonHelp(llmInstalled: true, usesLedger: true)
        XCTAssertEqual(withLLM, AuditGuidance.buttonHelp(llmInstalled: true, usesLedger: false))
        XCTAssertEqual(withLLM, "繰り返しと聞き取りミスを、Mac の中の LLM で見直す")
    }

    /// 英語のほかの 12 言語の全部で: 学習した直しの有無で文が違い、どの文も鍵 (英語) のままでない
    func testEveryLanguageHasDistinctTranslatedTexts() {
        L10n.language = .en
        let keysOn = ledgerDependentTexts(usesLedger: true)
        let keysOff = ledgerDependentTexts(usesLedger: false)
        let keyWithLLM = AuditGuidance.buttonHelp(llmInstalled: true, usesLedger: false)
        let languages = UILanguage.allCases.filter { $0 != .en }
        XCTAssertEqual(languages.count, 12)
        for language in languages {
            L10n.language = language
            let on = ledgerDependentTexts(usesLedger: true)
            let off = ledgerDependentTexts(usesLedger: false)
            for index in on.indices {
                XCTAssertNotEqual(on[index], off[index], "\(language.rawValue) #\(index)")
                XCTAssertNotEqual(on[index], keysOn[index], "\(language.rawValue) #\(index) is the English key")
                XCTAssertNotEqual(off[index], keysOff[index], "\(language.rawValue) #\(index) is the English key")
            }
            let withLLM = AuditGuidance.buttonHelp(llmInstalled: true, usesLedger: false)
            XCTAssertNotEqual(withLLM, keyWithLLM, "\(language.rawValue) LLM help is the English key")
        }
    }

    // MARK: ソースを読む見張り

    /// リポジトリの根 (Tests/KikimimiCoreTests/この.swift から 3 つ上)
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// AuditGuidance の中の鍵 (英語)。画面の側に直に書かれていたら、また画面の側で選ぶ形に戻ったという事
    private static let keys = [
        "Check for repetitions and mishearings with the LLM on your Mac",
        "Check for repetitions and apply learned corrections (to also check for other mishearings, download an LLM in Settings)",
        "Check for repetitions (to also check for mishearings, download an LLM in Settings)",
        "The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions and learned corrections are checked)",
        "The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions are checked)",
        "No LLM has been downloaded, so only repetitions and learned corrections were checked. To also check for other mishearings, download an LLM in the “Audit & translation” tab of Settings.",
        "No LLM has been downloaded, so only repetitions were checked. To also check for mishearings, download an LLM in the “Audit & translation” tab of Settings."
    ]

    /// ボタンの説明・青い帯・監査の後の知らせの 3 か所が AuditGuidance を呼び、
    /// 鍵の字が Sources/Kikimimi の中に直に書かれていない (アプリの側で文を選ぶ形に戻したら落ちる)
    func testAppUsesAuditGuidance() throws {
        let detail = try Self.read("Sources/Kikimimi/Views/TranscriptDetailView.swift")
        XCTAssertTrue(detail.contains("AuditGuidance.buttonHelp(llmInstalled: model.isLLMInstalled, usesLedger: model.useLedger)"),
                      "The audit button help must come from AuditGuidance.buttonHelp")
        XCTAssertTrue(detail.contains("AuditGuidance.bannerHeadline(usesLedger: model.useLedger)"),
                      "The LLM banner headline must come from AuditGuidance.bannerHeadline")
        let post = try Self.read("Sources/Kikimimi/AppModel+PostTasks.swift")
        XCTAssertTrue(post.contains("AuditGuidance.noLLMNote(usesLedger: learned != nil)"),
                      "The note after an audit without an LLM must come from AuditGuidance.noLLMNote")

        let folder = Self.root.appendingPathComponent("Sources/Kikimimi")
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for key in Self.keys where text.contains(key) {
                XCTFail("\(url.lastPathComponent) writes the key directly (use AuditGuidance): \(key)")
            }
        }
        XCTAssertGreaterThan(checked, 10)
        // 鍵は AuditGuidance の側に在る (鍵の字を写し違えていない)
        let guidance = try Self.read("Sources/KikimimiCore/LLM/AuditGuidance.swift")
        for key in Self.keys {
            XCTAssertTrue(guidance.contains("L(\"" + key + "\")"), key)
        }
    }
}
