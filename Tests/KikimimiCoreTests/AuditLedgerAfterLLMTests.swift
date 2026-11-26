import Foundation
import XCTest
@testable import KikimimiCore

/// 「LLM の監査が終わった後も、学習した直しの自動の直しが残る」事を見る。
/// アプリの流れ (`AppModel.runPost(.audit)`、前の LLM の監査が無い時) と同じ順に、KikimimiCore の関数を呼ぶ:
/// 監査の前の行と AuditOptions (台帳・利用者の決めた事) を始めに 1 回だけ決め、
/// (1) 規則だけの `Auditor.audit(generator: nil)` → `adopt`、(2) LLM つきの `Auditor.audit` → `adopt`。
/// アプリの側の呼び方そのもの (runPost) は、この試験では見ていない
final class AuditLedgerAfterLLMTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.language = .ja
    }

    override func tearDown() {
        L10n.language = .en
        super.tearDown()
    }

    // 行の番号 (segments の位置)
    private let autoLine = 0      // 自動の組 (2 回反映した Roblocks → Roblox) が当たる
    private let taughtLine = 1    // 自動の組 (教えた Lewa → Luau) が当たる
    private let suggestLine = 2   // 提案どまりの組 (1 回反映した Lou Tyce → Lou Tice) が当たる
    private let revertLine = 3    // 自動の組が当たるが、(1) の後に利用者が「元に戻す」
    private let editedLine = 4    // 自動の組が当たるが、(1) の後に利用者が手で直す
    private let otherLine = 5     // 台帳の組は当たらない。LLM が別の直しを見つける事が在る

    /// 試験の行 (id を試験の中で同じにするため、1 回だけ作る)
    private lazy var fixedSegments: [TranscriptSegment] = [
        "Open Roblocks Studio first.",
        "We write Lewa scripts every day.",
        "This program was created by Lou Tyce.",
        "Our studio is called Roblocks Labs.",
        "Roblocks was the old name of the team.",
        "We will bild a small game today."
    ].enumerated().map { TranscriptSegment(start: Double($0.offset) * 3, end: Double($0.offset) * 3 + 3, text: $0.element) }

    private func makeSegments() -> [TranscriptSegment] { fixedSegments }

    private func makeLedger() -> CorrectionLedger {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: nil, accepted: true)
        ledger.record(wrong: "Roblocks", right: "Roblox", language: "en", example: nil, accepted: true)
        _ = ledger.teach(wrong: "Lewa", right: "Luau")
        ledger.record(wrong: "Lou Tyce", right: "Lou Tice", language: "en", example: nil, accepted: true)
        XCTAssertEqual(ledger.corrections.map(\.isAutomatic), [true, true, false])
        return ledger
    }

    /// LLM に出させる直し: 見せた行のうち `line` を含む行に「FIX wrong => right」と答える
    /// (1 行だけに答える。半分近くの行を直す答えは、監査役が全部を提案どまりにするので)
    private typealias LLMFix = (line: String, wrong: String, right: String)

    /// 偽の LLM: 「Lines to check」の行に、fixes の直しを答える。
    /// 評価役 (1: … / 2: …) には、直した後の語 (right) を含む方を選ぶ
    private func fakeLLM(_ fixes: [LLMFix]) -> FakeGenerator {
        FakeGenerator { prompt in
            if let range = prompt.user.range(of: "Lines to check:\n") {
                var answer: [String] = []
                for line in prompt.user[range.upperBound...].split(separator: "\n") {
                    guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
                    let number = line[line.index(after: line.startIndex)..<close]
                    for fix in fixes where line.contains(fix.line) && line.contains(fix.wrong) {
                        answer.append("[\(number)] FIX \(fix.wrong) => \(fix.right)")
                    }
                }
                return (answer + ["END"]).joined(separator: "\n")
            }
            for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                if fixes.contains(where: { line.contains($0.right) }) { return String(line.prefix(1)) }
            }
            return "1"
        }
    }

    /// アプリと同じ順に (1) → 利用者の決め事 → (2) を通し、(1) の後と (2) の後の結果を返す
    private func runFlow(llm fixes: [LLMFix],
                         file: StaticString = #filePath, line: UInt = #line) throws -> (afterRules: Transcript, afterLLM: Transcript) {
        let segments = makeSegments()
        var transcript = Transcript(sourceName: "x", segments: segments, language: "en")
        // アプリと同じく、監査の前の行と、台帳・利用者の決めた事は、始めに 1 回だけ決める
        let before = transcript.segmentsBeforeAudit
        let options = AuditOptions(ledger: makeLedger(), decisions: transcript.audit?.userDecisions ?? [:])

        // (1) 規則だけの監査 → 反映
        transcript.adopt(try Auditor.audit(before, language: "en", options: options, generator: nil,
                                           modelName: nil, shouldCancel: { false }))
        // 利用者: 1 行の自動の直しを元に戻し、1 行を手で直す (LLM の監査が走っている間の操作)
        let reverted = try XCTUnwrap(transcript.audit?.change(forSegment: segments[revertLine].id), file: file, line: line)
        XCTAssertTrue(reverted.isApplied, file: file, line: line)
        transcript.setChange(reverted.id, applied: false)
        XCTAssertTrue(transcript.setLineText("Roblocks was really the old name of the team.",
                                             forSegment: segments[editedLine].id), file: file, line: line)
        let afterRules = transcript

        // (2) 偽の LLM つきの監査 → 反映
        transcript.adopt(try Auditor.audit(before, language: "en", options: options, generator: fakeLLM(fixes),
                                           modelName: "fake", shouldCancel: { false }))
        return (afterRules, transcript)
    }

    /// (1) の後と (2) の後で、同じでなければならない事を見る。
    /// autoText: 自動の組の行 (autoLine) の、あるはずの字 (LLM が同じ行を直す試験だけが変える)
    private func assertLedgerResultsSurvive(_ t: Transcript, label: String, autoText: String = "Open Roblox Studio first.",
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let segments = makeSegments()
        func text(_ i: Int) -> String? { t.segments.first { $0.id == segments[i].id }?.text }
        func change(_ i: Int) -> AuditChange? { t.audit?.change(forSegment: segments[i].id) }
        // 自動の組の行は、直ったまま
        XCTAssertEqual(text(autoLine), autoText, label, file: file, line: line)
        XCTAssertEqual(change(autoLine)?.isApplied, true, label, file: file, line: line)
        XCTAssertEqual(text(taughtLine), "We write Luau scripts every day.", label, file: file, line: line)
        XCTAssertEqual(change(taughtLine)?.isApplied, true, label, file: file, line: line)
        // 提案どまりの組は、提案のまま (行は聞き取ったまま)
        XCTAssertEqual(text(suggestLine), segments[suggestLine].text, label, file: file, line: line)
        XCTAssertEqual(change(suggestLine)?.isApplied, false, label, file: file, line: line)
        XCTAssertEqual(change(suggestLine)?.replacement, "This program was created by Lou Tice.", label, file: file, line: line)
        // 利用者が元に戻した行は、戻したまま (提案としては残る)
        XCTAssertEqual(text(revertLine), segments[revertLine].text, label, file: file, line: line)
        XCTAssertEqual(change(revertLine)?.isApplied, false, label, file: file, line: line)
        // 手で直した行は、触られていない (監査の直しも無い)
        XCTAssertEqual(text(editedLine), "Roblocks was really the old name of the team.", label, file: file, line: line)
        XCTAssertNil(change(editedLine), label, file: file, line: line)
        XCTAssertNotNil(t.lineEdit(forSegment: segments[editedLine].id), label, file: file, line: line)
    }

    /// (1) の後: 自動の組は直り、提案どまりの組は提案。利用者の決め事も入っている
    func testRulesOnlyAuditAppliesAutomaticPairs() throws {
        let flow = try runFlow(llm: [])
        try assertLedgerResultsSurvive(flow.afterRules, label: "after rules")
        XCTAssertNil(flow.afterRules.audit?.model)
    }

    /// (2) LLM が何も見つけない: 自動の直し・提案・利用者の決め事は、(1) の後と同じ
    func testAutomaticFixesSurviveAnLLMThatFindsNothing() throws {
        let flow = try runFlow(llm: [])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "LLM found nothing")
        XCTAssertEqual(flow.afterLLM.audit?.model, "fake")
        XCTAssertEqual(flow.afterLLM.segments.map(\.text), flow.afterRules.segments.map(\.text))
    }


    /// (2) LLM が別の行に別の直しを見つける: その行だけが直り、ほかは (1) の後と同じ
    func testAutomaticFixesSurviveAnLLMFixOnAnotherLine() throws {
        let flow = try runFlow(llm: [(line: "small game", wrong: "bild", right: "build")])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "LLM fixed another line")
        let other = makeSegments()[otherLine]
        XCTAssertEqual(flow.afterLLM.segments.first { $0.id == other.id }?.text, "We will build a small game today.")
        let change = try XCTUnwrap(flow.afterLLM.audit?.change(forSegment: other.id))
        XCTAssertEqual(change.origin, .llm)
        XCTAssertTrue(change.isApplied)
        XCTAssertEqual(flow.afterRules.segments.first { $0.id == other.id }?.text, other.text)
    }

    // MARK: 自動の組が当たる同じ行に、LLM が別の直しを出す (今の動きを書く)

    /// 自動の組の行の、(2) の後の直し (1 区間 1 件のはず) を返す。行の字も返す
    private func autoLineResult(_ t: Transcript, file: StaticString = #filePath,
                                line: UInt = #line) throws -> (text: String?, change: AuditChange) {
        let target = makeSegments()[autoLine]
        let changes = t.audit?.changes.filter { $0.original.id == target.id } ?? []
        XCTAssertEqual(changes.count, 1, "one change per line", file: file, line: line)
        let change = try XCTUnwrap(changes.first, file: file, line: line)
        // 元に戻すと、聞き取った字 (学習した直しの前) に戻る
        XCTAssertEqual(change.original.text, target.text, file: file, line: line)
        return (t.segments.first { $0.id == target.id }?.text, change)
    }

    /// 元に戻すと、聞き取った行に戻る事を見る
    private func assertRevertGivesTheHeardLine(_ t: Transcript, _ change: AuditChange,
                                               file: StaticString = #filePath, line: UInt = #line) {
        var t = t
        t.setChange(change.id, applied: false)
        let target = makeSegments()[autoLine]
        XCTAssertEqual(t.segments.first { $0.id == target.id }?.text, target.text, file: file, line: line)
    }

    /// LLM は、学習した直しを当てた後の行 (Open Roblox Studio first.) を見る。
    /// その同じ字 (Roblox) を、別の字 (Roblux) にする直しを、自信ありで出した (LLM だけなら当たる直し)。
    /// 学習した直しが書いた字に重なる LLM の直しは捨てる: 変更は学習した直しの物だけで、行は「Roblox」のまま。
    /// 元に戻すと、聞き取った行に戻る
    func testLLMChangesTheLearnedWordOnAnAutomaticLine() throws {
        let flow = try runFlow(llm: [(line: "Studio first", wrong: "Roblox", right: "Roblux")])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "same word")
        let result = try autoLineResult(flow.afterLLM)
        XCTAssertEqual(result.text, "Open Roblox Studio first.")
        XCTAssertEqual(result.change.origin, .ledger)
        XCTAssertTrue(result.change.isApplied)
        XCTAssertEqual(result.change.decisionPairs, [AuditChange.Pair(wrong: "Roblocks", right: "Roblox")])
        assertRevertGivesTheHeardLine(flow.afterLLM, result.change)
        // 学習した直しが無ければ、この LLM の直しは自信ありで当たる (捨てたのは、重なりのため)
        let alone = try Auditor.audit([TranscriptSegment(start: 0, end: 3, text: "Open Roblox Studio first.")], language: "en",
                                      generator: fakeLLM([(line: "Studio first", wrong: "Roblox", right: "Roblux")]),
                                      modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(alone.changes.map(\.replacement), ["Open Roblux Studio first."])
        XCTAssertEqual(alone.changes.map(\.isConfident), [true])
    }

    /// 重なりの見方 (`Auditor.touches`): 変わった所が、学習した直しの字の場所に重なるか
    func testOverlapIsSeenByPosition() {
        func touches(_ before: String, _ after: String, _ words: [String]) -> Bool {
            Auditor.touches(AuditChange(kind: .fix, origin: .llm, original: TranscriptSegment(start: 0, end: 1, text: before),
                                        replacement: after, reason: "", isConfident: true), words: words)
        }
        // 書き換える・一部を変える・字をくっつける・語の中に足す: 重なり
        XCTAssertTrue(touches("Open Roblox Studio first.", "Open Roblux Studio first.", ["Roblox"]))
        XCTAssertTrue(touches("Open Roblox Studio first.", "Open Robloxs Studio first.", ["Roblox"]))
        XCTAssertTrue(touches("Open Roblox Studio first.", "Open xRoblox Studio first.", ["Roblox"]))
        XCTAssertTrue(touches("Open Roblox Studio first.", "Open Rob-lox Studio first.", ["Roblox"]))
        XCTAssertTrue(touches("毎朝、公演を走っています。", "毎朝、公演を歩いています。", ["走って"]))
        // 大文字小文字は区別しない (文の頭で大文字になった字も見る)
        XCTAssertTrue(touches("Roblox is fun.", "Roblux is fun.", ["roblox"]))
        // 別の語を直す・語の外に空白つきで足す・句読点を変える: 重ならない
        XCTAssertFalse(touches("Open Roblox Studio first.", "Open Roblox Stadium first.", ["Roblox"]))
        XCTAssertFalse(touches("Open Roblox Studio first.", "Open the Roblox Studio first.", ["Roblox"]))
        XCTAssertFalse(touches("Open Roblox Studio first.", "Open Roblox Studio first!", ["Roblox"]))
        XCTAssertFalse(touches("毎朝、公演を走っています。", "毎朝、公園を走っています。", ["走って"]))
        // 同じ語が 2 回在る時は、どちらに重なっても重なり
        XCTAssertTrue(touches("Roblox and Roblox.", "Roblox and Roblux.", ["Roblox"]))
        XCTAssertFalse(touches("x", "y", []))
    }

    /// 提案どまり (反映 1 回) の組の行で、LLM が、その組の聞き間違えた字 (Tyce) を、学習した直しと違う字 (Tyson) に直した。
    /// 利用者が前に決めた組の提案を残す (LLM の直しで黙って置き換えない。自動の組の行と同じ考え方)。行は聞き取ったまま
    func testLLMChangesTheWrongWordOfASuggestedPair() throws {
        let flow = try runFlow(llm: [(line: "Lou Tyce", wrong: "Tyce", right: "Tyson")])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "suggested pair")
        let target = makeSegments()[suggestLine]
        let change = try XCTUnwrap(flow.afterLLM.audit?.change(forSegment: target.id))
        XCTAssertEqual(change.origin, .ledger)
        XCTAssertEqual(change.replacement, "This program was created by Lou Tice.")
        XCTAssertFalse(change.isApplied)
        // 学習した直しが無ければ、この LLM の直しは自信ありで当たる (残したのは、重なりのため)
        XCTAssertEqual(try confidenceAlone(target.text, [(line: "Lou Tyce", wrong: "Tyce", right: "Tyson")]), [true])
    }

    /// 学習した直しが無い時に、LLM の直しが自信ありか (重なりのせいで捨てた事を確かめるため)
    private func confidenceAlone(_ text: String, _ fixes: [LLMFix]) throws -> [Bool] {
        try Auditor.audit([TranscriptSegment(start: 0, end: 3, text: text)], language: "en", generator: fakeLLM(fixes),
                          modelName: "fake", shouldCancel: { false }).changes.map(\.isConfident)
    }

    /// 提案どまりの組の行で、LLM が学習した直しと同じ直し (Tyce → Tice) を出した: 今まで通り、LLM の直しが提案に代わって当たる
    func testLLMAgreeingWithASuggestedPairStillApplies() throws {
        let flow = try runFlow(llm: [(line: "Lou Tyce", wrong: "Tyce", right: "Tice")])
        let target = makeSegments()[suggestLine]
        let change = try XCTUnwrap(flow.afterLLM.audit?.change(forSegment: target.id))
        XCTAssertEqual(change.origin, .llm)
        XCTAssertEqual(change.replacement, "This program was created by Lou Tice.")
        XCTAssertEqual(change.isApplied, change.isConfident)
    }

    /// 日本語: 台帳の自動の組「浜って → 走って」が当たった行で、LLM が「走って → 歩いて」と直した。
    /// 学習した直しの字に重なるので捨てる。行は「走って」のまま。同じ行の重ならない直し (公演 → 公園) は、まとめて当てる
    func testJapaneseLLMFixOverTheLearnedWordIsDropped() throws {
        L10n.language = .ja
        var ledger = CorrectionLedger()
        for _ in 0..<2 { ledger.record(wrong: "浜って", right: "走って", language: "ja", example: nil, accepted: true) }
        let line = TranscriptSegment(start: 0, end: 3, text: "毎朝、公演を浜っています。")
        func run(_ fixes: [LLMFix]) throws -> Transcript {
            var t = Transcript(sourceName: "x", segments: [line], language: "ja")
            let options = AuditOptions(ledger: ledger)
            t.adopt(try Auditor.audit([line], language: "ja", options: options, generator: nil, modelName: nil, shouldCancel: { false }))
            t.adopt(try Auditor.audit([line], language: "ja", options: options, generator: fakeLLM(fixes),
                                      modelName: "fake", shouldCancel: { false }))
            return t
        }
        let over = try run([(line: "毎朝", wrong: "走って", right: "歩いて")])
        XCTAssertEqual(over.segments.map(\.text), ["毎朝、公演を走っています。"])
        XCTAssertEqual(over.audit?.changes.map(\.origin), [.ledger])
        // 学習した直しが無ければ、この LLM の直しは自信ありで当たる (捨てたのは、重なりのため)
        let alone = try Auditor.audit([TranscriptSegment(start: 0, end: 3, text: "毎朝、公演を走っています。")], language: "ja",
                                      generator: fakeLLM([(line: "毎朝", wrong: "走って", right: "歩いて")]),
                                      modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(alone.changes.map(\.isConfident), [true])
        let apart = try run([(line: "毎朝", wrong: "公演", right: "公園")])
        XCTAssertEqual(apart.segments.map(\.text), ["毎朝、公園を走っています。"])
        XCTAssertEqual(apart.audit?.changes.map(\.origin), [.llm])
        var reverted = apart
        reverted.setChange(try XCTUnwrap(apart.audit?.changes.first).id, applied: false)
        XCTAssertEqual(reverted.segments.map(\.text), [line.text])
    }

    /// LLM が、学習した直しの前の字 (Roblocks。LLM には見えていない字) を直すと答えた。
    /// 今の動き: 見せた行に無い字の直しなので使われず、自動の直しがそのまま残る
    func testLLMFixOfTheHeardWordOnAnAutomaticLineIsIgnored() throws {
        let flow = try runFlow(llm: [(line: "Studio first", wrong: "Roblocks", right: "Roblux")])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "heard word")
        let result = try autoLineResult(flow.afterLLM)
        XCTAssertEqual(result.text, "Open Roblox Studio first.")
        XCTAssertEqual(result.change.origin, .ledger)
        XCTAssertTrue(result.change.isApplied)
    }

    /// LLM が、同じ行の別の字 (Studio → Stadium) を直した。
    /// 今の動き: 学習した直しと LLM の直しが 1 件にまとまり、両方が当たる (Roblox も Stadium も入る)
    func testLLMFixesAnotherWordOnAnAutomaticLine() throws {
        let flow = try runFlow(llm: [(line: "Studio first", wrong: "Studio", right: "Stadium")])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "other word", autoText: "Open Roblox Stadium first.")
        let result = try autoLineResult(flow.afterLLM)
        XCTAssertEqual(result.change.origin, .llm)
        XCTAssertTrue(result.change.isApplied)
        XCTAssertEqual(result.change.decisionPairs, [AuditChange.Pair(wrong: "Roblocks", right: "Roblox"),
                                                     AuditChange.Pair(wrong: "Studio", right: "Stadium")])
        assertRevertGivesTheHeardLine(flow.afterLLM, result.change)
    }

    /// LLM が、同じ行の別の字に、確かめてもらう直し (数が変わる first → second) を出した。
    /// 今の動き: 自信の無い LLM の直しは捨てられ、自動の直しだけが残る (1 区間 1 件)
    func testUnsureLLMFixOnAnAutomaticLineIsDropped() throws {
        let flow = try runFlow(llm: [(line: "Studio first", wrong: "first", right: "second")])
        try assertLedgerResultsSurvive(flow.afterLLM, label: "unsure other word")
        let result = try autoLineResult(flow.afterLLM)
        XCTAssertEqual(result.text, "Open Roblox Studio first.")
        XCTAssertEqual(result.change.origin, .ledger)
    }
}
