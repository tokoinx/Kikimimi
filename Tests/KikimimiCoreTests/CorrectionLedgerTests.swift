import XCTest
@testable import KikimimiCore

/// 学習した直しの台帳 (利用者の決定を覚えて、監査で使う)
final class CorrectionLedgerTests: XCTestCase {
    private func segment(_ text: String, at start: Double = 0, language: String? = nil) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 3, text: text, language: language)
    }

    func testDecisionsTurnRulesOnAndOff() {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: "Open Roblocks Studio.", accepted: true)
        XCTAssertEqual(ledger.corrections.count, 1)
        XCTAssertTrue(ledger.corrections[0].isActive)
        XCTAssertFalse(ledger.blocks(wrong: "Roblocks", right: "Roblox"))
        // 元に戻すと保留、もう一度戻すと「もう提案しない」
        ledger.record(wrong: "roblocks", right: "roblox", language: "en", example: nil, accepted: false)
        XCTAssertEqual(ledger.corrections.count, 1, "the same pair, ignoring case")
        XCTAssertFalse(ledger.corrections[0].isActive)
        XCTAssertFalse(ledger.corrections[0].isBlocked)
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: nil, accepted: false)
        XCTAssertTrue(ledger.blocks(wrong: "Roblocks", right: "Roblox"))
        XCTAssertTrue(ledger.fixes(for: [segment("Open Roblocks Studio.")], language: "en").isEmpty)
        // 自分で書いた直しは、回数に関係なく当てる
        XCTAssertTrue(ledger.teach(wrong: "Roblocks", right: "Roblox"))
        XCTAssertTrue(ledger.corrections[0].isActive)
        XCTAssertFalse(ledger.blocks(wrong: "Roblocks", right: "Roblox"))
        // 空の語・同じ語は覚えない
        XCTAssertFalse(ledger.teach(wrong: " ", right: "x"))
        XCTAssertFalse(ledger.teach(wrong: "same", right: "same"))
        ledger.record(wrong: "", right: "x", language: nil, example: nil, accepted: true)
        XCTAssertEqual(ledger.corrections.count, 1)
        ledger.remove(ledger.corrections[0].id)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testLearnedFixesAreAppliedAtWordBoundaries() throws {
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Roblocks", right: "Roblox")
        _ = ledger.teach(wrong: "can", right: "cam")
        let segments = [
            segment("Welcome to Roblocks Studio, and roblocks again."),
            segment("We scan the room.", at: 3),
            segment("Nothing to fix here.", at: 6),
            segment("ロブロックスの Roblocksを開きます。", at: 9),
        ]
        let changes = ledger.fixes(for: segments, language: "en")
        XCTAssertEqual(changes.map(\.original.id), [segments[0].id, segments[3].id])
        XCTAssertEqual(changes[0].replacement, "Welcome to Roblox Studio, and Roblox again.")
        XCTAssertEqual(changes[1].replacement, "ロブロックスの Robloxを開きます。")
        XCTAssertTrue(changes.allSatisfy { $0.origin == .ledger && $0.isConfident && $0.kind == .fix })
        XCTAssertEqual(changes[0].wrong, "Roblocks")
        XCTAssertTrue(changes[0].reason.contains("学習した直し"))
        // 反映して、元に戻せる
        var transcript = Transcript(sourceName: "x", segments: segments, language: "en")
        transcript.adopt(AuditReport(changes: changes, model: nil, reviewedCount: segments.count))
        XCTAssertEqual(transcript.segments[0].text, "Welcome to Roblox Studio, and Roblox again.")
        transcript.setChange(try XCTUnwrap(transcript.audit?.changes.first).id, applied: false)
        XCTAssertEqual(transcript.segments[0].text, segments[0].text)
    }

    func testRulesRespectTheLineLanguageAndDoNotStack() {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "AI", right: "AI model", language: "en", example: nil, accepted: true)
        ledger.record(wrong: "機会", right: "機械", language: "ja", example: nil, accepted: true)
        let segments = [
            segment("The AI is fast.", language: "en"),
            segment("The AI model is fast.", at: 3, language: "en"),
            segment("この機会は速いです。", at: 6, language: "ja"),
            segment("機会 is a word.", at: 9, language: "en"),
        ]
        let changes = ledger.fixes(for: segments, language: "en")
        XCTAssertEqual(changes.map(\.replacement), ["The AI model is fast.", "この機械は速いです。"])
        // 違う言語の行でも同じ決定をしたら、どの言語の行にも当てる
        ledger.record(wrong: "機会", right: "機械", language: "en", example: nil, accepted: true)
        XCTAssertNil(ledger.corrections[1].language)
    }

    func testGlossaryGetsTheLearnedTerms() {
        var ledger = CorrectionLedger()
        XCTAssertNil(ledger.glossary(adding: " "))
        XCTAssertEqual(ledger.glossary(adding: "ききみみ"), "ききみみ")
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: nil, accepted: true)
        ledger.record(wrong: "whirled", right: "world", language: "en", example: nil, accepted: false)
        XCTAssertEqual(ledger.glossaryTerms(), ["Roblox"], "rejected pairs are not hints")
        // 学習した語は前に置く (whisper は長すぎるヒントの終わりだけを使うので、利用者が書いたヒントを終わりに残す)
        XCTAssertEqual(ledger.glossary(adding: "ききみみ"), "Roblox, ききみみ")
        _ = ledger.teach(wrong: "Lewa", right: "Luau", date: Date().addingTimeInterval(10))
        XCTAssertEqual(ledger.glossary(adding: "ききみみ"), "Roblox, Luau, ききみみ", "newest learned term next to the user's hint")
        ledger.remove(ledger.corrections[2].id)
        XCTAssertEqual(ledger.glossary(adding: "roblox studio"), "roblox studio", "already in the hint")
        XCTAssertEqual(ledger.glossary(adding: nil), "Roblox")
        // 上限
        for k in 0..<60 { _ = ledger.teach(wrong: "wrong\(k)", right: "RightTerm\(k)") }
        XCTAssertLessThanOrEqual(ledger.glossaryTerms().count, 24)
        XCTAssertLessThanOrEqual(ledger.glossaryTerms().joined(separator: ", ").count, 240)
    }

    func testLedgerIsSavedAndLoaded() throws {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: "Open Roblocks.", accepted: true,
                      date: Date(timeIntervalSince1970: 1_800_000_000))
        _ = ledger.teach(wrong: "機会", right: "機械", date: Date(timeIntervalSince1970: 1_800_000_100))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kikimimi-ledger-\(UUID().uuidString)/l.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ledger.save(to: url)
        XCTAssertEqual(CorrectionLedger.load(from: url), ledger)
        // 無いファイル・壊れたファイルは、空の台帳
        XCTAssertTrue(CorrectionLedger.load(from: url.appendingPathExtension("missing")).isEmpty)
        try Data("{ broken".utf8).write(to: url)
        XCTAssertTrue(CorrectionLedger.load(from: url).isEmpty)
    }

    /// 読めないファイルを、空の台帳で上書きしない。欠けた項目のある直しは補って読み、読めない 1 件は飛ばす
    func testUnreadableLedgerIsKeptAsideAndPartialEntriesAreRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kikimimi-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learned-corrections.json")
        // 無いファイル: 空の台帳。何も動かさない
        var loaded = CorrectionLedger.loadKeepingUnreadable(from: url)
        XCTAssertTrue(loaded.ledger.isEmpty)
        XCTAssertNil(loaded.setAside)
        // 利用者が手で書き足した「wrong」「right」だけの直し (自分で書いた直しとして読む)、回数だけの直し、読めない 1 件
        let text = """
        {"version": 1, "corrections": [
          {"wrong": "Roblocks", "right": "Roblox"},
          {"wrong": "whirled", "right": "world", "rejected": 2},
          {"wrong": 5},
          {"wrong": "same", "right": "same"},
          {"wrong": "Lewa", "right": "Luau", "accepted": 2, "updated": "2027-01-15T00:00:00Z", "id": "not a uuid"}
        ]}
        """
        try Data(text.utf8).write(to: url)
        loaded = CorrectionLedger.loadKeepingUnreadable(from: url)
        XCTAssertNil(loaded.setAside)
        XCTAssertEqual(loaded.ledger.corrections.map(\.wrong), ["Roblocks", "whirled", "Lewa"])
        XCTAssertTrue(loaded.ledger.corrections[0].taught)
        XCTAssertTrue(loaded.ledger.corrections[1].isBlocked)
        XCTAssertTrue(loaded.ledger.corrections[2].isAutomatic)
        XCTAssertFalse(loaded.ledger.corrections[2].taught)
        // 保存し直しても読める
        try loaded.ledger.save(to: url)
        let again = CorrectionLedger.load(from: url)
        XCTAssertEqual(again.corrections.map(\.id), loaded.ledger.corrections.map(\.id))
        XCTAssertEqual(again.corrections.map(\.taught), [true, false, false])
        XCTAssertEqual(again.corrections.map(\.accepted), [0, 0, 2])
        // 壊れたファイル: 別の名前でとっておき、空の台帳で始める
        try Data("{ \"corrections\": [ broken".utf8).write(to: url)
        loaded = CorrectionLedger.loadKeepingUnreadable(from: url, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(loaded.ledger.isEmpty)
        let aside = try XCTUnwrap(loaded.setAside)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("learned-corrections.unreadable-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ \"corrections\": [ broken")
    }

    /// 1 回反映しただけの直しは、次は提案。2 回で自動。数字・否定・漢字の当て推量は、覚えていても提案どまり
    func testOneAcceptanceIsASuggestionAndRiskyFixesStaySuggestions() {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "Lou Tyce", right: "Lou Tice", language: "en", example: nil, accepted: true)
        let line = [segment("This program was created by Lou Tyce.")]
        var changes = ledger.fixes(for: line, language: "en")
        XCTAssertEqual(changes.map(\.replacement), ["This program was created by Lou Tice."])
        XCTAssertFalse(changes[0].isConfident, "one acceptance: a suggestion")
        XCTAssertTrue(changes[0].reason.contains("もう一度反映すると"))
        XCTAssertEqual(changes[0].learned, [AuditChange.Pair(wrong: "Lou Tyce", right: "Lou Tice")])
        ledger.record(wrong: "Lou Tyce", right: "Lou Tice", language: "en", example: nil, accepted: true)
        XCTAssertTrue(ledger.corrections[0].isAutomatic)
        changes = ledger.fixes(for: line, language: "en")
        XCTAssertTrue(changes[0].isConfident, "two acceptances: automatic")
        // 元に戻すと、また提案に下がる
        ledger.record(wrong: "Lou Tyce", right: "Lou Tice", language: "en", example: nil, accepted: false)
        XCTAssertFalse(ledger.fixes(for: line, language: "en")[0].isConfident)

        // 監査役が「要確認」にとどめる種類の直しは、何回反映していても行ごとに確かめる
        var risky = CorrectionLedger()
        for _ in 0..<3 {
            risky.record(wrong: "fifteen", right: "fifty", language: "en", example: nil, accepted: true)
            risky.record(wrong: "can", right: "can't", language: "en", example: nil, accepted: true)
            risky.record(wrong: "こうせい", right: "構成", language: "ja", example: nil, accepted: true)
        }
        let lines = [
            segment("We sold fifteen units in March.", language: "en"),
            segment("Yes, we can ship it on Friday.", at: 3, language: "en"),
            segment("こうせい労働省の発表です。", at: 6, language: "ja"),
        ]
        let suggestions = risky.fixes(for: lines, language: "en")
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertTrue(suggestions.allSatisfy { !$0.isConfident }, "\(suggestions.map(\.reason))")
        XCTAssertTrue(suggestions[0].reason.contains("数字"))
        XCTAssertTrue(suggestions[1].reason.contains("否定"))
        XCTAssertTrue(suggestions[2].reason.contains("漢字"))
        // 反映はされない (提案として一覧に出る)
        var transcript = Transcript(sourceName: "x", segments: lines, language: "en")
        transcript.adopt(AuditReport(changes: suggestions, model: nil, reviewedCount: 3))
        XCTAssertEqual(transcript.segments.map(\.text), lines.map(\.text))
        // 設定で利用者が自分で書いた直しは、そのまま当てる
        XCTAssertTrue(risky.teach(wrong: "fifteen", right: "fifty"))
        XCTAssertTrue(risky.fixes(for: [lines[0]], language: "en")[0].isConfident)
    }

    /// 正しい語がもう入っているかは、語の切れ目で見る (「evaluate」の中の「lua」は数えない)
    func testRightTermCheckUsesWordBoundaries() {
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Lewa", right: "Lua")
        _ = ledger.teach(wrong: "eye", right: "AI")
        let segments = [
            segment("Let's evaluate the Lewa script."),
            segment("He said the eye model is trained again.", at: 3),
            segment("Lua and Lewa are different here.", at: 6),
        ]
        XCTAssertEqual(ledger.fixes(for: segments, language: "en").map(\.replacement),
                       ["Let's evaluate the Lua script.", "He said the AI model is trained again."])
        XCTAssertTrue(Auditor.containsTerm("We use Lua here.", "lua"))
        XCTAssertFalse(Auditor.containsTerm("We evaluate it.", "Lua"))
        XCTAssertTrue(Auditor.containsTerm("機械を使います。", "機械"))
    }

    /// いくつかの語をまとめた直しは、どの組にも利用者の決定を覚えられるよう、すべての組を持つ
    func testCombinedChangesCarryEveryPair() throws {
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Roblocks", right: "Roblox")
        _ = ledger.teach(wrong: "Lewa", right: "Luau")
        let segments = [segment("In Roblocks Studio we write Lewa, and we bild games.")]
        let both = ledger.fixes(for: segments, language: "en")
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(Set(both[0].decisionPairs), [AuditChange.Pair(wrong: "Roblocks", right: "Roblox"),
                                                    AuditChange.Pair(wrong: "Lewa", right: "Luau")])
        // LLM の直しとまとめたもの: 学習した 2 組と、LLM の 1 組
        let generator = FakeGenerator { prompt in
            if prompt.user.contains("Lines to check") { return "[1] FIX bild => build\nEND" }
            for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                if line.contains("build") { return String(line.prefix(1)) }
            }
            return "1"
        }
        let report = try Auditor.audit(segments, language: "en", options: AuditOptions(ledger: ledger), generator: generator,
                                       modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(report.changes.count, 1)
        XCTAssertEqual(report.changes[0].replacement, "In Roblox Studio we write Luau, and we build games.")
        XCTAssertEqual(report.changes[0].original.text, segments[0].text)
        XCTAssertEqual(Set(report.changes[0].decisionPairs.map(\.wrong)), ["Roblocks", "Lewa", "bild"])
        // 古い保存 (learned が無い) も読める
        let old = try JSONDecoder().decode(AuditChange.self, from: Data("""
        {"id":"\(UUID().uuidString)","kind":"fix","origin":"llm","original":{"id":"\(UUID().uuidString)","start":0,"end":1,"text":"a"},
         "reason":"r","isConfident":true,"isApplied":false,"wrong":"a","right":"b","replacement":"b"}
        """.utf8))
        XCTAssertEqual(old.decisionPairs, [AuditChange.Pair(wrong: "a", right: "b")])
    }

    /// 利用者がこの行では元に戻した「学習した直し」を、監査のやり直しで LLM の直しとまとめて戻さない
    func testReAuditDoesNotBringBackALearnedFixTheUserReverted() throws {
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Roblocks", right: "Roblox")
        let segments = [segment("Our studio is called Roblocks Labs, and we bild small games."),
                        segment("Open Roblocks Studio first.", at: 3)]
        var seen: [String] = []
        let generator = FakeGenerator { prompt in
            if prompt.user.contains("Lines to check") {
                seen.append(prompt.user)
                return "[1] FIX bild => build\nEND"
            }
            for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                if line.contains("build") { return String(line.prefix(1)) }
            }
            return "1"
        }
        func audit(_ transcript: Transcript) throws -> AuditReport {
            try Auditor.audit(transcript.segmentsBeforeAudit, language: "en",
                              options: AuditOptions(ledger: ledger, decisions: transcript.audit?.userDecisions ?? [:]),
                              generator: generator, modelName: "fake", shouldCancel: { false })
        }
        var transcript = Transcript(sourceName: "x", segments: segments, language: "en")
        // 1 回目 (規則と台帳だけの結果を先に反映した形): 学習した直しが 2 行に当たる
        transcript.adopt(try Auditor.audit(segments, language: "en", options: AuditOptions(ledger: ledger), generator: nil,
                                           modelName: nil, shouldCancel: { false }))
        XCTAssertEqual(transcript.segments[0].text, "Our studio is called Roblox Labs, and we bild small games.")
        // 利用者: 1 行目の名前は、本当に Roblocks
        transcript.setChange(try XCTUnwrap(transcript.audit?.change(forSegment: segments[0].id)).id, applied: false)
        XCTAssertEqual(transcript.segments[0].text, segments[0].text)
        // 監査のやり直し (LLM つき) を 2 回: どちらも、1 行目の Roblocks はそのまま。LLM の直しだけが入る
        for round in 1...2 {
            transcript.adopt(try audit(transcript))
            XCTAssertEqual(transcript.segments[0].text, "Our studio is called Roblocks Labs, and we build small games.", "round \(round)")
            XCTAssertEqual(transcript.segments[1].text, "Open Roblox Studio first.")
            XCTAssertTrue(try XCTUnwrap(seen.last).contains("[1] Our studio is called Roblocks Labs"), "the LLM sees the line as the user left it")
            let change = try XCTUnwrap(transcript.audit?.change(forSegment: segments[0].id))
            XCTAssertEqual(change.origin, .llm)
            XCTAssertNil(change.learned)
        }
    }

    func testAuditAppliesLearnedFixesBeforeTheLLMAndDropsRejectedOnes() throws {
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Roblocks", right: "Roblox")
        ledger.record(wrong: "whirled", right: "world", language: "en", example: nil, accepted: false)
        let segments = [
            segment("Welcome to Roblocks Studio."),
            segment("The leaves whirled around the yard.", at: 3),
            segment("We will bild a small game today.", at: 6),
        ]
        // LLM: 1 行目は直すものが無い (学習した直しが当たった後の文を見る)。2 行目は利用者が断った直し。3 行目は新しい直し
        let generator = FakeGenerator { prompt in
            if prompt.user.contains("Lines to check") {
                XCTAssertTrue(prompt.user.contains("[1] Welcome to Roblox Studio."), prompt.user)
                return "[2] FIX whirled => world\n[3] FIX bild => build\nEND"
            }
            // 評価役: 直した後を選ぶ
            for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                if line.contains("build") || line.contains("world") { return String(line.prefix(1)) }
            }
            return "1"
        }
        let report = try Auditor.audit(segments, language: "en", options: AuditOptions(ledger: ledger), generator: generator,
                                       modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(report.changes.map(\.origin), [.ledger, .llm])
        XCTAssertEqual(report.changes[0].original.text, "Welcome to Roblocks Studio.")
        XCTAssertEqual(report.changes[0].replacement, "Welcome to Roblox Studio.")
        XCTAssertEqual(report.changes[1].replacement, "We will build a small game today.")
        XCTAssertEqual(report.changes[1].wrong, "bild")
        XCTAssertEqual(report.changes[1].right, "build")
        // 断った直しは、評価役にも聞いていない
        XCTAssertFalse(generator.prompts.contains { $0.user.contains("The leaves world around") })
        // LLM が無くても、学習した直しは当たる
        let rules = try Auditor.audit(segments, language: "en", options: AuditOptions(ledger: ledger), generator: nil,
                                      modelName: nil, shouldCancel: { false })
        XCTAssertEqual(rules.changes.map(\.origin), [.ledger])
    }

    func testAConfidentLLMFixOnALearnedLineBecomesOneChange() throws {
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Roblocks", right: "Roblox")
        let segments = [segment("Welcome to Roblocks Studio, where we bild games.")]
        let generator = FakeGenerator { prompt in
            if prompt.user.contains("Lines to check") { return "[1] FIX bild => build\nEND" }
            for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                if line.contains("build") { return String(line.prefix(1)) }
            }
            return "1"
        }
        let report = try Auditor.audit(segments, language: "en", options: AuditOptions(ledger: ledger), generator: generator,
                                       modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(report.changes.count, 1)
        let change = try XCTUnwrap(report.changes.first)
        XCTAssertEqual(change.original.text, segments[0].text, "reverting restores the line as transcribed")
        XCTAssertEqual(change.replacement, "Welcome to Roblox Studio, where we build games.")
        XCTAssertTrue(change.reason.contains("学習した直し") && change.reason.contains("build"))
    }
    /// 大文字小文字・記号だけが違う直しも、利用者が決めたものは当てる (LLM の直しとしては使わない組)
    func testSurfaceOnlyCorrectionsApply() {
        var ledger = CorrectionLedger()
        XCTAssertTrue(ledger.teach(wrong: "T-pie", right: "TPIE"))
        XCTAssertTrue(ledger.teach(wrong: "roblox", right: "Roblox"))
        XCTAssertTrue(ledger.teach(wrong: "ルータイス", right: "ルー・タイス"))
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "We finished the first unit of T-pie today."),
            TranscriptSegment(start: 2, end: 4, text: "I like roblox and t-pie."),
            TranscriptSegment(start: 4, end: 6, text: "Roblox is already right, and TPIE too."),
            TranscriptSegment(start: 6, end: 8, text: "ルータイス氏の言葉です。"),
            TranscriptSegment(start: 8, end: 10, text: "The magpie flew away."),
        ]
        let fixes = ledger.fixes(for: segments, language: nil)
        XCTAssertEqual(fixes.map(\.replacement), [
            "We finished the first unit of TPIE today.",
            "I like Roblox and TPIE.",
            "ルー・タイス氏の言葉です。",
        ])
        // LLM の直しとしては、今までどおり使わない
        XCTAssertNil(Auditor.applyFix(to: "the T-pie course", wrong: "T-pie", right: "TPIE"))
        XCTAssertEqual(Auditor.applyFix(to: "the T-pie course", wrong: "T-pie", right: "TPIE", surfaceOnly: true), "the TPIE course")
    }
}

final class LLMEvalTests: XCTestCase {
    private let roblox = AuditEvalCase(
        id: "en-roblox", language: "en", glossary: "Roblox Studio",
        lines: ["Welcome to Roblocks Studio.", "First, we will open a new place and add a part.",
                "First, we will open a new place and add a part.", "The whole whirled is watching.", "Thank you all."]
            + LLMEvalTests.filler,
        expected: ["Welcome to Roblox Studio.", "First, we will open a new place and add a part.", "",
                   "The whole world is watching.", "Thank you all."] + LLMEvalTests.filler)

    /// 直す行が半分近くになると「書き換え」とみなして提案どまりにするので、正しい行を足しておく
    private static let filler = ["Now we look at the next step.", "Please save your work often.", "This is the main menu.",
                                 "We will come back to it later.", "That is all for this part."]

    /// 評価役への問いに、指定した語を含む方の番号で答える偽の LLM
    private func generator(fixes: String, prefer markers: [String]) -> FakeGenerator {
        FakeGenerator { prompt in
            if prompt.user.contains("Lines to check") { return fixes }
            for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                if markers.contains(where: { line.contains($0) }) { return String(line.prefix(1)) }
            }
            return "1"
        }
    }

    func testAuditScoreCountsFixesMissesAndHarm() throws {
        // 規則だけ: 繰り返しの行は消える。聞き間違いは残る
        var result = try LLMEval.runAudit([roblox], generator: nil, modelName: nil)
        XCTAssertEqual(result.score.errorLines, 3)
        XCTAssertEqual(result.score.fixedAutomatically, 1)
        XCTAssertEqual(result.score.missed, 2)
        XCTAssertEqual(result.score.cleanLines, 7)
        XCTAssertEqual(result.score.harmed, 0)

        // LLM が 2 つとも直す (規則が消した行は LLM に見せないので、番号は詰まる)
        let good = generator(fixes: "[1] FIX Roblocks => Roblox\n[3] FIX whirled => world\nEND", prefer: ["Roblox ", "world"])
        result = try LLMEval.runAudit([roblox], generator: good, modelName: "fake")
        XCTAssertEqual(result.score.fixedAutomatically, 3, result.details.joined(separator: "\n"))
        XCTAssertEqual(result.score.missed, 0)
        XCTAssertEqual(result.score.recall, 1)
        XCTAssertEqual(result.score.precision, 1)

        // LLM が正しい行を壊す: 害として数える。評価役の判断が割れた直しは、提案どまり
        let bad = generator(fixes: "[2] FIX part => cart\n[3] FIX whirled => world\nEND", prefer: ["cart"])
        result = try LLMEval.runAudit([roblox], generator: bad, modelName: "fake")
        XCTAssertEqual(result.score.harmed, 1, result.details.joined(separator: "\n"))
        XCTAssertEqual(result.score.fixedAutomatically, 1)
        XCTAssertEqual(result.score.fixedBySuggestion, 1)
        XCTAssertEqual(result.score.missed, 1)
        XCTAssertLessThan(result.score.precision, 1)
        XCTAssertTrue(result.details.contains { $0.contains("HARMED") })

        // 学習した直しがあれば、LLM が無くても直る
        var ledger = CorrectionLedger()
        _ = ledger.teach(wrong: "Roblocks", right: "Roblox")
        _ = ledger.teach(wrong: "whirled", right: "world")
        result = try LLMEval.runAudit([roblox], generator: nil, modelName: nil, ledger: ledger)
        XCTAssertEqual(result.score.fixedAutomatically, 3)
        XCTAssertTrue(result.score.summary.contains("3 error lines"))
    }

    func testTranslationScoreChecksJapaneseNumbersAndTerms() {
        let c = TranslationEvalCase(id: "t", language: "en", lines: ["We sold 1500 units of Roblox toys.", "That is 30 percent more."],
                                    keep: ["Roblox"])
        var result = LLMEval.score(c, translations: ["Roblox のおもちゃを 1500 個売りました。", "それは３０パーセント多いです。"])
        XCTAssertEqual(result.score.translated, 2)
        XCTAssertEqual(result.score.japanese, 2)
        XCTAssertEqual(result.score.numbersKept, 2)
        XCTAssertEqual(result.score.numbersChecked, 2)
        XCTAssertEqual(result.score.termsKept, 1)
        XCTAssertTrue(result.details.isEmpty)
        // 数字と固有名詞を落とした訳・日本語でない訳
        result = LLMEval.score(c, translations: ["おもちゃをたくさん売りました。", "That is 30 percent more."])
        XCTAssertEqual(result.score.japanese, 1)
        XCTAssertEqual(result.score.numbersKept, 1)
        XCTAssertEqual(result.score.termsKept, 0)
        XCTAssertEqual(result.details.count, 3)
    }

    func testTheSeedSetLoadsAndIsWellFormed() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/llm-eval/seed.json")
        let set = try JSONDecoder().decode(LLMEvalSet.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(set.audit.count, 10)
        XCTAssertGreaterThanOrEqual(set.translation.count, 3)
        for c in set.audit {
            XCTAssertEqual(c.lines.count, c.expected.count, c.id)
            XCTAssertTrue(["ja", "en"].contains(c.language), c.id)
        }
        XCTAssertEqual(Set(set.audit.map(\.id)).count, set.audit.count)
        // 規則だけ (LLM なし) でも動き、正しい行を壊さない
        let rules = try LLMEval.runAudit(set.audit, generator: nil, modelName: nil)
        XCTAssertEqual(rules.score.harmed, 0, rules.details.joined(separator: "\n"))
        XCTAssertGreaterThan(rules.score.fixedAutomatically, 0)
    }
}

/// 追加学習用のデータ (台帳 → 監査役・評価役の問いと答え)
final class FineTuneDataTests: XCTestCase {
    private let clean = [
        "Welcome to today's session.", "First, we open Roblox Studio and add a part.", "Then we press the play button.",
        "Please save your work often.", "This is the main menu.", "We will come back to it later.",
    ].map { FineTuneData.CleanLine(text: $0, language: "en") }

    func testRecordsTeachAcceptedFixesRejectedFixesAndCleanLines() throws {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: "Welcome to Roblocks Studio.", accepted: true)
        ledger.record(wrong: "whirled", right: "world", language: "en", example: "The leaves whirled around the yard.", accepted: false)
        ledger.record(wrong: "undecided", right: "decided", language: "en", example: "It is undecided.", accepted: true)
        ledger.record(wrong: "undecided", right: "decided", language: "en", example: nil, accepted: false)
        let records = FineTuneData.records(ledger: ledger, cleanLines: clean)
        XCTAssertEqual(records, FineTuneData.records(ledger: ledger, cleanLines: clean), "the same ledger gives the same data")
        let audits = records.filter { $0.messages[1].content.contains("Lines to check") }
        let judges = records.filter { $0.messages[1].content.contains("Which version") }
        XCTAssertEqual(audits.count + judges.count, records.count)

        // 反映した直し: 誤りの語のある行の番号で FIX を答える。答えは、監査役が読める形
        let fixes = audits.filter { $0.messages[2].content.contains("FIX Roblocks => Roblox") }
        XCTAssertEqual(fixes.count, 3)
        for record in fixes {
            let user = record.messages[1].content
            let lines = user.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
            let actions = Auditor.parse(record.messages[2].content, count: lines.count)
            XCTAssertEqual(actions.count, 1)
            let number = try XCTUnwrap(actions.keys.first)
            XCTAssertTrue(lines[number - 1].contains("Roblocks"), user)
            XCTAssertEqual(record.messages[0].content, Auditor.systemPrompt(language: "en"))
            XCTAssertTrue(record.messages[2].content.hasSuffix("END\n"))
        }
        // 正しい語を含む行を誤りの語に戻した行も、例に使う
        XCTAssertTrue(fixes.contains { $0.messages[1].content.contains("we open Roblocks Studio and add a part") })
        // 断った直し: その行があっても END だけ。本物の誤り (world → whirled に戻した行) は作らない
        let refused = audits.filter { $0.messages[1].content.contains("whirled") }
        XCTAssertEqual(refused.count, 3)
        XCTAssertTrue(refused.allSatisfy { $0.messages[2].content == "END\n" })
        // 決まっていない直し (反映 1・元に戻す 1) は使わない
        XCTAssertFalse(records.contains { $0.messages[1].content.contains("undecided") })
        // 直す必要のないまとまり
        XCTAssertGreaterThanOrEqual(audits.filter { $0.messages[2].content == "END\n" && !$0.messages[1].content.contains("whirled") }.count, 2)
        // 評価役: 反映した直しは直した後、断った直しは直す前
        XCTAssertTrue(judges.contains { $0.messages[1].content.hasSuffix("1: Welcome to Roblocks Studio.\n2: Welcome to Roblox Studio.") && $0.messages[2].content == "2" })
        XCTAssertTrue(judges.contains { $0.messages[1].content.hasSuffix("1: Welcome to Roblox Studio.\n2: Welcome to Roblocks Studio.") && $0.messages[2].content == "1" })
        XCTAssertTrue(judges.contains { $0.messages[1].content.contains("1: The leaves whirled") && $0.messages[2].content == "1" })

        // 1 行に 1 つの JSON
        let text = FineTuneData.jsonl(records)
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.count, records.count)
        let decoded = try JSONDecoder().decode(FineTuneData.Record.self, from: Data(rows[0].utf8))
        XCTAssertEqual(decoded, records[0])
        XCTAssertEqual(decoded.messages.map(\.role), ["system", "user", "assistant"])
        XCTAssertTrue(FineTuneData.records(ledger: CorrectionLedger(), cleanLines: []).isEmpty)
    }
}
