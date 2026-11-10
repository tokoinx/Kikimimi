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
        XCTAssertEqual(ledger.glossary(adding: "ききみみ"), "ききみみ, Roblox")
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
}

/// 評価ハーネス (決まった場面で監査役・翻訳役を動かして採点する)
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
