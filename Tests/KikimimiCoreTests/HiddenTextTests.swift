import Foundation
import XCTest
@testable import KikimimiCore

/// 練習で行の文字を隠す決まり (HiddenText) と、一覧の行が持つ言語の試験
final class HiddenTextTests: XCTestCase {
    func testNothingHidesNothing() {
        for language in ["en", "ja", nil, "ja+en"] as [String?] {
            XCTAssertFalse(HiddenText.canHide(.nothing, language: language))
            XCTAssertFalse(HiddenText.hidesSource(.nothing, language: language, revealed: false))
            XCTAssertFalse(HiddenText.hidesTranslation(.nothing, language: language, revealed: false))
        }
    }

    func testSourceHidesOnlyNonJapaneseSource() {
        XCTAssertTrue(HiddenText.hidesSource(.source, language: "en", revealed: false))
        XCTAssertFalse(HiddenText.hidesTranslation(.source, language: "en", revealed: false))
        XCTAssertFalse(HiddenText.hidesSource(.source, language: "ja", revealed: false))
        XCTAssertFalse(HiddenText.canHide(.source, language: "ja"))
        // 言語がわからない行も、日本語でないとみなして隠す
        XCTAssertTrue(HiddenText.hidesSource(.source, language: nil, revealed: false))
    }

    func testSourceAndTranslation() {
        XCTAssertTrue(HiddenText.hidesSource(.sourceAndTranslation, language: "en", revealed: false))
        XCTAssertTrue(HiddenText.hidesTranslation(.sourceAndTranslation, language: "en", revealed: false))
        XCTAssertFalse(HiddenText.hidesSource(.sourceAndTranslation, language: "ja", revealed: false))
        XCTAssertFalse(HiddenText.hidesTranslation(.sourceAndTranslation, language: "ja", revealed: false))
    }

    func testRevealedShowsEverything() {
        for hide in PracticeSettings.Hide.allCases {
            XCTAssertFalse(HiddenText.hidesSource(hide, language: "en", revealed: true))
            XCTAssertFalse(HiddenText.hidesTranslation(hide, language: "en", revealed: true))
        }
        // 見せても、隠す対象であることは変わらない (目のボタンは出したまま)
        XCTAssertTrue(HiddenText.canHide(.source, language: "en"))
    }

    func testRateLabel() {
        XCTAssertEqual(PracticeSettings.rates.map(HiddenText.rateLabel), ["0.5×", "0.6×", "0.75×", "0.85×", "1.0×", "1.25×"])
    }

    func testListItemLanguage() {
        let en = TranscriptSegment(start: 0, end: 1, text: "Hello there.", language: "en")
        let plain = TranscriptSegment(start: 1, end: 2, text: "No language here.")
        let ja = TranscriptSegment(start: 2, end: 3, text: "こんにちは。", language: "ja")
        let t = Transcript(sourceName: "a", segments: [en, plain, ja], language: "en")
        let cache = TranscriptRowCache()
        let rows = cache.items(of: t, job: UUID(), done: true, bilingual: false, query: "")
        XCTAssertEqual(rows.map(\.language), ["en", "en", "ja"])
        let units = TranscriptRowCache().items(of: t, job: UUID(), done: true, bilingual: true, query: "")
        XCTAssertEqual(units.map(\.language), ["en", "en", "ja"])
        // 文字起こしの言語が日本語で、区間に言語がなければ日本語
        let tj = Transcript(sourceName: "b", segments: [plain], language: "ja")
        XCTAssertEqual(TranscriptRowCache().items(of: tj, job: UUID(), done: true, bilingual: false, query: "")
            .map(\.language), ["ja"])
    }

    func testListItemLanguageOnAppend() {
        let job = UUID()
        let cache = TranscriptRowCache()
        var t = Transcript(sourceName: "a", segments: [TranscriptSegment(start: 0, end: 1, text: "One.")], language: "en")
        _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        t.segments.append(TranscriptSegment(start: 1, end: 2, text: "Two."))
        t.segments.append(TranscriptSegment(start: 2, end: 3, text: "Three."))
        let rows = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        XCTAssertTrue(cache.lastItemsWasAppend)
        XCTAssertEqual(rows.map(\.language), ["en", "en", "en"])
    }
}
