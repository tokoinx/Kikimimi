import XCTest
@testable import KikimimiCore

/// 訳の関門 (`TranslationGate`) と、その測り (`TranslationGateEval`)
final class TranslationGateTests: XCTestCase {
    /// 「English:」で始まれば英語、ほかは訳す先と同じ言語 (fr) と答える偽の判定
    private let fakeDetector: LanguageDetector = { $0.hasPrefix("English:") ? "en" : "fr" }

    private func flags(_ source: String, _ translation: String?, from sourceLanguage: String? = "en", to target: String,
                       terms: [(source: String, translation: String)] = [],
                       detector: LanguageDetector? = nil) -> [String] {
        TranslationGate.assess(source: source, translation: translation, sourceLanguage: sourceLanguage, target: target,
                               terms: terms, detector: detector).flags
    }

    func testFailedWhenThereIsNoTranslation() {
        for t in [nil, "", "   \n"] as [String?] {
            let f = TranslationGate.assess(source: "Hello.", translation: t, sourceLanguage: "en", target: "fr", detector: nil)
            XCTAssertEqual(f.flags, ["failed"])
            XCTAssertTrue(f.isSevere)
        }
    }

    func testScriptFollowsTranslatorIsPlausible() {
        XCTAssertTrue(flags("Hi everyone, welcome.", "大家好，欢迎。", to: "ja").contains("script"))
        XCTAssertTrue(flags("皆さん、こんにちは。", "Hello everyone.", from: "ja", to: "ko").contains("script"))
        XCTAssertTrue(flags("This is Japanese.", "これは日本語です", to: "zh").contains("script"))
        XCTAssertFalse(flags("皆さん、こんにちは。", "여러분, 안녕하세요.", from: "ja", to: "ko").contains("script"))
        // 名前だけの行を写した訳は、文字の検査では捨てない (写しの印は付く)
        let copy = flags("Roblox Studio", "Roblox Studio", to: "ko")
        XCTAssertFalse(copy.contains("script"))
        XCTAssertTrue(copy.contains("copied"))
        // 関門の 2 つの検査と、翻訳役の受け取りの決まりは同じ
        for (t, s, target) in [("大家好，欢迎。", "Hi everyone.", "ja"), ("Hello", "Привет", "th"), ("大家好。", "Hi everyone.", "zh"),
                               (String(repeating: "あ", count: 53), "Hi.", "ja"), ("Всем привет.", "Hi everyone.", "ru")] {
            let gate = Translator.hasWrongScript(t, source: s, target: target) || Translator.isTooLong(t, source: s, target: target)
            XCTAssertEqual(!gate, Translator.isPlausible(t, source: s, target: target), t)
        }
    }

    func testLongFollowsTheLengthRule() {
        let long = flags("Hi.", String(repeating: "abcdefghij ", count: 7) + "abcdefghi", to: "fr")
        XCTAssertTrue(long.contains("long"))
        XCTAssertFalse(flags("Hi.", String(repeating: "abcdefghij ", count: 7) + "a", to: "fr").contains("long"))
        XCTAssertTrue(TranslationGate.assess(source: "Hi.", translation: String(repeating: "あいうえおかきくけこ", count: 6),
                                             sourceLanguage: "en", target: "ja", detector: nil).flags.contains("long"))
    }

    func testRepeatedIsSevere() {
        let f = TranslationGate.assess(source: "See you next time, everyone.",
                                       translation: "à bientôt à bientôt à bientôt à bientôt à bientôt",
                                       sourceLanguage: "en", target: "fr", detector: nil)
        XCTAssertTrue(f.flags.contains("repeated"))
        XCTAssertTrue(f.isSevere)
        XCTAssertFalse(flags("We sold 1500 toys today.", "Nous avons vendu 1500 jouets aujourd'hui.", to: "fr").contains("repeated"))
    }

    func testCopiedOnlyWhenTheLanguagesDiffer() {
        let source = "Hello everyone, welcome back to the channel."
        let f = TranslationGate.assess(source: source, translation: " Hello  everyone, welcome back to the channel. ",
                                       sourceLanguage: "en", target: "fr", detector: nil)
        XCTAssertTrue(f.flags.contains("copied"))
        XCTAssertFalse(f.isSevere)
        XCTAssertFalse(flags(source, source, from: "fr", to: "fr").contains("copied"))
        // 原文の言語が分からない時は、違う言語と見る
        XCTAssertTrue(flags(source, source, from: nil, to: "fr").contains("copied"))
    }

    func testLanguageUsesTheDetectorAndSkipsShortText() {
        XCTAssertTrue(flags("Hello everyone, welcome.", "English: hello everyone, welcome", to: "fr", detector: fakeDetector)
            .contains("language"))
        XCTAssertFalse(flags("Hello everyone, welcome.", "Bonjour à tous, bienvenue.", to: "fr", detector: fakeDetector)
            .contains("language"))
        // 短い文は判定しない。「Yes. → はい。」は、言語も短さも印が付かない
        XCTAssertEqual(flags("Yes.", "はい。", to: "ja", detector: LLMEval.defaultLanguageDetector), [])
        XCTAssertFalse(flags("Yes.", "English:", to: "fr", detector: fakeDetector).contains("language"))
    }

    func testCorrectTranslationsInOtherScriptsHaveNoFlags() {
        let source = "The weather was very nice yesterday, so we went for a long walk in the park."
        let translations: [(String, String)] = [
            ("th", "เมื่อวานอากาศดีมาก เราจึงไปเดินเล่นในสวนสาธารณะเป็นเวลานาน"),
            ("ko", "어제는 날씨가 아주 좋아서 공원에서 오랫동안 산책했습니다."),
            ("ru", "Вчера была очень хорошая погода, поэтому мы долго гуляли в парке."),
            ("zh", "昨天天气很好，所以我们在公园里散步了很久。"),
            ("ja", "昨日はとても天気が良かったので、公園を長い時間散歩しました。")
        ]
        for (target, t) in translations {
            XCTAssertEqual(flags(source, t, to: target, detector: LLMEval.defaultLanguageDetector), [], target)
        }
    }

    func testNumbersIgnoreThousandsSeparators() {
        let source = "We sold 4,000 units in 15 days."
        XCTAssertFalse(flags(source, "Nous avons vendu 4.000 unités en 15 jours.", to: "fr").contains("number"))
        XCTAssertFalse(flags(source, "Nous avons vendu 4 000 unités en 15 jours.", to: "fr").contains("number"))
        let f = TranslationGate.assess(source: source, translation: "Nous avons vendu des unités en quinze jours.",
                                       sourceLanguage: "en", target: "fr", detector: nil)
        XCTAssertTrue(f.flags.contains("number"))
        XCTAssertEqual(f.detail, "number: 15, 4000")
    }

    func testTermsOnlyWhenTheSourceHasTheTerm() {
        let terms = [(source: "Roblox", translation: "Roblox"), (source: "Studio", translation: "スタジオ")]
        let f = TranslationGate.assess(source: "Open roblox now.", translation: "Ouvrez le jeu maintenant.",
                                       sourceLanguage: "en", target: "fr", terms: terms, detector: nil)
        XCTAssertTrue(f.flags.contains("term"))
        XCTAssertEqual(f.detail, "term: Roblox")
        XCTAssertFalse(flags("Open Roblox now.", "Ouvrez ROBLOX maintenant.", to: "fr", terms: terms).contains("term"))
        XCTAssertFalse(flags("Open the game now.", "Ouvrez le jeu maintenant.", to: "fr", terms: terms).contains("term"))
    }

    func testShortNeedsALongSourceAndALowRatio() {
        let source = "It has been months, and I feel like I am still standing there at his grave."
        XCTAssertTrue(flags(source, "Des mois.", to: "fr").contains("short"))
        XCTAssertFalse(flags(source, "Cela fait des mois, et j'ai l'impression d'être encore devant sa tombe.", to: "fr")
            .contains("short"))
        // 漢字は重く数えるので、正しい中国語の訳は短すぎない
        XCTAssertFalse(flags(source, "已经好几个月了，我觉得自己仍然站在他的墓前。", to: "zh").contains("short"))
        XCTAssertFalse(flags("Yes, sure.", "Oui.", to: "fr").contains("short"))
        XCTAssertFalse(TranslationGate.severe.contains("short"))
    }

    func testFlagsComeInTheFixedOrderAndRoundTrip() throws {
        let f = TranslationGate.assess(source: "We sold 4,000 units of Roblox toys in 15 days, which is a record.",
                                       translation: "Vendu.", sourceLanguage: "en", target: "fr",
                                       terms: [(source: "Roblox", translation: "Roblox")], detector: nil)
        XCTAssertEqual(f.flags, ["number", "term", "short"])
        XCTAssertEqual(f.detail, "number: 15, 4000; term: Roblox")
        let decoded = try JSONDecoder().decode(TranslationGate.Finding.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(decoded, f)
        XCTAssertEqual(TranslationGate.severe, ["failed", "script", "long", "repeated"])
        XCTAssertTrue(TranslationGate.severe.isSubset(of: Set(TranslationGate.all)))
    }

    // MARK: 測り

    func testRemovingNumberDeletesTheWholeNumber() {
        let source = "We sold 4,000 units in 15 days."
        let broken = TranslationGateEval.removingNumber(from: "Nous avons vendu 4.000 unités en 15 jours.", source: source)
        XCTAssertNotNil(broken)
        XCTAssertFalse(LLMEval.numbersLost(sources: [source], translation: broken ?? "").lost.isEmpty)
        XCTAssertFalse(broken?.contains("4.000") == true && broken?.contains("15") == true)
        XCTAssertNil(TranslationGateEval.removingNumber(from: "Nous avons vendu des unités.", source: source))
        XCTAssertNil(TranslationGateEval.removingNumber(from: "Bonjour.", source: "Hello."))
    }

    func testOtherLanguageSentenceAvoidsTargetAndSource() {
        for target in TranslationTarget.all {
            for k in 0..<10 {
                let s = TranslationGateEval.otherLanguageSentence(target: target, sourceLanguage: "en", index: k)
                let language = TranslationGateEval.otherLanguageSentences.first { $0.text == s }?.language
                XCTAssertNotEqual(language, target)
                XCTAssertNotEqual(language, "en")
            }
        }
        XCTAssertTrue(LLMEval.isRepetitive(TranslationGateEval.repeatingHead("Bonjour à tous.")))
    }

    func testCheckReferencesCountsFalseAlarmsAndCaughtMutations() {
        let set = LLMEvalSet(name: "t", translation: [
            TranslationEvalCase(id: "a", language: "en",
                                lines: ["We sold 4,000 units of our new toys in 15 days, which is a record for us."],
                                keep: ["toys"], target: "fr",
                                references: ["Nous avons vendu 4.000 unités de nos nouveaux toys en 15 jours, un record pour nous."])
        ])
        let result = TranslationGateEval.checkReferences(set, file: "t.json", detector: nil)
        let s = result.byTarget["fr"]
        XCTAssertEqual(s?.units, 1)
        XCTAssertEqual(s?.flaggedUnits, 0)
        XCTAssertEqual(s?.mutations["number"]?.caught, 1)
        XCTAssertEqual(s?.mutations["copied"]?.caught, 1)
        XCTAssertEqual(s?.mutations["repeated"]?.caught, 1)
        XCTAssertEqual(s?.mutations["failed"]?.caught, 1)
        XCTAssertEqual(s?.mutations["short"]?.caught, 1)
        // 判定が無いと、ラテン文字の言語の「別の言語」は、文字の種類の違う文の時だけ拾う
        XCTAssertEqual(s?.mutations["language"]?.tried, 1)
    }

    func testCheckOutputsSplitsChrFByFlag() throws {
        let output = LLMEval.TranslationOutput(id: "o", target: "fr", language: "en", lineCount: 3, units: [
            .init(lines: [0], source: "We sold 1500 toys today.", text: "Nous avons vendu 1500 jouets aujourd'hui.",
                  reference: "Nous avons vendu 1500 jouets aujourd'hui."),
            .init(lines: [1], source: "We sold 2500 toys yesterday.", text: "Nous avons vendu des jouets hier.",
                  reference: "Nous avons vendu 2500 jouets hier."),
            .init(lines: [2], source: "42", text: nil, reference: nil, asSource: true)
        ])
        let result = TranslationGateEval.checkOutputs([output], file: "r.json", detector: nil)
        let s = try XCTUnwrap(result.byTarget["fr"])
        XCTAssertEqual(s.units, 2)
        XCTAssertEqual(s.skippedAsSource, 1)
        XCTAssertEqual(s.flaggedUnits, 1)
        XCTAssertEqual(s.flags["number"], 1)
        XCTAssertEqual(s.unflaggedChrF ?? 0, 100, accuracy: 1e-9)
        XCTAssertLessThan(s.flaggedChrF ?? 100, 100)
        XCTAssertEqual(s.chrFByFlag["number"] ?? 0, s.flaggedChrF ?? -1, accuracy: 1e-9)
        XCTAssertEqual(result.examples.map(\.kind), ["output"])
        let report = TranslationGateReport(files: ["r.json"], outputs: result.byTarget, examples: result.examples)
        let decoded = try JSONDecoder().decode(TranslationGateReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.outputs, report.outputs)
        XCTAssertEqual(decoded.examples, report.examples)
    }
}
