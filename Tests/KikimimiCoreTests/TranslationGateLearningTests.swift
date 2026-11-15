import Foundation
import XCTest
@testable import KikimimiCore

/// 自己改善の小さな輪 (U6): 関門が利用者の判定から学ぶ・たまった直しを評価の問題にする・評価に記憶を渡す
final class TranslationGateLearningTests: XCTestCase {
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

    private func run(_ segments: [TranscriptSegment], _ generator: FakeGenerator, target: String = "fr",
                     memory: TranslationMemoryLookup?) throws -> (TranslationRunSummary, [TranslationResult]) {
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: target, memory: memory,
                                                          generator: generator,
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        return (summary, all)
    }

    private func suppressing(_ checks: Set<String>, target: String = "fr") -> TranslationMemoryLookup {
        TranslationMemoryLookup(target: target, sentences: [], suppressedChecks: checks)
    }

    // MARK: 数の足し引き

    func testCountGateAddsSubtractsAndNeverGoesBelowZero() {
        var m = TranslationMemory()
        XCTAssertTrue(m.countGate(flags: ["number", "short"], target: "FR", confirmed: 1))
        XCTAssertEqual(m.gate.count, 2)
        XCTAssertEqual(m.gate.first { $0.check == "number" }?.target, "fr", "訳す先はそろえる")
        m.countGate(flags: ["number"], target: "fr", edited: 1)
        let number = m.gate.first { $0.check == "number" }
        XCTAssertEqual(number?.confirmed, 1)
        XCTAssertEqual(number?.edited, 1)
        // 引く (0 より下げない)
        m.countGate(flags: ["number"], target: "fr", edited: -1)
        m.countGate(flags: ["number"], target: "fr", edited: -1)
        XCTAssertEqual(m.gate.first { $0.check == "number" }?.edited, 0)
        // まだ無い組を引いても、何も足さない
        XCTAssertFalse(m.countGate(flags: ["term"], target: "fr", edited: -1))
        XCTAssertNil(m.gate.first { $0.check == "term" })
        // 重い印・知らない符号は数えない
        XCTAssertFalse(m.countGate(flags: ["script", "failed", "long", "unknown"], target: "fr", confirmed: 1))
        XCTAssertEqual(m.gate.count, 2)
        // 同じ符号が 2 つ在っても 1 回だけ
        m.countGate(flags: ["short", "short"], target: "fr", confirmed: 1)
        XCTAssertEqual(m.gate.first { $0.check == "short" }?.confirmed, 2)
    }

    // MARK: 5 回・8 割の境目

    func testSuppressionNeedsFiveJudgementsAndEightyPercent() {
        func suppressed(_ confirmed: Int, _ edited: Int, check: String = "number") -> Bool {
            TranslationMemory.isSuppressed(GateCount(check: check, target: "fr", confirmed: confirmed, edited: edited))
        }
        XCTAssertEqual(TranslationMemory.gateMinimumJudgements, 5)
        XCTAssertEqual(TranslationMemory.gateFalseAlarmRatio, 0.8)
        XCTAssertFalse(suppressed(4, 0), "4 回では決めない")
        XCTAssertTrue(suppressed(5, 0))
        XCTAssertTrue(suppressed(4, 1), "5 回のうち 4 回 (8 割)")
        XCTAssertFalse(suppressed(3, 2), "6 割")
        XCTAssertTrue(suppressed(8, 2))
        XCTAssertFalse(suppressed(7, 3))
        XCTAssertFalse(suppressed(0, 0))
    }

    func testSevereChecksAreNeverSuppressed() {
        for check in ["failed", "script", "long"] {
            XCTAssertFalse(TranslationMemory.isSuppressed(GateCount(check: check, target: "fr", confirmed: 20)), check)
        }
        // ファイルに手で書かれた重い印の数も、止める検査にしない
        let m = TranslationMemory(gate: [GateCount(check: "script", target: "fr", confirmed: 20),
                                         GateCount(check: "number", target: "fr", confirmed: 5)])
        XCTAssertEqual(m.suppressedChecks(target: "fr"), ["number"])
        XCTAssertEqual(m.suppressedChecks(target: "de"), [], "訳す先ごと")
        // 写しにも、重い印は入らない
        let lookup = TranslationMemoryLookup(target: "fr", sentences: [], suppressedChecks: ["script", "number"])
        XCTAssertEqual(lookup.suppressedChecks, ["number"])
        // 外す時も、重い印は残す
        let finding = TranslationGate.Finding(flags: ["script", "number"], detail: "number: 15")
        XCTAssertEqual(finding.removing(["script", "number"]).flags, ["script"])
    }

    func testResetGateAndSuppressedList() {
        var m = TranslationMemory()
        for _ in 0..<5 { m.countGate(flags: ["short", "number"], target: "th", confirmed: 1) }
        m.countGate(flags: ["copied"], target: "de", confirmed: 5)
        m.countGate(flags: ["term"], target: "de", confirmed: 2)
        XCTAssertEqual(m.suppressedGate.map { "\($0.target):\($0.check)" }, ["de:copied", "th:number", "th:short"])
        XCTAssertTrue(m.resetGate(check: "number", target: "TH"))
        XCTAssertEqual(m.suppressedChecks(target: "th"), ["short"])
        XCTAssertFalse(m.resetGate(check: "number", target: "th"))
        XCTAssertNil(m.gate.first { $0.check == "number" }, "0 に戻す (1 件を消す)")
    }

    // MARK: 同じ訳に 2 度足さない (覚えの vote)

    /// 1 区間に、印 (数の抜け) の付いた機械の訳を置いた結果
    private func flaggedTranscript() -> (Transcript, UUID) {
        let a = TranscriptSegment(start: 0, end: 2, text: "We sold 4,000 units in 15 days.", translation: "Nous avons vendu beaucoup.")
        var t = Transcript(sourceName: "x", segments: [a], language: "en", duration: 2, translationLanguage: "fr")
        t.translationReview = [TranslationNote(head: a.id,
                                               signature: Transcript.reviewSignature(source: a.text, translation: "Nous avons vendu beaucoup."),
                                               flags: ["number"], detail: "number: 15, 4000", origin: TranslationNote.llm)]
        return (t, a.id)
    }

    func testConfirmSetsTheVoteOnce() throws {
        var (t, a) = flaggedTranscript()
        XCTAssertNil(t.translationNote(for: a)?.vote)
        let confirmed = try XCTUnwrap(t.confirmTranslation(of: a))
        XCTAssertEqual(confirmed.vote, TranslationNote.confirmed)
        // もう「この訳でよい」の覚えは印つきでないので、2 度目は何もしない
        XCTAssertNil(t.confirmTranslation(of: a))
        // vote は読み書きで残り、無い古い覚えは nil と読む
        let back = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.translationNote(for: a)?.vote, TranslationNote.confirmed)
        let old = try JSONDecoder().decode(TranslationNote.self, from: Data(#"{"head":"\#(a.uuidString)","signature":"x"}"#.utf8))
        XCTAssertNil(old.vote)
        // vote の無い覚えは、書いた JSON にも項目を出さない (前の形のまま)
        let plain = TranslationNote(head: a, signature: "x", origin: TranslationNote.llm)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("vote"))
    }

    func testEditVoteIsSetOnceAndRemovedOnRevert() throws {
        var (t, a) = flaggedTranscript()
        let edited = try XCTUnwrap(t.setUserTranslation("Nous avons vendu 4 000 unités en 15 jours.", for: a))
        XCTAssertEqual(edited.vote, TranslationNote.edited, "印つきの訳を初めて直した")
        XCTAssertEqual(edited.flags, ["number"])
        // 2 度目に直しても、vote はそのまま (呼ぶ側は、前も "edited" なので足さない)
        let again = try XCTUnwrap(t.setUserTranslation("Nous avons vendu 4 000 unités en quinze jours (15).", for: a))
        XCTAssertEqual(again.vote, TranslationNote.edited)
        // 機械の訳に戻す: 捨てた覚えの vote は "edited" (呼ぶ側が引く)、戻った印つきの覚えの vote は nil
        let removed = try XCTUnwrap(t.revertUserTranslation(of: a))
        XCTAssertEqual(removed.vote, TranslationNote.edited)
        let restored = try XCTUnwrap(t.translationNote(for: a))
        XCTAssertTrue(restored.isFlagged)
        XCTAssertNil(restored.vote, "戻した後に、また判定できる")
    }

    func testConfirmThenEditThenRevertDoesNotCountTwice() throws {
        var (t, a) = flaggedTranscript()
        XCTAssertEqual(t.confirmTranslation(of: a)?.vote, TranslationNote.confirmed)
        // 「この訳でよい」の後に直した: 前の覚えは印つき ("llm") でないので、"edited" にしない
        let edited = try XCTUnwrap(t.setUserTranslation("Nous avons vendu 4 000 unités en 15 jours.", for: a))
        XCTAssertEqual(edited.vote, TranslationNote.confirmed)
        let removed = try XCTUnwrap(t.revertUserTranslation(of: a))
        XCTAssertEqual(removed.vote, TranslationNote.confirmed, "呼ぶ側は edited を引かない")
        let restored = try XCTUnwrap(t.translationNote(for: a))
        XCTAssertTrue(restored.isFlagged)
        XCTAssertEqual(restored.vote, TranslationNote.confirmed, "もう数えた訳")
        // もう 1 度「この訳でよい」: vote は前のまま (呼ぶ側は、前の vote が在るので足さない)
        XCTAssertEqual(t.confirmTranslation(of: a)?.vote, TranslationNote.confirmed)
    }

    /// アプリ (AppModel) の数え方を、核の部品だけでなぞる: 足す・引く・2 度足さない
    func testAppStyleCountingFollowsTheVotes() throws {
        var memory = TranslationMemory()
        var (t, a) = flaggedTranscript()
        // 直す (AppModel.setTranslation)
        var before = t.translationNote(for: a)
        let note = try XCTUnwrap(t.setUserTranslation("Nous avons vendu 4 000 unités en 15 jours.", for: a))
        if note.vote == TranslationNote.edited, before?.vote != TranslationNote.edited {
            memory.countGate(flags: note.flags, target: "fr", edited: 1)
        }
        // もう 1 度直す (足さない)
        before = t.translationNote(for: a)
        let note2 = try XCTUnwrap(t.setUserTranslation("Nous avons vendu 4 000 unités en quinze jours.", for: a))
        if note2.vote == TranslationNote.edited, before?.vote != TranslationNote.edited {
            memory.countGate(flags: note2.flags, target: "fr", edited: 1)
        }
        XCTAssertEqual(memory.gate.first?.edited, 1)
        // 機械の訳に戻す (AppModel.revertTranslation): 引く
        let removed = try XCTUnwrap(t.revertUserTranslation(of: a))
        if removed.vote == TranslationNote.edited { memory.countGate(flags: removed.flags, target: "fr", edited: -1) }
        XCTAssertEqual(memory.gate.first?.edited, 0)
        // 戻った印つきの訳に「この訳でよい」(AppModel.confirmTranslation): 足す
        before = t.translationNote(for: a)
        let confirmed = try XCTUnwrap(t.confirmTranslation(of: a))
        if before?.vote == nil, confirmed.vote == TranslationNote.confirmed {
            memory.countGate(flags: confirmed.flags, target: "fr", confirmed: 1)
        }
        XCTAssertEqual(memory.gate.first?.confirmed, 1)
        XCTAssertEqual(memory.gate.first?.edited, 0)
    }

    // MARK: 翻訳で、止めた検査の印を外す

    private let sold = "We sold 4,000 units in 15 days this year, and that is really great news for us."
    private let soldFr = "Nous avons vendu beaucoup de produits cette année, et c'est une très bonne nouvelle pour nous."

    func testSuppressedCheckIsNotKeptButOthersAre() throws {
        // 止めない時: 数の抜けの印が付く
        let (s0, r0) = try run([seg(0, sold)], fake([sold: soldFr]), memory: nil)
        XCTAssertEqual(r0.first?.flags, ["number"])
        XCTAssertEqual(s0.flagged, 1)
        // 数の検査を止めた: 印も説明も残さない
        let (s1, r1) = try run([seg(0, sold)], fake([sold: soldFr]), memory: suppressing(["number"]))
        XCTAssertEqual(r1.first?.flags, [])
        XCTAssertNil(r1.first?.detail)
        XCTAssertEqual(s1.flagged, 0)
        XCTAssertEqual(r1.first?.text, soldFr, "訳は同じ")
        // ほかの検査を止めても、数の抜けの印は残る
        let (_, r2) = try run([seg(0, sold)], fake([sold: soldFr]), memory: suppressing(["term", "short"]))
        XCTAssertEqual(r2.first?.flags, ["number"])
        XCTAssertEqual(r2.first?.detail, "number: 15, 4000")
        // 訳す先の違う写しは使わない
        let (_, r3) = try run([seg(0, sold)], fake([sold: soldFr]), memory: suppressing(["number"], target: "de"))
        XCTAssertEqual(r3.first?.flags, ["number"])
    }

    func testRemovingKeepsOtherDetailParts() {
        let f = TranslationGate.Finding(flags: ["number", "term"], detail: "number: 15; term: Roblox")
        XCTAssertEqual(f.removing(["number"]), TranslationGate.Finding(flags: ["term"], detail: "term: Roblox"))
        XCTAssertEqual(f.removing(["term", "number"]), TranslationGate.Finding(flags: [], detail: nil))
        XCTAssertEqual(f.removing([]), f)
        XCTAssertEqual(f.removing(["short"]), f)
    }

    // 文が 4 つの原文 (U4 の試験と同じ物)
    private let welcome = "Welcome. Welcome, everyone. I'm just going to make sure that all of this is working. "
        + "It just takes a minute."
    private let piece1 = "Welcome. Welcome, everyone."
    private let piece2 = "I'm just going to make sure that all of this is working."
    private let piece3 = "It just takes a minute."
    private let fr1 = "Bienvenue. Bienvenue à tous."
    private let fr2 = "Je vais juste vérifier que tout cela fonctionne correctement."
    private let fr3 = "Cela ne prend qu'une minute."

    func testShortSuppressedStillTriggersTheSplitRetry() throws {
        let g = fake([welcome: "Bienvenue.", piece1: fr1, piece2: fr2, piece3: fr3])
        let (summary, results) = try run([seg(0, welcome)], g, memory: suppressing(["short"]))
        XCTAssertEqual(summary.retried, 1, "訳し直しの引き金は、止める前の判定")
        XCTAssertEqual(summary.retryFixed, 1)
        XCTAssertEqual(results.first?.text, "\(fr1) \(fr2) \(fr3)")
        // 訳し直しが失敗して初めの訳が残っても、止めた short の印は残さない
        let g2 = fake([welcome: "Bienvenue.", piece1: fr1, piece3: fr3])
        let (summary2, results2) = try run([seg(0, welcome)], g2, memory: suppressing(["short"]))
        XCTAssertEqual(summary2.retried, 1)
        XCTAssertEqual(summary2.retryFixed, 0)
        XCTAssertEqual(results2.first?.text, "Bienvenue.")
        XCTAssertFalse(results2.first?.flags.contains("short") ?? true)
        XCTAssertEqual(summary2.flagged, 0)
    }

    // MARK: 記憶の入・切と、写しの作り方

    func testSuppressionWorksWhenReuseIsOff() {
        var m = TranslationMemory()
        XCTAssertNil(m.lookup(target: "fr", reuse: false), "止める検査も無ければ nil (前と同じ)")
        XCTAssertNil(m.lookup(target: "fr", reuse: true))
        m.remember(source: sold, sourceLanguage: "en", target: "fr", translation: "Nous avons vendu 4 000 unités.",
                   machine: nil, model: nil)
        m.setTerm(source: "units", translation: "unités", target: "fr")
        XCTAssertNil(m.lookup(target: "fr", reuse: false), "切の時は、文も対も渡さない (前と同じ)")
        for _ in 0..<5 { m.countGate(flags: ["number"], target: "fr", confirmed: 1) }
        let off = m.lookup(target: "fr", reuse: false)
        XCTAssertEqual(off?.suppressedChecks, ["number"])
        XCTAssertEqual(off?.isEmpty, true, "切の時は、覚えた文を渡さない")
        XCTAssertEqual(off?.terms.isEmpty, true, "切の時は、訳語の対を渡さない")
        let on = m.lookup(target: "fr", reuse: true)
        XCTAssertEqual(on?.suppressedChecks, ["number"])
        XCTAssertEqual(on?.count, 1)
        XCTAssertEqual(on?.terms.count, 1)
        // 文も対も無く、止める検査だけが在る時も nil にしない
        let only = TranslationMemory(gate: [GateCount(check: "short", target: "th", confirmed: 5)])
        XCTAssertEqual(only.lookup(target: "th", reuse: true)?.suppressedChecks, ["short"])
        XCTAssertNil(only.lookup(target: "fr", reuse: true))
    }

    // MARK: 古いファイル

    func testOldFileWithoutGateAndBrokenEntries() throws {
        let old = #"{"version":1,"sentences":[],"terms":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(TranslationMemory.self, from: Data(old.utf8)).gate, [])
        let broken = """
        {"version":1,"gate":[{"check":"number","target":"FR","confirmed":5,"edited":-2},{"target":"fr"},{"check":"","target":"fr"},
         {"check":"short","target":"fr","confirmed":"x"},42]}
        """
        let m = try JSONDecoder().decode(TranslationMemory.self, from: Data(broken.utf8))
        XCTAssertEqual(m.gate.map(\.check), ["number", "short"], "壊れた 1 件だけを飛ばす")
        XCTAssertEqual(m.gate.first?.target, "fr")
        XCTAssertEqual(m.gate.first?.edited, 0, "負の数は 0 と読む")
        XCTAssertEqual(m.gate.last?.confirmed, 0, "読めない数は 0 と読む")
        // 書いて読み戻せる
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kikimimi-gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try m.save(to: url)
        XCTAssertEqual(TranslationMemory.load(from: url).gate.map(\.check), ["number", "short"])
    }

    // MARK: 取り分けた直しを、評価の問題にする

    /// 取り分ける (heldOut) 原文と、取り分けない原文を n 個ずつ作る
    private func sources(heldOut: Bool, count: Int) -> [String] {
        var out: [String] = []
        var i = 0
        while out.count < count {
            let s = "This is sentence number \(i) that the user corrected by hand."
            if TranslationMemory.isHeldOut(TranslationMemory.normalizedSource(s)) == heldOut { out.append(s) }
            i += 1
        }
        return out
    }

    func testEvaluationCasesUseOnlyHeldOutCorrections() {
        var m = TranslationMemory()
        XCTAssertEqual(m.evaluationCases(detector: nil), [], "0 件")
        let held = sources(heldOut: true, count: 3)
        let kept = sources(heldOut: false, count: 4)
        for (k, s) in held.enumerated() {
            m.remember(source: s, sourceLanguage: k == 2 ? nil : "en", target: k == 0 ? "de" : "ja",
                       translation: "訳 \(k)", machine: "機械 \(k)", model: nil)
        }
        for s in kept { m.remember(source: s, sourceLanguage: "en", target: "ja", translation: "残す訳", machine: nil, model: nil) }
        let cases = m.evaluationCases(detector: { _ in "en" })
        XCTAssertEqual(cases.count, 3, "取り分けた直しだけ")
        XCTAssertEqual(cases.map(\.targetLanguage), ["de", "ja", "ja"], "訳す先の順")
        for c in cases {
            XCTAssertEqual(c.lines.count, 1, "1 件 = 1 場面")
            XCTAssertEqual(c.references?.count, 1)
            XCTAssertTrue(held.contains(c.lines[0]))
            XCTAssertEqual(c.language, "en")
            XCTAssertTrue(c.id.hasPrefix("memory-\(c.targetLanguage)-"))
            let entry = m.sentences.first { $0.source == c.lines[0] }
            XCTAssertEqual(c.references?.first, entry?.translation)
            XCTAssertEqual(c.id, "memory-\(c.targetLanguage)-" + String(entry?.id.uuidString.lowercased().prefix(8) ?? ""),
                           "id は記憶の id から決まる")
        }
        XCTAssertEqual(m.evaluationCases(detector: nil).first { $0.lines[0] == held[2] }?.language, "en",
                       "原文の言語が分からなければ en")
        XCTAssertEqual(m.evaluationCases(detector: { _ in "fr" }).first { $0.lines[0] == held[2] }?.language, "fr")
        // 問題のファイルとして読み戻せる
        let set = LLMEvalSet(name: "m", translation: cases)
        let back = try? JSONDecoder().decode(LLMEvalSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(back?.translation, cases)
    }

    // MARK: 評価に記憶を渡す (--memory)

    func testEvalWithMemoryLeavesOutTheCaseSentenceAndCountsReuse() throws {
        let line = "So the first thing I want to talk about today is the system."
        var m = TranslationMemory()
        m.remember(source: line, sourceLanguage: "en", target: "fr", translation: "Le bon answer.", machine: nil, model: nil)
        // 問題の行と同じ文は抜く: LLM に送り、記憶の訳 (答え) は置かない
        let c = TranslationEvalCase(id: "a", language: "en", lines: [line], target: "fr",
                                    references: ["Le bon answer."])
        let g = fake([line: "La première chose dont je veux parler aujourd'hui, c'est le système."])
        let result = try LLMEval.runTranslation([c], generator: g, memory: m, detector: { _ in "fr" })
        XCTAssertEqual(g.prompts.count, 1)
        XCTAssertEqual(result.score.reused, 0)
        XCTAssertEqual(result.outputs.first?.reused, 0)
        XCTAssertEqual(result.outputs.first?.units.first?.text, "La première chose dont je veux parler aujourd'hui, c'est le système.")

        // 2 行で 1 文のまとまり: どの行も記憶の文と同じでないので、まとまりは記憶に当たる (2 行)
        let parts = ["So the first thing I want to talk about", "today is the system."]
        var m2 = TranslationMemory()
        m2.remember(source: Transcript.join(parts), sourceLanguage: "en", target: "fr", translation: "Le système.",
                    machine: nil, model: nil)
        let c2 = TranslationEvalCase(id: "b", language: "en", lines: parts, target: "fr")
        let g2 = fake([:])
        let r2 = try LLMEval.runTranslation([c2], generator: g2, memory: m2, detector: { _ in "fr" })
        XCTAssertEqual(g2.prompts.count, 0)
        XCTAssertEqual(r2.score.reused, 2)
        XCTAssertEqual(r2.byTarget["fr"]?.reused, 2)
        XCTAssertTrue(r2.score.summary.contains("from memory 2 lines"))
        // 採点し直しても残る
        XCTAssertEqual(LLMEval.rescore(r2.outputs, detector: { _ in "fr" }).score.reused, 2)

        // --memory が無い時は、前と同じ (reused は残さない)
        let r3 = try LLMEval.runTranslation([c2], generator: fake([:]), detector: { _ in "fr" })
        XCTAssertNil(r3.outputs.first?.reused)
        XCTAssertEqual(r3.score.reused, 0)
        XCTAssertFalse(r3.score.summary.contains("from memory"))
    }

    func testEvalLookupMergesTermsPreferringTheCase() throws {
        var m = TranslationMemory()
        m.setTerm(source: "dashboard", translation: "tableau", target: "fr")
        m.setTerm(source: "stream", translation: "live", target: "fr")
        m.setTerm(source: "stream", translation: "配信", target: "ja")
        for _ in 0..<5 { m.countGate(flags: ["copied"], target: "fr", confirmed: 1) }
        let c = TranslationEvalCase(id: "t", language: "en", lines: ["x"], target: "fr",
                                    terms: [TranslationEvalTerm(source: "Dashboard", translation: "panneau")])
        let lookup = try XCTUnwrap(LLMEval.caseLookup(c, memory: m, useTerms: true))
        XCTAssertEqual(Set(lookup.terms.map { "\($0.source)=\($0.translation)" }), ["Dashboard=panneau", "stream=live"],
                       "同じ原語は問題の対")
        XCTAssertEqual(lookup.suppressedChecks, ["copied"])
        // --no-terms: 問題の対は渡さず、記憶の対だけ
        let noTerms = try XCTUnwrap(LLMEval.caseLookup(c, memory: m, useTerms: false))
        XCTAssertEqual(Set(noTerms.terms.map(\.translation)), ["tableau", "live"])
        // 記憶が無ければ、前と同じ (問題の対だけ)
        let plain = try XCTUnwrap(LLMEval.caseLookup(c, memory: nil, useTerms: true))
        XCTAssertEqual(plain.terms.map(\.translation), ["panneau"])
        XCTAssertTrue(plain.isEmpty)
        XCTAssertTrue(plain.suppressedChecks.isEmpty)
        XCTAssertNil(LLMEval.caseLookup(c, memory: nil, useTerms: false))
    }

    func testOldResultsWithoutReusedDecode() throws {
        let score = try JSONDecoder().decode(TranslationEvalScore.self, from: Data(#"{"cases":1,"lines":2,"translated":2}"#.utf8))
        XCTAssertEqual(score.reused, 0)
        let report = try JSONDecoder().decode(LLMEvalReport.self, from: Data("""
        {"model":"m","audit":{"cases":0,"errorLines":0,"fixedAutomatically":0,"fixedBySuggestion":0,"wrongFixes":0,"missed":0,
         "cleanLines":0,"harmed":0,"falseSuggestions":0,"seconds":0},
         "translation":{"cases":1,"lines":1},"translationOutputs":[{"id":"a","target":"fr","language":"en","lineCount":1,
         "units":[{"lines":[0],"source":"Hi.","text":"Salut."}]}]}
        """.utf8))
        XCTAssertEqual(report.translation.reused, 0)
        XCTAssertNil(report.translationOutputs?.first?.reused)
        XCTAssertEqual(report.rescored(from: "x", detector: { _ in "fr" })?.translation.reused, 0)
    }
}
