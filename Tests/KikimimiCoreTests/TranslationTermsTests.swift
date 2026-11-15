import Foundation
import XCTest
@testable import KikimimiCore

/// 訳語の対 (U5): 記憶の読み書き・原文に出る対の選び方・指示文・用語集との食い違い・関門の印・評価
final class TranslationTermsTests: XCTestCase {
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

    private func pair(_ source: String, _ translation: String, _ target: String = "ja") -> TermPair {
        TermPair(source: source, translation: translation, target: target)
    }

    private func run(_ segments: [TranscriptSegment], _ generator: FakeGenerator, target: String,
                     memory: TranslationMemoryLookup?, options: TranslationOptions = TranslationOptions()) throws
        -> (TranslationRunSummary, [TranslationResult]) {
        var all: [TranslationResult] = []
        let summary = try Translator.translateSummarizing(segments, language: "en", target: target, options: options,
                                                          memory: memory, generator: generator,
                                                          shouldCancel: { false }) { batch, _, _ in all += batch }
        return (summary, all)
    }

    // MARK: 記憶のファイル

    func testTermsRoundTripAndReplaceTheSameSourceAndTarget() throws {
        var memory = TranslationMemory()
        XCTAssertNotNil(memory.setTerm(source: " dashboard ", translation: "管理画面", target: "JA"))
        XCTAssertNotNil(memory.setTerm(source: "Dashboard", translation: "管理ページ", target: "ja"))
        XCTAssertNotNil(memory.setTerm(source: "dashboard", translation: "tableau de bord", target: "fr"))
        XCTAssertNil(memory.setTerm(source: "  ", translation: "x", target: "ja"))
        XCTAssertNil(memory.setTerm(source: "x", translation: "", target: "ja"))
        XCTAssertEqual(memory.terms.count, 2)
        XCTAssertEqual(memory.termList(target: "ja").map(\.translation), ["管理ページ"])
        XCTAssertEqual(memory.termList(target: "ja").first?.source, "Dashboard")
        XCTAssertEqual(memory.termList().map(\.target), ["fr", "ja"])
        XCTAssertTrue(memory.isEmpty)
        XCTAssertFalse(memory.hasNothing)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terms-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try memory.save(to: url)
        let loaded = TranslationMemory.load(from: url)
        // 日時は秒までで保存されるので、日時のほかを比べる
        XCTAssertEqual(loaded.terms.map { [$0.id.uuidString, $0.source, $0.translation, $0.target] },
                       memory.terms.map { [$0.id.uuidString, $0.source, $0.translation, $0.target] })

        let id = try XCTUnwrap(loaded.termList(target: "fr").first?.id)
        var changed = loaded
        changed.removeTerm(id)
        XCTAssertEqual(changed.terms.map(\.target), ["ja"])
    }

    func testOldFileWithoutTermsAndABrokenTermAreRead() throws {
        let old = #"{"version": 1, "sentences": [{"source": "Hello there, how are you today?", "target": "ja", "translation": "こんにちは"}]}"#
        let a = try JSONDecoder().decode(TranslationMemory.self, from: Data(old.utf8))
        XCTAssertEqual(a.sentences.count, 1)
        XCTAssertTrue(a.terms.isEmpty)

        let mixed = #"{"version": 1, "sentences": [], "terms": [{"source": "dashboard", "translation": "管理画面", "target": "ja"}, {"source": 3}, {"source": "", "translation": "x", "target": "ja"}, {"source": "ship", "translation": "上线", "target": "ZH"}]}"#
        let b = try JSONDecoder().decode(TranslationMemory.self, from: Data(mixed.utf8))
        XCTAssertEqual(b.terms.map(\.source), ["dashboard", "ship"])
        XCTAssertEqual(b.terms.last?.target, "zh")
    }

    // MARK: 原文に出る対

    func testWordBoundaryForLatinAndCyrillic() {
        XCTAssertTrue(TermPair.occurs("car", in: "My CAR is red."))
        XCTAssertFalse(TermPair.occurs("car", in: "My career is long."))
        XCTAssertFalse(TermPair.occurs("car", in: "A scar."))
        XCTAssertTrue(TermPair.occurs("car", in: "career, car."))
        XCTAssertTrue(TermPair.occurs("log file", in: "Send the Log File now."))
        XCTAssertTrue(TermPair.occurs("кот", in: "Это Кот."))
        XCTAssertFalse(TermPair.occurs("кот", in: "Это котик."))
    }

    func testUnspacedScriptsMatchByContaining() {
        XCTAssertTrue(TermPair.occurs("管理画面", in: "この管理画面を開きます。"))
        XCTAssertTrue(TermPair.occurs("料金プラン", in: "新しい料金プランを説明します。"))
        XCTAssertTrue(TermPair.occurs("화면", in: "관리화면을 엽니다."))
        XCTAssertTrue(TermPair.occurs("โฟลเดอร์", in: "ใส่ในโฟลเดอร์ส่วนกลาง"))
    }

    func testMatchingIsLongestFirstAndAtMostEight() {
        let pairs = (1...10).map { pair("word\($0)", "w\($0)") } + [pair("sales team", "営業"), pair("team", "チーム")]
        let text = (1...10).map { "word\($0)" }.joined(separator: " ") + " sales team"
        let matched = TermPair.matching(pairs, in: text)
        XCTAssertEqual(matched.count, TermPair.maxPerPrompt)
        XCTAssertEqual(TermPair.maxPerPrompt, 8)
        XCTAssertEqual(matched.first?.source, "sales team")
        XCTAssertEqual(TermPair.matching([pair("Team", "a"), pair("team", "b")], in: "the team").map(\.translation), ["a"])
        XCTAssertTrue(TermPair.matching(pairs, in: "nothing here").isEmpty)
    }

    func testLookupHoldsOnlyTheTargetsTermsAndFollowsTheSwitch() {
        var memory = TranslationMemory()
        memory.setTerm(source: "dashboard", translation: "管理画面", target: "ja")
        memory.setTerm(source: "dashboard", translation: "tableau de bord", target: "fr")
        XCTAssertNil(memory.lookup(target: "ja", reuse: false))
        let ja = memory.lookup(target: "ja", reuse: true)
        XCTAssertEqual(ja?.terms.map(\.translation), ["管理画面"])
        XCTAssertEqual(ja?.isEmpty, true)
        XCTAssertNil(memory.lookup(target: "de", reuse: true))
        XCTAssertNil(TranslationMemory().lookup(target: "ja", reuse: true))
        XCTAssertEqual(ja?.terms(in: "Open the Dashboard.").count, 1)
    }

    // MARK: 指示文

    func testPromptWithoutTermsIsUnchanged() {
        let context = [(source: "Hi.", translation: "やあ。")]
        let old = "Glossary (keep exactly as written): Roblox, Studio\n\n"
            + "Previous lines, already translated (context only, do not output):\nHi. => やあ。\n\n"
            + "Lines to translate:\n[1] Open the dashboard."
        XCTAssertEqual(Translator.userPrompt(lines: ["Open the dashboard."], context: context, glossary: "Roblox, Studio"), old)
        XCTAssertEqual(Translator.userPrompt(lines: ["Open the dashboard."], context: context, glossary: "Roblox, Studio",
                                             terms: []), old)
    }

    func testPromptWithTerms() {
        let text = Translator.userPrompt(lines: ["Open the dashboard."], context: [], glossary: nil,
                                         terms: [pair("dashboard", "管理画面")])
        XCTAssertEqual(text, "Terms (always translate the left as the right):\ndashboard => 管理画面\n\n"
            + "Lines to translate:\n[1] Open the dashboard.")
    }

    func testGlossaryDropsAWordThatATermTranslates() {
        let terms = [pair("Dashboard", "管理画面")]
        XCTAssertEqual(Translator.glossaryText("Roblox, dashboard, Studio", without: terms), "Roblox, Studio")
        XCTAssertEqual(Translator.glossaryText("Roblox、 Studio", without: terms), "Roblox、 Studio")
        XCTAssertNil(Translator.glossaryText("dashboard", without: terms))
        XCTAssertEqual(Translator.glossaryText(" Roblox ", without: []), "Roblox")
        let text = Translator.userPrompt(lines: ["x"], context: [], glossary: "dashboard", terms: terms)
        XCTAssertFalse(text.contains("Glossary"))
    }

    func testOnlyTermsInTheSentLinesGoIntoThePromptAndNoExtraCalls() throws {
        let segments = [seg(0, "Please open the dashboard now."), seg(10, "The car is parked over there.")]
        let answers = ["Please open the dashboard now.": "今すぐダッシュボードを開いてください。",
                       "The car is parked over there.": "車はあそこに止めてあります。"]
        let lookup = TranslationMemoryLookup(target: "ja", sentences: [],
                                             terms: [pair("dashboard", "管理画面"), pair("career", "経歴")])
        // 1 行ずつ送る (どの行に出る対かを見るため)
        let options = TranslationOptions(maxLinesPerChunk: 1)
        let g = fake(answers)
        let (summary, results) = try run(segments, g, target: "ja", memory: lookup, options: options)
        XCTAssertEqual(g.prompts.count, 2)
        XCTAssertTrue(g.prompts[0].user.contains("Terms (always translate the left as the right):\ndashboard => 管理画面\n"))
        XCTAssertFalse(g.prompts[0].user.contains("career"))
        XCTAssertFalse(g.prompts[1].user.contains("Terms"))
        // 訳に訳語が無いので、印だけ (訳はそのまま。訳し直さない)
        XCTAssertEqual(results[0].text, "今すぐダッシュボードを開いてください。")
        XCTAssertEqual(results[0].flags, ["term"])
        XCTAssertEqual(results[0].detail, "term: dashboard → 管理画面")
        XCTAssertTrue(results[1].flags.isEmpty)
        XCTAssertEqual(summary.flagged, 1)
        XCTAssertEqual(summary.retried, 0)
    }

    func testTermsThatDoNotOccurLeaveThePromptsExactlyAsBefore() throws {
        let segments = [seg(0, "Please open the settings now."), seg(10, "The car is parked over there.")]
        let answers = ["Please open the settings now.": "今すぐ設定を開いてください。",
                       "The car is parked over there.": "車はあそこに止めてあります。"]
        let before = fake(answers)
        let (_, a) = try run(segments, before, target: "ja", memory: nil,
                             options: TranslationOptions(glossary: "Roblox, dashboard"))
        let after = fake(answers)
        let lookup = TranslationMemoryLookup(target: "ja", sentences: [], terms: [pair("dashboard", "管理画面")])
        let (_, b) = try run(segments, after, target: "ja", memory: lookup,
                             options: TranslationOptions(glossary: "Roblox, dashboard"))
        XCTAssertEqual(before.prompts.map(\.user), after.prompts.map(\.user))
        XCTAssertEqual(before.prompts.map(\.maxTokens), after.prompts.map(\.maxTokens))
        XCTAssertEqual(a, b)
    }

    func testKeptTermGivesNoFlagAndATermForAnotherTargetIsNotUsed() throws {
        let segments = [seg(0, "Please open the dashboard now.")]
        let g = fake(["Please open the dashboard now.": "今すぐ管理画面を開いてください。"])
        let lookup = TranslationMemoryLookup(target: "ja", sentences: [], terms: [pair("dashboard", "管理画面")])
        let (_, results) = try run(segments, g, target: "ja", memory: lookup)
        XCTAssertTrue(results[0].flags.isEmpty)

        // 写しの訳す先が違う時は、対を使わない
        let other = fake(["Please open the dashboard now.": "Ouvrez le tableau maintenant, s'il vous plaît."])
        let (_, r2) = try run(segments, other, target: "fr", memory: lookup)
        XCTAssertFalse(other.prompts[0].user.contains("Terms"))
        XCTAssertTrue(r2[0].flags.isEmpty)
    }

    func testSplitRetryPiecesGetTheirTerms() throws {
        let source = "Welcome, everyone, to the class. Please open the dashboard on your screen now. It just takes a minute."
        let pieces = Translator.sentencePieces(source, language: "en")
        XCTAssertEqual(pieces.count, 3)
        let answers = [source: "Bienvenue.",
                       pieces[0]: "Bienvenue à tous, dans ce cours.",
                       pieces[1]: "Ouvrez le panneau de contrôle sur votre écran maintenant.",
                       pieces[2]: "Cela ne prend qu'une minute."]
        let g = fake(answers)
        let lookup = TranslationMemoryLookup(target: "fr", sentences: [],
                                             terms: [pair("dashboard", "panneau de contrôle", "fr")])
        let (summary, results) = try run([seg(0, source)], g, target: "fr", memory: lookup)
        XCTAssertEqual(summary.retried, 1)
        XCTAssertEqual(summary.retryFixed, 1)
        XCTAssertEqual(g.prompts.count, 2)
        XCTAssertTrue(g.prompts[0].user.contains("dashboard => panneau de contrôle"))
        XCTAssertTrue(g.prompts[1].user.contains("dashboard => panneau de contrôle"))
        XCTAssertTrue(results[0].flags.isEmpty, results[0].flags.description)
    }

    // MARK: 関門

    func testGateFlagsAMissingTermWithTheReason() {
        let f = TranslationGate.assess(source: "Open the dashboard.", translation: "ダッシュボードを開きます。",
                                       sourceLanguage: "en", target: "ja",
                                       terms: [(source: "dashboard", translation: "管理画面")], detector: nil)
        XCTAssertEqual(f.flags, ["term"])
        XCTAssertEqual(f.detail, "term: dashboard → 管理画面")
        XCTAssertFalse(f.isSevere)
        let reason = TranslationNote.reasonText("term", detail: f.detail)
        XCTAssertEqual(reason, L("Your term is not in the translation: %@", "dashboard → 管理画面"))
        XCTAssertTrue(reason?.contains("dashboard → 管理画面") == true)

        let ok = TranslationGate.assess(source: "Open the dashboard.", translation: "管理画面を開きます。",
                                        sourceLanguage: "en", target: "ja",
                                        terms: [(source: "dashboard", translation: "管理画面")], detector: nil)
        XCTAssertTrue(ok.flags.isEmpty)
        // 原語が語の切れ目で当たらない原文では見ない
        let none = TranslationGate.assess(source: "My career is long.", translation: "私の経歴は長い。",
                                          sourceLanguage: "en", target: "ja",
                                          terms: [(source: "car", translation: "車")], detector: nil)
        XCTAssertTrue(none.flags.isEmpty)
    }

    func testLooseMatchForInflectedTargets() {
        XCTAssertEqual(TermPair.looseMatchMinimumLength, 5)
        XCTAssertEqual(TermPair.keptPrefixRatio, 0.75)
        // ロシア語: 格で語の終わりが変わる (заказчик → заказчика)
        XCTAssertTrue(TermPair.kept("заказчик", in: "Заказчика это не устроит.", target: "ru"))
        XCTAssertFalse(TermPair.kept("заказчик", in: "Клиент хочет скидку.", target: "ru"))
        // ドイツ語: 複数・合成語 (Besprechung → Besprechungen)
        XCTAssertTrue(TermPair.kept("Besprechung", in: "Die besprechungen sind am Donnerstag.", target: "de"))
        XCTAssertFalse(TermPair.kept("Besprechung", in: "Das Meeting ist am Donnerstag.", target: "de"))
        // 韓国語: 助詞が付く
        XCTAssertTrue(TermPair.kept("기록 파일", in: "기록 파일을 보내 주세요.", target: "ko"))
        // 短い語は、そのまま含むかで見る (app → "ap" だけでは当てない)
        XCTAssertTrue(TermPair.kept("app", in: "la nueva APP", target: "es"))
        XCTAssertFalse(TermPair.kept("aplicación", in: "la nueva app", target: "es"))
        XCTAssertFalse(TermPair.kept("Vertrieb", in: "das Vertrauen", target: "de"))
        // 日本語・中国語・タイ語は、そのまま含むかで見る (頭の 75% では当てない)
        XCTAssertFalse(TermPair.kept("管理画面です", in: "管理画面を", target: "ja"))
        XCTAssertTrue(TermPair.kept("管理画面", in: "この管理画面を", target: "ja"))
        XCTAssertFalse(TermPair.kept("โฟลเดอร์ส่วนกลาง", in: "โฟลเดอร์ส่วนตัว", target: "th"))
    }

    // MARK: 評価

    private func termCase(terms: [TranslationEvalTerm]?, keep: [String]? = nil) -> TranslationEvalCase {
        TranslationEvalCase(id: "t", language: "en", lines: ["Please open the dashboard.", "Then check the Roblox page."],
                            keep: keep, target: "ja", terms: terms)
    }

    func testScoringCountsTermsInTheSourceAndKeepStaysTheSame() {
        let terms = [TranslationEvalTerm(source: "dashboard", translation: "管理画面"),
                     TranslationEvalTerm(source: "career", translation: "経歴")]
        let translations = ["管理画面を開いてください。", "それから Roblox のページを見ます。"]
        let a = LLMEval.score(termCase(terms: terms), translations: translations).score
        XCTAssertEqual(a.termsChecked, 1)
        XCTAssertEqual(a.termsKept, 1)
        let missed = LLMEval.score(termCase(terms: terms), translations: ["ダッシュボードを開いて。", "Roblox を見る。"])
        XCTAssertEqual(missed.score.termsChecked, 1)
        XCTAssertEqual(missed.score.termsKept, 0)
        XCTAssertTrue(missed.details.contains { $0.contains("term lost: dashboard => 管理画面") })

        // keep だけの問題は、今と同じ点
        let keepOnly = LLMEval.score(termCase(terms: nil, keep: ["Roblox"]), translations: translations).score
        XCTAssertEqual(keepOnly.termsChecked, 1)
        XCTAssertEqual(keepOnly.termsKept, 1)
        let both = LLMEval.score(termCase(terms: terms, keep: ["Roblox"]), translations: translations).score
        XCTAssertEqual(both.termsChecked, 2)
        XCTAssertEqual(both.termsKept, 2)
    }

    func testRunTranslationGivesTermsUnlessTurnedOff() throws {
        let c = termCase(terms: [TranslationEvalTerm(source: "dashboard", translation: "管理画面")])
        let answers = ["Please open the dashboard.": "ダッシュボードを開いてください。",
                       "Then check the Roblox page.": "それから Roblox のページを見てください。"]
        let on = fake(answers)
        let a = try LLMEval.runTranslation([c], generator: on, detector: nil)
        XCTAssertTrue(on.prompts.contains { $0.user.contains("dashboard => 管理画面") })
        XCTAssertEqual(a.score.termsChecked, 1)
        XCTAssertEqual(a.score.termsKept, 0)
        XCTAssertEqual(a.outputs.first?.terms, c.terms)

        let off = fake(answers)
        let b = try LLMEval.runTranslation([c], generator: off, useTerms: false, detector: nil)
        XCTAssertFalse(off.prompts.contains { $0.user.contains("Terms") })
        XCTAssertEqual(b.score.termsChecked, 1)
        XCTAssertEqual(b.score.termsKept, 0)
        // 採点し直しでも、残した対で数える
        XCTAssertEqual(LLMEval.rescore(b.outputs, detector: nil).score.termsChecked, 1)
    }

    func testTheTermsSetLoadsAndEveryTermOccurs() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/llm-eval/translation-terms.json")
        let set = try JSONDecoder().decode(LLMEvalSet.self, from: Data(contentsOf: url))
        XCTAssertTrue(set.audit.isEmpty)
        XCTAssertEqual(set.translation.count, 10)
        XCTAssertEqual(Set(set.translation.map(\.id)).count, set.translation.count)
        XCTAssertEqual(Set(set.translation.filter { $0.language == "en" }.map(\.targetLanguage)),
                       ["ja", "zh", "ko", "de", "fr", "es", "ru", "th"])
        XCTAssertEqual(set.translation.filter { $0.language == "ja" }.map(\.targetLanguage), ["en", "en"])
        for c in set.translation {
            XCTAssertEqual(c.target, c.targetLanguage, c.id)
            XCTAssertNil(c.references, c.id)
            let terms = try XCTUnwrap(c.terms, c.id)
            XCTAssertTrue((1...2).contains(terms.count), c.id)
            let text = c.lines.joined(separator: "\n")
            for term in terms {
                XCTAssertTrue(TermPair.occurs(term.source, in: text), "\(c.id): \(term.source)")
                XCTAssertFalse(term.translation.isEmpty, c.id)
            }
        }
    }
}
