import XCTest
@testable import KikimimiCore

/// 数えるだけの箱 (いくつかのスレッドから足す)
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]

    func add(_ key: Int) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    var all: [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

/// 監査・翻訳・評価役の問いに、それらしい形で答える偽の LLM の答え方
private func plausibleAnswer(_ prompt: LLMPrompt) -> String {
    if prompt.grammar == GBNF.choice { return "1" }
    let numbered: [(Int, String)] = prompt.user.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let n = Int(line[line.index(after: line.startIndex)..<close]),
              line.index(close, offsetBy: 2) <= line.endIndex else { return nil }
        return (n, String(line[line.index(close, offsetBy: 2)...]))
    }
    if let grammar = prompt.grammar, grammar.contains("END") {
        // 監査: 「Roblocks」を含む行だけを直す
        let fixes = numbered.filter { $0.1.contains("Roblocks") }.map { "[\($0.0)] FIX Roblocks => Roblox\n" }
        return fixes.joined() + "END\n"
    }
    return numbered.map { "[\($0.0)] tr:\($0.1)" }.joined(separator: "\n") + "\n"
}

private let chatSystem = "chat interrupt"

private func sampleSegments() -> [TranscriptSegment] {
    let texts = [
        "Welcome to today's session about building games in Roblocks Studio.",
        "First, we will open a new place and add a part.",
        "Then we press the play button to test it.",
        "Next, we change the color of the part to red.",
        "After that, we add a script to make it spin.",
        "Roblocks Studio saves the place automatically.",
        "Let's try moving the camera around the scene.",
        "That is all for the first lesson.",
    ]
    return texts.enumerated().map { i, text in
        TranscriptSegment(start: Double(i) * 3, end: Double(i) * 3 + 3, text: text)
    }
}

/// 監査の直しを、比べられる形にする (直しの番号 id は毎回変わるので入れない)
private func describe(_ report: AuditReport) -> [String] {
    report.changes.map { c in
        "\(c.kind.rawValue)|\(c.original.id)|\(c.replacement ?? "-")|\(c.reason)|\(c.isConfident)|\(c.isApplied)"
    }
}

final class LLMInterruptTests: XCTestCase {
    /// 包みは generate のたびに、その手前で 1 度だけ「通す」を呼び、答えは包んだエンジンのまま
    func testYieldRunsBeforeEveryGenerate() throws {
        var events: [String] = []
        let fake = FakeGenerator { prompt in
            events.append("generate")
            return "answer:" + prompt.user
        }
        let wrapped = YieldingGenerator(fake, adapterPath: "/a.gguf") { events.append("yield") }
        XCTAssertEqual(wrapped.adapterPath, "/a.gguf")
        XCTAssertEqual(wrapped.contextLength, fake.contextLength)
        XCTAssertEqual(wrapped.tokenCount("abcdef"), fake.tokenCount("abcdef"))
        XCTAssertTrue(events.isEmpty, "tokenCount and contextLength do not yield")

        let first = try wrapped.generate(LLMPrompt(system: "s", user: "one"), shouldCancel: { false })
        var streamed: [String] = []
        let second = try wrapped.generate(LLMPrompt(system: "s", user: "two"), shouldCancel: { false },
                                          onText: { streamed.append($0) })
        XCTAssertEqual(first, "answer:one")
        XCTAssertEqual(second, "answer:two")
        XCTAssertEqual(streamed, ["answer:two"])
        XCTAssertEqual(events, ["yield", "generate", "yield", "generate"])
        XCTAssertEqual(fake.prompts.map(\.user), ["one", "two"])
    }

    /// 取り出すのは、今のエンジンに合う依頼 (モデルが同じで、差分を重ねていない) だけ。合わない依頼は残る
    func testOnlyMatchingRequestsAreTaken() {
        let queue = LLMInterruptQueue<String>()
        var ran: [String] = []
        for (name, path) in [("first", "/a.gguf"), ("other model", "/b.gguf"), ("second", "/a.gguf")] {
            queue.add(modelPath: path, body: { engine in "\(name)@\(engine)" }, completion: { result in
                if case .success(let text) = result { ran.append(text) }
            })
        }
        XCTAssertEqual(queue.waitingCount, 3)
        // 差分を重ねたエンジンでは、どれも通さない
        XCTAssertEqual(queue.runWaiting(modelPath: "/a.gguf", adapterLoaded: true, engine: "lora"), 0)
        XCTAssertEqual(queue.waitingCount, 3)
        XCTAssertTrue(ran.isEmpty)
        // 差分なしの同じモデル: 合う 2 つを、入れた順に通す
        XCTAssertEqual(queue.runWaiting(modelPath: "/a.gguf", adapterLoaded: false, engine: "A"), 2)
        XCTAssertEqual(ran, ["first@A", "second@A"])
        XCTAssertEqual(queue.waitingCount, 1)
        XCTAssertEqual(queue.yielded, 2)
        // 残った依頼は、キューの順番で取り出せる
        XCTAssertNotNil(queue.takeFirst(matching: "/b.gguf", adapterLoaded: false))
        XCTAssertEqual(queue.waitingCount, 0)
    }

    /// 依頼は 1 度だけ走る: 継ぎ目が取れば、キューの側は取れない。キューの側が取れば、継ぎ目は取れない
    func testRequestIsTakenOnce() {
        let queue = LLMInterruptQueue<Int>()
        var calls = 0
        let a = queue.add(modelPath: "/m", body: { $0 * 2 }, completion: { _ in calls += 1 })
        XCTAssertEqual(queue.runWaiting(modelPath: "/m", adapterLoaded: false, engine: 1), 1)
        XCTAssertNil(queue.take(id: a))
        XCTAssertEqual(calls, 1)

        let b = queue.add(modelPath: "/m", body: { $0 * 2 }, completion: { _ in calls += 1 })
        let taken = queue.take(id: b)
        XCTAssertNotNil(taken)
        XCTAssertEqual(queue.runWaiting(modelPath: "/m", adapterLoaded: false, engine: 1), 0)
        taken?.run(3)
        XCTAssertEqual(calls, 2)
    }

    /// 継ぎ目とキューの側が、いくつものスレッドから同時に取りに来ても、どの依頼もちょうど 1 度だけ走る
    func testRequestsRunExactlyOnceUnderRace() {
        let queue = LLMInterruptQueue<Int>()
        let tally = Tally()
        let count = 400
        var ids: [Int] = []
        for i in 0..<count {
            ids.append(queue.add(modelPath: "/m", body: { _ in i }, completion: { result in
                if case .success(let n) = result { tally.add(n) }
            }))
        }
        let idList = ids
        DispatchQueue.concurrentPerform(iterations: count) { i in
            if i % 2 == 0 {
                queue.take(id: idList[i])?.run(0)
            } else {
                queue.runWaiting(modelPath: "/m", adapterLoaded: false, engine: 0)
            }
        }
        let counts = tally.all
        XCTAssertEqual(counts.count, count)
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 }, "\(counts.filter { $0.value != 1 })")
        XCTAssertEqual(queue.waitingCount, 0)
    }

    /// 割り込みの body のエラー (中止を含む) は、割り込みの依頼の側にだけ返り、監査の流れには漏れない
    func testInterruptErrorDoesNotLeak() throws {
        let fake = FakeGenerator(plausibleAnswer)
        let queue = LLMInterruptQueue<FakeGenerator>()
        var outcomes: [String] = []
        queue.add(modelPath: "/m", body: { engine -> String in
            _ = try engine.generate(LLMPrompt(system: chatSystem, user: "hi"), shouldCancel: { true })
            return "not reached"
        }, completion: { result in
            if case .failure(let error) = result { outcomes.append("failed:\(error)") }
        })
        queue.add(modelPath: "/m", body: { _ -> String in throw LLMError.promptTooLong(tokens: 9, limit: 1) },
                  completion: { result in
            if case .failure = result { outcomes.append("failed:other") }
        })
        let wrapped = YieldingGenerator(fake) { queue.runWaiting(modelPath: "/m", adapterLoaded: false, engine: fake) }
        let report = try Auditor.audit(sampleSegments(), language: "en", generator: wrapped, modelName: "fake",
                                       shouldCancel: { false })
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.first, "failed:\(LLMError.cancelled)")
        XCTAssertFalse(report.changes.isEmpty)
        XCTAssertEqual(queue.waitingCount, 0)
    }

    /// 偽のエンジンで、監査と翻訳の結果と、監査・翻訳が出した依頼の列が、割り込みあり・なしで同じ
    func testAuditAndTranslationAreTheSameWithInterrupts() throws {
        let segments = sampleSegments()
        let auditOptions = AuditOptions(glossary: "Roblox Studio", maxLinesPerChunk: 3)
        let translateOptions = TranslationOptions(maxLinesPerChunk: 3)

        func runAll(_ generator: any TextGenerating) throws -> ([String], [UUID: String]) {
            let report = try Auditor.audit(segments, language: "en", options: auditOptions, generator: generator,
                                           modelName: "fake", shouldCancel: { false })
            var translations: [UUID: String] = [:]
            _ = try Translator.translate(segments, language: "en", options: translateOptions, generator: generator,
                                         shouldCancel: { false }) { batch, _, _ in
                for r in batch { translations[r.head] = r.text }
            }
            return (describe(report), translations)
        }

        // 割り込みなし
        let plain = FakeGenerator(plausibleAnswer)
        let (auditA, translateA) = try runAll(plain)
        XCTAssertGreaterThan(plain.prompts.count, 4, "several chunks")

        // generate のたびに、割り込み (同じエンジンで、別の依頼) を 1 つ積んで通す
        let shared = FakeGenerator(plausibleAnswer)
        let queue = LLMInterruptQueue<FakeGenerator>()
        var answered = 0
        let wrapped = YieldingGenerator(shared) {
            queue.add(modelPath: "/m", body: { engine in
                try engine.generate(LLMPrompt(system: chatSystem, user: "[1] chat"), shouldCancel: { false })
            }, completion: { result in
                if case .success = result { answered += 1 }
            })
            queue.runWaiting(modelPath: "/m", adapterLoaded: false, engine: shared)
        }
        let (auditB, translateB) = try runAll(wrapped)
        let ownPrompts = shared.prompts.filter { $0.system != chatSystem }

        XCTAssertEqual(auditA, auditB)
        XCTAssertEqual(translateA, translateB)
        XCTAssertFalse(auditA.isEmpty)
        XCTAssertEqual(translateA.count, segments.count)
        XCTAssertEqual(ownPrompts.map(\.system), plain.prompts.map(\.system))
        XCTAssertEqual(ownPrompts.map(\.user), plain.prompts.map(\.user))
        XCTAssertEqual(ownPrompts.map(\.grammar), plain.prompts.map(\.grammar))
        XCTAssertEqual(answered, plain.prompts.count, "one interrupt answered before each generate")
        XCTAssertEqual(queue.yielded, plain.prompts.count)
    }
}
