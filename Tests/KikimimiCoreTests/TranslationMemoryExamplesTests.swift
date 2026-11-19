import Foundation
import XCTest
@testable import KikimimiCore

/// 訳の記憶の中の似た文を、手本として指示文に足す (実験。既定は切)
final class TranslationMemoryExamplesTests: XCTestCase {
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

    private func remembered(_ source: String, _ translation: String, target: String = "ja",
                            heldOut: Bool = false) -> RememberedTranslation {
        RememberedTranslation(source: source, target: target, translation: translation, heldOut: heldOut)
    }

    private func run(_ segments: [TranscriptSegment], _ generator: FakeGenerator, target: String = "ja",
                     memory: TranslationMemoryLookup?, examples: Int,
                     excluding: Set<UUID> = []) throws -> (TranslationRunSummary, [TranslationResult]) {
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: target,
                                                          options: TranslationOptions(memoryExamples: examples),
                                                          memory: memory, memoryExcluding: excluding,
                                                          generator: generator,
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        return (summary, all)
    }

    /// 指示文の手本の行 (無ければ空)
    private func exampleLines(_ prompt: LLMPrompt) -> [String] {
        guard let range = prompt.user.range(of: "Examples of earlier translations (same style):\n") else { return [] }
        return prompt.user[range.upperBound...].components(separatedBy: "\n\n")[0].split(separator: "\n").map(String.init)
    }

    private let line = "I'm going to check that the microphone is working before we start the meeting."
    private let lineJa = "会議を始める前に、マイクが動いているか確かめます。"
    private let near1 = "I'm going to check that the camera is working before we start the meeting."
    private let near1Ja = "会議を始める前に、カメラが動いているか確かめます。"
    private let near2 = "Let me check that the microphone is working before we start."
    private let near2Ja = "始める前に、マイクが動いているか確かめさせてください。"
    private let far = "The weather in Paris was lovely yesterday afternoon."
    private let farJa = "昨日の午後、パリの天気はすばらしかった。"

    private var memory: TranslationMemoryLookup {
        TranslationMemoryLookup(target: "ja", sentences: [remembered(near1, near1Ja), remembered(near2, near2Ja),
                                                          remembered(far, farJa)])
    }

    // MARK: 切の時

    func testOffKeepsThePromptAndCallsUnchanged() throws {
        let empty = TranslationMemoryLookup(target: "ja", sentences: [])
        let a = fake([line: lineJa])
        let (sa, ra) = try run([seg(0, line)], a, memory: empty, examples: 0)
        let b = fake([line: lineJa])
        let (sb, rb) = try run([seg(0, line)], b, memory: memory, examples: 0)
        // 既定の TranslationOptions() も切
        let c = fake([line: lineJa])
        _ = try Translator.translateSummarizing([seg(0, line)], language: "en", target: "ja", memory: memory,
                                                generator: c, shouldCancel: { false }) { _, _, _ in }
        XCTAssertEqual(TranslationOptions().memoryExamples, 0)
        XCTAssertEqual(a.prompts.count, 1)
        XCTAssertEqual(b.prompts.map(\.user), a.prompts.map(\.user))
        XCTAssertEqual(c.prompts.map(\.user), a.prompts.map(\.user))
        XCTAssertEqual(b.prompts.map(\.system), a.prompts.map(\.system))
        XCTAssertEqual(b.prompts.map(\.maxTokens), a.prompts.map(\.maxTokens))
        XCTAssertFalse(b.prompts[0].user.contains("Examples of earlier"))
        XCTAssertEqual(rb.map(\.text), ra.map(\.text))
        XCTAssertEqual(sa.examplesUsed, 0)
        XCTAssertEqual(sb.examplesUsed, 0)
        // 手本が空の指示文は、手本の引数を足す前と同じ
        XCTAssertEqual(Translator.userPrompt(lines: [line], context: [], glossary: nil, examples: []),
                       Translator.userPrompt(lines: [line], context: [], glossary: nil))
    }

    // MARK: 入の時

    func testOnAddsOnlySimilarSentencesUpToTheLimit() throws {
        let g = fake([line: lineJa])
        let (summary, results) = try run([seg(0, line)], g, memory: memory, examples: 2)
        XCTAssertEqual(g.prompts.count, 1)
        XCTAssertEqual(exampleLines(g.prompts[0]), ["\(near1) => \(near1Ja)", "\(near2) => \(near2Ja)"])
        XCTAssertEqual(summary.examplesUsed, 1)
        XCTAssertEqual(results.first?.text, lineJa)
        // 手本は、訳語の対の後・直前の行の前
        let user = g.prompts[0].user
        let examplesAt = try XCTUnwrap(user.range(of: "Examples of earlier")).lowerBound
        let linesAt = try XCTUnwrap(user.range(of: "Lines to translate:")).lowerBound
        XCTAssertLessThan(examplesAt, linesAt)

        // 件数の上限
        let one = fake([line: lineJa])
        _ = try run([seg(0, line)], one, memory: memory, examples: 1)
        XCTAssertEqual(exampleLines(one.prompts[0]), ["\(near1) => \(near1Ja)"])

        // 似ていない文だけなら、手本を足さない (下限の点)
        XCTAssertLessThan(MemoryExampleIndex.similarity(line, far), MemoryExampleIndex.minimumScore)
        XCTAssertGreaterThanOrEqual(MemoryExampleIndex.similarity(line, near2), MemoryExampleIndex.minimumScore)
        let onlyFar = TranslationMemoryLookup(target: "ja", sentences: [remembered(far, farJa)])
        let none = fake([line: lineJa])
        let (s, _) = try run([seg(0, line)], none, memory: onlyFar, examples: 2)
        XCTAssertTrue(exampleLines(none.prompts[0]).isEmpty)
        XCTAssertFalse(none.prompts[0].user.contains("Examples of earlier"))
        XCTAssertEqual(s.examplesUsed, 0)
    }

    func testLongExamplesAreNotUsed() throws {
        let long = near1 + String(repeating: " And then we will talk about it again.", count: 4)
        XCTAssertGreaterThan(long.count, MemoryExampleIndex.maximumCharacters)
        let longTranslation = String(repeating: "あ", count: MemoryExampleIndex.maximumCharacters + 1)
        let lookup = TranslationMemoryLookup(target: "ja", sentences: [remembered(long, near1Ja),
                                                                        remembered(near1, longTranslation),
                                                                        remembered(near2, near2Ja)])
        let g = fake([line: lineJa])
        _ = try run([seg(0, line)], g, memory: lookup, examples: 3)
        XCTAssertEqual(exampleLines(g.prompts[0]), ["\(near2) => \(near2Ja)"])
    }

    func testHeldOutSameAndExcludedSentencesAreNotUsed() throws {
        // 取り分けた文は使わない
        let held = TranslationMemoryLookup(target: "ja", sentences: [remembered(near1, near1Ja, heldOut: true),
                                                                      remembered(near2, near2Ja)])
        let a = fake([line: lineJa])
        _ = try run([seg(0, line)], a, memory: held, examples: 2)
        XCTAssertEqual(exampleLines(a.prompts[0]), ["\(near2) => \(near2Ja)"])

        // 同じ文 (U2 の再利用で訳が置かれる文) は、手本にしない
        let same = TranslationMemoryLookup(target: "ja", sentences: [remembered(near1, near1Ja), remembered(near2, near2Ja)])
        let b = fake([line: lineJa])
        let (sb, rb) = try run([seg(0, line), seg(10, near1)], b, memory: same, examples: 2)
        XCTAssertEqual(sb.fromMemory, 1)
        XCTAssertEqual(rb.first { $0.fromMemory }?.text, near1Ja)
        XCTAssertEqual(exampleLines(b.prompts[0]), ["\(near2) => \(near2Ja)"])

        // 評価で抜く文 (memoryExcluding の区間の文) も、手本にしない
        let segments = [seg(0, line), seg(10, near1)]
        let c = fake([line: lineJa, near1: near1Ja])
        let (sc, _) = try run(segments, c, memory: same, examples: 2, excluding: [segments[1].id])
        XCTAssertEqual(sc.fromMemory, 0)
        XCTAssertEqual(c.prompts.count, 1)
        XCTAssertFalse(exampleLines(c.prompts[0]).contains("\(near1) => \(near1Ja)"))
        XCTAssertEqual(exampleLines(c.prompts[0]), ["\(near2) => \(near2Ja)"])

        // 原文の空白・NFKC が違うだけの文も、同じ文と見る
        let spaced = TranslationMemoryLookup(target: "ja", sentences: [remembered("  " + line.replacingOccurrences(of: " ", with: "  "), lineJa),
                                                                        remembered(near2, near2Ja)])
        let d = fake([line: lineJa])
        let (sd, _) = try run([seg(0, line)], d, memory: spaced, examples: 2, excluding: [])
        // 同じ文は U2 で置かれ、LLM には送らない
        XCTAssertEqual(sd.fromMemory, 1)
        XCTAssertTrue(d.prompts.isEmpty)
    }

    func testOtherTargetMemoryIsNotUsed() throws {
        // 写しの訳す先が違う (フランス語の写しで、日本語へ訳す)
        let fr = TranslationMemoryLookup(target: "fr", sentences: [remembered(near1, "Je vérifie la caméra.", target: "fr")])
        let a = fake([line: lineJa])
        let (sa, _) = try run([seg(0, line)], a, memory: fr, examples: 2)
        XCTAssertTrue(exampleLines(a.prompts[0]).isEmpty)
        XCTAssertEqual(sa.examplesUsed, 0)
        // 写しの中で、訳す先の違う文は候補に入らない
        let mixed = TranslationMemoryLookup(target: "ja", sentences: [remembered(near1, "Je vérifie la caméra.", target: "fr"),
                                                                       remembered(near2, near2Ja)])
        XCTAssertEqual(mixed.examples.map(\.source), [near2])
        let b = fake([line: lineJa])
        _ = try run([seg(0, line)], b, memory: mixed, examples: 2)
        XCTAssertEqual(exampleLines(b.prompts[0]), ["\(near2) => \(near2Ja)"])
    }

    func testSplitRetryPiecesGetNoExamples() throws {
        let welcome = "Welcome. Welcome, everyone. I'm just going to make sure that all of this is working. "
            + "It just takes a minute."
        let piece1 = "Welcome. Welcome, everyone."
        let piece2 = "I'm just going to make sure that all of this is working."
        let piece3 = "It just takes a minute."
        let lookup = TranslationMemoryLookup(target: "fr", sentences: [
            remembered("I'm just going to make sure that all of this is working fine.", "Je vérifie que tout marche bien.",
                       target: "fr")
        ])
        let g = fake([welcome: "Bienvenue.", piece1: "Bienvenue. Bienvenue à tous.",
                      piece2: "Je vais juste vérifier que tout cela fonctionne correctement.",
                      piece3: "Cela ne prend qu'une minute."])
        let (summary, _) = try run([seg(0, welcome)], g, target: "fr", memory: lookup, examples: 2)
        XCTAssertEqual(g.prompts.count, 2, "初めの 1 回と、訳し直しの 1 回")
        XCTAssertEqual(exampleLines(g.prompts[0]).count, 1, "初めの 1 回には手本が入る")
        XCTAssertTrue(exampleLines(g.prompts[1]).isEmpty, "訳し直しのかけらには手本を足さない")
        XCTAssertEqual(summary.retried, 1)
        XCTAssertEqual(summary.examplesUsed, 1)
    }

    func testExamplesUsedCountsCallsWithExamples() throws {
        // 1 回に 1 行ずつ送る: 似た文の在る行 2 つと、似た文の無い行 1 つ
        let other = "Bananas are yellow and taste sweet when they are ripe."
        let segments = [seg(0, line), seg(10, other), seg(20, near2.replacingOccurrences(of: "Let me", with: "Please"))]
        var answers = [line: lineJa, other: "バナナは黄色い。"]
        answers[segments[2].text] = "確かめてください。"
        let g = fake(answers)
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: "ja",
                                                          options: TranslationOptions(maxLinesPerChunk: 1, memoryExamples: 2),
                                                          memory: memory, generator: g,
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        XCTAssertEqual(g.prompts.count, 3)
        XCTAssertEqual(g.prompts.map { exampleLines($0).isEmpty }, [false, true, false])
        XCTAssertEqual(summary.examplesUsed, 2)
    }

    func testBudgetStaysTheSameWithExamples() throws {
        // 文脈が足りる時、出力の上限は送る行で決まり、手本で伸びた指示文で減らない
        let a = fake([line: lineJa])
        _ = try run([seg(0, line)], a, memory: memory, examples: 0)
        let b = fake([line: lineJa])
        _ = try run([seg(0, line)], b, memory: memory, examples: 2)
        XCTAssertEqual(b.prompts[0].maxTokens, a.prompts[0].maxTokens)
        XCTAssertGreaterThan(b.prompts[0].user.count, a.prompts[0].user.count)
    }

    // MARK: 評価の道

    func testEvalRunsWithExamplesAndRecordsTheCount() throws {
        var mem = TranslationMemory()
        mem.sentences = [remembered(near1, near1Ja), remembered(near2, near2Ja), remembered(far, farJa)]
        let c = TranslationEvalCase(id: "ex", language: "en", lines: [line, near1], target: "ja",
                                    references: [lineJa, near1Ja])
        let g = fake([line: lineJa, near1: near1Ja])
        let result = try LLMEval.runTranslation([c], generator: g, memory: mem, examples: 2, detector: nil)
        // 問題の行と同じ文 (near1) は、再利用にも手本にも使わない
        XCTAssertEqual(result.score.reused, 0)
        XCTAssertEqual(g.prompts.count, 1)
        XCTAssertEqual(exampleLines(g.prompts[0]), ["\(near2) => \(near2Ja)"])
        XCTAssertEqual(result.score.examplesUsed, 1)
        XCTAssertEqual(result.byTarget["ja"]?.examplesUsed, 1)
        XCTAssertEqual(result.outputs.first?.examplesUsed, 1)
        XCTAssertTrue(result.score.summary.contains("calls with examples 1"))
        // 採点し直しても残る
        XCTAssertEqual(LLMEval.rescore(result.outputs, detector: nil).score.examplesUsed, 1)

        // 記憶が無ければ、examples を渡しても切
        let h = fake([line: lineJa, near1: near1Ja])
        let plain = try LLMEval.runTranslation([c], generator: h, examples: 2, detector: nil)
        XCTAssertFalse(h.prompts[0].user.contains("Examples of earlier"))
        XCTAssertEqual(plain.score.examplesUsed, 0)
        XCTAssertNil(plain.outputs.first?.examplesUsed)
    }

    func testOldReportsReadExamplesUsedAsZero() throws {
        let old = #"{"cases": 1, "lines": 2, "translated": 2, "reused": 1}"#
        let score = try JSONDecoder().decode(TranslationEvalScore.self, from: Data(old.utf8))
        XCTAssertEqual(score.examplesUsed, 0)
        XCTAssertEqual(score.reused, 1)
        let output = #"{"id": "a", "target": "ja", "language": "en", "lineCount": 1, "units": []}"#
        let o = try JSONDecoder().decode(LLMEval.TranslationOutput.self, from: Data(output.utf8))
        XCTAssertNil(o.examplesUsed)
        XCTAssertEqual(LLMEval.score(o).score.examplesUsed, 0)
        // 書いて読み直しても残る
        var s = TranslationEvalScore()
        s.examplesUsed = 4
        let back = try JSONDecoder().decode(TranslationEvalScore.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.examplesUsed, 4)
    }

    // MARK: 大きな記憶で選ぶ時間

    func testSelectingFromTwoThousandSentencesIsQuick() throws {
        // 決まった種の擬似乱数で、2000 件の英語の文を作る
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ n: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(n))
        }
        let words = ["the", "meeting", "microphone", "camera", "check", "working", "start", "before", "we", "will",
                     "talk", "about", "project", "budget", "next", "week", "people", "office", "question", "answer",
                     "really", "think", "going", "make", "sure", "everything", "today", "tomorrow", "server", "update"]
        func sentence() -> String {
            (0..<(8 + next(12))).map { _ in words[next(words.count)] }.joined(separator: " ") + "."
        }
        let sentences = (0..<2000).map { i in remembered(sentence() + " \(i)", "訳 \(i)") }
        let lookup = TranslationMemoryLookup(target: "ja", sentences: sentences)
        XCTAssertEqual(lookup.examples.count, 2000)
        let lines = (0..<10).map { _ in sentence() }
        let started = Date()
        let index = MemoryExampleIndex(lookup.examples, excluding: [])
        let built = Date()
        let chosen = index.select(for: lines, limit: 2)
        let finished = Date()
        print(String(format: "memory examples: 2000 sentences, index %.1f ms, select for 10 lines %.1f ms (%d chosen)",
                     built.timeIntervalSince(started) * 1000, finished.timeIntervalSince(built) * 1000, chosen.count))
        XCTAssertLessThanOrEqual(chosen.count, 2)
    }
}
