import Foundation
import XCTest
@testable import KikimimiCore

/// 聞き取った文を、利用者が手で直す (Transcript.lineEdits・setLineText・revertLineEdit) の試験。
/// 監査・翻訳・結果の一覧の覚えておく所と、ぶつからない事も見る
final class LineEditTests: XCTestCase {
    private func transcript(_ texts: [String]) -> Transcript {
        let segments = texts.enumerated().map { i, text in
            TranscriptSegment(start: Double(i) * 2, end: Double(i) * 2 + 1.5, text: text)
        }
        return Transcript(sourceName: "a", segments: segments, language: "ja", duration: Double(texts.count) * 2)
    }

    private func fix(_ segment: TranscriptSegment, to text: String, confident: Bool = true) -> AuditChange {
        AuditChange(kind: .fix, origin: .llm, original: segment, replacement: text, reason: "r", isConfident: confident)
    }

    private func delete(_ segment: TranscriptSegment, confident: Bool = true) -> AuditChange {
        AuditChange(kind: .delete, origin: .rule, original: segment, reason: "r", isConfident: confident)
    }

    // MARK: 直す・戻す

    func testEditKeepsTheHeardTextAndRecord() throws {
        var t = transcript(["浜って", "次の文"])
        let id = t.segments[0].id
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(t.setLineText("走って", forSegment: id, date: date))
        XCTAssertEqual(t.segments[0].text, "走って")
        let edit = try XCTUnwrap(t.lineEdit(forSegment: id))
        XCTAssertEqual(edit, LineEdit(segmentID: id, heard: "浜って", edited: "走って", date: date))
        XCTAssertEqual(t.lineEdits?.count, 1)
        XCTAssertNil(t.lineEdit(forSegment: t.segments[1].id))

        // もう一度直しても、聞き取った文は最初のまま。記録は置き換え (1 件のまま)
        XCTAssertTrue(t.setLineText("走っていて", forSegment: id))
        XCTAssertEqual(t.segments[0].text, "走っていて")
        XCTAssertEqual(t.lineEdit(forSegment: id)?.heard, "浜って")
        XCTAssertEqual(t.lineEdits?.count, 1)

        // 戻す
        XCTAssertTrue(t.revertLineEdit(forSegment: id))
        XCTAssertEqual(t.segments[0].text, "浜って")
        XCTAssertNil(t.lineEdit(forSegment: id))
        XCTAssertNil(t.lineEdits)
        XCTAssertFalse(t.revertLineEdit(forSegment: id))
    }

    func testEditingBackToTheHeardTextRemovesTheRecord() {
        var t = transcript(["浜って"])
        let id = t.segments[0].id
        XCTAssertTrue(t.setLineText("走って", forSegment: id))
        XCTAssertTrue(t.setLineText("  浜って \n", forSegment: id))
        XCTAssertEqual(t.segments[0].text, "浜って")
        XCTAssertNil(t.lineEdits)
    }

    func testNothingChangesForEmptySameOrMissing() {
        var t = transcript([" Hello there."])
        let id = t.segments[0].id
        let before = t
        XCTAssertFalse(t.setLineText("", forSegment: id))
        XCTAssertFalse(t.setLineText(" \n\t ", forSegment: id))
        // 今の文と同じ (整えると同じ) 文
        XCTAssertFalse(t.setLineText("Hello there.", forSegment: id))
        XCTAssertFalse(t.setLineText("Hello   there.\n", forSegment: id))
        XCTAssertFalse(t.setLineText("x", forSegment: UUID()))
        XCTAssertFalse(t.revertLineEdit(forSegment: UUID()))
        XCTAssertEqual(t, before)
    }

    func testNormalization() {
        XCTAssertEqual(LineEdit.normalized("  a\nb\r\nc\td  "), "a b c d")
        XCTAssertEqual(LineEdit.normalized("a\u{0007}b\u{0000}c"), "abc")
        XCTAssertEqual(LineEdit.normalized("a    b \n  c"), "a b c")
        XCTAssertEqual(LineEdit.normalized("\u{2028}走って\u{3000}\u{3000}いる"), "走って いる")
        // 1 つだけの全角の空白は、そのまま
        XCTAssertEqual(LineEdit.normalized("走って\u{3000}いる"), "走って\u{3000}いる")
        XCTAssertEqual(LineEdit.normalized("\n\t \u{0001}"), "")

        var t = transcript(["浜って"])
        let id = t.segments[0].id
        XCTAssertTrue(t.setLineText(" 走って\n\nいる\u{0007} ", forSegment: id))
        XCTAssertEqual(t.segments[0].text, "走って いる")
        XCTAssertEqual(t.lineEdit(forSegment: id)?.edited, "走って いる")
    }

    // MARK: 訳

    func testEditRemovesTheTranslation() {
        var t = transcript(["one", "two", "three", "four"])
        let s = t.segments
        t.segments[0].translation = "一"
        // 2 つの区間にまたがる訳 (two + three)
        t.segments[1].translation = "二と三"
        t.segments[1].translationCovers = [s[2].id]
        t.segments[3].translation = "四"

        XCTAssertTrue(t.setLineText("one!", forSegment: s[0].id))
        XCTAssertNil(t.segments[0].translation)
        XCTAssertEqual(t.segments[1].translation, "二と三")

        // まとまりの続きの区間を直すと、まとまりの訳が消える
        XCTAssertTrue(t.setLineText("three!", forSegment: s[2].id))
        XCTAssertNil(t.segments[1].translation)
        XCTAssertNil(t.segments[1].translationCovers)
        XCTAssertEqual(t.segments[3].translation, "四")

        // 戻した時も、訳は消える (訳し直すのは利用者)
        t.segments[3].translation = "四"
        XCTAssertTrue(t.setLineText("four!", forSegment: s[3].id))
        t.segments[3].translation = "四!"
        XCTAssertTrue(t.revertLineEdit(forSegment: s[3].id))
        XCTAssertNil(t.segments[3].translation)
        XCTAssertEqual(t.segments[3].text, "four")
    }

    /// 翻訳の途中に利用者が文を直した: 古い文の訳は、直した行に置かない
    func testTranslationOfTheOldTextIsNotPlacedOnTheEditedLine() {
        var t = transcript(["one", "two"])
        let s = t.segments
        let sources = Dictionary(s.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(t.setLineText("one!", forSegment: s[0].id))
        XCTAssertFalse(t.apply(TranslationResult(head: s[0].id, covers: [], text: "一"), sources: sources))
        XCTAssertFalse(t.apply(TranslationResult(head: s[0].id, covers: [s[1].id], text: "一と二"), sources: sources))
        XCTAssertNil(t.segments[0].translation)
        // 直していない行には、ふつうに置く
        XCTAssertTrue(t.apply(TranslationResult(head: s[1].id, covers: [], text: "二"), sources: sources))
        XCTAssertEqual(t.segments[1].translation, "二")
        XCTAssertEqual(t.segments[0].text, "one!")
    }

    // MARK: 監査

    func testEditingAnAuditFixedLine() throws {
        var t = transcript(["浜って", "two", "two", "four"])
        let s = t.segments
        let audited = fix(s[0], to: "浜っ手")
        let suggestion = fix(s[3], to: "for", confident: false)
        let repeated = delete(s[2])
        t.adopt(AuditReport(changes: [audited, suggestion, repeated], model: "m", reviewedCount: 4))
        // 利用者の決定 (直しを決めた印) は、行を直しても変えない
        t.audit?.userDecisions = ["x": true]
        XCTAssertEqual(t.segments.map(\.text), ["浜っ手", "two", "four"])

        // 反映済みの監査の直しが在る行を直す: 聞き取った文は監査の前の文。監査の直しは結果から消える
        XCTAssertTrue(t.setLineText("走って", forSegment: s[0].id))
        XCTAssertEqual(t.lineEdit(forSegment: s[0].id)?.heard, "浜って")
        XCTAssertNil(t.audit?.change(forSegment: s[0].id))
        XCTAssertEqual(t.audit?.changes.count, 2)
        XCTAssertEqual(t.audit?.userDecisions, ["x": true])

        // 要確認の提案が在る行を直す: 提案は消える。聞き取った文は今の文
        XCTAssertTrue(t.setLineText("for you", forSegment: s[3].id))
        XCTAssertEqual(t.lineEdit(forSegment: s[3].id)?.heard, "four")
        XCTAssertNil(t.audit?.change(forSegment: s[3].id))

        // 監査の直しを全部戻しても、すべて反映しても、監査の前の区間を見ても、直した行の文は変わらない
        t.revertAllChanges()
        XCTAssertEqual(t.segments.map(\.text), ["走って", "two", "two", "for you"])
        let deleteID = try XCTUnwrap(t.audit?.change(forSegment: s[2].id)?.id)
        t.setChange(deleteID, applied: true)
        XCTAssertEqual(t.segments.map(\.text), ["走って", "two", "for you"])
        XCTAssertEqual(t.segmentsBeforeAudit.map(\.text), ["走って", "two", "two", "for you"])
        XCTAssertNotNil(t.lineEdit(forSegment: s[0].id))
        XCTAssertNotNil(t.lineEdit(forSegment: s[3].id))

        // 戻すと、監査の前の文 (聞き取った文) になる
        XCTAssertTrue(t.revertLineEdit(forSegment: s[0].id))
        XCTAssertEqual(t.segments[0].text, "浜って")
    }

    func testAdoptDoesNotTouchEditedLines() {
        var t = transcript(["浜って", "two", "three"])
        let s = t.segments
        XCTAssertTrue(t.setLineText("走って", forSegment: s[0].id))
        XCTAssertTrue(t.setLineText("TWO", forSegment: s[1].id))
        let report = AuditReport(changes: [fix(s[0], to: "浜っ手"), delete(s[1]), fix(s[2], to: "3")],
                                 model: "m", reviewedCount: 3)
        t.adopt(report)
        XCTAssertEqual(t.segments.map(\.text), ["走って", "TWO", "3"])
        XCTAssertEqual(t.audit?.changes.map(\.original.id), [s[2].id])
        XCTAssertEqual(t.audit?.changes.first?.isApplied, true)

        // もう一度監査しても同じ (前の監査の直しを戻す所も、直した行に当たらない)
        t.adopt(report)
        XCTAssertEqual(t.segments.map(\.text), ["走って", "TWO", "3"])
        XCTAssertEqual(t.audit?.changes.count, 1)

        // 直しを戻した後の監査は、ふつうに当たる
        XCTAssertTrue(t.revertLineEdit(forSegment: s[0].id))
        XCTAssertTrue(t.revertLineEdit(forSegment: s[1].id))
        t.adopt(report)
        XCTAssertEqual(t.segments.map(\.text), ["浜っ手", "3"])
        XCTAssertEqual(t.audit?.changes.count, 3)
    }

    // MARK: 保存・合わない記録

    func testOldJSONWithoutLineEditsLoadsAndRoundTrips() throws {
        let old = """
        {"sourceName":"a","segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":0,"end":1,"text":"浜って"}],
         "duration":1,"elapsed":0}
        """
        var t = try JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        XCTAssertNil(t.lineEdits)
        XCTAssertEqual(t.segments.first?.text, "浜って")
        let plain = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(plain, t)

        XCTAssertTrue(t.setLineText("走って", forSegment: t.segments[0].id, date: Date(timeIntervalSince1970: 5)))
        let reloaded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(reloaded, t)
        XCTAssertEqual(reloaded.lineEdit(forSegment: t.segments[0].id)?.heard, "浜って")
    }

    func testRecordThatNoLongerMatchesIsIgnoredAndPruned() {
        var t = transcript(["浜って", "two"])
        let s = t.segments
        XCTAssertTrue(t.setLineText("走って", forSegment: s[0].id))
        // 文が外から変わった (別の所で書き換えた)
        t.segments[0].text = "ほかの文"
        XCTAssertNil(t.lineEdit(forSegment: s[0].id))
        XCTAssertTrue(t.validLineEdits.isEmpty)
        XCTAssertFalse(t.revertLineEdit(forSegment: s[0].id))
        // 監査も、ふつうに当たる
        t.adopt(AuditReport(changes: [fix(t.segments[0], to: "別の文")], model: nil, reviewedCount: 2))
        XCTAssertEqual(t.segments[0].text, "別の文")
        // 次に書く時に、合わない記録は取り除く。聞き取った文は、今の文から決め直す (反映済みの監査の直しの前の文)
        XCTAssertTrue(t.setLineText("TWO", forSegment: s[1].id))
        XCTAssertEqual(t.lineEdits?.map(\.segmentID), [s[1].id])
        XCTAssertTrue(t.setLineText("走って", forSegment: s[0].id))
        XCTAssertEqual(t.lineEdit(forSegment: s[0].id)?.heard, "ほかの文")
    }

    // MARK: 結果の一覧の行

    func testRowCacheRebuildsOnEditAndRevert() throws {
        let cache = TranscriptRowCache()
        let job = UUID()
        var t = transcript(["浜って", "two", "three"])
        let s = t.segments
        t.segments[1].translation = "二と三"
        t.segments[1].translationCovers = [s[2].id]
        for bilingual in [false, true] {
            let before = cache.items(of: t, job: job, done: true, bilingual: bilingual, query: "")
            XCTAssertTrue(before.allSatisfy { !$0.isEditedLine })
        }

        // 同じ条件 (対訳でない・終わった) で一度作ってから、直した結果を渡す (条件ではなく、結果の違いで作り直す事を見る)
        _ = cache.items(of: t, job: job, done: true, bilingual: false, query: "")
        var edited = t
        XCTAssertTrue(edited.setLineText("走って", forSegment: s[0].id))
        let plain = cache.items(of: edited, job: job, done: true, bilingual: false, query: "")
        XCTAssertFalse(cache.lastItemsWasAppend)
        XCTAssertEqual(plain[0].text, "走って")
        XCTAssertEqual(plain[0].heard, "浜って")
        // 単言語の行は、区間の並びを持たない (直す画面は、その区間だけ)
        XCTAssertTrue(plain.allSatisfy { $0.segmentIDs == nil })
        XCTAssertEqual(plain[0].editSegmentIDs, [s[0].id])
        XCTAssertFalse(plain[1].isEditedLine)

        // 文は同じで、記録だけが変わった時も作り直す
        var recordOnly = edited
        recordOnly.lineEdits = [LineEdit(segmentID: s[0].id, heard: "ほかの聞き取り", edited: "走って")]
        XCTAssertEqual(cache.items(of: recordOnly, job: job, done: true, bilingual: false, query: "")[0].heard,
                       "ほかの聞き取り")

        // 対訳: 2 区間のまとまりの続きを直す (まとまりの訳が消え、行が分かれる)。もう一度訳して 1 行に戻す
        XCTAssertTrue(edited.setLineText("THREE", forSegment: s[2].id))
        edited.segments[1].translation = "二と三"
        edited.segments[1].translationCovers = [s[2].id]
        let bilingual = cache.items(of: edited, job: job, done: true, bilingual: true, query: "")
        XCTAssertEqual(bilingual.count, 2)
        XCTAssertEqual(bilingual[0].heard, "浜って")
        XCTAssertEqual(bilingual[1].text, "two THREE")
        XCTAssertEqual(bilingual[1].heard, "two three")
        // 2 区間の行は、区間の全部を持つ (直す画面は、2 つの入力欄)。1 区間の行は nil
        XCTAssertEqual(bilingual[1].segmentIDs, [s[1].id, s[2].id])
        XCTAssertEqual(bilingual[1].editSegmentIDs, [s[1].id, s[2].id])
        XCTAssertNil(bilingual[0].segmentIDs)

        // 戻すと、印が消える
        XCTAssertTrue(edited.revertLineEdit(forSegment: s[0].id))
        let reverted = cache.items(of: edited, job: job, done: true, bilingual: true, query: "")
        XCTAssertEqual(reverted[0].text, "浜って")
        XCTAssertFalse(reverted[0].isEditedLine)
        XCTAssertEqual(reverted[0].editSegmentIDs, [s[0].id])
        XCTAssertEqual(reverted, TranscriptRowCache().items(of: edited, job: job, done: true, bilingual: true, query: ""))
    }

    /// 文字起こし中に区間を足しただけの道 (足した分だけ作る) は、記録が変わった時には通らない
    func testAppendPathChecksLineEdits() {
        let base = transcript(["one", "two"])
        var next = base
        next.segments.append(TranscriptSegment(start: 10, end: 11, text: "three"))
        XCTAssertNotNil(TranscriptRowCache.appended(next, to: base))
        next.lineEdits = [LineEdit(segmentID: base.segments[0].id, heard: "x", edited: "one")]
        XCTAssertNil(TranscriptRowCache.appended(next, to: base))
    }

    /// 対訳の、2 つ以上の区間から成る行: 区間の並びは行の区間の全部。2 つ目の区間だけを直すと、行の文が変わり、印が出る
    func testBilingualRowWithSeveralSegments() {
        var t = transcript(["one", "two", "three", "four"])
        let s = t.segments
        t.segments[0].translation = "一から三"
        t.segments[0].translationCovers = [s[1].id, s[2].id]
        let before = TranscriptRowCache().items(of: t, job: UUID(), done: true, bilingual: true, query: "")
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before[0].segmentIDs, [s[0].id, s[1].id, s[2].id])
        XCTAssertNil(before[0].heard)
        XCTAssertNil(before[1].segmentIDs)

        XCTAssertTrue(t.setLineText("TWO", forSegment: s[1].id))
        // 訳のまとまりは消えるので、行は区間ごとに分かれる
        let split = TranscriptRowCache().items(of: t, job: UUID(), done: true, bilingual: true, query: "")
        XCTAssertEqual(split.count, 4)
        XCTAssertEqual(split[1].heard, "two")
        XCTAssertNil(split[1].segmentIDs)
        // 訳し直して、またまとまった行
        t.segments[0].translation = "一から三"
        t.segments[0].translationCovers = [s[1].id, s[2].id]
        let joined = TranscriptRowCache().items(of: t, job: UUID(), done: true, bilingual: true, query: "")
        XCTAssertEqual(joined[0].segmentIDs, [s[0].id, s[1].id, s[2].id])
        XCTAssertEqual(joined[0].text, "one TWO three")
        XCTAssertEqual(joined[0].heard, "one two three")
        XCTAssertNil(joined[1].heard)
    }

    // MARK: 学習した直しの台帳に覚えさせる組

    /// 組を切り出し、聞き取った文の中のその場所の wrong を right に置き換えると、直した文になる事を確かめる
    @discardableResult
    private func pair(_ heard: String, _ edited: String, file: StaticString = #filePath,
                      line: UInt = #line) -> AuditChange.Pair? {
        guard let span = LineEdit.suggestedSpan(heard: heard, edited: edited) else {
            XCTAssertNil(LineEdit.suggestedPair(heard: heard, edited: edited), file: file, line: line)
            return nil
        }
        let h = Array(LineEdit.normalized(heard))
        let replaced = String(h[..<span.range.lowerBound]) + span.pair.right + String(h[span.range.upperBound...])
        XCTAssertEqual(replaced, LineEdit.normalized(edited), "replacing gives the edited text", file: file, line: line)
        XCTAssertEqual(String(h[span.range]), span.pair.wrong, file: file, line: line)
        XCTAssertEqual(LineEdit.suggestedPair(heard: heard, edited: edited), span.pair, file: file, line: line)
        return span.pair
    }

    func testSuggestedPairInSpacedText() {
        XCTAssertEqual(pair("I red the book", "I read the book"), AuditChange.Pair(wrong: "red", right: "read"))
        XCTAssertEqual(pair("we went to new york last year", "we went to New York last year"),
                       AuditChange.Pair(wrong: "new york", right: "New York"))
        XCTAssertEqual(pair("Open Roblocks Studio.", "Open Roblox Studio."),
                       AuditChange.Pair(wrong: "Roblocks", right: "Roblox"))
        // 端の句読点は入れない
        XCTAssertEqual(pair("It was created by Lou Tyce.", "It was created by Lou Tice."),
                       AuditChange.Pair(wrong: "Tyce", right: "Tice"))
        // 1 字の語は、右隣の語まで広げる (右に無ければ左)
        XCTAssertEqual(pair("a b c d", "a x c d"), AuditChange.Pair(wrong: "b c", right: "x c"))
        XCTAssertEqual(pair("go to x", "go to y"), AuditChange.Pair(wrong: "to x", right: "to y"))
        // 語の切れ目で、消すだけ・足すだけの直しは、組にしない
        XCTAssertNil(pair("the the cat", "the cat"))
        XCTAssertNil(pair("the cat", "the black cat"))
        XCTAssertNil(pair("It works.", "It works. (edited)"))
        XCTAssertNil(pair("変更が効きました。", "変更が効きました。（確認用に直した）"))
        // 同じ・空・文をまるごと書き換えた
        XCTAssertNil(pair("same text", " same   text "))
        XCTAssertNil(pair("", "x"))
        XCTAssertNil(pair("This sentence was heard completely wrong by the model, sadly.",
                          "A totally different sentence that the speaker actually said out loud."))
    }

    /// 日本語は、OS の版で語の分け方が変わり得るので、値でなく、成り立つべき事を見る
    func testSuggestedPairInJapanese() throws {
        let p = try XCTUnwrap(pair("浜って", "走って"))
        XCTAssertGreaterThanOrEqual(p.wrong.count, 2)
        XCTAssertTrue(p.wrong.contains("浜"))
        XCTAssertTrue(p.right.contains("走"))
        let q = try XCTUnwrap(pair("毎朝、公園で浜っています。", "毎朝、公園で走っています。"))
        XCTAssertGreaterThanOrEqual(q.wrong.count, 2)
        XCTAssertTrue(q.wrong.contains("浜") && q.right.contains("走"))
        pair("聞き耳で文字起こしをする", "ききみみで文字起こしをする")
        pair("今日は機会学習の話です。", "今日は機械学習の話です。")
    }

    /// カタカナの語は、語の分け方が途中で切っても、カタカナの続きの全部を組にする
    /// (2026-11-23 に画面で見た形: 「ロブロクス」→「ロブロックス」が「ロクス → ロックス」になっていた)
    func testSuggestedPairCoversTheWholeKatakanaWord() throws {
        let p = try XCTUnwrap(pair("子供たちはロブロクスで遊びました。", "子供たちはロブロックスで遊びました。"))
        XCTAssertEqual(p, AuditChange.Pair(wrong: "ロブロクス", right: "ロブロックス"))
        // 長音の「ー」も、語の中の字として数える
        let q = try XCTUnwrap(pair("新しいコンピューダーを買った。", "新しいコンピューターを買った。"))
        XCTAssertEqual(q, AuditChange.Pair(wrong: "コンピューダー", right: "コンピューター"))
        // 中黒「・」では広げない (別の語)
        let r = try XCTUnwrap(pair("ジョン・スミズさんが来た。", "ジョン・スミスさんが来た。"))
        XCTAssertEqual(r, AuditChange.Pair(wrong: "スミズ", right: "スミス"))
        // カタカナでない所は、今までどおり
        XCTAssertTrue(LineEdit.isKatakana("ー") && LineEdit.isKatakana("ッ") && LineEdit.isKatakana("ｶ"))
        XCTAssertFalse(LineEdit.isKatakana("・") || LineEdit.isKatakana("は") || LineEdit.isKatakana("浜") || LineEdit.isKatakana("a"))
    }

    func testLearnedIsKeptChangedAndRead() throws {
        var t = transcript(["浜って"])
        let id = t.segments[0].id
        let learned = AuditChange.Pair(wrong: "浜って", right: "走って")
        XCTAssertTrue(t.setLineText("走って", forSegment: id, learned: learned))
        XCTAssertEqual(t.lineEdit(forSegment: id)?.learned, learned)
        // 組を渡さずに直し直すと、組は引き継ぐ。渡すと置き換える
        XCTAssertTrue(t.setLineText("走っていた", forSegment: id))
        XCTAssertEqual(t.lineEdit(forSegment: id)?.learned, learned)
        XCTAssertTrue(t.setLineText("走って", forSegment: id, learned: nil))
        XCTAssertNil(t.lineEdit(forSegment: id)?.learned)
        // 文は変えずに、組だけを置く
        XCTAssertTrue(t.setLineLearned(learned, forSegment: id))
        XCTAssertFalse(t.setLineLearned(learned, forSegment: id))
        XCTAssertEqual(t.lineEdit(forSegment: id)?.heard, "浜って")
        XCTAssertFalse(t.setLineLearned(learned, forSegment: UUID()))

        let reloaded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(reloaded.lineEdit(forSegment: id)?.learned, learned)
        // learned の無い古い記録も読める
        let old = """
        {"segmentID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","heard":"a","edited":"b","date":0}
        """
        XCTAssertNil(try JSONDecoder().decode(LineEdit.self, from: Data(old.utf8)).learned)
    }

    func testLedgerUpdate() {
        let a = AuditChange.Pair(wrong: "浜って", right: "走って")
        let b = AuditChange.Pair(wrong: "浜", right: "走")
        XCTAssertTrue(LineEdit.ledgerUpdate(old: nil, new: nil).isEmpty)
        XCTAssertTrue(LineEdit.ledgerUpdate(old: a, new: a).isEmpty, "the same pair: nothing (no second count)")
        XCTAssertEqual(LineEdit.ledgerUpdate(old: nil, new: a), LineEdit.LedgerUpdate(record: a))
        XCTAssertEqual(LineEdit.ledgerUpdate(old: a, new: b), LineEdit.LedgerUpdate(retract: a, record: b))
        // 戻した・覚えないにした
        XCTAssertEqual(LineEdit.ledgerUpdate(old: a, new: nil), LineEdit.LedgerUpdate(retract: a))

        // 台帳に当てると: 1 回覚えて、同じ組は増えず、戻すと 0 回
        var ledger = CorrectionLedger()
        func run(_ update: LineEdit.LedgerUpdate) {
            if let r = update.retract { ledger.retract(wrong: r.wrong, right: r.right) }
            if let n = update.record { ledger.record(wrong: n.wrong, right: n.right, language: "ja", example: nil, accepted: true) }
        }
        run(LineEdit.ledgerUpdate(old: nil, new: a))
        run(LineEdit.ledgerUpdate(old: a, new: a))
        XCTAssertEqual(ledger.corrections.map(\.accepted), [1])
        run(LineEdit.ledgerUpdate(old: a, new: nil))
        XCTAssertEqual(ledger.corrections.map(\.accepted), [0])
        XCTAssertTrue(ledger.active.isEmpty)
    }

    /// 1 回覚えた「浜って → 走って」は、別の区間の「浜って」に、要確認の直し (自動でない) として出る
    func testOneLearnedLineEditIsASuggestionElsewhere() throws {
        var ledger = CorrectionLedger()
        ledger.record(wrong: "浜って", right: "走って", language: "ja", example: "浜って", accepted: true)
        let other = TranscriptSegment(start: 10, end: 12, text: "毎朝、公園を浜っています。", language: "ja")
        let changes = ledger.fixes(for: [other], language: "ja")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.replacement, "毎朝、公園を走っています。")
        XCTAssertEqual(changes.first?.isConfident, false)
    }
}
