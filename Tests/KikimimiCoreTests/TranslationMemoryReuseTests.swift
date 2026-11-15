import XCTest
@testable import KikimimiCore

/// 直した訳の再利用 (U2): 記憶に在る文は LLM に送らずに、記憶の訳を置く
final class TranslationMemoryReuseTests: XCTestCase {
    private func seg(_ start: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, text: text)
    }

    /// 依頼の中の「[n] 本文」の行の本文
    private func sentLines(_ fake: FakeGenerator) -> [String] {
        fake.prompts.flatMap { prompt in
            prompt.user.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      Int(line[line.index(after: line.startIndex)..<close]) != nil else { return nil }
                return String(line[line.index(close, offsetBy: 2)...])
            }
        }
    }

    private func echo() -> FakeGenerator {
        FakeGenerator { prompt in
            prompt.user.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return "\(line[...close]) 機械(\(line[line.index(close, offsetBy: 2)...]))"
            }.joined(separator: "\n") + "\n"
        }
    }

    private let remembered = "So the first thing I want to talk about today is the system."
    private let other = "Right, and that is exactly the point where people run into trouble."

    private func memory(_ source: String, _ translation: String, target: String = "ja") -> TranslationMemoryLookup {
        var m = TranslationMemory()
        m.remember(source: source, sourceLanguage: "en", target: target, translation: translation, machine: "古い訳", model: nil)
        return m.lookup(target: target)
    }

    private func run(_ segments: [TranscriptSegment], memory: TranslationMemoryLookup?, only: Set<UUID>? = nil,
                     excluding: Set<UUID> = [], target: String = "ja",
                     fake: FakeGenerator) throws -> (TranslationRunSummary, [TranslationResult]) {
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: target, only: only,
                                                          memory: memory, memoryExcluding: excluding, generator: fake,
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        return (summary, all)
    }

    func testRememberedSentenceIsNotSentAndGetsMemoryNote() throws {
        let segments = [seg(0, remembered), seg(3, other)]
        let fake = echo()
        let (summary, results) = try run(segments, memory: memory(remembered, "まず今日話したいのは、仕組みです。"), fake: fake)
        XCTAssertEqual(summary, TranslationRunSummary(failed: 0, fromMemory: 1, sentToLLM: 1))
        XCTAssertEqual(sentLines(fake), [other], "記憶に無い文だけを LLM に送る")
        let hit = try XCTUnwrap(results.first { $0.head == segments[0].id })
        XCTAssertTrue(hit.fromMemory)
        XCTAssertEqual(hit.text, "まず今日話したいのは、仕組みです。")
        XCTAssertFalse(try XCTUnwrap(results.first { $0.head == segments[1].id }).fromMemory)

        // 置くと、覚えが "memory" になる (機械の訳は持たない)。LLM の訳には覚えが付かない
        var t = Transcript(sourceName: "a", segments: segments, language: "en")
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        for r in results { XCTAssertTrue(t.apply(r, sources: sources)) }
        let note = try XCTUnwrap(t.translationNote(for: segments[0].id))
        XCTAssertEqual(note.origin, TranslationNote.memory)
        XCTAssertTrue(note.isRemembered)
        XCTAssertNil(note.machine)
        XCTAssertNil(t.translationNote(for: segments[1].id))
        XCTAssertTrue(t.userTranslatedIDs.isEmpty, "記憶から置いた訳は守らない")
    }

    func testRememberedSentenceIsInTheContextOfLaterLines() throws {
        let segments = [seg(0, remembered), seg(3, other)]
        let fake = echo()
        _ = try run(segments, memory: memory(remembered, "記憶の訳です。"), fake: fake)
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertTrue(fake.prompts[0].user.contains("\(remembered) => 記憶の訳です。"), fake.prompts[0].user)
    }

    func testShortSentenceIsNotReused() throws {
        // 「Yes, sure.」は重さ 8 (16 より小さい)。「はい、そうです。」も 12
        XCTAssertLessThan(TranslationGate.weight("Yes, sure."), TranslationMemoryLookup.minimumSourceWeight)
        let segments = [seg(0, "Yes, sure.")]
        let fake = echo()
        let (summary, results) = try run(segments, memory: memory("Yes, sure.", "はい、もちろん。"), fake: fake)
        XCTAssertEqual(summary.fromMemory, 0)
        XCTAssertEqual(summary.sentToLLM, 1)
        XCTAssertEqual(results.first?.fromMemory, false)
        XCTAssertNil(memory("はい、そうです。", "Yes.", target: "en").translation(for: "はい、そうです。"))
        // 漢字・かなは 2 と数えるので、8 字の日本語の文は引く
        XCTAssertEqual(memory("今日は良い天気です", "It is nice today.", target: "en").translation(for: "今日は良い天気です"),
                       "It is nice today.")
    }

    func testMemoryForAnotherTargetIsNotUsed() throws {
        let segments = [seg(0, remembered)]
        let fake = echo()
        // 英語へ訳した記憶の写しを、日本語へ訳す時に渡しても引かない
        let (summary, _) = try run(segments, memory: memory(remembered, "In English.", target: "en"), fake: fake)
        XCTAssertEqual(summary.fromMemory, 0)
        XCTAssertEqual(sentLines(fake), [remembered])
        // 記憶の写しは、訳す先が同じ物だけを入れる
        var m = TranslationMemory()
        m.remember(source: remembered, sourceLanguage: "en", target: "ko", translation: "번역", machine: nil, model: nil)
        XCTAssertTrue(m.lookup(target: "ja").isEmpty)
        XCTAssertEqual(m.lookup(target: "KO ").count, 1)
    }

    func testWhitespaceAndWidthDifferencesAreTheSameSentence() throws {
        // 全角の英字・続く空白・前後の空白の違いは、同じ文と見る
        let stored = "  Ｓｏ the first thing I want  to talk about\u{3000}today is the system. "
        let segments = [seg(0, remembered)]
        let fake = echo()
        let (summary, results) = try run(segments, memory: memory(stored, "記憶の訳。"), fake: fake)
        XCTAssertEqual(summary.fromMemory, 1)
        XCTAssertEqual(summary.sentToLLM, 0)
        XCTAssertTrue(fake.prompts.isEmpty)
        XCTAssertEqual(results.first?.text, "記憶の訳。")
    }

    func testSentenceOverSeveralSegmentsIsLookedUpAsOneUnit() throws {
        // 文の途中で切れた 2 区間は、1 つのまとまりとして引く (原文は区間の文をつないだ物)
        let segments = [seg(0, "So the first thing I want to talk about"), seg(2.5, "today is the system.")]
        let joined = Transcript.join(segments.map(\.text))
        let fake = echo()
        let (summary, results) = try run(segments, memory: memory(joined, "まとまりの訳。"), fake: fake)
        XCTAssertEqual(summary.fromMemory, 1)
        XCTAssertTrue(fake.prompts.isEmpty)
        XCTAssertEqual(results.first?.covers, [segments[1].id])
        var t = Transcript(sourceName: "a", segments: segments, language: "en")
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        XCTAssertTrue(t.apply(try XCTUnwrap(results.first), sources: sources))
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.origin, TranslationNote.memory)
    }

    func testRedoDoesNotUseMemory() throws {
        // 利用者が自分で押した「この文を訳し直す」の区間は、記憶を引かない
        let segments = [seg(0, remembered), seg(3, other)]
        let fake = echo()
        let mem = TranslationMemory(sentences: [
            RememberedTranslation(source: remembered, target: "ja", translation: "記憶 1"),
            RememberedTranslation(source: other, target: "ja", translation: "記憶 2"),
        ]).lookup(target: "ja")
        let (summary, results) = try run(segments, memory: mem, excluding: [segments[0].id], fake: fake)
        XCTAssertEqual(summary, TranslationRunSummary(failed: 0, fromMemory: 1, sentToLLM: 1))
        XCTAssertEqual(sentLines(fake), [remembered])
        XCTAssertEqual(results.first { $0.head == segments[1].id }?.text, "記憶 2")
        XCTAssertFalse(Translator.memoryCoversAll(segments, language: "en", memory: mem, memoryExcluding: [segments[0].id]))
        XCTAssertTrue(Translator.memoryCoversAll(segments, language: "en", memory: mem))
    }

    func testNoMemoryMeansEverythingGoesToTheLLM() throws {
        // 設定が切の時、AppModel は記憶を渡さない (nil)。渡さなければ今までと同じ
        let segments = [seg(0, remembered), seg(3, other)]
        let fake = echo()
        let (summary, results) = try run(segments, memory: nil, fake: fake)
        XCTAssertEqual(summary, TranslationRunSummary(failed: 0, fromMemory: 0, sentToLLM: 2))
        XCTAssertEqual(sentLines(fake), [remembered, other])
        XCTAssertFalse(results.contains(where: \.fromMemory))
        XCTAssertFalse(Translator.memoryCoversAll(segments, language: "en", memory: nil))
    }

    func testHeldOutEntriesAreReused() throws {
        // 取り分けた 1 件 (heldOut) も、同じ文の再利用には使う
        let source = try XCTUnwrap((0..<200).map { "This is test sentence number \($0) for the memory." }
            .first { TranslationMemory.isHeldOut(TranslationMemory.normalizedSource($0)) })
        var m = TranslationMemory()
        let entry = m.remember(source: source, sourceLanguage: "en", target: "ja", translation: "取り分けた訳。",
                               machine: nil, model: nil)
        XCTAssertEqual(entry?.heldOut, true)
        XCTAssertEqual(m.lookup(target: "ja").translation(for: source), "取り分けた訳。")
    }

    func testWithoutGeneratorOnlyMemoryIsUsed() throws {
        // LLM を読み込まない時 (記憶だけで埋まる時に使う): 記憶に無い文は、訳せなかった区間と数える
        let segments = [seg(0, remembered), seg(3, other)]
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", memory: memory(remembered, "記憶の訳。"),
                                                          generator: nil, shouldCancel: { false }) { batch, _, _ in all += batch }
        XCTAssertEqual(summary, TranslationRunSummary(failed: 1, fromMemory: 1, sentToLLM: 0))
        XCTAssertEqual(all.map(\.text), ["記憶の訳。"])
    }

    func testEditedTranslationIsStillProtected() throws {
        // 利用者が直した訳 ("edited") は、記憶の訳でも機械の訳でも上書きしない
        let segments = [seg(0, remembered)]
        var t = Transcript(sourceName: "a", segments: segments, language: "en")
        t.segments[0].translation = "機械の訳"
        XCTAssertNotNil(t.setUserTranslation("自分の訳", for: segments[0].id))
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        let fromMemory = TranslationResult(head: segments[0].id, covers: [], text: "記憶の訳", fromMemory: true)
        XCTAssertFalse(t.apply(fromMemory, sources: sources))
        XCTAssertFalse(t.apply(TranslationResult(head: segments[0].id, covers: [], text: "新しい機械の訳"), sources: sources))
        XCTAssertEqual(t.segments[0].translation, "自分の訳")
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.origin, TranslationNote.edited)
    }

    func testMemoryTranslationIsNotProtectedFromMachineTranslation() throws {
        // 記憶から置いた訳 ("memory") は守らない: 機械の訳を置くと、覚えも外れる
        let segments = [seg(0, remembered)]
        var t = Transcript(sourceName: "a", segments: segments, language: "en")
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        XCTAssertTrue(t.apply(TranslationResult(head: segments[0].id, covers: [], text: "記憶の訳", fromMemory: true),
                              sources: sources))
        XCTAssertEqual(t.translationNote(for: segments[0].id)?.origin, TranslationNote.memory)
        XCTAssertTrue(t.apply(TranslationResult(head: segments[0].id, covers: [], text: "記憶の訳"), sources: sources))
        XCTAssertNil(t.translationNote(for: segments[0].id), "同じ文の機械の訳でも、覚えは外す")
        XCTAssertNil(t.translationReview)
    }
}
