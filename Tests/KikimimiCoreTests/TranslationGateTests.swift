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
        // 名前だけの行を写した訳は、文字の検査では捨てない (短い原文なので、写しの印も付かない)
        let copy = flags("Roblox Studio", "Roblox Studio", to: "ko")
        XCTAssertFalse(copy.contains("script"))
        XCTAssertFalse(copy.contains("copied"))
        // 長い原文の写しには、写しの印が付く (文字の種類の検査では捨てない)
        let longCopy = flags("Roblox Studio Developer Conference", "Roblox Studio Developer Conference", to: "ko")
        XCTAssertFalse(longCopy.contains("script"))
        XCTAssertTrue(longCopy.contains("copied"))
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

    func testRepeatedIsOnlyAMark() {
        let f = TranslationGate.assess(source: "See you next time, everyone.",
                                       translation: "à bientôt à bientôt à bientôt à bientôt à bientôt",
                                       sourceLanguage: "en", target: "fr", detector: nil)
        XCTAssertTrue(f.flags.contains("repeated"))
        // 繰り返しは印だけ (歌の繰り返しは、正しい訳の事が在る)
        XCTAssertFalse(f.isSevere)
        XCTAssertFalse(flags("We sold 1500 toys today.", "Nous avons vendu 1500 jouets aujourd'hui.", to: "fr").contains("repeated"))
    }

    func testCopiedOnlyWhenTheLanguagesDiffer() {
        let source = "Hello everyone, welcome back to the channel."
        let f = TranslationGate.assess(source: source, translation: " Hello  everyone, welcome back to the channel. ",
                                       sourceLanguage: "en", target: "fr", detector: nil)
        XCTAssertTrue(f.flags.contains("copied"))
        XCTAssertFalse(f.isSevere)
        XCTAssertFalse(flags(source, source, from: "fr", to: "fr").contains("copied"))
        // 短い原文 (重さ 16 未満) の写しには付けない (「No.」→「No.」は正しい訳)
        XCTAssertLessThan(TranslationGate.weight("No."), TranslationGate.shortSentenceWeight)
        XCTAssertFalse(flags("No.", "No.", to: "fr").contains("copied"))
        XCTAssertEqual(TranslationGate.shortSentenceWeight, TranslationMemoryLookup.minimumSourceWeight)
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
        let f = TranslationGate.assess(source: source, translation: "Nous avons vendu des unités en quelques jours.",
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
        XCTAssertEqual(TranslationGate.severe, ["failed", "script", "long"])
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

    // MARK: 言葉で書いた数

    private func hasNumberFlag(_ source: String, _ translation: String, _ target: String) -> Bool {
        TranslationGate.assess(source: source, translation: translation, sourceLanguage: nil, target: target,
                               detector: nil).flags.contains("number")
    }

    func testSpelledOutNumbersInChineseAreNotLost() {
        XCTAssertFalse(hasNumberFlag("I waited 10 minutes, then 30 more.", "我等了十分钟，然后又等了三十分钟。", "zh"))
        // 繁体字の形も当たる (一萬 は簡体字では 一万)
        XCTAssertFalse(hasNumberFlag("About 10000 people came.", "大約一萬人來了。", "zh"))
        // target を渡さなければ、前のまま「消えた」
        XCTAssertEqual(LLMEval.numbersLost(sources: ["I waited 10 minutes, then 30 more."],
                                           translation: "我等了十分钟，然后又等了三十分钟。").lost, ["10", "30"])
    }

    func testSpelledOutNumbersInOtherLanguagesAreNotLost() {
        XCTAssertFalse(hasNumberFlag("It takes 30 minutes.", "三十分かかります。", "ja"))
        XCTAssertFalse(hasNumberFlag("It takes 30 minutes.", "Tiga puluh menit.", "id"))
        XCTAssertFalse(hasNumberFlag("35人が来ました。", "Thirty-five people came.", "en"))
        XCTAssertFalse(hasNumberFlag("35人が来ました。", "thirty five people came.", "en"))
        XCTAssertFalse(hasNumberFlag("It takes 30 minutes.", "삼십 분 걸립니다.", "ko"))
        XCTAssertFalse(hasNumberFlag("It takes 30 minutes.", "ใช้เวลาสามสิบนาที", "th"))
        // やわらかいハイフン入りの形 (fünf­und­dreißig) と、ふつうの書き方が当たる
        XCTAssertFalse(hasNumberFlag("35 people came.", "Fünfunddreißig Leute kamen.", "de"))
        XCTAssertFalse(hasNumberFlag("21 people came.", "Vingt et un personnes sont venues.", "fr"))
        XCTAssertFalse(hasNumberFlag("21 people came.", "Пришли двадцать один человек.", "ru"))
        XCTAssertFalse(hasNumberFlag("It takes 30 minutes.", "Mất ba mươi phút.", "vi"))
    }

    func testSpelledOutNumbersMatchOnlyWholeWords() {
        // "often" の中の "ten" では当たらない
        XCTAssertTrue(hasNumberFlag("10人が来た。", "People often came.", "en"))
        // 言葉の形も数字も無い
        XCTAssertTrue(hasNumberFlag("I waited 30 minutes.", "我等了很久。", "zh"))
        XCTAssertTrue(hasNumberFlag("It takes 30 minutes.", "Butuh beberapa menit.", "id"))
        // 先頭が 0 の数は、言葉では救わない
        XCTAssertTrue(hasNumberFlag("Room 07 is open.", "七号室が開いている。", "ja"))
        XCTAssertTrue(hasNumberFlag("Room 07 is open.", "Room seven is open.", "en"))
    }

    func testKanjiNumbersMustNotBePartOfALargerNumber() {
        // 「三十人」の中の「十」では 10 に当てない
        XCTAssertTrue(hasNumberFlag("10 people came.", "三十人が来た。", "ja"))
        XCTAssertTrue(hasNumberFlag("10 people came.", "来了三十人。", "zh"))
        XCTAssertFalse(hasNumberFlag("30 people came.", "三十人が来た。", "ja"))
        XCTAssertFalse(hasNumberFlag("30 people came.", "来了三十人。", "zh"))
        XCTAssertTrue(hasNumberFlag("30 people came.", "百三十人が来た。", "ja"))
        XCTAssertTrue(hasNumberFlag("30 people came.", "来了一百三十人。", "zh"))
        XCTAssertFalse(hasNumberFlag("It was on the 31st.", "十二月三十一日だった。", "ja"))
        XCTAssertFalse(hasNumberFlag("It was on the 31st.", "那是十二月三十一日。", "zh"))
        // 1 か所でも、前後が漢数字でない当たり方が在れば救う
        XCTAssertFalse(hasNumberFlag("10 people came.", "十人と三十人が来た。", "ja"))
        XCTAssertFalse(hasNumberFlag("10 people came.", "来了十人和三十人。", "zh"))
    }

    func testRemovingNumberAgreesWithTheGateOnSpelledOutNumbers() {
        let source = "We waited 30 minutes, then 15 more."
        let translation = "我们等了30分钟，又等了十五分钟。"
        let broken = TranslationGateEval.removingNumber(from: translation, source: source, target: "zh")
        XCTAssertNotNil(broken)
        XCTAssertTrue(hasNumberFlag(source, broken ?? "", "zh"))
        // 数字を消しても言葉の形が残るなら、関門と同じく「消えた」と見ない
        let both = "我们等了30分钟（三十分钟），又等了十五分钟。"
        XCTAssertNotNil(TranslationGateEval.removingNumber(from: both, source: source))
        XCTAssertNil(TranslationGateEval.removingNumber(from: both, source: source, target: "zh"))
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
