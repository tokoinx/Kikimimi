import XCTest
@testable import KikimimiCore

/// 翻訳の評価ハーネス (13 言語): 点 chrF、言語の判定を受け取る採点、訳す先ごとの集計、古い JSON、比べ方
final class TranslationEvalTests: XCTestCase {
    // MARK: chrF

    /// sacreBLEU 2.6.0 の `CHRF()` (既定) で出した値
    private let pairs: [(hypothesis: String, reference: String, chrF: Double)] = [
        ("The cost is about 20 dollars.", "The cost is around 20 dollars.", 68.5226),
        ("費用は約20ドルです。", "費用はおよそ20ドルです。", 51.3099),
        ("ใช้เวลาทั้งหมดประมาณสิบนาที", "ใช้เวลาประมาณสิบนาทีทั้งหมด", 78.5118),
        ("Zuerst öffnen wir einen neuen Ort.", "Zuerst erstellen wir einen neuen Ort und fügen ein Element hinzu.", 41.31),
        ("总共大约需要十分钟。", "总共需要大约十分钟。", 34.3254),
        ("abc", "abc", 100.0),
        ("completely different", "nothing shared here", 11.7355),
        ("Hi", "Hello there, how are you today?", 2.3585),
    ]

    func testChrFMatchesSacreBLEU() {
        for pair in pairs {
            XCTAssertEqual(ChrF.sentence(hypothesis: pair.hypothesis, reference: pair.reference), pair.chrF, accuracy: 0.005,
                           pair.hypothesis)
        }
        // コーパスの点は、文ごとの統計を足してから 1 回計算する (文の点の平均ではない)
        let corpus = ChrF.corpus(hypotheses: pairs.map(\.hypothesis), references: pairs.map(\.reference))
        XCTAssertEqual(corpus, 44.3466, accuracy: 0.005)
        let mean = pairs.map(\.chrF).reduce(0, +) / Double(pairs.count)
        XCTAssertGreaterThan(abs(corpus - mean), 1)
        // 空白は数えない。大文字と小文字は区別する。訳が空なら 0
        XCTAssertEqual(ChrF.sentence(hypothesis: "a b c", reference: "abc"), 100, accuracy: 1e-9)
        XCTAssertLessThan(ChrF.sentence(hypothesis: "ABC", reference: "abc"), 1)
        XCTAssertEqual(ChrF.sentence(hypothesis: "", reference: "abc"), 0)
    }

    func testChrFStatisticsAddUpAndRoundTrip() throws {
        var total = ChrF.Statistics()
        for pair in pairs { total.add(ChrF.statistics(hypothesis: pair.hypothesis, reference: pair.reference)) }
        XCTAssertEqual(total.score, 44.3466, accuracy: 0.005)
        XCTAssertEqual(total.hypothesis.count, ChrF.characterOrder)
        let decoded = try JSONDecoder().decode(ChrF.Statistics.self, from: JSONEncoder().encode(total))
        XCTAssertEqual(decoded, total)
        // 参照の無い次数は、仮説の数も数えない ("Hi" に 3 文字以上の n-gram は無い)
        let short = ChrF.statistics(hypothesis: "abcd", reference: "ab")
        XCTAssertEqual(short.hypothesis, [4, 3, 0, 0, 0, 0])
        XCTAssertEqual(short.reference, [2, 1, 0, 0, 0, 0])
        XCTAssertEqual(short.matches, [2, 1, 0, 0, 0, 0])
    }

    // MARK: 繰り返し

    func testRepetitionNeedsFiveRepeatsOfThreeOrMoreCharacters() {
        XCTAssertTrue(LLMEval.isRepetitive("とてもとてもとてもとてもとても"))
        XCTAssertTrue(LLMEval.isRepetitive("Okay. abcabcabcabcabc and so on"))
        XCTAssertTrue(LLMEval.isRepetitive("à bientôt à bientôt à bientôt à bientôt à bientôt"))
        XCTAssertTrue(LLMEval.isRepetitive("the the the the the"))
        XCTAssertFalse(LLMEval.isRepetitive("the the the the"))
        XCTAssertFalse(LLMEval.isRepetitive("とてもとてもとてもとても"))
        XCTAssertFalse(LLMEval.isRepetitive("..............................."))
        XCTAssertFalse(LLMEval.isRepetitive("Nous avons vendu 1500 jouets aujourd'hui."))
        XCTAssertFalse(LLMEval.isRepetitive(""))
    }

    // MARK: 採点

    private let frCase = TranslationEvalCase(
        id: "fr", language: "en", lines: ["We sold 1500 units of Roblox toys today.", "That is thirty percent more than before.",
                                          "See you next time, everyone."],
        keep: ["Roblox"], target: "fr",
        references: ["Nous avons vendu 1500 jouets Roblox aujourd'hui.", "C'est trente pour cent de plus qu'avant.",
                     "À la prochaine, tout le monde."])

    /// 「That is」を含めば英語、ほかはフランス語と答える偽の判定
    private let fakeDetector: LanguageDetector = { $0.contains("That is") ? "en" : "fr" }

    func testScoreCountsTargetLanguageCopiesRepeatsNumbersTermsAndChrF() {
        let translations = ["Nous avons vendu 1500 jouets Roblox aujourd'hui.", "That is thirty percent more than before.",
                            "à bientôt à bientôt à bientôt à bientôt à bientôt"]
        let result = LLMEval.score(frCase, translations: translations, detector: fakeDetector)
        let s = result.score
        XCTAssertEqual(s.lines, 3)
        XCTAssertEqual(s.translated, 3)
        XCTAssertEqual(s.inTarget, 2)
        XCTAssertEqual(s.copied, 1)
        XCTAssertEqual(s.repeated, 1)
        XCTAssertEqual(s.numbersKept, 1)
        XCTAssertEqual(s.numbersChecked, 1)
        XCTAssertEqual(s.termsKept, 1)
        XCTAssertEqual(s.termsChecked, 1)
        let chrF = try? XCTUnwrap(s.chrF)
        XCTAssertEqual(chrF ?? -1, ChrF.corpus(hypotheses: translations, references: frCase.references ?? []), accuracy: 1e-9)
        XCTAssertTrue(result.details.contains { $0.contains("not in fr") })
        XCTAssertTrue(result.details.contains { $0.contains("copied") })
        XCTAssertTrue(result.details.contains { $0.contains("repeated") })

        // 短い訳は判定しない (判定が「英語」と言っても、合っていると数える)
        let short = LLMEval.score(frCase, translations: ["Oui.", nil, nil], detector: { _ in "en" })
        XCTAssertEqual(short.score.translated, 1)
        XCTAssertEqual(short.score.inTarget, 1)
        // 訳せなかった行も、chrF では空の訳として数える (訳さないほど点が下がる)
        XCTAssertLessThan(short.score.chrF ?? 100, 10)
        // 判定が分からない (nil) 訳は、外れとは数えない
        let unknown = LLMEval.score(frCase, translations: [translations[0], nil, nil], detector: { _ in nil })
        XCTAssertEqual(unknown.score.inTarget, 1)
        // 人の訳が無ければ chrF は出さない
        var noReferences = frCase
        noReferences.references = nil
        XCTAssertNil(LLMEval.score(noReferences, translations: translations, detector: fakeDetector).score.chrF)
        // 原文が訳す先と同じ言語なら、写しは数えない
        var same = frCase
        same.language = "fr"
        XCTAssertEqual(LLMEval.score(same, translations: translations, detector: fakeDetector).score.copied, 0)
    }

    func testMergedLinesAreComparedWithTheJoinedReferences() {
        let merged = "Nous avons vendu 1500 jouets Roblox aujourd'hui. C'est trente pour cent de plus."
        let units = [LLMEval.TranslationUnit(lines: [0, 1], text: merged), LLMEval.TranslationUnit(lines: [2], text: nil)]
        let s = LLMEval.score(frCase, units: units, detector: fakeDetector).score
        XCTAssertEqual(s.translated, 2)
        XCTAssertEqual(s.inTarget, 2)
        var expected = ChrF.statistics(hypothesis: merged,
                                       reference: Transcript.join(Array((frCase.references ?? [])[0...1])))
        expected.add(ChrF.statistics(hypothesis: "", reference: (frCase.references ?? [])[2]))
        XCTAssertEqual(s.chrFStatistics, expected)
        XCTAssertEqual(s.chrF ?? -1, expected.score, accuracy: 1e-9)
    }

    func testWithoutADetectorTheScriptIsChecked() {
        let th = TranslationEvalCase(id: "th", language: "en", lines: ["Thank you all for coming today."], target: "th")
        XCTAssertEqual(LLMEval.score(th, translations: ["ขอบคุณทุกคนที่มาในวันนี้"]).score.inTarget, 1)
        XCTAssertEqual(LLMEval.score(th, translations: ["Thank you all for coming today."]).score.inTarget, 0)
        // 日本語は、今までどおりの検査 (判定の係は使わない)
        let ja = TranslationEvalCase(id: "ja", language: "en", lines: ["Thank you all for coming today."])
        XCTAssertEqual(ja.targetLanguage, "ja")
        XCTAssertEqual(LLMEval.score(ja, translations: ["今日は来てくれてありがとう。"], detector: { _ in "zh" }).score.inTarget, 1)
        XCTAssertEqual(LLMEval.score(ja, translations: ["谢谢你们今天来这里。"], detector: { _ in "ja" }).score.inTarget, 0)
    }

    /// 依頼の「[n] 本文」の行を、表のとおりに訳して返す偽の翻訳役
    private func table(_ table: [String: String]) -> FakeGenerator {
        FakeGenerator { prompt in
            prompt.user.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      let n = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
                let source = String(line[line.index(close, offsetBy: 2)...])
                return "[\(n)] \(table[source] ?? source)"
            }.joined(separator: "\n") + "\n"
        }
    }

    func testRunTranslationPassesTheTargetAndCountsPerTarget() throws {
        let th = TranslationEvalCase(id: "th", language: "en", lines: ["Thank you all for coming today.", "First we open",
                                                                        "a new place."],
                                     target: "th", references: ["ขอบคุณทุกคนที่มาในวันนี้", "ก่อนอื่นเราเปิด", "สถานที่ใหม่"])
        let ja = TranslationEvalCase(id: "ja", language: "en", lines: ["Thank you all for coming today."])
        let generator = table([
            "We sold 1500 units of Roblox toys today.": "Nous avons vendu 1500 jouets Roblox aujourd'hui.",
            "That is thirty percent more than before.": "C'est trente pour cent de plus qu'avant.",
            "See you next time, everyone.": "À la prochaine, tout le monde.",
            "Thank you all for coming today.": "ขอบคุณทุกคนที่มาในวันนี้",
            // 文の途中で切れた 2 行は、1 つの文として訳す
            "First we open a new place.": "ก่อนอื่นเราเปิดสถานที่ใหม่",
        ])
        var asked: [String] = []
        let result = try LLMEval.runTranslation([frCase, th], generator: generator, detector: { text in
            text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) } ? "th" : "fr"
        }, onCase: { done, _ in asked.append("\(done)") })
        XCTAssertEqual(asked, ["1", "2"])
        XCTAssertTrue(generator.prompts.contains { $0.system.contains("French") })
        XCTAssertTrue(generator.prompts.contains { $0.system.contains("Thai") })
        XCTAssertEqual(Set(result.byTarget.keys), ["fr", "th"])
        let fr = try XCTUnwrap(result.byTarget["fr"])
        XCTAssertEqual(fr.lines, 3)
        XCTAssertEqual(fr.translated, 3)
        XCTAssertEqual(fr.inTarget, 3)
        XCTAssertEqual(fr.copied, 0)
        XCTAssertEqual(fr.chrF ?? -1, 100, accuracy: 1e-9)
        let thai = try XCTUnwrap(result.byTarget["th"])
        XCTAssertEqual(thai.lines, 3)
        XCTAssertEqual(thai.translated, 3, result.details.joined(separator: "\n"))
        XCTAssertEqual(thai.inTarget, 3)
        XCTAssertEqual(thai.chrF ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(result.score.lines, 6)
        XCTAssertEqual(result.score.cases, 2)
        XCTAssertEqual(result.score.translated, 6)

        // 日本語へ: 訳す先を書かない古い場面は、日本語に訳す
        let japanese = try LLMEval.runTranslation([ja], generator: table(["Thank you all for coming today.": "今日は来てくれてありがとう。"]),
                                                  detector: nil)
        XCTAssertEqual(Set(japanese.byTarget.keys), ["ja"])
        XCTAssertEqual(japanese.byTarget["ja"]?.inTarget, 1)
        XCTAssertNil(japanese.byTarget["ja"]?.chrF)
    }

    // MARK: 古いファイル

    func testOldReportsAndOldCasesStillLoad() throws {
        let old = #"{"cases":3,"lines":9,"translated":9,"japanese":8,"numbersKept":3,"numbersChecked":3,"termsKept":2,"termsChecked":2,"seconds":12.5}"#
        let score = try JSONDecoder().decode(TranslationEvalScore.self, from: Data(old.utf8))
        XCTAssertEqual(score.inTarget, 8)
        XCTAssertEqual(score.translated, 9)
        XCTAssertEqual(score.copied, 0)
        XCTAssertEqual(score.repeated, 0)
        XCTAssertNil(score.chrF)
        XCTAssertEqual(score.seconds, 12.5)
        // 新しい形は、書いて読めば同じ
        var now = LLMEval.score(frCase, translations: ["Nous avons vendu 1500 jouets Roblox aujourd'hui.", nil, nil],
                                detector: fakeDetector).score
        now.seconds = 1
        let encoded = try JSONEncoder().encode(now)
        XCTAssertEqual(try JSONDecoder().decode(TranslationEvalScore.self, from: encoded), now)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"inTarget\""))

        let oldCase = #"{"id":"t","language":"en","lines":["Hello there."],"keep":["Roblox"]}"#
        let c = try JSONDecoder().decode(TranslationEvalCase.self, from: Data(oldCase.utf8))
        XCTAssertNil(c.target)
        XCTAssertEqual(c.targetLanguage, "ja")
        XCTAssertNil(c.references)
        XCTAssertNil(c.domain)
        XCTAssertEqual(c.keep, ["Roblox"])
    }

    // MARK: 比べ方

    func testRegressionsArePerTarget() {
        var base = TranslationEvalScore()
        base.lines = 10
        base.translated = 10
        base.inTarget = 9
        base.numbersKept = 3
        base.termsKept = 2
        base.copied = 1
        base.repeated = 0
        base.chrF = 50
        let before = ["fr": base, "th": base]
        XCTAssertEqual(LLMEval.translationRegressions(before, baseline: before), [])
        // chrF の 1.0 点までの下がりは、揺れとして許す
        var small = base
        small.chrF = 49.2
        XCTAssertEqual(LLMEval.translationRegressions(["fr": small], baseline: before), [])
        var drop = base
        drop.chrF = 48.9
        XCTAssertEqual(LLMEval.translationRegressions(["fr": drop], baseline: before).count, 1)
        var copied = base
        copied.copied = 2
        var repeated = base
        repeated.repeated = 1
        var lost = base
        lost.inTarget = 8
        lost.translated = 9
        let worse = LLMEval.translationRegressions(["fr": copied, "th": repeated], baseline: before)
        XCTAssertEqual(worse.count, 2)
        XCTAssertTrue(worse[0].hasPrefix("fr: copied"))
        XCTAssertTrue(worse[1].hasPrefix("th: repeated"))
        XCTAssertEqual(LLMEval.translationRegressions(["fr": lost], baseline: before).count, 2)
        // 前の結果に無い訳す先は比べない。良くなった所は数えない
        var better = base
        better.chrF = 60
        better.copied = 0
        XCTAssertEqual(LLMEval.translationRegressions(["fr": better, "de": drop], baseline: before), [])
        // 前の結果に chrF が無ければ、chrF は比べない
        var noPoints = base
        noPoints.chrF = nil
        XCTAssertEqual(LLMEval.translationRegressions(["fr": drop], baseline: ["fr": noPoints]), [])
    }

    func testTableHasOneRowPerTarget() {
        var s = TranslationEvalScore()
        s.lines = 4
        s.translated = 4
        s.inTarget = 3
        s.chrF = 51.234
        s.seconds = 2
        let rows = LLMEval.translationTable(["th": s, "fr": TranslationEvalScore()])
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].hasPrefix("target"))
        XCTAssertTrue(rows[1].hasPrefix("fr"))
        XCTAssertTrue(rows[2].hasPrefix("th"))
        XCTAssertTrue(rows[2].contains("51.23"))
        XCTAssertTrue(rows[2].contains("0.50"))
    }

    // MARK: リポジトリの問題

    func testTheMiniTranslationSetLoadsAndIsWellFormed() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/llm-eval/translation-mini.json")
        let set = try JSONDecoder().decode(LLMEvalSet.self, from: Data(contentsOf: url))
        XCTAssertTrue(set.audit.isEmpty)
        XCTAssertEqual(Set(set.translation.map(\.targetLanguage)), ["fr", "th", "en"])
        XCTAssertEqual(Set(set.translation.map(\.id)).count, set.translation.count)
        for c in set.translation {
            XCTAssertEqual(c.references?.count, c.lines.count, c.id)
            XCTAssertNotEqual(c.language, c.targetLanguage, c.id)
            XCTAssertEqual(c.target, c.targetLanguage, c.id)
            // 人の訳をそのまま訳とすれば、点は 100 で、すべてその言語
            let perfect = LLMEval.score(c, translations: c.references ?? [], detector: LLMEval.defaultLanguageDetector)
            XCTAssertEqual(perfect.score.chrF ?? -1, 100, accuracy: 1e-9, c.id)
            XCTAssertEqual(perfect.score.inTarget, c.lines.count, perfect.details.joined(separator: "\n"))
            XCTAssertEqual(perfect.score.copied, 0, c.id)
        }
        XCTAssertTrue(set.translation.contains { $0.language == "ja" && $0.targetLanguage == "en" })
        // 古い問題 (seed.json) の翻訳の場面は、日本語へ訳す
        let seedURL = url.deletingLastPathComponent().appendingPathComponent("seed.json")
        let seed = try JSONDecoder().decode(LLMEvalSet.self, from: Data(contentsOf: seedURL))
        XCTAssertTrue(seed.translation.allSatisfy { $0.targetLanguage == "ja" && $0.references == nil })
    }

    #if canImport(NaturalLanguage)
    func testSystemDetectorNamesTheLanguages() {
        let samples: [(String, String)] = [
            ("Thank you very much for coming to the meeting today.", "en"),
            ("Merci beaucoup d'être venus à la réunion aujourd'hui.", "fr"),
            ("Vielen Dank, dass Sie heute zur Besprechung gekommen sind.", "de"),
            ("ขอบคุณมากที่มาร่วมประชุมในวันนี้", "th"),
            ("非常感谢大家今天来参加会议。", "zh"),
            ("今日は会議に来てくれて本当にありがとうございます。", "ja"),
            ("오늘 회의에 와 주셔서 정말 감사합니다.", "ko"),
        ]
        for (text, code) in samples {
            XCTAssertEqual(SystemLanguageDetector.detect(text), code, text)
        }
    }
    #endif
}
