import Foundation
import XCTest
@testable import KikimimiCore

/// 結果の一覧の行と数を覚えておく所 (TranscriptRowCache) の試験: 末尾に区間を足したときに足した分だけを作る道と、
/// すべてから作り直す道が、同じものを返すこと
final class TranscriptRowCacheTests: XCTestCase {
    private let job = UUID()

    private func segment(_ i: Int, language: String? = "en", translation: String? = nil,
                         covers: [UUID]? = nil) -> TranscriptSegment {
        let start = Double(i) * 2.5
        let text = language == "ja" ? "日本語の文 \(i) です。" : "English line number \(i) here."
        return TranscriptSegment(start: start, end: start + 2.3, text: text, translation: translation,
                                 translationCovers: covers, language: language)
    }

    private func transcript(_ segments: [TranscriptSegment], language: String? = "en") -> Transcript {
        Transcript(sourceName: "a", segments: segments, language: language, duration: 1000)
    }

    /// 作り直したときと同じか (新しい入れ物で作ったものと比べる)
    private func assertSameAsFresh(_ cache: TranscriptRowCache, _ t: Transcript, done: Bool = false, bilingual: Bool = false,
                                   query: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let fresh = TranscriptRowCache()
        XCTAssertEqual(cache.items(of: t, job: job, done: done, bilingual: bilingual, query: query),
                       fresh.items(of: t, job: job, done: done, bilingual: bilingual, query: query), file: file, line: line)
        XCTAssertEqual(cache.summary(of: t, job: job, done: done), fresh.summary(of: t, job: job, done: done),
                       file: file, line: line)
    }

    func testAppendBuildsOnlyTheNewRows() {
        let cache = TranscriptRowCache()
        var segments = (0..<50).map { segment($0) }
        var t = transcript(segments)
        _ = cache.summary(of: t, job: job, done: false)
        _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        XCTAssertFalse(cache.lastItemsWasAppend)
        for round in 0..<5 {
            segments += (0..<(round + 1)).map { segment(50 + round * 10 + $0) }
            t.segments = segments
            let summary = cache.summary(of: t, job: job, done: false)
            XCTAssertTrue(cache.lastSummaryWasAppend)
            let items = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
            XCTAssertTrue(cache.lastItemsWasAppend)
            XCTAssertEqual(items.map(\.id), segments.map(\.id))
            XCTAssertEqual(summary.languageLabel, t.languageLabel)
            XCTAssertEqual(summary.spokenLanguages, t.spokenLanguages)
            assertSameAsFresh(cache, t)
        }
    }

    func testAppendWithSearchAndBilingual() {
        for bilingual in [false, true] {
            let cache = TranscriptRowCache()
            var t = transcript((0..<20).map { segment($0) })
            _ = cache.items(of: t, job: job, done: false, bilingual: bilingual, query: " 1 ")
            t.segments += (20..<35).map { segment($0) }
            let items = cache.items(of: t, job: job, done: false, bilingual: bilingual, query: " 1 ")
            XCTAssertTrue(cache.lastItemsWasAppend, "bilingual \(bilingual)")
            XCTAssertTrue(items.allSatisfy { $0.text.contains("1") })
            assertSameAsFresh(cache, t, bilingual: bilingual, query: " 1 ")
        }
    }

    func testSecondLanguageRebuildsTheTags() {
        let cache = TranscriptRowCache()
        var t = transcript((0..<10).map { segment($0) })
        let before = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        XCTAssertTrue(before.allSatisfy { $0.languageTag == nil })
        t.segments.append(segment(10, language: "ja"))
        let after = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        // 2 つめの言語が出たので、すべての行に印が付く (作り直す)
        XCTAssertFalse(cache.lastItemsWasAppend)
        XCTAssertEqual(after.first?.languageTag, "英")
        XCTAssertEqual(after.last?.languageTag, "日")
        XCTAssertEqual(cache.summary(of: t, job: job, done: false).spokenLanguages, ["en", "ja"])
        // そのあとは、また足すだけ (印はそのまま)
        t.segments.append(segment(11, language: "ja"))
        _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        XCTAssertTrue(cache.lastItemsWasAppend)
        assertSameAsFresh(cache, t)
    }

    func testEverythingElseRebuilds() {
        let base = (0..<10).map { segment($0) }
        func prepared() -> (TranscriptRowCache, Transcript) {
            let cache = TranscriptRowCache()
            let t = transcript(base)
            _ = cache.summary(of: t, job: job, done: false)
            _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
            return (cache, t)
        }
        // 前の区間の文が変わった (区間の数も増えた)
        do {
            var (cache, t) = prepared()
            t.segments[3].text = "changed"
            t.segments.append(segment(10))
            _ = cache.summary(of: t, job: job, done: false)
            XCTAssertFalse(cache.lastSummaryWasAppend)
            _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
            XCTAssertFalse(cache.lastItemsWasAppend)
            assertSameAsFresh(cache, t)
        }
        // やり直し (区間がすべて入れ替わり、前より多い)
        do {
            var (cache, t) = prepared()
            t.segments = (0..<12).map { segment($0) }
            _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
            XCTAssertFalse(cache.lastItemsWasAppend)
            assertSameAsFresh(cache, t)
        }
        // 終わった (最後の結果で置き換え。翻訳の状況も数える)
        do {
            var (cache, t) = prepared()
            t.segments.append(segment(10))
            let summary = cache.summary(of: t, job: job, done: true)
            XCTAssertFalse(cache.lastSummaryWasAppend)
            XCTAssertEqual(summary.stats, t.translationStats)
            _ = cache.items(of: t, job: job, done: true, bilingual: false, query: "")
            XCTAssertFalse(cache.lastItemsWasAppend)
            assertSameAsFresh(cache, t, done: true)
        }
        // 文字起こしのほかの値 (言語) が変わった
        do {
            var (cache, t) = prepared()
            t.language = "ja"
            t.segments.append(segment(10))
            _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
            XCTAssertFalse(cache.lastItemsWasAppend)
            assertSameAsFresh(cache, t)
        }
        // 区間が減った
        do {
            var (cache, t) = prepared()
            t.segments.removeLast()
            _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
            XCTAssertFalse(cache.lastItemsWasAppend)
            assertSameAsFresh(cache, t)
        }
        // 検索語・対訳・ジョブが変わった
        do {
            let (cache, t) = prepared()
            var more = t
            more.segments.append(segment(10))
            _ = cache.items(of: more, job: job, done: false, bilingual: false, query: "x")
            XCTAssertFalse(cache.lastItemsWasAppend)
            _ = cache.items(of: t, job: job, done: false, bilingual: true, query: "x")
            XCTAssertFalse(cache.lastItemsWasAppend)
            _ = cache.items(of: more, job: UUID(), done: false, bilingual: true, query: "x")
            XCTAssertFalse(cache.lastItemsWasAppend)
        }
    }

    /// 対訳で、訳が後ろの区間も含む (1 行にまとまる) ときは作り直す
    func testBilingualUnitThatSpansSegmentsRebuilds() {
        let cache = TranscriptRowCache()
        let next = segment(10)
        var segments = (0..<9).map { segment($0) }
        segments.append(segment(9, translation: "訳", covers: [next.id]))
        var t = transcript(segments)
        _ = cache.items(of: t, job: job, done: false, bilingual: true, query: "")
        t.segments.append(next)
        let items = cache.items(of: t, job: job, done: false, bilingual: true, query: "")
        XCTAssertFalse(cache.lastItemsWasAppend)
        XCTAssertEqual(items.count, 10)
        assertSameAsFresh(cache, t, bilingual: true)
    }

    func testUnchangedTranscriptReturnsTheSameRows() {
        let cache = TranscriptRowCache()
        let t = transcript((0..<10).map { segment($0) })
        let a = cache.items(of: t, job: job, done: true, bilingual: false, query: "")
        let b = cache.items(of: t, job: job, done: true, bilingual: false, query: "")
        XCTAssertEqual(a, b)
    }

    func testBatchIntervalGrowsWithRows() {
        XCTAssertEqual(LiveSegmentBuffer.interval(forRows: 0), 0.25)
        XCTAssertEqual(LiveSegmentBuffer.interval(forRows: 499), 0.25)
        XCTAssertEqual(LiveSegmentBuffer.interval(forRows: 500), 0.5)
        XCTAssertEqual(LiveSegmentBuffer.interval(forRows: 2000), 0.5)
        XCTAssertEqual(LiveSegmentBuffer.interval(forRows: 2001), 1.0)
        XCTAssertEqual(LiveSegmentBuffer.interval(forRows: 50_000), LiveSegmentBuffer.maxInterval)
    }
}
