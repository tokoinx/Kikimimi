import XCTest
@testable import KikimimiCore

/// llama.cpp が計算に失敗した時 (`LLMError.decodeFailed`) の、監査・翻訳の受け止め方を見る試験。
/// 本物の llama は試験から呼べないので、決めた回数だけ答えたあとで失敗を投げる偽物を使う。

/// 決めた回数 (answers) だけ respond で答え、その次からは error を投げる偽の LLM
private final class FailingGenerator: TextGenerating {
    var contextLength = 8192
    let answers: Int
    let error: LLMError
    let respond: (LLMPrompt) -> String
    /// 答えた依頼 (失敗した依頼は入らない)
    var prompts: [LLMPrompt] = []
    /// 失敗を投げた回数
    var failures = 0

    init(answers: Int, error: LLMError, _ respond: @escaping (LLMPrompt) -> String) {
        self.answers = answers
        self.error = error
        self.respond = respond
    }

    func tokenCount(_ text: String) -> Int { text.utf8.count / 3 + 1 }

    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        if shouldCancel() { throw LLMError.cancelled }
        guard prompts.count < answers else {
            failures += 1
            throw error
        }
        prompts.append(prompt)
        return respond(prompt)
    }
}

/// llama.cpp の失敗の番号: -1・-2・-3 は `llama_batch_ext_add_token` の戻り値、-100・-101 はこのアプリが決めた番号
private let failureCodes: [Int32] = [-1, -2, -3, LLMBatchCheck.positionFailedCode, LLMBatchCheck.outputFailedCode]

/// 依頼の中の「[n] 本文」の行を取り出す
private func numbered(in prompt: LLMPrompt) -> [(Int, String)] {
    prompt.user.split(separator: "\n").compactMap { line -> (Int, String)? in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let n = Int(line[line.index(after: line.startIndex)..<close]),
              line.index(close, offsetBy: 2) <= line.endIndex else { return nil }
        return (n, String(line[line.index(close, offsetBy: 2)...]))
    }
}

/// 互いに似ていない文 (規則の「繰り返し」に当たらない) を count 行
private func distinctSegments(_ count: Int) -> [TranscriptSegment] {
    let texts = [
        "Open the editor before the meeting starts.",
        "Our designer prefers warm colors for menus.",
        "Yesterday the build server crashed twice.",
        "Please water the plants on Friday.",
        "Seven people joined the call from Osaka.",
        "The bridge downtown closes at midnight.",
        "Remember to back up your laptop weekly.",
        "A cat slept on the keyboard all morning.",
        "Lunch will be served in the north hall.",
        "We should test the parser with long inputs.",
        "Her violin lesson moved to Thursday.",
        "Snow is expected in the mountains tonight.",
    ]
    return (0..<count).map { i in
        TranscriptSegment(start: Double(i) * 3, end: Double(i) * 3 + 3, text: texts[i % texts.count])
    }
}

final class LLMFailureTests: XCTestCase {
    override func tearDown() {
        L10n.language = .en
        super.tearDown()
    }

    // MARK: 知らせの文

    /// 知らせの文に、llama.cpp の番号がそのまま入る (英語・日本語を含む、画面のすべての言語で)
    func testDecodeFailedMessageShowsTheCode() {
        for language in UILanguage.allCases {
            L10n.language = language
            for code in failureCodes {
                let text = LLMError.decodeFailed(code).errorDescription ?? ""
                XCTAssertEqual(text, L("The LLM failed to compute (llama.cpp error %d).", Int(code)), "\(language)")
                XCTAssertTrue(text.contains("\(code)"), "\(language) \(code): \(text)")
                // localizedDescription (アプリが知らせに使う物) も同じ文
                XCTAssertEqual(LLMError.decodeFailed(code).localizedDescription, text)
            }
        }
        L10n.language = .ja
        let japanese = LLMError.decodeFailed(-1).errorDescription
        L10n.language = .en
        XCTAssertNotEqual(japanese, LLMError.decodeFailed(-1).errorDescription, "日本語の画面では訳した文")
    }

    // MARK: 番号の決まり (LlamaEngine が呼ぶ)

    func testBatchCheckAddedPassesIndicesAndThrowsNegatives() throws {
        XCTAssertEqual(try LLMBatchCheck.added(0), 0)
        XCTAssertEqual(try LLMBatchCheck.added(1), 1)
        XCTAssertEqual(try LLMBatchCheck.added(511), 511)
        for code: Int32 in [-1, -2, -3, -7] {
            XCTAssertThrowsError(try LLMBatchCheck.added(code)) { error in
                XCTAssertEqual(error as? LLMError, .decodeFailed(code))
            }
        }
    }

    func testBatchCheckPositionAndOutputUseOwnCodes() throws {
        XCTAssertEqual(LLMBatchCheck.positionFailedCode, -100)
        XCTAssertEqual(LLMBatchCheck.outputFailedCode, -101)
        XCTAssertNoThrow(try LLMBatchCheck.positionSet(true))
        XCTAssertNoThrow(try LLMBatchCheck.outputMarked(true))
        XCTAssertThrowsError(try LLMBatchCheck.positionSet(false)) { error in
            XCTAssertEqual(error as? LLMError, .decodeFailed(-100))
        }
        XCTAssertThrowsError(try LLMBatchCheck.outputMarked(false)) { error in
            XCTAssertEqual(error as? LLMError, .decodeFailed(-101))
        }
    }

    func testBatchCheckProcessedThrowsEveryNonZero() throws {
        XCTAssertNoThrow(try LLMBatchCheck.processed(0))
        for rc: Int32 in [1, 2, -1, -3] {
            XCTAssertThrowsError(try LLMBatchCheck.processed(rc)) { error in
                XCTAssertEqual(error as? LLMError, .decodeFailed(rc))
            }
        }
    }

    // MARK: 監査

    /// はじめの依頼で失敗: 失敗はそのまま投げ直され、LLM の結果として渡る物は無い (規則だけの途中の結果は渡る)
    func testAuditRethrowsAtOnceAndReportsNoLLMResult() {
        for code in failureCodes {
            let fake = FailingGenerator(answers: 0, error: .decodeFailed(code)) { _ in "END\n" }
            var partials: [AuditReport] = []
            var finished: AuditReport?
            XCTAssertThrowsError(try {
                finished = try Auditor.audit(distinctSegments(6), language: "en", generator: fake, modelName: "fake",
                                             shouldCancel: { false }, onPartial: { partials.append($0) })
            }()) { error in
                XCTAssertEqual(error as? LLMError, .decodeFailed(code))
            }
            XCTAssertNil(finished)
            XCTAssertEqual(fake.failures, 1, "失敗の後に、もう一度は頼まない")
            // 途中の結果は、規則だけの物 (LLM の名前が無く、途中の印が付く) の 1 回だけ
            XCTAssertEqual(partials.count, 1)
            XCTAssertNil(partials.first?.model)
            XCTAssertEqual(partials.first?.isPartial, true)
            XCTAssertFalse(partials.contains { $0.model != nil }, "見ていないのに LLM で見終えたことにしない")
        }
    }

    /// 2 つ目のまとまりで失敗: 1 つ目のまとまりの結果は onPartial で渡り (途中の印つき)、
    /// 失敗はそのまま投げ直され、見終えた結果 (途中の印の無い物) は渡らない
    func testAuditFailingOnSecondChunkKeepsFinishedChunks() {
        var segments = distinctSegments(6)
        segments[1].text = "We will bild a small game today."
        let options = AuditOptions(maxLinesPerChunk: 3)
        for code in failureCodes {
            // 1 つ目のまとまり (1 回) と、その直しの評価役 (2 回) には答え、2 つ目のまとまりで失敗する
            let fake = FailingGenerator(answers: 3, error: .decodeFailed(code)) { prompt in
                if prompt.grammar == GBNF.choice {
                    for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                        if line.contains("build") { return String(line.prefix(1)) }
                    }
                    return "1"
                }
                let fixes = numbered(in: prompt).filter { $0.1.contains("bild") }.map { "[\($0.0)] FIX bild => build\n" }
                return fixes.joined() + "END\n"
            }
            var partials: [AuditReport] = []
            var progress: [(Int, Int)] = []
            XCTAssertThrowsError(try Auditor.audit(segments, language: "en", options: options, generator: fake,
                                                   modelName: "fake", shouldCancel: { false },
                                                   onProgress: { progress.append(($0, $1)) },
                                                   onPartial: { partials.append($0) })) { error in
                XCTAssertEqual(error as? LLMError, .decodeFailed(code))
            }
            XCTAssertEqual(fake.prompts.count, 3)
            XCTAssertEqual(fake.failures, 1)
            // 規則だけの結果 + 1 つ目のまとまりの結果
            XCTAssertEqual(partials.count, 2)
            let last = partials.last
            XCTAssertEqual(last?.model, "fake")
            XCTAssertEqual(last?.isPartial, true, "途中で止まった結果には、途中の印が付く")
            let fix = last?.change(forSegment: segments[1].id)
            XCTAssertEqual(fix?.replacement, "We will build a small game today.")
            XCTAssertEqual(fix?.origin, .llm)
            // 2 つ目のまとまり (4〜6 行目) には、LLM の結果が無い
            for segment in segments[3...] {
                XCTAssertFalse(last?.changes.contains { $0.original.id == segment.id && $0.origin == .llm } ?? true)
            }
            // 見終えたのは 2 つのうち 1 つまで
            XCTAssertEqual(progress.last.map { [$0.0, $0.1] }, [1, 2])
        }
    }

    // MARK: 読めなかった答え

    /// 監査を通し、結果と、onUnread に渡った数 (呼ばれた回数も) を返す
    private func auditCountingUnread(_ segments: [TranscriptSegment], options: AuditOptions = AuditOptions(),
                                     _ respond: @escaping (LLMPrompt) -> String) throws -> (report: AuditReport, unread: [Int]) {
        var unread: [Int] = []
        let report = try Auditor.audit(segments, language: "en", options: options, generator: FakeGenerator(respond),
                                       modelName: "fake", shouldCancel: { false }, onUnread: { unread.append($0) })
        return (report, unread)
    }

    /// 「END」で終わる答えは、改行の有無によらず書き切った答え (読めなかった所は 0)
    func testReplyEndingWithEndIsNotCounted() throws {
        for reply in ["END\n", "END", "END\r\n", "  END  \n\n"] {
            let result = try auditCountingUnread(distinctSegments(4)) { _ in reply }
            XCTAssertEqual(result.unread, [0], "答え \(reply.debugDescription)")
            XCTAssertTrue(result.report.changes.isEmpty)
        }
    }

    /// 空の答え・空白だけの答えは、1 か所読めなかったと数える (「指摘なし」と同じに見なさない)
    func testEmptyOrBlankReplyIsCounted() throws {
        for reply in ["", "  \n \n"] {
            let result = try auditCountingUnread(distinctSegments(4)) { _ in reply }
            XCTAssertEqual(result.unread, [1], "答え \(reply.debugDescription)")
            XCTAssertNil(result.report.isPartial, "監査はふつうに終わる")
        }
    }

    /// 行の途中で切れた答え: 書き切った行の直しは使い、読めなかった所を 1 と数える
    func testCutOffReplyKeepsFinishedFixAndIsCounted() throws {
        var segments = distinctSegments(4)
        segments[1].text = "We will bild a small game today."
        let result = try auditCountingUnread(segments) { prompt in
            if prompt.grammar == GBNF.choice {
                for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
                    if line.contains("build") { return String(line.prefix(1)) }
                }
                return "1"
            }
            return "[2] FIX bild => build\n[3] FIX wor"
        }
        XCTAssertEqual(result.unread, [1])
        let fix = result.report.change(forSegment: segments[1].id)
        XCTAssertEqual(fix?.replacement, "We will build a small game today.")
        XCTAssertEqual(fix?.origin, .llm)
    }

    /// 2 つのまとまりのうち 1 つだけが切れた: 読めなかった所は 1
    func testOneOfTwoChunksCutOffCountsOne() throws {
        let segments = distinctSegments(6)
        let result = try auditCountingUnread(segments, options: AuditOptions(maxLinesPerChunk: 3)) { prompt in
            prompt.user.contains(segments[3].text) ? "[1] DE" : "END\n"
        }
        XCTAssertEqual(result.unread, [1])
    }

    /// 評価役の答えが 2 回とも読めない: 直しは捨て (今までどおり)、読めなかった所として数える
    func testBothJudgeVotesUnreadableDropTheFixAndAreCounted() throws {
        var segments = distinctSegments(4)
        segments[1].text = "We will bild a small game today."
        let result = try auditCountingUnread(segments) { prompt in
            prompt.grammar == GBNF.choice ? "" : "[2] FIX bild => build\nEND\n"
        }
        XCTAssertEqual(result.unread, [1])
        XCTAssertNil(result.report.change(forSegment: segments[1].id))
    }

    /// 評価役の答えが 1 回だけ読めた: 今までどおり (直した後を選べば提案に残る) で、数えない
    func testOneReadableJudgeVoteIsNotCounted() throws {
        var segments = distinctSegments(4)
        segments[1].text = "We will bild a small game today."
        var judged = 0
        let result = try auditCountingUnread(segments) { prompt in
            guard prompt.grammar == GBNF.choice else { return "[2] FIX bild => build\nEND\n" }
            judged += 1
            // 1 回目 (1: 直す前 / 2: 直した後) は直した後を選び、2 回目は読めない答え
            return judged == 1 ? "2" : ""
        }
        XCTAssertEqual(judged, 2)
        XCTAssertEqual(result.unread, [0])
        let fix = result.report.change(forSegment: segments[1].id)
        XCTAssertEqual(fix?.replacement, "We will build a small game today.")
        XCTAssertEqual(fix?.isConfident, false, "1 票だけなので確かめてもらう提案")
    }

    /// 規則だけの監査では、onUnread を呼ばない
    func testRulesOnlyAuditDoesNotReportUnread() throws {
        var calls = 0
        _ = try Auditor.audit(distinctSegments(4), language: "en", generator: nil, modelName: nil,
                              shouldCancel: { false }, onUnread: { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }

    // MARK: 翻訳

    /// はじめの依頼で失敗: 失敗はそのまま投げ直される (行を「訳せなかった」に数えて黙って終えない)。
    /// 訳の結果は 1 つも渡らず、もとから訳の在る行は送られない
    func testTranslationRethrowsAtOnce() {
        var segments = distinctSegments(4)
        segments[0].translation = "もとからある訳"
        for code in failureCodes {
            let fake = FailingGenerator(answers: 0, error: .decodeFailed(code)) { prompt in
                numbered(in: prompt).map { "[\($0.0)] 訳:\($0.1)\n" }.joined()
            }
            var batches: [[TranslationResult]] = []
            var summary: TranslationRunSummary?
            XCTAssertThrowsError(try {
                summary = try Translator.translateSummarizing(segments, language: "en", generator: fake,
                                                              shouldCancel: { false }) { batch, _, _ in batches.append(batch) }
            }()) { error in
                XCTAssertEqual(error as? LLMError, .decodeFailed(code))
            }
            XCTAssertNil(summary, "失敗した行を failed・rejected に数えた結果を返さない")
            XCTAssertEqual(fake.failures, 1)
            XCTAssertTrue(batches.allSatisfy(\.isEmpty), "訳の結果は渡らない (始めの 0 件の知らせだけ)")
            XCTAssertEqual(segments[0].translation, "もとからある訳")
        }
    }

    /// 2 つ目のまとまりで失敗: 1 つ目のまとまりの訳は渡り、失敗はそのまま投げ直される。
    /// もとから訳の在る行の結果は作らない (訳を上書きしない)
    func testTranslationFailingOnSecondChunkKeepsFinishedChunks() {
        var segments = distinctSegments(5)
        segments[0].translation = "もとからある訳"
        let options = TranslationOptions(maxLinesPerChunk: 2)
        for code in failureCodes {
            let fake = FailingGenerator(answers: 1, error: .decodeFailed(code)) { prompt in
                numbered(in: prompt).map { "[\($0.0)] 訳:\($0.1)\n" }.joined()
            }
            var results: [TranslationResult] = []
            var progress: [(Int, Int)] = []
            XCTAssertThrowsError(try Translator.translate(segments, language: "en", options: options, generator: fake,
                                                          shouldCancel: { false }) { batch, done, total in
                results += batch
                progress.append((done, total))
            }) { error in
                XCTAssertEqual(error as? LLMError, .decodeFailed(code))
            }
            XCTAssertEqual(fake.prompts.count, 1)
            XCTAssertEqual(fake.failures, 1, "失敗した後、1 行ずつの訳し直しで頼み直さない")
            // 1 つ目のまとまり (2・3 行目) の訳だけが渡る。訳はどれも空でない (訳せなかった印として渡さない)
            XCTAssertEqual(results.map(\.head), [segments[1].id, segments[2].id])
            XCTAssertEqual(results.map(\.text), ["訳:\(segments[1].text)", "訳:\(segments[2].text)"])
            XCTAssertFalse(results.contains { $0.head == segments[0].id }, "もとから訳の在る行は、結果を作らない")
            XCTAssertFalse(fake.prompts.contains { $0.user.contains("[1] \(segments[0].text)") })
            XCTAssertEqual(progress.last.map { [$0.0, $0.1] }, [2, 4])
        }
    }
}
