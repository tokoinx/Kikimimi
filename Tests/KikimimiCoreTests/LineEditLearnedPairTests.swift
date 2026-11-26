import Foundation
import XCTest
@testable import KikimimiCore

/// 行を直す画面の「この直しを覚える」の組 (画面が見せる組 = 保存が覚える組) と、トグルの初めの値の試験
final class LineEditLearnedPairTests: XCTestCase {
    private let heard = "彼女も川沿いを浜っていました。"
    private let edited = "彼女も川沿いを走っています。"

    /// 学習した直し (浜って → 走って、自動) を反映した行 (彼女も川沿いを走っていました。) を作る
    private func auditFixedTranscript() throws -> (Transcript, UUID) {
        var ledger = CorrectionLedger()
        for _ in 0..<2 { ledger.record(wrong: "浜って", right: "走って", language: "ja", example: nil, accepted: true) }
        let segment = TranscriptSegment(start: 0, end: 2, text: heard)
        var t = Transcript(sourceName: "x", segments: [segment, TranscriptSegment(start: 2, end: 4, text: "次の文です。")],
                           language: "ja")
        t.adopt(try Auditor.audit(t.segmentsBeforeAudit, language: "ja", options: AuditOptions(ledger: ledger),
                                  generator: nil, modelName: nil, shouldCancel: { false }))
        XCTAssertEqual(t.segments[0].text, "彼女も川沿いを走っていました。")
        XCTAssertEqual(t.audit?.change(forSegment: segment.id)?.isApplied, true)
        return (t, segment.id)
    }

    /// 監査の直しを反映していた行を直す時: 画面が見せる組 (`suggestedLearnedPair`) は、保存が記録に残す聞き取った文
    /// (監査の前の文) から切り出す。その組で保存すると、記録の組も、台帳に渡す組も、同じ組になる。
    /// 記録の聞き取った文の中の wrong を right に置き換えると、直した文になる (`suggestedSpan` の決まり)
    func testPairOnAnAuditFixedLineIsTheOneTheSaveKeeps() throws {
        var (t, id) = try auditFixedTranscript()
        // 画面と保存の、聞き取った文は同じ (監査の前の文)
        XCTAssertEqual(t.heardText(forSegment: id), heard)
        let shown = try XCTUnwrap(t.suggestedLearnedPair(forSegment: id, edited: edited))
        XCTAssertEqual(shown, AuditChange.Pair(wrong: "浜っていました", right: "走っています"))
        XCTAssertEqual(heard.replacingOccurrences(of: shown.wrong, with: shown.right), edited)
        // 前の画面の決め方 (監査の直しの後の字から切り出す) では「ました → ます」になり、
        // 記録の聞き取った文 (浜っていました) に当てても、直した文にならない
        let old = try XCTUnwrap(LineEdit.suggestedPair(heard: t.segments[0].text, edited: edited))
        XCTAssertEqual(old, AuditChange.Pair(wrong: "ました", right: "ます"))
        XCTAssertNotEqual(heard.replacingOccurrences(of: old.wrong, with: old.right), edited)

        // 画面の組で保存する (アプリの保存は、画面の組をそのまま渡す)
        XCTAssertTrue(t.setLineText(edited, forSegment: id, learned: shown))
        let edit = try XCTUnwrap(t.lineEdit(forSegment: id))
        XCTAssertEqual(edit.heard, heard)
        XCTAssertEqual(edit.learned, shown)
        // 台帳に渡す組 (`ledgerUpdate`) も同じ
        XCTAssertEqual(LineEdit.ledgerUpdate(old: nil, new: edit.learned).record, shown)
        // 直した後にもう一度開いても、聞き取った文と組は同じ
        XCTAssertEqual(t.heardText(forSegment: id), heard)
        XCTAssertEqual(t.suggestedLearnedPair(forSegment: id, edited: edited), shown)
    }

    /// 聞き取った文の決め方: 直していない・監査の直しも無い行は今の文。区間が無ければ nil
    func testHeardTextOfOtherLines() throws {
        let (t, _) = try auditFixedTranscript()
        let other = t.segments[1]
        XCTAssertEqual(t.heardText(forSegment: other.id), other.text)
        XCTAssertNil(t.suggestedLearnedPair(forSegment: other.id, edited: other.text))
        XCTAssertNil(t.heardText(forSegment: UUID()))
        XCTAssertNil(t.suggestedLearnedPair(forSegment: UUID(), edited: "x"))
    }

    /// トグルの初めの値: 2 つの語がどちらも ひらがなだけの組は切。カタカナ・漢字を含む組・英語の組は入
    func testRemembersByDefault() {
        func p(_ w: String, _ r: String) -> AuditChange.Pair { AuditChange.Pair(wrong: w, right: r) }
        // ひらがなだけ (活用の尻・助詞): 切
        XCTAssertFalse(LineEdit.remembersByDefault(p("ました", "ます")))
        XCTAssertFalse(LineEdit.remembersByDefault(p("を", "に")))
        XCTAssertFalse(LineEdit.remembersByDefault(p("いる", "いた")))
        XCTAssertFalse(LineEdit.remembersByDefault(p("すーぱー", "すうぱあ")), "the long vowel mark counts as hiragana")
        // 漢字・カタカナを含む: 入
        XCTAssertTrue(LineEdit.remembersByDefault(p("浜って", "走って")))
        XCTAssertTrue(LineEdit.remembersByDefault(p("はし", "箸")))
        XCTAssertTrue(LineEdit.remembersByDefault(p("こうえん", "公園")))
        XCTAssertTrue(LineEdit.remembersByDefault(p("ろぶろっくす", "ロブロックス")))
        XCTAssertTrue(LineEdit.remembersByDefault(p("浜っていました", "走っています")))
        // 英語: 今まで通り (2 字以上なら入、1 字なら切)
        XCTAssertTrue(LineEdit.remembersByDefault(p("Roblocks", "Roblox")))
        XCTAssertFalse(LineEdit.remembersByDefault(p("a", "an")))
        XCTAssertFalse(LineEdit.remembersByDefault(nil))
        // 文から切り出した組でも同じ (「を → に」は、切り出すと右隣の語まで広がり、漢字を含むので入になる)
        XCTAssertEqual(LineEdit.suggestedPair(heard: "今日は東京に行きました。", edited: "今日は東京に行きます。"), p("ました", "ます"))
        XCTAssertEqual(LineEdit.suggestedPair(heard: "彼は家にいる。", edited: "彼は家にいた。"), p("いる", "いた"))
        XCTAssertEqual(LineEdit.suggestedPair(heard: "駅を行く。", edited: "駅に行く。"), p("を行く", "に行く"))
        XCTAssertTrue(LineEdit.remembersByDefault(p("を行く", "に行く")))
    }

    /// 見張り: 行を直す画面は、保存と同じ関数で組を出し、初めの値も同じ関数で決める (ソースを読んで見る)。
    /// アプリの保存 (`AppModel.setLineTexts`) は、組を切り出し直さず、画面の組をそのまま渡す
    func testTheLineEditSheetUsesTheSameFunctions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Kikimimi")
        let sheet = try String(contentsOf: root.appendingPathComponent("Views/LineEditSheet.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains(".suggestedLearnedPair(forSegment:"))
        XCTAssertTrue(sheet.contains(".heardText(forSegment:"))
        XCTAssertTrue(sheet.contains("LineEdit.remembersByDefault("))
        XCTAssertFalse(sheet.contains("LineEdit.suggestedPair("), "the sheet must not cut the pair from another text")
        XCTAssertFalse(sheet.contains("letterCount("), "the default of the toggle is LineEdit.remembersByDefault")
        let save = try String(contentsOf: root.appendingPathComponent("AppModel+LineEdit.swift"), encoding: .utf8)
        XCTAssertFalse(save.contains("suggestedPair("), "the save keeps the pair the sheet showed")
        XCTAssertFalse(save.contains("suggestedLearnedPair("), "the save keeps the pair the sheet showed")
    }
}
