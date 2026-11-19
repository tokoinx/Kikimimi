import Foundation
import XCTest
@testable import KikimimiCore

/// 訳の関門を翻訳に入れる (U3): 印だけを付ける「要確認」と、訳せなかった行の理由
final class TranslationGateFlowTests: XCTestCase {
    private func seg(_ start: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, text: text)
    }

    /// 1 行ごとに、決めた訳を返す偽の LLM (原文 → 訳。無い原文には何も返さない)
    private func fake(_ answers: [String: String]) -> FakeGenerator {
        FakeGenerator { prompt in
            prompt.user.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      Int(line[line.index(after: line.startIndex)..<close]) != nil else { return nil }
                let source = String(line[line.index(close, offsetBy: 2)...])
                return answers[source].map { "\(line[...close]) \($0)" }
            }.joined(separator: "\n") + "\n"
        }
    }

    private let sold = "We sold 4,000 units in 15 days, which is a record for our small team."
    private let goodSold = "私たちは15日間で4,000個を売りました。小さなチームにとっての記録です。"
    private let lostSold = "私たちはたくさんの製品を売りました。小さなチームにとっての記録です。"
    private let weather = "The weather was very nice yesterday, so we went for a long walk in the park."
    private let goodWeather = "昨日はとても天気が良かったので、公園を長い時間散歩しました。"

    private func run(_ segments: [TranscriptSegment], _ answers: [String: String], target: String = "ja",
                     memory: TranslationMemoryLookup? = nil) throws -> (TranslationRunSummary, [TranslationResult]) {
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: target, memory: memory,
                                                          generator: fake(answers),
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        return (summary, all)
    }

    /// 結果に置く (AppModel と同じく、訳の結果の後に、訳せなかった理由を置く)
    private func applied(_ segments: [TranscriptSegment], _ summary: TranslationRunSummary,
                         _ results: [TranslationResult]) -> Transcript {
        var t = Transcript(sourceName: "a", segments: segments, language: "en", translationLanguage: "ja")
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        for r in results { XCTAssertTrue(t.apply(r, sources: sources)) }
        for r in summary.rejected { XCTAssertTrue(t.apply(r, sources: sources)) }
        return t
    }

    private func rows(_ t: Transcript) -> (cache: TranscriptRowCache, items: [TranscriptListItem]) {
        let cache = TranscriptRowCache()
        let items = cache.items(of: t, job: UUID(), done: true, bilingual: true, query: "", target: "ja")
        return (cache, items)
    }

    // MARK: 印だけ (訳は入る)

    func testMissingNumberGetsANoteButTheTranslationIsUsed() throws {
        let segments = [seg(0, sold), seg(3, weather)]
        let (summary, results) = try run(segments, [sold: lostSold, weather: goodWeather])
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.flagged, 1)
        XCTAssertTrue(summary.rejected.isEmpty)
        let flagged = try XCTUnwrap(results.first { $0.head == segments[0].id })
        XCTAssertEqual(flagged.text, lostSold, "訳は入れ替えない")
        XCTAssertEqual(flagged.flags, ["number"])
        XCTAssertEqual(flagged.detail, "number: 15, 4000")

        let t = applied(segments, summary, results)
        XCTAssertEqual(t.segments[0].translation, lostSold)
        let note = try XCTUnwrap(t.translationNote(for: segments[0].id))
        XCTAssertEqual(note.origin, TranslationNote.llm)
        XCTAssertTrue(note.isFlagged)
        XCTAssertEqual(note.flags, ["number"])
        XCTAssertEqual(note.reasonTexts, [L("A number from the original is missing: %@", "15, 4000")])
        XCTAssertTrue(t.userTranslatedIDs.isEmpty, "印の付いた機械の訳は守らない")
        // 正しい訳には、覚えを作らない
        XCTAssertNil(t.translationNote(for: segments[1].id))
        XCTAssertEqual(t.flaggedTranslationCount, 1)

        // 行の覚え: 印の付いた行だけが「要確認」。数は、行を作る時に数えてある
        let (cache, items) = rows(t)
        XCTAssertEqual(items.map(\.needsTranslationReview), [true, false])
        XCTAssertEqual(cache.flaggedItemIDs, [segments[0].id])
    }

    func testCorrectTranslationsGetNoNotes() throws {
        let segments = [seg(0, sold), seg(3, weather)]
        let (summary, results) = try run(segments, [sold: goodSold, weather: goodWeather])
        XCTAssertEqual(summary.flagged, 0)
        XCTAssertTrue(results.allSatisfy { $0.flags.isEmpty })
        let t = applied(segments, summary, results)
        XCTAssertNil(t.translationReview)
        XCTAssertTrue(rows(t).cache.flaggedItemIDs.isEmpty)
    }

    func testShortCopyIsNotMarkedButALongCopyIs() throws {
        let short = "No."
        let long = "Roblox Studio Developer Conference keynote"
        let segments = [seg(0, short), seg(3, long)]
        let (summary, results) = try run(segments, [short: short, long: long], target: "fr")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(results.first { $0.head == segments[0].id }?.flags.contains("copied"), false)
        XCTAssertEqual(results.first { $0.head == segments[1].id }?.flags.contains("copied"), true)
    }

    func testRepeatedIsOnlyAMark() throws {
        // 繰り返しは重い印でない: 訳は受け取り、印だけを付ける
        let source = "See you next time, everyone, and thank you for watching the stream."
        let repeated = "à bientôt à bientôt à bientôt à bientôt à bientôt à bientôt"
        let segments = [seg(0, source)]
        let (summary, results) = try run(segments, [source: repeated], target: "fr")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(results.first?.text, repeated)
        XCTAssertEqual(results.first?.flags.contains("repeated"), true)
    }

    // MARK: 訳せなかった行の理由

    func testWrongScriptIsRejectedAndTheReasonIsKept() throws {
        let segments = [seg(0, weather)]
        let chinese = "昨天天气很好，所以我们在公园里散步了很久。"
        let (summary, results) = try run(segments, [weather: chinese])
        XCTAssertTrue(results.isEmpty, "訳の結果としては渡さない (今の呼び手を変えない)")
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.rejected.map(\.flags), [["script"]])
        XCTAssertTrue(summary.rejected.allSatisfy(\.isRejection))

        var t = applied(segments, summary, results)
        XCTAssertNil(t.segments[0].translation, "訳は入らない")
        let note = try XCTUnwrap(t.translationNote(for: segments[0].id))
        XCTAssertEqual(note.origin, TranslationNote.llm)
        XCTAssertEqual(note.signature, Transcript.reviewSignature(source: weather, translation: ""))
        XCTAssertEqual(note.reasonTexts, [L("The translation used the wrong kind of letters, so it was not used.")])
        XCTAssertEqual(t.flaggedTranslationCount, 0, "訳の無い行は「要確認」に数えない")
        let (cache, items) = rows(t)
        XCTAssertEqual(items.first?.hasUntranslatedReason, true)
        XCTAssertEqual(items.first?.needsTranslationReview, false)
        XCTAssertTrue(cache.flaggedItemIDs.isEmpty)

        // 後から訳が入ると、理由の覚えは無い物になる (signature が合わない。置いた時に捨てる)
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        XCTAssertTrue(t.apply(TranslationResult(head: segments[0].id, covers: [], text: goodWeather), sources: sources))
        XCTAssertNil(t.translationNote(for: segments[0].id))
        XCTAssertNil(t.translationReview)
        // 置き方を通さずに訳が入っても、覚えは合わなくなる
        var u = applied(segments, summary, [])
        u.segments[0].translation = goodWeather
        XCTAssertNil(u.translationNote(for: segments[0].id))
    }

    func testNoAnswerIsFailedAndTooLongIsLong() throws {
        let other = "Right, and that is exactly the point where people run into trouble."
        let segments = [seg(0, weather), seg(3, other)]
        let (summary, _) = try run(segments, [other: String(repeating: "とても長い訳です。", count: 40)])
        XCTAssertEqual(summary.failed, 2)
        XCTAssertEqual(summary.rejected.map(\.flags), [["failed"], ["long"]])
        XCTAssertEqual(TranslationNote.reasonText("failed", detail: nil), L("The model returned no translation for this line."))
        XCTAssertNil(TranslationNote.reasonText("unknown", detail: nil), "知らない符号は出さない")
    }

    func testRejectionIsNotRecordedOverATranslation() {
        // 区間にもう訳が在る時は、理由を残さない
        var s = seg(0, weather)
        s.translation = goodWeather
        var t = Transcript(sourceName: "a", segments: [s], language: "en")
        let rejection = TranslationResult(head: s.id, covers: [], text: "", flags: ["script"])
        XCTAssertFalse(t.apply(rejection, sources: [s.id: weather]))
        XCTAssertNil(t.translationReview)
    }

    // MARK: この訳でよい・直す

    func testConfirmRemovesTheMarkAndKeepsTheFlags() throws {
        let segments = [seg(0, sold)]
        let (summary, results) = try run(segments, [sold: lostSold])
        var t = applied(segments, summary, results)
        let note = try XCTUnwrap(t.confirmTranslation(of: segments[0].id))
        XCTAssertEqual(note.origin, TranslationNote.confirmed)
        XCTAssertEqual(note.flags, ["number"], "印は残す (検査の誤りの数を数えるため)")
        XCTAssertEqual(note.detail, "number: 15, 4000")
        XCTAssertFalse(try XCTUnwrap(t.translationNote(for: segments[0].id)).isFlagged)
        XCTAssertEqual(t.flaggedTranslationCount, 0)
        let (cache, items) = rows(t)
        XCTAssertEqual(items.first?.needsTranslationReview, false)
        XCTAssertTrue(cache.flaggedItemIDs.isEmpty)
        // 2 度目は何もしない
        XCTAssertNil(t.confirmTranslation(of: segments[0].id))
        // 翻訳の終わりに同じ訳をもう 1 度置いても、「この訳でよい」は残る
        let sources = [segments[0].id: sold]
        XCTAssertTrue(t.apply(try XCTUnwrap(results.first), sources: sources))
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.origin, TranslationNote.confirmed)
        // 機械の別の訳が来れば、上書きする (守らない)
        XCTAssertTrue(t.apply(TranslationResult(head: segments[0].id, covers: [], text: goodSold), sources: sources))
        XCTAssertNil(t.translationNote(for: segments[0].id))
    }

    func testConfirmNeedsAFlaggedTranslation() {
        var s = seg(0, weather)
        s.translation = goodWeather
        var t = Transcript(sourceName: "a", segments: [s], language: "en")
        XCTAssertNil(t.confirmTranslation(of: s.id))
        XCTAssertNil(t.translationReview)
    }

    func testEditingAFlaggedTranslationKeepsTheFlags() throws {
        let segments = [seg(0, sold)]
        let (summary, results) = try run(segments, [sold: lostSold])
        var t = applied(segments, summary, results)
        let edited = try XCTUnwrap(t.setUserTranslation(goodSold, for: segments[0].id))
        XCTAssertEqual(edited.origin, TranslationNote.edited)
        XCTAssertEqual(edited.flags, ["number"])
        XCTAssertEqual(edited.detail, "number: 15, 4000")
        XCTAssertEqual(edited.machine, lostSold)
        XCTAssertEqual(t.flaggedTranslationCount, 0)
        XCTAssertEqual(rows(t).items.first?.isEditedTranslation, true)
        XCTAssertEqual(rows(t).items.first?.needsTranslationReview, false)
        // 機械の訳に戻すと、「要確認」の印も戻る
        XCTAssertNotNil(t.revertUserTranslation(of: segments[0].id))
        XCTAssertEqual(t.segments[0].translation, lostSold)
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.isFlagged, true)
        // 直した訳を機械の訳と同じに書き直した時も、機械の訳 (と印) に戻る
        XCTAssertNotNil(t.setUserTranslation(goodSold, for: segments[0].id))
        XCTAssertNil(t.setUserTranslation(lostSold, for: segments[0].id))
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.isFlagged, true)
    }

    func testWritingIntoAnUntranslatedLineDropsTheReason() throws {
        let segments = [seg(0, weather)]
        let (summary, _) = try run(segments, [weather: "昨天天气很好，所以我们在公园里散步了很久。"])
        var t = applied(segments, summary, [])
        let edited = try XCTUnwrap(t.setUserTranslation(goodWeather, for: segments[0].id))
        XCTAssertEqual(edited.origin, TranslationNote.edited)
        XCTAssertNil(edited.machine)
        XCTAssertEqual(edited.flags, ["script"])
        XCTAssertEqual(t.translationReview?.count, 1)
    }

    // MARK: 利用者の訳・覚えた訳には掛けない

    func testMemoryAndEditedTranslationsAreNotGated() throws {
        let segments = [seg(0, sold), seg(3, weather)]
        var m = TranslationMemory()
        // 数の抜けた訳でも、利用者が直した訳なので、印を付けない
        m.remember(source: sold, sourceLanguage: "en", target: "ja", translation: lostSold, machine: nil, model: nil)
        let (summary, results) = try run(segments, [weather: goodWeather], memory: m.lookup(target: "ja"))
        XCTAssertEqual(summary.fromMemory, 1)
        XCTAssertEqual(summary.flagged, 0)
        let remembered = try XCTUnwrap(results.first { $0.fromMemory })
        XCTAssertTrue(remembered.flags.isEmpty)
        let t = applied(segments, summary, results)
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.origin, TranslationNote.memory)
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.flags, [])

        // 利用者が直した訳は、関門を通らない (印は付かない)
        var u = Transcript(sourceName: "a", segments: [seg(0, sold)], language: "en")
        let edited = try XCTUnwrap(u.setUserTranslation(lostSold, for: u.segments[0].id))
        XCTAssertEqual(edited.flags, [])
        XCTAssertEqual(u.flaggedTranslationCount, 0)
    }

    // MARK: 古い結果・知らない符号

    func testOldDocumentAndUnknownFlagsDecode() throws {
        let id = UUID()
        let json = """
        {"sourceName":"old","segments":[{"id":"\(id.uuidString)","start":0,"end":1,"text":"\(sold)","translation":"\(lostSold)"}],
         "language":"en","duration":1,"elapsed":0,
         "translationReview":[{"head":"\(id.uuidString)","signature":"\(sold)\\u0001\(lostSold)",
                               "flags":["number","from-the-future"],"detail":"number: 15, 4000","origin":"llm"}]}
        """
        let t = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        let note = try XCTUnwrap(t.translationNote(for: id))
        XCTAssertTrue(note.isFlagged)
        XCTAssertEqual(note.reasonTexts, [L("A number from the original is missing: %@", "15, 4000")])
        XCTAssertEqual(t.flaggedTranslationCount, 1)

        // 印の無い前の版の結果も読める
        let old = """
        {"sourceName":"old","segments":[{"id":"\(id.uuidString)","start":0,"end":1,"text":"Hello.","translation":"こんにちは。"}],
         "language":"en","duration":1,"elapsed":0}
        """
        let back = try JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        XCTAssertNil(back.translationReview)
        XCTAssertEqual(back.flaggedTranslationCount, 0)
    }

    func testFlaggedCountInRowCacheFollowsTheList() throws {
        // 3 行: 印つき・印つき (後で「この訳でよい」)・正しい訳
        let third = "Right, and that is exactly the point where 25 people run into trouble."
        let segments = [seg(0, sold), seg(3, third), seg(6, weather)]
        let (summary, results) = try run(segments, [sold: lostSold, third: "それがまさに、人がつまずく所です。", weather: goodWeather])
        XCTAssertEqual(summary.flagged, 2)
        var t = applied(segments, summary, results)
        XCTAssertEqual(rows(t).cache.flaggedItemIDs, [segments[0].id, segments[1].id])
        XCTAssertNotNil(t.confirmTranslation(of: segments[1].id))
        XCTAssertEqual(rows(t).cache.flaggedItemIDs, [segments[0].id])
        // 対訳でない一覧には、覚えを出さない (数えない)
        let cache = TranscriptRowCache()
        _ = cache.items(of: t, job: UUID(), done: true, bilingual: false, query: "", target: "ja")
        XCTAssertTrue(cache.flaggedItemIDs.isEmpty)
        // 検索で絞っても、数は一覧全体の物
        let searched = TranscriptRowCache()
        let items = searched.items(of: t, job: UUID(), done: true, bilingual: true, query: "weather", target: "ja")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(searched.flaggedItemIDs, [segments[0].id])
    }
}
