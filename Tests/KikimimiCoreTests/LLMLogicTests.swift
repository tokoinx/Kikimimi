import XCTest
@testable import KikimimiCore

/// 決まった答えを返す偽の LLM。受け取った依頼を覚えておく。
final class FakeGenerator: TextGenerating {
    var contextLength = 8192
    var prompts: [LLMPrompt] = []
    let respond: (LLMPrompt) -> String

    init(_ respond: @escaping (LLMPrompt) -> String) {
        self.respond = respond
    }

    func tokenCount(_ text: String) -> Int { text.utf8.count / 3 + 1 }

    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        if shouldCancel() { throw LLMError.cancelled }
        prompts.append(prompt)
        return respond(prompt)
    }
}

/// 評価役への問い (1: … / 2: …) に、指定した語を含む方の番号で答える
private func vote(for marker: String, in prompt: LLMPrompt) -> String {
    for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
        if line.contains(marker) { return String(line.prefix(1)) }
    }
    return "1"
}

/// 依頼の中の「[n] 本文」の行を取り出す
private func numberedLines(in prompt: LLMPrompt) -> [(Int, String)] {
    prompt.user.split(separator: "\n").compactMap { line -> (Int, String)? in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let n = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
        return (n, String(line[line.index(close, offsetBy: 2)...]))
    }
}

private func seg(_ start: TimeInterval, _ text: String, length: TimeInterval = 2) -> TranscriptSegment {
    TranscriptSegment(start: start, end: start + length, text: text)
}

final class GrammarTests: XCTestCase {
    func testLiteralEscaping() {
        XCTAssertEqual(GBNF.literal("[1] "), "\"[1] \"")
        XCTAssertEqual(GBNF.literal("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
    }

    func testNumberedLines() {
        let g = GBNF.numberedLines(count: 3)
        XCTAssertTrue(g.hasPrefix("root ::= \"[1] \" line \"\\n\" \"[2] \" line \"\\n\" \"[3] \" line \"\\n\""), g)
        XCTAssertTrue(g.contains("line ::= [^\\r\\n]+"))
    }

    func testAuditActions() {
        let g = GBNF.auditActions(count: 3)
        XCTAssertTrue(g.hasPrefix("root ::= i1? i2? i3? \"END\\n\"\n"), g)
        XCTAssertTrue(g.contains("i2 ::= \"[2] \" action \"\\n\""))
        XCTAssertTrue(g.contains("action ::= \"DEL\" note? | \"FIX \" phrase \" => \" phrase"))
        XCTAssertTrue(g.contains("phrase ::= [^\\r\\n=>]{1,40}"))
        XCTAssertTrue(g.contains("note ::= \" \" [^\\r\\n]{1,60}"))
    }

    func testCompleteLines() {
        XCTAssertEqual(completeLines(of: "[1] a\n[2] b\n"), ["[1] a", "[2] b"])
        XCTAssertEqual(completeLines(of: "[1] a\n[2] b が途中"), ["[1] a"])
        XCTAssertEqual(completeLines(of: "[1] a\r\n[2] b\r\n"), ["[1] a", "[2] b"])
        XCTAssertEqual(completeLines(of: ""), [])
    }
}

final class TextAnalysisTests: XCTestCase {
    func testScript() {
        XCTAssertTrue(Script.needsTranslation("Hello, everyone."))
        XCTAssertFalse(Script.needsTranslation("こんにちは。"))
        XCTAssertFalse(Script.needsTranslation("Roblox Studio を開きます"))
        XCTAssertFalse(Script.needsTranslation("以上です"))
        XCTAssertFalse(Script.needsTranslation("以上"))
        XCTAssertTrue(Script.needsTranslation("以上", transcriptLanguage: "zh"))
        XCTAssertFalse(Script.needsTranslation("100%"))
        XCTAssertFalse(Script.needsTranslation("…"))
        XCTAssertTrue(Script.needsTranslation("Merci beaucoup"))
        XCTAssertEqual(Script.englishName(for: "en"), "English")
        XCTAssertEqual(Script.englishName(for: nil), "the original language")
    }

    func testNonJapaneseHan() {
        XCTAssertTrue(Script.containsNonJapaneseHan("大家好，欢迎回到频道。"))
        XCTAssertTrue(Script.containsNonJapaneseHan("我们开始吧"))
        XCTAssertTrue(Script.containsNonJapaneseHan("約 400 Robux，五美元"), "中国語の読点")
        XCTAssertFalse(Script.containsNonJapaneseHan("皆さん、こんにちは。Roblox Studio を開きます。"))
        XCTAssertFalse(Script.containsNonJapaneseHan("髙橋さんと山﨑さん、時々"))
        XCTAssertFalse(Script.containsNonJapaneseHan("Hello, world!"))
        XCTAssertGreaterThan(JapaneseKanji.set.count, 6000)
    }

    func testSimilarity() {
        XCTAssertEqual(TextSimilarity.distance("kitten", "sitting"), 3)
        XCTAssertEqual(TextSimilarity.distance("", "abc"), 3)
        XCTAssertEqual(TextSimilarity.ratio("Hello, world!", "hello world"), 1)
        XCTAssertLessThan(TextSimilarity.ratio("apple pie", "banana split"), 0.5)
    }
}

final class AuditorTests: XCTestCase {
    func testFindRepeats() {
        let segments = [
            seg(0, "Today we will talk about the new release."),
            seg(2, "Today we will talk about the new release."),        // 同じ文 (長い) → 自動で消す
            seg(4, "Thank you."),
            seg(6, "Thank you."),                                         // 短い → キーが 8 文字 → 提案
            seg(8, "We shipped the update to every customer last week."),
            seg(9.5, "We shipped the update to every customer last weak."), // ほぼ同じ → 言い直しかもしれないので提案
            seg(30, "We shipped the update to every customer last week."), // 10 秒以上あと → 何もしない
            seg(33, "This is the part about pricing and plans."),
            seg(34.5, "about pricing and plans"),                          // 一部の繰り返し → 提案
        ]
        let changes = Auditor.findRepeats(segments)
        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.original.id, $0) })
        XCTAssertEqual(byID[segments[1].id]?.isConfident, true)
        XCTAssertEqual(byID[segments[1].id]?.kind, .delete)
        XCTAssertEqual(byID[segments[3].id]?.isConfident, false)
        XCTAssertEqual(byID[segments[5].id]?.isConfident, false)
        XCTAssertNil(byID[segments[6].id])
        XCTAssertEqual(byID[segments[8].id]?.isConfident, false)
        XCTAssertNil(byID[segments[0].id])
        XCTAssertEqual(changes.count, 4)
    }

    func testGenuineRepetitionIsOnlySuggested() {
        // 聞き返し (句読点が違う) は本当の発話なので見送る
        let echo = [seg(0, "The meeting was moved to Thursday."), seg(2.5, "The meeting was moved to Thursday?")]
        XCTAssertTrue(Auditor.findRepeats(echo).isEmpty)
        // 何人かが順に同じあいさつをする (短い・間がある) → 提案どまり
        let greetings = [seg(0, "よろしくお願いいたします。"), seg(2.5, "よろしくお願いいたします。"), seg(5, "よろしくお願いいたします。")]
        XCTAssertTrue(Auditor.findRepeats(greetings).allSatisfy { !$0.isConfident })
        // 語学の練習で、間をあけて同じ文をくり返す → 提案どまり
        let lesson = [seg(0, "Where is the nearest station, please?", length: 3), seg(7, "Where is the nearest station, please?", length: 3)]
        XCTAssertEqual(Auditor.findRepeats(lesson).map(\.isConfident), [false])
        // 言い直し (月曜 → 火曜) は自動で消さない
        let correction = [seg(0, "We'll meet on Monday at the main office."), seg(2, "We'll meet on Tuesday at the main office.")]
        XCTAssertTrue(Auditor.findRepeats(correction).allSatisfy { !$0.isConfident })
    }

    func testRepeatsSkipJapaneseShortReplies() {
        let segments = [seg(0, "はい"), seg(1, "はい"), seg(2, "そうですね"), seg(3, "そうですね")]
        XCTAssertTrue(Auditor.findRepeats(segments).isEmpty)
    }

    func testParse() {
        let out = "[2] FIX Roblocks => Roblox\n[3] DEL duplicate of [2]\n[2] DEL again\n[9] DEL out of range\n[4] FIX no arrow\nEND\n[1] FIX 途中 => で"
        let actions = Auditor.parse(out, count: 4)
        XCTAssertEqual(actions[2], .fix(wrong: "Roblocks", right: "Roblox"))
        XCTAssertEqual(actions[3], .delete("duplicate of [2]"))
        XCTAssertNil(actions[4], "=> の無い直しは読まない")
        XCTAssertNil(actions[1], "書き切っていない最後の行は使わない")
        XCTAssertNil(actions[9])
        XCTAssertTrue(Auditor.parse("END\n", count: 3).isEmpty)
    }

    func testApplyFix() {
        XCTAssertEqual(Auditor.applyFix(to: "Open Roblocks Studio. Roblocks is fun.", wrong: "Roblocks", right: "Roblox"),
                       "Open Roblox Studio. Roblocks is fun.", "最初の 1 か所だけ")
        XCTAssertEqual(Auditor.applyFix(to: "You can scan the code with your phone.", wrong: "can", right: "can't"),
                       "You can't scan the code with your phone.", "語の途中 (scan) は変えない")
        XCTAssertEqual(Auditor.applyFix(to: "fall through the Whirled", wrong: "whirled", right: "world"), "fall through the world")
        XCTAssertEqual(Auditor.applyFix(to: "議事録を構成します", wrong: "構成", right: "校正"), "議事録を校正します")
        XCTAssertNil(Auditor.applyFix(to: "Hello world", wrong: "planet", right: "earth"), "行に無い語は直さない")
        XCTAssertNil(Auditor.applyFix(to: "Hello world", wrong: "world", right: "World."), "何も変わらない直しは使わない")
    }

    func testFixAssessment() {
        let small = Auditor.fixAssessment(original: "Open the Roblocks Studio app.", replacement: "Open the Roblox Studio app.", language: "en")
        XCTAssertEqual(small.keep, true)
        XCTAssertEqual(small.confident, true)
        // 翻訳してしまった直しは受け付けない
        let translated = Auditor.fixAssessment(original: "Open the app.", replacement: "アプリを開きます。", language: "en")
        XCTAssertEqual(translated.keep, false)
        // 丸ごと書き換えは受け付けない
        let rewrite = Auditor.fixAssessment(original: "We met at noon.", replacement: "The weather was lovely all afternoon long.", language: "en")
        XCTAssertEqual(rewrite.keep, false)
        // 句読点だけの違いは直しにならない
        XCTAssertEqual(Auditor.fixAssessment(original: "Hello world", replacement: "Hello, world.", language: "en").keep, false)
        // 日本語の同音異義語
        let ja = Auditor.fixAssessment(original: "会議の議事録を構成します", replacement: "会議の議事録を校正します", language: "ja")
        XCTAssertEqual(ja.keep, true)
        XCTAssertEqual(ja.confident, true)
    }

    func testAuditWithLLMAndApply() throws {
        var segments = [
            seg(0, "Welcome to the Roblocks Studio tutorial."),
            seg(3, "First, open a new place."),
            seg(6, "Thank you for watching."),
            seg(9, "Then press the play button."),
        ]
        segments[0].translation = "古い訳"
        let fake = FakeGenerator { prompt in
            XCTAssertNotNil(prompt.grammar)
            XCTAssertTrue(prompt.system.contains("English"))
            if prompt.grammar == GBNF.choice { return vote(for: "Roblox Studio tutorial", in: prompt) }
            XCTAssertTrue(prompt.user.contains("Roblox Studio"), "語彙のヒントを渡す")
            return "[1] FIX Roblocks => Roblox\n[3] DEL hallucination\nEND\n"
        }
        let report = try Auditor.audit(segments, language: "en", options: AuditOptions(glossary: "Roblox Studio"),
                                       generator: fake, modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(report.changes.count, 2)
        XCTAssertEqual(report.model, "fake")
        let fix = try XCTUnwrap(report.changes.first { $0.kind == .fix })
        XCTAssertTrue(fix.isConfident, "評価役が 2 回とも直した方を選んだ")
        XCTAssertEqual(fake.prompts.filter { $0.grammar == GBNF.choice }.count, 2)
        // 定番の文は規則が先に見つけ、実際にそう話すこともあるので提案どまり (LLM の削除より規則を優先)
        let del = try XCTUnwrap(report.changes.first { $0.kind == .delete })
        XCTAssertEqual(del.origin, .rule)
        XCTAssertFalse(del.isConfident)

        var t = Transcript(sourceName: "x", segments: segments, language: "en")
        t.adopt(report)
        XCTAssertEqual(t.segments.count, 4)
        XCTAssertEqual(t.segments[0].text, "Welcome to the Roblox Studio tutorial.")
        XCTAssertNil(t.segments[0].translation, "文が変わったら訳し直す")
        XCTAssertEqual(t.audit?.appliedFixes, 1)
        XCTAssertEqual(t.audit?.appliedDeletes, 0)

        // 提案の削除を反映すると消え、元に戻すと元の位置に戻る
        t.setChange(del.id, applied: true)
        XCTAssertEqual(t.segments.count, 3)
        t.setChange(del.id, applied: false)
        XCTAssertEqual(t.segments.map(\.text)[2], "Thank you for watching.")
        XCTAssertEqual(t.segments.count, 4)
        // 修正を元に戻すと、元の文と訳に戻る
        t.setChange(fix.id, applied: false)
        XCTAssertEqual(t.segments[0].text, "Welcome to the Roblocks Studio tutorial.")
        XCTAssertEqual(t.segments[0].translation, "古い訳")
        XCTAssertEqual(t.audit?.pendingSuggestions, 2)
        // もう一度反映
        t.setChange(fix.id, applied: true)
        XCTAssertEqual(t.segments[0].text, "Welcome to the Roblox Studio tutorial.")
        t.revertAllChanges()
        XCTAssertEqual(t.segments.map(\.text), segments.map(\.text))
    }

    func testNumbersMakeLinesDifferent() {
        XCTAssertFalse(TextSimilarity.isNearDuplicate("We have 3 options to choose from today.", "We have 4 options to choose from today.", minimumRatio: 0.8))
        XCTAssertFalse(TextSimilarity.isNearDuplicate("第一章は導入の話をします", "第二章は導入の話をします", minimumRatio: 0.8))
        XCTAssertTrue(TextSimilarity.isNearDuplicate("We have three options to choose from.", "We have three option to choose from.", minimumRatio: 0.8))
        let steps = (1...4).map { seg(Double($0) * 2, "Step \($0): open the settings window.") }
        XCTAssertTrue(Auditor.findRepeats(steps).isEmpty)
    }

    func testUnbackedDeleteAndTooManyFixesStaySuggestions() throws {
        let segments = (0..<8).map { seg(Double($0) * 3, "Line number \($0) of a perfectly normal talk.") }
        let fake = FakeGenerator { prompt in
            if prompt.grammar == GBNF.choice { return vote(for: "walk", in: prompt) }
            return "[1] DEL looks odd\n[2] FIX talk => walk\n[3] FIX talk => walk\n[4] FIX talk => walk\n[5] FIX talk => walk\n"
                + "[6] FIX zebra => horse\n[7] FIX talk => talk\nEND\n"
        }
        let report = try Auditor.audit(segments, language: "en", generator: fake, modelName: "fake", shouldCancel: { false })
        XCTAssertEqual(report.changes.count, 5, "行に無い語・何も変わらない直しは捨てる")
        XCTAssertTrue(report.changes.allSatisfy { !$0.isConfident }, "半分の行を直したがる答えは提案どまり")
        var t = Transcript(sourceName: "x", segments: segments)
        t.adopt(report)
        XCTAssertEqual(t.segments.map(\.text), segments.map(\.text), "提案は本文を変えない")
        XCTAssertEqual(t.audit?.pendingSuggestions, 5)
    }

    func testJudgeVotes() throws {
        let segments = [seg(0, "Make sure the part doesn't fall through the whirled."), seg(3, "本日は新しい話をします。")]
        // 評価役がいつも 1 番目を選ぶ (位置の癖): 1 票だけ → 提案どまり
        let biased = FakeGenerator { prompt in
            prompt.grammar == GBNF.choice ? "1" : "[1] FIX whirled => world\nEND\n"
        }
        let r1 = try Auditor.audit([segments[0]], language: "en", generator: biased, modelName: "f", shouldCancel: { false })
        XCTAssertEqual(r1.changes.count, 1)
        XCTAssertFalse(r1.changes[0].isConfident)
        XCTAssertTrue(r1.changes[0].reason.contains("評価役"))
        // 評価役が 2 回とも直す前を選ぶ: 直しを捨てる
        let refuse = FakeGenerator { prompt in
            prompt.grammar == GBNF.choice ? vote(for: "whirled", in: prompt) : "[1] FIX whirled => world\nEND\n"
        }
        XCTAssertTrue(try Auditor.audit([segments[0]], language: "en", generator: refuse, modelName: "f", shouldCancel: { false }).changes.isEmpty)
        // 助詞を削るだけの直しは、評価役が認めても提案どまり
        let particle = FakeGenerator { prompt in
            prompt.grammar == GBNF.choice ? vote(for: "本日新しい", in: prompt) : "[1] FIX 本日は => 本日\nEND\n"
        }
        let r3 = try Auditor.audit([segments[1]], language: "ja", generator: particle, modelName: "f", shouldCancel: { false })
        XCTAssertEqual(r3.changes.count, 1)
        XCTAssertFalse(r3.changes[0].isConfident)
        XCTAssertTrue(r3.changes[0].reason.contains("足す・削る"))
    }

    func testDeleteWithWrongLineNumberIsIgnored() throws {
        let segments = [seg(0, "The function runs every frame."), seg(3, "Thank you for watching."), seg(6, "That's it for today, see you next time.")]
        // 3 行目を消せと言いながら、理由には 2 行目の文を書いている (番号の取り違え)
        let fake = FakeGenerator { _ in "[3] DEL Thank you for watching.\nEND\n" }
        let report = try Auditor.audit(segments, language: "en", generator: fake, modelName: "f", shouldCancel: { false })
        XCTAssertFalse(report.changes.contains { $0.original.id == segments[2].id })
        XCTAssertTrue(Auditor.noteQuotesAnotherLine("Thank you for watching.", target: 2, chunk: [0, 1, 2], lines: segments.map(\.text)))
        XCTAssertFalse(Auditor.noteQuotesAnotherLine("duplicate of [2]", target: 2, chunk: [0, 1, 2], lines: segments.map(\.text)))
    }

    func testMeaningRisk() {
        func risk(_ o: String, _ w: String, _ r: String) -> String? {
            Auditor.meaningRisk(original: o, fixed: Auditor.applyFix(to: o, wrong: w, right: r) ?? o, wrong: w, right: r)
        }
        XCTAssertNotNil(risk("We sold 1,500 units last year.", "1,500", "15,000"))
        XCTAssertNotNil(risk("会議は3時からです", "3時", "5時"))
        XCTAssertNotNil(risk("I can't go tomorrow.", "can't", "can"))
        XCTAssertNotNil(risk("We don't recommend this approach.", "don't", "do"))
        XCTAssertNotNil(risk("明日は参加できます", "できます", "できません"))
        XCTAssertNotNil(risk("Open Roblox Studio now.", "Studio", "工作室"))
        XCTAssertNil(risk("Open Roblocks Studio now.", "Roblocks", "Roblox"))
        XCTAssertNil(risk("議事録を構成します", "構成", "校正"))
    }

    func testDeletesDoNotBackEachOther() throws {
        let text = "We can start the meeting right now, everyone."
        let segments = [seg(0, text), seg(3, "Any questions before we begin?"), seg(6, text)]
        // 2 つの写しを両方とも消せと言う答え: どちらも裏付けにならず、提案どまり (文が消えてしまわない)
        let fake = FakeGenerator { _ in "[1] DEL duplicate of [3]\n[3] DEL duplicate of [1]\nEND\n" }
        let report = try Auditor.audit(segments, language: "en", generator: fake, modelName: "f", shouldCancel: { false })
        XCTAssertEqual(report.changes.filter { $0.kind == .delete }.count, 2)
        XCTAssertTrue(report.changes.allSatisfy { !$0.isConfident })
    }

    func testPartialResultsAndDecisionsSurviveReaudit() throws {
        let segments = (0..<12).map { seg(Double($0) * 3, "Sentence number \($0) about the Roblocks project.") }
        var partials: [AuditReport] = []
        let fake = FakeGenerator { prompt in
            if prompt.grammar == GBNF.choice { return vote(for: "Roblox project", in: prompt) }
            return "[1] FIX Roblocks => Roblox\nEND\n"
        }
        let report = try Auditor.audit(segments, language: "en", options: AuditOptions(maxLinesPerChunk: 4),
                                       generator: fake, modelName: "f", shouldCancel: { false }, onPartial: { partials.append($0) })
        XCTAssertEqual(partials.count, 4, "規則の結果 + 3 まとまり")
        XCTAssertEqual(partials.map { $0.changes.count }, [0, 1, 2, 3])
        XCTAssertEqual(report.changes.count, 3)

        var t = Transcript(sourceName: "x", segments: segments, language: "en")
        t.adopt(report)
        XCTAssertEqual(t.audit?.appliedFixes, 3)
        // 訳を付けてから、利用者が 1 つ取り消す
        for i in t.segments.indices { t.segments[i].translation = "訳 \(i)" }
        let rejected = report.changes[0]
        t.setChange(rejected.id, applied: false)
        XCTAssertEqual(t.segments[0].text, segments[0].text)
        // 同じ結果で監査をやり直しても、取り消した直しは取り消したまま、ほかの直しの訳も残る
        t.adopt(report)
        XCTAssertEqual(t.segments[0].text, segments[0].text)
        XCTAssertEqual(t.audit?.appliedFixes, 2)
        XCTAssertEqual(t.segments[4].text, "Sentence number 4 about the Roblox project.")
        XCTAssertEqual(t.segments[4].translation, "訳 4")
        XCTAssertEqual(t.segmentsBeforeAudit.map(\.text), segments.map(\.text))
    }

    func testSmallChunkTooManyFixes() {
        XCTAssertTrue(Auditor.isTooMany(2, of: 3))
        XCTAssertTrue(Auditor.isTooMany(4, of: 8))
        XCTAssertFalse(Auditor.isTooMany(2, of: 5))
        XCTAssertFalse(Auditor.isTooMany(3, of: 20))
        XCTAssertTrue(Auditor.isTooMany(9, of: 20))
    }

    func testStockPhraseIsSuggestion() {
        let changes = Auditor.findRepeats([seg(0, "ご視聴ありがとうございました"), seg(3, "Thanks for watching!")])
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.allSatisfy { $0.kind == .delete && !$0.isConfident && $0.origin == .rule })
    }

    func testRulesOnlyAndCancel() throws {
        let segments = [seg(0, "The quick brown fox jumps."), seg(1, "The quick brown fox jumps.")]
        let report = try Auditor.audit(segments, language: "en", generator: nil, modelName: nil, shouldCancel: { false })
        XCTAssertEqual(report.changes.count, 1)
        XCTAssertNil(report.model)
        let fake = FakeGenerator { _ in "END\n" }
        XCTAssertThrowsError(try Auditor.audit(segments, language: "en", generator: fake, modelName: "f", shouldCancel: { true })) {
            XCTAssertEqual($0 as? LLMError, .cancelled)
        }
    }

    func testChunker() {
        let chunks = LLMChunker.chunks(Array(0..<10), cost: { $0 == 5 ? 50 : 10 }, maxLines: 4, maxCost: 40)
        XCTAssertEqual(chunks, [[0, 1, 2, 3], [4], [5], [6, 7, 8, 9]])
        XCTAssertEqual(LLMChunker.chunks([], cost: { _ in 1 }, maxLines: 3, maxCost: 10), [])
    }
}

final class TranslatorTests: XCTestCase {
    func testTranslateInOrderAndSkipJapanese() throws {
        let segments = [
            seg(0, "Hello everyone."),
            seg(2, "こんにちは。"),
            seg(4, "Let's get started."),
            seg(6, "100%"),
        ]
        let fake = FakeGenerator { prompt in
            numberedLines(in: prompt).map { "[\($0.0)] 訳:\($0.1)" }.joined(separator: "\n") + "\n"
        }
        var collected: [UUID: String] = [:]
        var progress: [(Int, Int)] = []
        let failed = try Translator.translate(segments, language: "en", generator: fake, shouldCancel: { false }) { batch, done, total in
            for r in batch { collected[r.head] = r.text }
            progress.append((done, total))
        }
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(collected[segments[0].id], "訳:Hello everyone.")
        XCTAssertEqual(collected[segments[2].id], "訳:Let's get started.")
        XCTAssertNil(collected[segments[1].id])
        XCTAssertNil(collected[segments[3].id])
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertEqual(fake.prompts[0].grammar, GBNF.numberedLines(count: 2))
        XCTAssertNotNil(fake.prompts[0].maxLineBytes)
        XCTAssertTrue(fake.prompts[0].japaneseOnly)
        XCTAssertEqual(fake.prompts[0].examples, Translator.examples, "日本語の手本を見せる")
        XCTAssertEqual(progress.last?.0, 2)
        XCTAssertEqual(progress.last?.1, 2)
    }

    func testMissingLinesAreRetriedOneByOne() throws {
        let segments = (0..<3).map { seg(Double($0) * 2, "Sentence \($0).") }
        let fake = FakeGenerator { prompt in
            let lines = numberedLines(in: prompt)
            if lines.count > 1 { return "[1] 文 0\n[3] 文 2\n" } // 2 行目が抜けた
            return "[1] 文 \(lines[0].1.dropFirst(9).dropLast())\n"
        }
        var collected: [UUID: String] = [:]
        let failed = try Translator.translate(segments, language: "en", generator: fake, shouldCancel: { false }) { batch, _, _ in
            for r in batch { collected[r.head] = r.text }
        }
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(fake.prompts.count, 2)
        XCTAssertEqual(collected[segments[1].id], "文 1")
        XCTAssertEqual(collected[segments[2].id], "文 2")
    }

    func testContextUsesPreviousTranslations() throws {
        var segments = (0..<4).map { seg(Double($0) * 2, "Line \($0) here.") }
        segments[0].translation = "0 行目"
        let fake = FakeGenerator { prompt in
            numberedLines(in: prompt).map { "[\($0.0)] 訳" }.joined(separator: "\n") + "\n"
        }
        _ = try Translator.translate(segments, language: "en", options: TranslationOptions(maxLinesPerChunk: 2),
                                     generator: fake, shouldCancel: { false }) { _, _, _ in }
        XCTAssertEqual(fake.prompts.count, 2)
        XCTAssertTrue(fake.prompts[0].user.contains("Line 0 here. => 0 行目"))
        XCTAssertTrue(fake.prompts[1].user.contains("Line 2 here. => 訳"), fake.prompts[1].user)
    }

    func testSentenceSpanningSegmentsIsTranslatedOnce() throws {
        let segments = [
            seg(0, "We set up a weekly meeting where", length: 2),
            seg(2, "each person could share their progress and", length: 2),
            seg(4, "any problems they were having.", length: 2),
            seg(9, "It worked well.", length: 2),       // 間があく・前の文が終わっている → 別の行
        ]
        let fake = FakeGenerator { prompt in
            numberedLines(in: prompt).map { "[\($0.0)] 訳(\($0.1))" }.joined(separator: "\n") + "\n"
        }
        var results: [TranslationResult] = []
        _ = try Translator.translate(segments, language: "en", generator: fake, shouldCancel: { false }) { batch, _, _ in
            results += batch
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].head, segments[0].id)
        XCTAssertEqual(results[0].covers, [segments[1].id, segments[2].id])
        XCTAssertEqual(results[0].text,
                       "訳(We set up a weekly meeting where each person could share their progress and any problems they were having.)")

        var t = Transcript(sourceName: "x", segments: segments, language: "en")
        let sources = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        for r in results { XCTAssertTrue(t.apply(r, sources: sources)) }
        XCTAssertEqual(t.untranslatedCount, 0)
        let units = t.bilingualUnits()
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].segments.count, 3)
        XCTAssertEqual(units[0].end, 6)
        // 対訳の字幕は、文ごとに 1 枚 (始まりは最初の区間、終わりは最後の区間)
        let srt = Exporter.srt(t, content: .bilingual)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:06,000\nWe set up a weekly meeting where each person"), srt)
        XCTAssertTrue(srt.contains("2\n00:00:09,000 --> 00:00:11,000\nIt worked well.\n訳(It worked well.)"))
        XCTAssertEqual(Exporter.srt(t).components(separatedBy: " --> ").count - 1, 4, "原文だけなら区間ごと")
        // 文の途中の区間を監査で直すと、その文の訳は訳し直しになる
        t.invalidateTranslation(of: segments[1].id)
        XCTAssertNil(t.segments[0].translation)
        XCTAssertEqual(t.untranslatedCount, 3)
        XCTAssertEqual(Translator.pendingIndices(t.segments, language: "en"), [0, 1, 2])
    }

    func testSentenceUnitsLimits() {
        let five = (0..<5).map { seg(Double($0), "part \($0) of a long run", length: 1) }
        XCTAssertEqual(Translator.sentenceUnits(Array(0..<5), in: five), [[0, 1, 2, 3], [4]], "4 区間まで")
        let gapped = [seg(0, "first half", length: 1), seg(3, "second half", length: 1)]
        XCTAssertEqual(Translator.sentenceUnits([0, 1], in: gapped), [[0], [1]], "1.5 秒より空いたら別の文")
        XCTAssertTrue(Translator.endsSentence("Really?\""))
        XCTAssertTrue(Translator.endsSentence("そうです。」"))
        XCTAssertFalse(Translator.endsSentence("and then"))
    }

    func testChineseOutputIsRejected() throws {
        let segments = [seg(0, "Hi everyone.")]
        let fake = FakeGenerator { _ in "[1] 大家好，欢迎。\n" }
        let failed = try Translator.translate(segments, language: "en", generator: fake, shouldCancel: { false }) { _, _, _ in }
        XCTAssertEqual(failed, 1)
    }

    func testImplausibleAndCancel() throws {
        let segments = [seg(0, "Hi.")]
        let fake = FakeGenerator { _ in "[1] " + String(repeating: "あ", count: 200) + "\n" }
        let failed = try Translator.translate(segments, language: "en", generator: fake, shouldCancel: { false }) { _, _, _ in }
        XCTAssertEqual(failed, 1)
        XCTAssertThrowsError(try Translator.translate(segments, language: "en", generator: fake, shouldCancel: { true }) { _, _, _ in })
    }
}

final class BilingualExportTests: XCTestCase {
    private func sample() -> Transcript {
        var t = Transcript(sourceName: "talk",
                           segments: [seg(0, "Hello | world."), seg(2, "こんにちは"), seg(4, "Untranslated line.")],
                           language: "en", model: "m", duration: 6, elapsed: 1)
        t.segments[0].translation = "こんにちは、世界。"
        t.translationModel = "Qwen3.5 4B"
        return t
    }

    func testJapaneseText() {
        let t = sample()
        XCTAssertEqual(t.japaneseText(of: t.segments[0]), "こんにちは、世界。")
        XCTAssertEqual(t.japaneseText(of: t.segments[1]), "こんにちは")
        XCTAssertNil(t.japaneseText(of: t.segments[2]))
        XCTAssertTrue(t.hasTranslation)
        XCTAssertEqual(t.translatableCount, 2)
        XCTAssertEqual(t.untranslatedCount, 1)
    }

    func testMainlyForeign() {
        let english = Transcript(sourceName: "a", segments: [seg(0, "Hello."), seg(1, "こんにちは"), seg(2, "Bye.")], language: "en")
        XCTAssertTrue(english.isMainlyForeign)
        // 日本語の講演に英語の相づちが少しだけ
        let japanese = Transcript(sourceName: "b", segments: (0..<9).map { seg(Double($0), "これは \($0) 番目の話です") } + [seg(9, "OK.")],
                                  language: "ja")
        XCTAssertFalse(japanese.isMainlyForeign)
        XCTAssertEqual(japanese.translatableCount, 1)
        XCTAssertFalse(Transcript(sourceName: "c", segments: [seg(0, "100")]).isMainlyForeign)
        XCTAssertFalse(Transcript(sourceName: "d").isMainlyForeign)
    }

    func testFormats() {
        let t = sample()
        XCTAssertEqual(Exporter.txt(t, content: .japanese), "こんにちは、世界。\nこんにちは\nUntranslated line.\n")
        XCTAssertTrue(Exporter.txt(t, content: .bilingual).hasPrefix("[00:00] Hello | world.\n        こんにちは、世界。\n[00:02] こんにちは\n"))
        let srt = Exporter.srt(t, content: .bilingual)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nHello | world.\nこんにちは、世界。\n"), srt)
        XCTAssertTrue(srt.contains("2\n00:00:02,000 --> 00:00:04,000\nこんにちは\n"), "日本語の区間は 1 行だけ")
        XCTAssertTrue(Exporter.vtt(t, content: .japanese).contains("00:00:00.000 --> 00:00:02.000\nこんにちは、世界。"))
        let md = Exporter.markdown(t, content: .bilingual)
        XCTAssertTrue(md.contains("翻訳: Qwen3.5 4B"))
        XCTAssertTrue(md.contains("| 00:00 | Hello \\| world. | こんにちは、世界。 |"), md)
        XCTAssertTrue(md.contains("| 00:04 | Untranslated line. |  |"))
        let csv = Exporter.csv(t, content: .bilingual)
        XCTAssertTrue(csv.hasPrefix("start,end,text,japanese\n0.000,2.000,\"Hello | world.\",\"こんにちは、世界。\"\n"), csv)
        XCTAssertEqual(Exporter.render(t, as: .txt), Exporter.txt(t))
        XCTAssertEqual(ExportContent.available(for: .json), [.original])
    }

    func testCodableRoundTripWithAuditAndTranslation() throws {
        var t = sample()
        t.adopt(AuditReport(changes: [AuditChange(kind: .delete, origin: .rule, original: t.segments[2],
                                                  reason: "test", isConfident: true)],
                            model: nil, reviewedCount: 3))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Transcript.self, from: Data(Exporter.json(t).utf8))
        XCTAssertEqual(back.segments.count, 2)
        XCTAssertEqual(back.segments[0].translation, "こんにちは、世界。")
        XCTAssertEqual(back.audit?.changes.first?.isApplied, true)
        XCTAssertEqual(back.translationModel, "Qwen3.5 4B")
        // 古い形式 (訳・監査なし) の JSON も読める
        let old = #"{"sourceName":"a","segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":0,"end":1,"text":"x"}],"duration":1,"elapsed":0}"#
        let legacy = try JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        XCTAssertNil(legacy.segments[0].translation)
        XCTAssertNil(legacy.audit)
    }
}

final class LLMCatalogTests: XCTestCase {
    func testCatalog() {
        XCTAssertEqual(LLMCatalog.all.filter(\.recommended).map(\.id), [LLMCatalog.defaultModelID])
        XCTAssertEqual(Set(LLMCatalog.all.map(\.id)).count, LLMCatalog.all.count)
        XCTAssertEqual(LLMCatalog.spec(id: "qwen3.5-4b")?.fileName, "qwen3.5-4b.gguf")
        XCTAssertEqual(LLMModelSpec.treeURL(repository: "bartowski/Qwen_Qwen3.5-4B-GGUF")?.absoluteString,
                       "https://huggingface.co/api/models/bartowski/Qwen_Qwen3.5-4B-GGUF/tree/main")
        XCTAssertEqual(LLMModelSpec.downloadURL(repository: "a/b", path: "sub dir/x.gguf")?.absoluteString,
                       "https://huggingface.co/a/b/resolve/main/sub%20dir/x.gguf")
    }

    func testPickFile() throws {
        let json = """
        [
          {"type":"file","oid":"1","size":1500,"path":"README.md"},
          {"type":"file","oid":"2","size":900,"path":"mmproj-Qwen_Qwen3.5-4B-f16.gguf",
           "lfs":{"oid":"\(String(repeating: "a", count: 64))","size":900000000,"pointerSize":135}},
          {"type":"file","oid":"3","size":135,"path":"Qwen_Qwen3.5-4B-Q4_K_S.gguf",
           "lfs":{"oid":"\(String(repeating: "b", count: 64))","size":2630000000,"pointerSize":135}},
          {"type":"file","oid":"4","size":135,"path":"Qwen_Qwen3.5-4B-Q4_K_M.gguf",
           "lfs":{"oid":"\(String(repeating: "C", count: 64))","size":2780000000,"pointerSize":135}},
          {"type":"directory","oid":"5","size":0,"path":"Q4_K_M"},
          {"type":"file","oid":"6","size":135,"path":"Q4_K_M/Qwen_Qwen3.5-4B-Q4_K_M.gguf"}
        ]
        """
        let entries = try JSONDecoder().decode([HFFileEntry].self, from: Data(json.utf8))
        let spec = try XCTUnwrap(LLMCatalog.spec(id: "qwen3.5-4b"))
        let picked = try XCTUnwrap(spec.pickFile(from: entries))
        XCTAssertEqual(picked.path, "Qwen_Qwen3.5-4B-Q4_K_M.gguf")
        XCTAssertEqual(picked.fileSize, 2_780_000_000)
        XCTAssertEqual(picked.sha256, String(repeating: "c", count: 64))
        XCTAssertNil(entries[0].sha256)

        let unsloth = [HFFileEntry(type: "file", path: "Qwen3.5-2B-UD-Q4_K_XL.gguf", size: 1, lfs: nil),
                       HFFileEntry(type: "file", path: "Qwen3.5-2B-BF16.gguf", size: 1, lfs: nil)]
        XCTAssertEqual(spec.pickFile(from: unsloth)?.path, "Qwen3.5-2B-UD-Q4_K_XL.gguf")
        XCTAssertNil(spec.pickFile(from: [HFFileEntry(type: "file", path: "model-Q4_K_M-00001-of-00002.gguf", size: 1, lfs: nil)]))
    }

    func testGGUFFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gguf = dir.appendingPathComponent("a.gguf")
        try (Data("GGUF".utf8) + Data(count: 2_000_000)).write(to: gguf)
        XCTAssertTrue(GGUFFile.isGGUF(at: gguf))
        let ggml = dir.appendingPathComponent("b.bin")
        try (Data([0x6c, 0x6d, 0x67, 0x67]) + Data(count: 2_000_000)).write(to: ggml)
        XCTAssertFalse(GGUFFile.isGGUF(at: ggml))
    }
}
