import Foundation
import XCTest
@testable import KikimimiCore

/// 訳の後ろが抜けた時だけ、文に分けて訳し直す (U4)
final class TranslationSplitRetryTests: XCTestCase {
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

    /// 依頼の「Lines to translate:」の後ろの行 (番号つき)
    private func sentLines(_ prompt: LLMPrompt) -> [String] {
        guard let range = prompt.user.range(of: "Lines to translate:\n") else { return [] }
        return prompt.user[range.upperBound...].split(separator: "\n").map(String.init)
    }

    // 原文 (文が 4 つ。初めの「Welcome.」は軽いので、次の文にまとめる)
    private let welcome = "Welcome. Welcome, everyone. I'm just going to make sure that all of this is working. "
        + "It just takes a minute."
    private let piece1 = "Welcome. Welcome, everyone."
    private let piece2 = "I'm just going to make sure that all of this is working."
    private let piece3 = "It just takes a minute."
    private let cut = "Bienvenue."
    private let fr1 = "Bienvenue. Bienvenue à tous."
    private let fr2 = "Je vais juste vérifier que tout cela fonctionne correctement."
    private let fr3 = "Cela ne prend qu'une minute."

    private func run(_ segments: [TranscriptSegment], _ generator: FakeGenerator, target: String = "fr",
                     options: TranslationOptions = TranslationOptions()) throws
        -> (TranslationRunSummary, [TranslationResult]) {
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: target, options: options,
                                                          generator: generator,
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        return (summary, all)
    }

    // MARK: 文の分け方

    func testSentencePiecesInEnglishMergeALeadingShortPiece() {
        XCTAssertEqual(Translator.sentencePieces(welcome, language: "en"), [piece1, piece2, piece3])
    }

    func testSentencePiecesMergeAShortPieceIntoThePreviousSentence() {
        let text = "I'm going to check that everything works. Oh yeah. It takes about a minute to finish."
        XCTAssertEqual(Translator.sentencePieces(text, language: "en"),
                       ["I'm going to check that everything works. Oh yeah.", "It takes about a minute to finish."])
    }

    func testSentencePiecesInJapanese() {
        let text = "今日はとてもいい天気ですね。公園に行きましょう。そうしましょう。"
        XCTAssertEqual(Translator.sentencePieces(text, language: "ja"),
                       ["今日はとてもいい天気ですね。", "公園に行きましょう。", "そうしましょう。"])
    }

    func testSentencePiecesWithAFixedSplitter() {
        // 分け方は差し替えられる。全部が軽ければ 1 つにまとめる
        let split: (String, String?) -> [String] = { text, _ in text.components(separatedBy: "|") }
        XCTAssertEqual(Translator.sentencePieces("Hi.|Ok.|Yes.", language: nil, split: split), ["Hi. Ok. Yes."])
        XCTAssertEqual(Translator.sentencePieces("A long first sentence here.| Yes.|Another long sentence here.",
                                                 language: nil, split: split),
                       ["A long first sentence here. Yes.", "Another long sentence here."])
        XCTAssertEqual(Translator.sentencePieces("One single sentence without an end", language: "en"),
                       ["One single sentence without an end"])
    }

    func testJoinTranslationsByTarget() {
        XCTAssertEqual(Translator.joinTranslations(["ようこそ。", " みなさん。"], target: "ja"), "ようこそ。みなさん。")
        XCTAssertEqual(Translator.joinTranslations(["欢迎。", "大家好。"], target: "zh"), "欢迎。大家好。")
        XCTAssertEqual(Translator.joinTranslations(["ยินดีต้อนรับ", "ทุกคน"], target: "th"), "ยินดีต้อนรับ ทุกคน")
        XCTAssertEqual(Translator.joinTranslations(["Bienvenue.", "Merci."], target: "fr"), "Bienvenue. Merci.")
        XCTAssertEqual(Translator.joinTranslations(["Hello.", "Thanks."], target: "en"), "Hello. Thanks.")
    }

    // MARK: 訳し直す・入れ替える

    func testShortTranslationIsSplitResentAndReplaced() throws {
        let g = fake([welcome: cut, piece1: fr1, piece2: fr2, piece3: fr3])
        let segments = [seg(0, welcome)]
        let (summary, results) = try run(segments, g)
        XCTAssertEqual(g.prompts.count, 2, "初めの 1 回と、訳し直しの 1 回")
        XCTAssertEqual(sentLines(g.prompts[0]), ["[1] \(welcome)"])
        XCTAssertEqual(sentLines(g.prompts[1]), ["[1] \(piece1)", "[2] \(piece2)", "[3] \(piece3)"])
        // 訳し直しも、同じ指示文・同じ手本・行の数に合わせた文法
        XCTAssertEqual(g.prompts[1].system, g.prompts[0].system)
        XCTAssertEqual(g.prompts[1].examples, g.prompts[0].examples)
        XCTAssertEqual(g.prompts[1].grammar, GBNF.numberedLines(count: 3))
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.text, "\(fr1) \(fr2) \(fr3)")
        XCTAssertFalse(result.flags.contains("short"), "印は消える")
        XCTAssertEqual(result.flags, [])
        XCTAssertEqual(summary.retried, 1)
        XCTAssertEqual(summary.retryFixed, 1)
        XCTAssertEqual(summary.retryCalls, 1)
        XCTAssertEqual(summary.retryLines, 3)
        XCTAssertEqual(summary.sentToLLM, 1, "初めに送った行の数は変えない")
        XCTAssertEqual(summary.flagged, 0)
        XCTAssertEqual(summary.failed, 0)
    }

    func testJapaneseRetryIsJoinedWithoutSpaces() throws {
        let g = fake([welcome: "ようこそ。", piece1: "ようこそ。みなさん、ようこそ。",
                      piece2: "すべてがちゃんと動いているか、確かめます。", piece3: "1 分だけかかります。"])
        let (summary, results) = try run([seg(0, welcome)], g, target: "ja")
        XCTAssertEqual(results.first?.text, "ようこそ。みなさん、ようこそ。すべてがちゃんと動いているか、確かめます。1 分だけかかります。")
        XCTAssertEqual(summary.retryFixed, 1)
    }

    func testReplacedTranslationKeepsOtherFlags() throws {
        let source = "Welcome, everyone, to the stream. We sold 4,000 units in 15 days this year."
        let pieces = Translator.sentencePieces(source, language: "en")
        XCTAssertEqual(pieces.count, 2)
        let g = fake([source: "Bienvenue.", pieces[0]: "Bienvenue à tous dans ce direct.",
                      pieces[1]: "Nous avons vendu beaucoup de produits cette année en quelques jours."])
        let (summary, results) = try run([seg(0, source)], g)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.text, "Bienvenue à tous dans ce direct. Nous avons vendu beaucoup de produits cette année en quelques jours.")
        XCTAssertEqual(result.flags, ["number"], "入れ替えた訳の、ほかの印は残す")
        XCTAssertEqual(result.detail, "number: 15, 4000")
        XCTAssertEqual(summary.retryFixed, 1)
        XCTAssertEqual(summary.flagged, 1)
    }

    // MARK: 入れ替えない

    func testOnePieceNotTranslatedKeepsTheFirstTranslation() throws {
        let g = fake([welcome: cut, piece1: fr1, piece3: fr3])
        let (summary, results) = try run([seg(0, welcome)], g)
        XCTAssertEqual(g.prompts.count, 2)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.text, cut, "初めの訳を残す")
        XCTAssertTrue(result.flags.contains("short"), "short の印も残す")
        XCTAssertEqual(summary.retried, 1)
        XCTAssertEqual(summary.retryFixed, 0)
        XCTAssertEqual(summary.flagged, 1)
        XCTAssertEqual(summary.failed, 0)
    }

    func testRejectedPieceKeepsTheFirstTranslation() throws {
        // かけらの訳が受け取れない (長すぎる) 時も、入れ替えない
        let g = fake([welcome: cut, piece1: fr1, piece2: String(repeating: "très long ", count: 60), piece3: fr3])
        let (summary, results) = try run([seg(0, welcome)], g)
        XCTAssertEqual(results.first?.text, cut)
        XCTAssertEqual(summary.retryFixed, 0)
    }

    func testStillShortJoinedTranslationIsNotUsed() throws {
        let g = fake([welcome: cut, piece1: "Oui.", piece2: "Oui.", piece3: "Oui."])
        let (summary, results) = try run([seg(0, welcome)], g)
        XCTAssertEqual(results.first?.text, cut)
        XCTAssertTrue(results.first?.flags.contains("short") ?? false)
        XCTAssertEqual(summary.retried, 1)
        XCTAssertEqual(summary.retryFixed, 0)
    }

    func testOneSentenceIsNotRetried() throws {
        let source = "I'm just going to make sure that all of this is working before we start the meeting"
        let g = fake([source: cut])
        let (summary, results) = try run([seg(0, source)], g)
        XCTAssertEqual(g.prompts.count, 1, "文が 1 つなら送り直さない")
        XCTAssertTrue(results.first?.flags.contains("short") ?? false)
        XCTAssertEqual(summary.retried, 0)
    }

    func testSwitchOffDoesNotRetry() throws {
        let g = fake([welcome: cut, piece1: fr1, piece2: fr2, piece3: fr3])
        let (summary, results) = try run([seg(0, welcome)], g, options: TranslationOptions(splitRetry: false))
        XCTAssertEqual(g.prompts.count, 1)
        XCTAssertEqual(results.first?.text, cut)
        XCTAssertTrue(results.first?.flags.contains("short") ?? false)
        XCTAssertEqual(summary.retried, 0)
    }

    func testTranslationsWithoutShortAreSentExactlyAsBefore() throws {
        // short でない訳 (印なし・number だけ) では、呼び出しの数と依頼が、訳し直しを切った時と同じ
        let sold = "We sold 4,000 units in 15 days. It is a record for our small team."
        let answers = [welcome: "\(fr1) \(fr2) \(fr3)", sold: "Nous avons vendu beaucoup. C'est un record pour notre petite équipe."]
        let segments = [seg(0, welcome), seg(3, sold)]
        let on = fake(answers), off = fake(answers)
        let (a, resultsOn) = try run(segments, on)
        let (_, resultsOff) = try run(segments, off, options: TranslationOptions(splitRetry: false))
        XCTAssertEqual(on.prompts.count, 1)
        XCTAssertEqual(on.prompts.map(\.user), off.prompts.map(\.user))
        XCTAssertEqual(on.prompts.map(\.system), off.prompts.map(\.system))
        XCTAssertEqual(resultsOn, resultsOff)
        XCTAssertEqual(resultsOn.last?.flags, ["number"])
        XCTAssertEqual(a.retried, 0)
    }

    func testRetryContextIsTheLinesBeforeTheUnit() throws {
        let first = "The weather was very nice yesterday, so we went for a long walk in the park."
        let frFirst = "Il faisait très beau hier, alors nous avons fait une longue promenade dans le parc."
        let g = fake([first: frFirst, welcome: cut, piece1: fr1, piece2: fr2, piece3: fr3])
        let (summary, _) = try run([seg(0, first), seg(3, welcome)], g)
        XCTAssertEqual(summary.retryFixed, 1)
        XCTAssertEqual(g.prompts.count, 2)
        let retryUser = g.prompts[1].user
        XCTAssertTrue(retryUser.contains("\(first) => \(frFirst)"), "前のまとまりを文脈に入れる")
        XCTAssertFalse(retryUser.contains("=> \(cut)"), "初めの訳は文脈に入れない")
    }

    // MARK: 評価も同じ道を通る

    func testEvalUsesTheSplitRetry() throws {
        let c = TranslationEvalCase(id: "w", language: "en", lines: [welcome], target: "fr",
                                    references: ["\(fr1) \(fr2) \(fr3)"])
        let answers = [welcome: cut, piece1: fr1, piece2: fr2, piece3: fr3]
        let on = try LLMEval.runTranslation([c], generator: fake(answers), detector: { _ in "fr" })
        XCTAssertEqual(on.score.retried, 1)
        XCTAssertEqual(on.score.retryFixed, 1)
        XCTAssertEqual(on.byTarget["fr"]?.retryFixed, 1)
        XCTAssertEqual(on.outputs.first?.units.first?.text, "\(fr1) \(fr2) \(fr3)")
        XCTAssertEqual(on.score.chrF ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(on.outputs.first?.retried, 1)
        // 採点し直しても、訳し直しの数は残る
        let again = LLMEval.rescore(on.outputs, detector: { _ in "fr" })
        XCTAssertEqual(again.score.retried, 1)
        XCTAssertEqual(again.byTarget["fr"]?.retryFixed, 1)

        let off = try LLMEval.runTranslation([c], generator: fake(answers), splitRetry: false, detector: { _ in "fr" })
        XCTAssertEqual(off.score.retried, 0)
        XCTAssertEqual(off.outputs.first?.units.first?.text, cut)
        XCTAssertEqual(LLMEval.translationRegressions(off.byTarget, baseline: on.byTarget).count, 1, "chrF が下がる")

        let rows = LLMEval.translationTable(on.byTarget)
        // 表の升は空白で埋めるので、後ろの空白を外して見る
        XCTAssertTrue(rows[0].trimmingCharacters(in: .whitespaces).hasSuffix("retry"))
        XCTAssertTrue(rows[1].trimmingCharacters(in: .whitespaces).hasSuffix("1/1"))
        XCTAssertTrue(on.score.summary.contains("split retries 1 (used 1)"))
    }

    func testOldResultsWithoutRetryCountsDecode() throws {
        let score = try JSONDecoder().decode(TranslationEvalScore.self, from: Data(#"{"cases":1,"lines":2,"translated":2}"#.utf8))
        XCTAssertEqual(score.retried, 0)
        XCTAssertEqual(score.retryFixed, 0)
        let output = try JSONDecoder().decode(LLMEval.TranslationOutput.self, from: Data("""
        {"id":"a","target":"fr","language":"en","lineCount":1,"units":[{"lines":[0],"source":"Hi.","text":"Salut."}]}
        """.utf8))
        XCTAssertNil(output.retried)
        XCTAssertEqual(LLMEval.score(output).score.retried, 0)
        // 新しい項目は書いて読み戻せる
        var s = TranslationEvalScore()
        s.retried = 3
        s.retryFixed = 2
        let back = try JSONDecoder().decode(TranslationEvalScore.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.retried, 3)
        XCTAssertEqual(back.retryFixed, 2)
    }
}
