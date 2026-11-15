import Foundation
import XCTest
@testable import KikimimiCore

/// 訳の覚え (利用者が直した訳) と、訳の記憶の試験
final class TranslationReviewTests: XCTestCase {
    private func segment(_ text: String, at start: Double, translation: String? = nil, covers: [UUID]? = nil,
                         language: String? = nil) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, text: text, translation: translation, translationCovers: covers,
                          language: language)
    }

    /// 3 区間: 1 つめと 2 つめは 1 つの訳 (2 つめを含める)、3 つめは訳なし
    private func sample() -> (Transcript, a: UUID, b: UUID, c: UUID) {
        let b = segment("the system behaves.", at: 2)
        let a = segment("So the first thing is how", at: 0, translation: "まず、仕組みがどう振る舞うかです。", covers: [b.id])
        let c = segment("Thank you very much.", at: 6)
        let t = Transcript(sourceName: "x", segments: [a, b, c], language: "en", duration: 10, translationLanguage: "ja")
        return (t, a.id, b.id, c.id)
    }

    // MARK: 古い結果

    func testOldDocumentWithoutReviewDecodes() throws {
        let json = """
        {"sourceName":"old","segments":[{"id":"\(UUID().uuidString)","start":0,"end":1,"text":"Hello.","translation":"こんにちは。"}],
         "language":"en","duration":1,"elapsed":0}
        """
        let t = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertNil(t.translationReview)
        XCTAssertEqual(t.segments.first?.translation, "こんにちは。")
        XCTAssertTrue(t.validTranslationNotes.isEmpty)
        XCTAssertTrue(t.userTranslatedIDs.isEmpty)
    }

    func testReviewRoundTripsAndToleratesMissingFields() throws {
        var (t, a, _, _) = sample()
        t.setUserTranslation("最初に話したいのは、仕組みの振る舞いです。", for: a)
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(back, t)
        // flags・origin の無い覚えも読める
        let note = """
        {"head":"\(a.uuidString)","signature":"x"}
        """
        let decoded = try JSONDecoder().decode(TranslationNote.self, from: Data(note.utf8))
        XCTAssertEqual(decoded.flags, [])
        XCTAssertEqual(decoded.origin, "")
        XCTAssertFalse(decoded.isEdited)
    }

    // MARK: 覚えは、signature が合う時だけ有効

    func testNoteIsValidOnlyWhileSignatureMatches() {
        var (t, a, b, _) = sample()
        let note = t.setUserTranslation("  最初に話したいのは、\n仕組みの振る舞いです。 ", for: b)
        // 押したのは 2 つめの区間でも、まとまりの先頭 (1 つめ) に置く。改行は空白にし、前後の空白を外す
        XCTAssertEqual(note?.head, a)
        XCTAssertEqual(t.segments[0].translation, "最初に話したいのは、 仕組みの振る舞いです。")
        XCTAssertEqual(t.segments[0].translationCovers, [b], "the unit is kept")
        XCTAssertEqual(note?.machine, "まず、仕組みがどう振る舞うかです。")
        XCTAssertEqual(note?.origin, TranslationNote.edited)
        XCTAssertEqual(note?.signature, Transcript.reviewSignature(source: "So the first thing is how the system behaves.",
                                                                    translation: "最初に話したいのは、 仕組みの振る舞いです。"))
        XCTAssertEqual(t.translationNote(for: a), note)
        XCTAssertEqual(t.userTranslatedIDs, [a, b])
        // 原文が変わる (監査の直しで、まとめた区間の文が変わった) と、覚えは無い物と扱う
        var changed = t
        changed.segments[1].text = "the system works."
        XCTAssertNil(changed.translationNote(for: a))
        XCTAssertTrue(changed.validTranslationNotes.isEmpty)
        XCTAssertTrue(changed.userTranslatedIDs.isEmpty)
        // 合わなくなった覚えを捨てる
        changed.pruneTranslationReview()
        XCTAssertNil(changed.translationReview)
        // 訳が外れる (監査の直しで訳し直しになった) と、覚えは無い物と扱う。文と訳が元に戻れば、また有効
        var cleared = t
        cleared.invalidateTranslation(of: b)
        XCTAssertNil(cleared.translationNote(for: a))
        cleared.segments[0].translation = "最初に話したいのは、 仕組みの振る舞いです。"
        cleared.segments[0].translationCovers = [b]
        XCTAssertEqual(cleared.translationNote(for: a), note)
    }

    func testEditingAgainKeepsTheFirstMachineTranslation() {
        var (t, a, _, _) = sample()
        t.setUserTranslation("一つ目の直し", for: a)
        let second = t.setUserTranslation("二つ目の直し", for: a)
        XCTAssertEqual(second?.machine, "まず、仕組みがどう振る舞うかです。")
        XCTAssertEqual(t.translationReview?.count, 1)
        // 同じ訳・空の訳では、何もしない
        XCTAssertNil(t.setUserTranslation("二つ目の直し", for: a))
        XCTAssertNil(t.setUserTranslation("   ", for: a))
        XCTAssertNil(t.setUserTranslation("x", for: UUID()))
        // 機械の訳と同じに書き直したら、機械の訳に戻す
        XCTAssertNil(t.setUserTranslation("まず、仕組みがどう振る舞うかです。", for: a))
        XCTAssertNil(t.translationReview)
        XCTAssertEqual(t.segments[0].translation, "まず、仕組みがどう振る舞うかです。")
    }

    // MARK: 機械の訳に戻す

    func testRevertRestoresTheMachineTranslation() {
        var (t, a, b, c) = sample()
        t.setUserTranslation("直した訳", for: a)
        let removed = t.revertUserTranslation(of: b)
        XCTAssertEqual(removed?.head, a)
        XCTAssertEqual(t.segments[0].translation, "まず、仕組みがどう振る舞うかです。")
        XCTAssertEqual(t.segments[0].translationCovers, [b])
        XCTAssertNil(t.translationReview)
        // 訳の無かった行に自分で書いた訳を戻すと、訳が無くなる (また訳す行になる)
        let own = t.setUserTranslation("どうもありがとう。", for: c)
        XCTAssertNil(own?.machine)
        XCTAssertFalse(Translator.pendingIndices(t.segments, language: "en").contains(2))
        t.revertUserTranslation(of: c)
        XCTAssertNil(t.segments[2].translation)
        XCTAssertTrue(Translator.pendingIndices(t.segments, language: "en").contains(2))
        // 直していない行は、戻さない
        XCTAssertNil(t.revertUserTranslation(of: a))
    }

    // MARK: 機械の訳が、利用者の訳を上書きしない

    /// 翻訳の途中に利用者が直した訳が、翻訳の終わりの apply (AppModel は、訳し終えた全部をもう 1 度 apply する) で戻らない
    func testApplyDoesNotOverwriteAUserTranslation() {
        var (t, a, b, c) = sample()
        // 翻訳を始めた時の原文 (AppModel の sources と同じ作り)
        let sources = Dictionary(t.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { x, _ in x })
        // 翻訳の途中: まだ訳の無い 3 つめの行を、利用者が自分で訳した
        t.setUserTranslation("本当にありがとうございます。", for: c)
        XCTAssertFalse(t.apply(TranslationResult(head: c, covers: [], text: "どうもありがとう。"), sources: sources))
        XCTAssertEqual(t.segments[2].translation, "本当にありがとうございます。")
        // 機械の訳が先に入っていた行を直し、終わりの apply で同じ機械の訳がもう 1 度来た
        t.setUserTranslation("最初に話したいのは、仕組みの振る舞いです。", for: a)
        XCTAssertFalse(t.apply(TranslationResult(head: a, covers: [b], text: "まず、仕組みがどう振る舞うかです。"),
                               sources: sources))
        XCTAssertEqual(t.segments[0].translation, "最初に話したいのは、仕組みの振る舞いです。")
        // 機械の訳のまとまりが、利用者の訳の区間を含む時も置かない (含めると、利用者の訳が消える)
        XCTAssertFalse(t.apply(TranslationResult(head: b, covers: [c], text: "訳"), sources: sources))
        XCTAssertEqual(t.segments[2].translation, "本当にありがとうございます。")
        XCTAssertNotNil(t.translationNote(for: a))
        XCTAssertNotNil(t.translationNote(for: c))
    }

    /// 行の「訳」の待ち行列 (job.lineQueue) の結果も、利用者の訳を上書きしない。
    /// 待っている間に利用者が直した行は、訳し直しの写し (clearingTranslations) の上では訳が無いが、結果は置かない
    func testLineQueueResultDoesNotOverwriteAUserTranslation() {
        var (t, _, _, c) = sample()
        // 行の「訳」を押した時の写し (AppModel の translateLines と同じ作り)
        let copy = Translator.clearingTranslations(of: [], in: t.segments)
        let sources = Dictionary(copy.map { ($0.id, $0.text) }, uniquingKeysWith: { x, _ in x })
        t.setUserTranslation("本当にありがとうございます。", for: c)
        XCTAssertFalse(t.apply(TranslationResult(head: c, covers: [], text: "どうもありがとう。"), sources: sources))
        XCTAssertEqual(t.segments[2].translation, "本当にありがとうございます。")
    }

    /// 利用者が自分で「この文を訳し直す」を押した時は、利用者の訳を外してよい (覚えも捨てる)
    func testUserRequestedRetranslationDropsTheUserTranslation() {
        var (t, a, b, c) = sample()
        t.setUserTranslation("直した訳", for: a)
        t.setUserTranslation("自分の訳", for: c)
        let unit = Translator.redoUnitIDs(containing: b, in: t.segments, language: "en")
        XCTAssertTrue(t.dropUserTranslations(touching: Set(unit)))
        // 訳し終えるまで、画面には前の訳を残す
        XCTAssertEqual(t.segments[0].translation, "直した訳")
        XCTAssertNil(t.translationNote(for: a))
        XCTAssertNotNil(t.translationNote(for: c), "only the requested sentence")
        let copy = Translator.clearingTranslations(of: [b], in: t.segments)
        let sources = Dictionary(copy.map { ($0.id, $0.text) }, uniquingKeysWith: { x, _ in x })
        XCTAssertTrue(t.apply(TranslationResult(head: a, covers: [b], text: "新しい機械の訳"), sources: sources))
        XCTAssertEqual(t.segments[0].translation, "新しい機械の訳")
        // 「〇〇語で訳し直す」(訳を全部外す) は、覚えも捨てる
        t.removeAllTranslations()
        XCTAssertNil(t.translationReview)
    }

    /// 監査で原文が変わった行は、覚えが無い物になり、新しい原文の機械の訳が入る
    func testAuditChangeReleasesTheUserTranslation() {
        var (t, _, _, c) = sample()
        t.setUserTranslation("自分の訳", for: c)
        t.invalidateTranslation(of: c)
        t.segments[2].text = "Thank you so much."
        let sources = Dictionary(t.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { x, _ in x })
        XCTAssertTrue(t.apply(TranslationResult(head: c, covers: [], text: "本当にありがとう。"), sources: sources))
        XCTAssertNil(t.translationNote(for: c))
    }

    // MARK: 行の覚え

    func testRowsCarryTheNote() {
        var (t, a, _, c) = sample()
        let note = t.setUserTranslation("直した訳", for: a)
        let job = UUID()
        let cache = TranscriptRowCache()
        let items = cache.items(of: t, job: job, done: true, bilingual: true, query: "")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].review, note)
        XCTAssertTrue(items[0].isEditedTranslation)
        XCTAssertEqual(items[0].translation, "直した訳")
        XCTAssertNil(items[1].review)
        // 対訳でない行には入れない
        XCTAssertNil(TranscriptRowCache().items(of: t, job: job, done: true, bilingual: false, query: "")[0].review)
        // 覚えが変わると作り直す (同じ結果なら、前の行を返す)
        t.setUserTranslation("自分の訳", for: c)
        let again = cache.items(of: t, job: job, done: true, bilingual: true, query: "")
        XCTAssertFalse(cache.lastItemsWasAppend)
        XCTAssertTrue(again[1].isEditedTranslation)
        // 覚えだけが違う結果は、末尾に足しただけとは見ない
        var base = t
        base.translationReview = nil
        var more = t
        more.segments.append(segment("More.", at: 9))
        XCTAssertNil(TranscriptRowCache.appended(more, to: base))
        XCTAssertNotNil(TranscriptRowCache.appended(more, to: t))
    }

    func testAppendedRowsKeepTheNotes() {
        // 文字起こしの最中に末尾が増えても、行の覚えは作り直した時と同じ
        var (t, a, _, _) = sample()
        t.setUserTranslation("直した訳", for: a)
        let job = UUID()
        let cache = TranscriptRowCache()
        _ = cache.items(of: t, job: job, done: false, bilingual: true, query: "")
        t.segments.append(segment("More.", at: 9))
        let items = cache.items(of: t, job: job, done: false, bilingual: true, query: "")
        XCTAssertTrue(cache.lastItemsWasAppend)
        XCTAssertEqual(items, TranscriptRowCache().items(of: t, job: job, done: false, bilingual: true, query: ""))
        XCTAssertTrue(items[0].isEditedTranslation)
    }

    // MARK: 訳の記憶

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimimi-memory-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(TranslationMemory.fileName)
    }

    func testMemorySavesAndLoads() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = TranslationMemory()
        let entry = memory.remember(source: "Thank you.", sourceLanguage: "en", target: "ja", translation: "ありがとう。",
                                    machine: "感謝します。", model: "Qwen3.5 4B")
        XCTAssertNotNil(entry)
        try memory.save(to: url)
        let loaded = TranslationMemory.load(from: url)
        XCTAssertEqual(loaded.sentences.count, 1)
        XCTAssertEqual(loaded.sentences[0].translation, "ありがとう。")
        XCTAssertEqual(loaded.sentences[0].machine, "感謝します。")
        XCTAssertEqual(loaded.sentences[0].model, "Qwen3.5 4B")
        XCTAssertEqual(loaded.sentences[0].id, entry?.id)
        XCTAssertEqual(loaded.version, 1)
        // 形は { "version": 1, "sentences": [...] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1)
        XCTAssertEqual((object?["sentences"] as? [Any])?.count, 1)
        // 無いファイルは空
        XCTAssertTrue(TranslationMemory.load(from: temporaryFile()).isEmpty)
    }

    func testMemorySkipsABrokenEntryAndUnknownFields() throws {
        let json = """
        {"version":1,
         "terms":[{"source":"Roblox","translation":"Roblox","target":"ja"}],
         "sentences":[
          {"source":"Hello.","target":"ja","translation":"こんにちは。","future":"x"},
          {"source":"Broken.","target":"ja"},
          {"source":"   ","target":"ja","translation":"空"},
          {"id":"not-a-uuid","source":"Good night.","target":"ja","translation":"おやすみ。","heldOut":"yes"}
         ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let memory = try decoder.decode(TranslationMemory.self, from: Data(json.utf8))
        XCTAssertEqual(memory.sentences.map(\.source), ["Hello.", "Good night."])
        // 欠けた取り分けの印は、原文から決める
        XCTAssertEqual(memory.sentences[1].heldOut,
                       TranslationMemory.isHeldOut(TranslationMemory.normalizedSource("Good night.")))
    }

    func testUnreadableMemoryIsSetAside() throws {
        let url = temporaryFile()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let loaded = TranslationMemory.loadKeepingUnreadable(from: url, date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(loaded.memory.isEmpty)
        let aside = try XCTUnwrap(loaded.setAside)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("translation-memory.unreadable-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // 空のファイル・無いファイルは、よけない
        XCTAssertNil(TranslationMemory.loadKeepingUnreadable(from: url).setAside)
    }

    func testSameSourceAndTargetIsReplaced() {
        var memory = TranslationMemory()
        let first = memory.remember(source: "Thank  you.", sourceLanguage: "en", target: "ja", translation: "ありがとう。",
                                    machine: "感謝。", model: "A")
        // NFKC (全角の英字) と空白の違いは、同じ原文
        let second = memory.remember(source: " Ｔｈａｎｋ you.\n", sourceLanguage: "en", target: "JA",
                                     translation: "どうもありがとう。", machine: "別の機械の訳", model: "B")
        XCTAssertEqual(memory.sentences.count, 1)
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(memory.sentences[0].translation, "どうもありがとう。")
        XCTAssertEqual(memory.sentences[0].machine, "感謝。", "the first machine translation is kept")
        // 訳す先が違えば別の 1 件
        memory.remember(source: "Thank you.", sourceLanguage: "en", target: "de", translation: "Danke.", machine: nil, model: nil)
        XCTAssertEqual(memory.sentences.count, 2)
        XCTAssertEqual(memory.entry(source: "thank you.", target: "ja")?.translation, nil, "case is not folded")
        XCTAssertEqual(memory.entry(source: "Thank you.", target: "ja")?.translation, "どうもありがとう。")
        // 空の原文・訳は入れない
        XCTAssertNil(memory.remember(source: " ", sourceLanguage: nil, target: "ja", translation: "x", machine: nil, model: nil))
        XCTAssertNil(memory.remember(source: "x", sourceLanguage: nil, target: "ja", translation: " ", machine: nil, model: nil))
        // 機械の訳に戻したら、その 1 件を消す
        XCTAssertTrue(memory.forget(source: "Thank you.", target: "ja"))
        XCTAssertFalse(memory.forget(source: "Thank you.", target: "ja"))
        XCTAssertEqual(memory.sentences.map(\.target), ["de"])
    }

    func testHeldOutIsFixed() {
        // 決まった計算のハッシュなので、起動ごとに変わらない (FNV-1a 64 ビットの決まった値)
        XCTAssertEqual(TranslationMemory.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(TranslationMemory.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(TranslationMemory.stableHash("foobar"), 0x8594_4171_f739_67e8)
        // 5 件に 1 件ほどが取り分けになる
        let sources = (0..<1000).map { "Sentence number \($0)." }
        let held = sources.filter { TranslationMemory.isHeldOut(TranslationMemory.normalizedSource($0)) }.count
        XCTAssertGreaterThan(held, 150)
        XCTAssertLessThan(held, 250)
        // 入れた時に決め、そろえた原文が同じなら同じ
        var memory = TranslationMemory()
        let entry = memory.remember(source: "Sentence number 7.", sourceLanguage: nil, target: "ja", translation: "7 番目の文。",
                                    machine: nil, model: nil)
        XCTAssertEqual(entry?.heldOut, TranslationMemory.isHeldOut("Sentence number 7."))
        XCTAssertEqual(TranslationMemory.isHeldOut(TranslationMemory.normalizedSource("Sentence  number 7. ")),
                       TranslationMemory.isHeldOut("Sentence number 7."))
    }
}
