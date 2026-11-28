import XCTest
@testable import KikimimiCore

/// 訳す先の言語を選べる翻訳の試験 (訳す区間の決め方・指示文・手本・検査・結果の記録・書き出し・一覧の行・練習の隠し方)
final class TranslationTargetTests: XCTestCase {
    override func tearDown() {
        L10n.language = .en
        super.tearDown()
    }

    private func seg(_ start: TimeInterval, _ text: String, language: String? = nil) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, text: text, language: language)
    }

    /// 依頼の中の「[n] 本文」の行を取り出す
    private func numberedLines(in prompt: LLMPrompt) -> [(Int, String)] {
        prompt.user.split(separator: "\n").compactMap { line -> (Int, String)? in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let n = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
            return (n, String(line[line.index(close, offsetBy: 2)...]))
        }
    }

    /// 行の頭に印を付けて返す偽の翻訳役
    private func echo(_ mark: String) -> FakeGenerator {
        FakeGenerator { prompt in
            self.numberedLines(in: prompt).map { "[\($0.0)] \(mark)\($0.1)" }.joined(separator: "\n") + "\n"
        }
    }

    // MARK: 言語の名前

    func testTargetsFollowTheDisplayLanguages() {
        XCTAssertEqual(TranslationTarget.all, UILanguage.allCases.map(\.rawValue))
        XCTAssertEqual(TranslationTarget.all.count, 13)
        XCTAssertEqual(TranslationTarget.fallback, "ja")
        XCTAssertEqual(TranslationTarget.normalized("en"), "en")
        XCTAssertEqual(TranslationTarget.normalized("PT"), "pt")
        XCTAssertEqual(TranslationTarget.normalized("yue"), "ja")
        XCTAssertEqual(TranslationTarget.normalized(nil), "ja")
        XCTAssertEqual(TranslationTarget.normalized(""), "ja")
        XCTAssertEqual(TranslationTarget.englishName(for: "zh"), "Simplified Chinese")
        XCTAssertEqual(TranslationTarget.englishName(for: "pt"), "Brazilian Portuguese")
        for code in TranslationTarget.all {
            XCTAssertFalse(TranslationTarget.englishName(for: code).isEmpty, code)
        }
        L10n.language = .en
        XCTAssertEqual(TranslationTarget.displayName(for: "fr"), "French")
        L10n.language = .ja
        XCTAssertEqual(TranslationTarget.displayName(for: "ja"), "日本語")
        // 監査の指示文が使う名前は、前と同じ (ja は「the original language」)。翻訳の指示文の原文の名前だけ "Japanese"
        XCTAssertEqual(Script.englishName(for: "ja"), "the original language")
        XCTAssertEqual(Translator.sourceLanguageName(for: "ja"), "Japanese")
        XCTAssertEqual(Translator.sourceLanguageName(for: "JA"), "Japanese")
        XCTAssertEqual(Translator.sourceLanguageName(for: "en"), "English")
        XCTAssertEqual(Translator.sourceLanguageName(for: nil), "the original language")
        XCTAssertTrue(Auditor.systemPrompt(language: "ja").contains("The transcript is mostly in the original language."))
        XCTAssertTrue(Translator.systemPrompt(language: "ja").contains("from the original language into natural, easy-to-read Japanese."))
    }

    // MARK: 訳す区間

    func testTranslateIntoEnglish() throws {
        // 日本語の結果。英語とわかっている区間・文字の無い区間は訳さない
        let segments = [
            seg(0, "皆さん、こんにちは。"),
            seg(2, "Hello there.", language: "en"),
            seg(4, "100%"),
            seg(6, "では始めましょう。"),
        ]
        let fake = echo("EN:")
        var collected: [UUID: String] = [:]
        let failed = try Translator.translate(segments, language: "ja", target: "en", generator: fake,
                                              shouldCancel: { false }) { batch, _, _ in
            for r in batch { collected[r.head] = r.text }
        }
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(collected[segments[0].id], "EN:皆さん、こんにちは。")
        XCTAssertEqual(collected[segments[3].id], "EN:では始めましょう。")
        XCTAssertNil(collected[segments[1].id], "the English line is not translated")
        XCTAssertNil(collected[segments[2].id])
        XCTAssertEqual(fake.prompts.count, 1)
        let prompt = fake.prompts[0]
        XCTAssertTrue(prompt.system.contains("from Japanese into natural, easy-to-read English."), prompt.system)
        XCTAssertTrue(prompt.system.contains("- Write English only."))
        XCTAssertTrue(prompt.system.contains("If a line is already English, copy it unchanged."))
        XCTAssertFalse(prompt.system.contains("katakana"))
        XCTAssertFalse(prompt.japaneseOnly)
        XCTAssertEqual(prompt.examples, Translator.examples(for: "en"))
        XCTAssertNotEqual(prompt.examples, Translator.examples)
        // 日本語へ訳す時は、日本語の区間を訳さない (これまでと同じ)
        XCTAssertEqual(Translator.pendingIndices(segments, language: "ja"), [1])
        XCTAssertEqual(Translator.pendingIndices(segments, language: "ja", target: "en"), [0, 3])
    }

    func testUnknownLanguageIsTranslatedAndSameLanguageIsNot() {
        // 言語が分からない区間は、訳す先と同じ文字でも訳す (指示文で、もうその言語ならそのまま写させる)
        let unknown = [seg(0, "Bonjour à tous."), seg(2, "Hello."), seg(4, "42")]
        XCTAssertEqual(Translator.pendingIndices(unknown, language: nil, target: "fr"), [0, 1])
        // 中国語の結果は、簡体字へは訳さない
        let chinese = [seg(0, "大家好，欢迎回来。"), seg(2, "我们开始吧。")]
        XCTAssertEqual(Translator.pendingIndices(chinese, language: "zh", target: "zh"), [])
        XCTAssertEqual(Translator.pendingIndices(chinese, language: "zh", target: "ja"), [0, 1])
        // 区間の言語が、文字起こし全体の言語より先
        let mixed = [seg(0, "Hello.", language: "en"), seg(2, "こんにちは。", language: "ja")]
        XCTAssertEqual(Translator.pendingIndices(mixed, language: "en", target: "en"), [1])
        XCTAssertEqual(Translator.unitIDs(containing: mixed[0].id, in: mixed, language: "en", target: "en"), [])
        XCTAssertEqual(Translator.unitIDs(containing: mixed[1].id, in: mixed, language: "en", target: "en"), [mixed[1].id])
        XCTAssertFalse(Script.needsTranslation("…", segmentLanguage: nil, transcriptLanguage: nil, target: "de"))
        XCTAssertTrue(Script.needsTranslation("Guten Tag", segmentLanguage: nil, transcriptLanguage: "en", target: "de"))
        XCTAssertFalse(Script.needsTranslation("Guten Tag", segmentLanguage: "de", transcriptLanguage: "en", target: "de"))
    }

    func testPromptsForOtherTargets() {
        let zh = Translator.systemPrompt(language: "en", target: "zh")
        XCTAssertTrue(zh.contains("into natural, easy-to-read Simplified Chinese."), zh)
        XCTAssertTrue(zh.contains("- Write Simplified Chinese only. Use Simplified Chinese characters."), zh)
        let pt = Translator.systemPrompt(language: "en", target: "pt")
        XCTAssertTrue(pt.contains("- Write Brazilian Portuguese only. Use Brazilian Portuguese."), pt)
        let fr = Translator.systemPrompt(language: nil, target: "fr")
        XCTAssertTrue(fr.contains("from the original language into natural, easy-to-read French."), fr)
        XCTAssertFalse(fr.contains("訳文"), "the output example is left to the examples")
        XCTAssertEqual(Translator.systemPrompt(language: "en"), Translator.systemPrompt(language: "en", target: "ja"))
    }

    // MARK: 訳の検査

    func testPlausibilityPerTarget() {
        // ko・ru・th: その言語の文字が無い訳は捨てる。原文と同じ訳 (名前だけの行など) は受け取る
        XCTAssertFalse(Translator.isPlausible("Hello everyone.", source: "皆さん、こんにちは。", target: "ko"))
        XCTAssertTrue(Translator.isPlausible("여러분, 안녕하세요.", source: "皆さん、こんにちは。", target: "ko"))
        XCTAssertTrue(Translator.isPlausible("Roblox Studio", source: "Roblox Studio", target: "ko"))
        XCTAssertFalse(Translator.isPlausible("Hello", source: "Привет", target: "th"))
        XCTAssertTrue(Translator.isPlausible("Всем привет.", source: "Hi everyone.", target: "ru"))
        XCTAssertTrue(Translator.isPlausible("20", source: "20", target: "ru"))
        // zh: かなが入った訳は日本語に流れている
        XCTAssertFalse(Translator.isPlausible("みなさん、こんにちは。", source: "Hi everyone.", target: "zh"))
        XCTAssertTrue(Translator.isPlausible("大家好。", source: "Hi everyone.", target: "zh"))
        // fr などのラテン文字の言語は、文字の種類を見ない
        XCTAssertTrue(Translator.isPlausible("Hi everyone.", source: "皆さん、こんにちは。", target: "fr"))
        XCTAssertTrue(Translator.isPlausible("大家好", source: "Hi.", target: "fr"))
        // 空・長すぎる訳は、どの言語でも捨てる (原文 × 6 + 60 字まで)
        XCTAssertFalse(Translator.isPlausible("  ", source: "Hi.", target: "fr"))
        XCTAssertTrue(Translator.isPlausible(String(repeating: "a", count: 78), source: "Hi.", target: "fr"))
        XCTAssertFalse(Translator.isPlausible(String(repeating: "a", count: 79), source: "Hi.", target: "fr"))
        // 日本語は、これまでと同じ (原文 × 4 + 40 字まで・中国語の文字を捨てる)
        XCTAssertFalse(Translator.isPlausible("大家好，欢迎。", source: "Hi everyone.", target: "ja"))
        XCTAssertFalse(Translator.isPlausible(String(repeating: "あ", count: 53), source: "Hi.", target: "ja"))
        XCTAssertTrue(Translator.isPlausible(String(repeating: "あ", count: 52), source: "Hi.", target: "ja"))
    }

    func testRejectedTranslationIsNotUsed() throws {
        let segments = [seg(0, "Hi everyone.")]
        let fake = FakeGenerator { _ in "[1] Hi everyone, again.\n" } // ハングルが無い
        let failed = try Translator.translate(segments, language: "en", target: "ko", generator: fake,
                                              shouldCancel: { false }) { batch, _, _ in XCTAssertTrue(batch.isEmpty) }
        XCTAssertEqual(failed, 1)
    }

    // MARK: 手本

    func testExamplesForEveryTarget() {
        for code in TranslationTarget.all {
            let examples = Translator.examples(for: code)
            XCTAssertEqual(examples.count, 1, code)
            guard let example = examples.first else { continue }
            let source = numberedLines(in: LLMPrompt(system: "", user: example.user))
            let answer = numberedLines(in: LLMPrompt(system: "", user: example.assistant))
            XCTAssertEqual(source.count, 3, code)
            XCTAssertEqual(answer.map(\.0), source.map(\.0), code)
            XCTAssertTrue(example.user.hasPrefix("Lines to translate:\n[1] "), code)
            XCTAssertTrue(example.assistant.hasSuffix("\n"), code)
            XCTAssertTrue(answer[2].1.contains("20"), "\(code): the number stays")
            XCTAssertNotEqual(source.map(\.1), answer.map(\.1), code)
        }
        // 英語へ訳す手本は、日本語の 3 行が原文
        let en = Translator.examples(for: "en")[0]
        XCTAssertTrue(en.user.contains("[3] 費用は約 20 ドルです。"), en.user)
        XCTAssertTrue(en.assistant.contains("[3] It costs about 20 dollars.\n"), en.assistant)
        // 日本語の手本は、これまでと一字も同じ
        XCTAssertEqual(Translator.examples, [LLMExample(
            user: "Lines to translate:\n[1] Hi everyone, thanks for joining us today.\n[2] Let's take a look at the results.\n[3] It costs about 20 dollars.",
            assistant: "[1] みなさん、今日はお集まりいただきありがとうございます。\n[2] では、結果を見てみましょう。\n[3] 費用は約 20 ドルです。\n"
        )])
        XCTAssertEqual(Translator.examples(for: "ja"), Translator.examples)
        XCTAssertEqual(Translator.examples(for: "xx"), Translator.examples)
    }

    // MARK: 結果の記録

    func testStatsPerTarget() {
        let japanese = Transcript(sourceName: "a", segments: [seg(0, "こんにちは。"), seg(2, "今日はいい天気です。"), seg(4, "100")],
                                  language: "ja")
        let ja = japanese.translationStats(target: "ja")
        XCTAssertEqual(ja.translatable, 0)
        XCTAssertFalse(ja.isMainlyForeign)
        XCTAssertFalse(japanese.isMainlyForeign(target: "ja"))
        XCTAssertEqual(japanese.translationStats, ja)
        let en = japanese.translationStats(target: "en")
        XCTAssertEqual(en.translatable, 2)
        XCTAssertEqual(en.untranslated, 2)
        XCTAssertTrue(en.isMainlyForeign)
        XCTAssertTrue(japanese.isMainlyForeign(target: "en"))
        XCTAssertEqual(japanese.translationText(of: japanese.segments[0], target: "ja"), "こんにちは。")
        XCTAssertNil(japanese.translationText(of: japanese.segments[0], target: "en"))
        let units = japanese.bilingualUnits(target: "en")
        XCTAssertEqual(units.map(\.translation), [nil, nil, "100"])
        XCTAssertEqual(units.map(\.isOriginalInTarget), [false, false, true])
        XCTAssertEqual(japanese.bilingualUnits().map(\.isOriginalInTarget), [true, true, true])
    }

    func testTranslationTargetAndRemovingAllTranslations() {
        var t = Transcript(sourceName: "a", segments: [seg(0, "Hello."), seg(2, "World.")], language: "en")
        XCTAssertEqual(t.translationTarget(default: "fr"), "fr", "no translation yet: the setting")
        t.segments[0].translation = "こんにちは。"
        t.segments[0].translationCovers = [t.segments[1].id]
        t.translationModel = "m"
        XCTAssertEqual(t.translationTarget(default: "fr"), "ja", "an old result without the record was translated into Japanese")
        t.translationLanguage = "en"
        XCTAssertEqual(t.translationTarget(default: "fr"), "en")
        t.removeAllTranslations()
        XCTAssertFalse(t.hasTranslation)
        XCTAssertTrue(t.segments.allSatisfy { $0.translation == nil && $0.translationCovers == nil })
        XCTAssertNil(t.translationModel)
        XCTAssertNil(t.translationLanguage)
        XCTAssertEqual(t.translationTarget(default: "de"), "de")
        XCTAssertEqual(t.segments.map(\.text), ["Hello.", "World."])
    }

    /// 訳を全部外すと、監査の直しが覚えている直す前の区間の訳も外れる (直しを元に戻しても、前の言語の訳が戻らない)
    func testRemovingAllTranslationsAlsoClearsTheAuditSnapshots() {
        var t = Transcript(sourceName: "a", segments: [seg(0, "Hello."), seg(3, "Um um um."), seg(6, "World.")], language: "en")
        t.segments[0].translation = "こんにちは。"
        t.segments[1].translation = "えーと。"
        t.segments[2].translation = "世界。"
        t.translationLanguage = "ja"
        let fix = AuditChange(kind: .fix, origin: .rule, original: t.segments[0], replacement: "Hullo.", reason: "r", isConfident: true)
        let delete = AuditChange(kind: .delete, origin: .rule, original: t.segments[1], reason: "r", isConfident: true)
        t.adopt(AuditReport(changes: [fix, delete], model: nil, reviewedCount: 3))
        XCTAssertEqual(t.segments.count, 2)
        t.removeAllTranslations()
        t.translationLanguage = "en"
        XCTAssertTrue(t.audit?.changes.allSatisfy { $0.original.translation == nil && $0.original.translationCovers == nil } ?? false)
        func noTranslation(_ step: String) {
            XCTAssertTrue(t.segments.allSatisfy { $0.translation == nil }, step)
        }
        t.setChange(fix.id, applied: false)
        noTranslation("fix turned off")
        t.setChange(delete.id, applied: false)
        noTranslation("delete turned off")
        XCTAssertEqual(t.segments.count, 3)
        t.setChange(fix.id, applied: true)
        t.setChange(delete.id, applied: true)
        t.revertAllChanges()
        noTranslation("revert all")
        // 監査をやり直して、前の直しが出なかった
        t.adopt(AuditReport(changes: [], model: nil, reviewedCount: 3))
        noTranslation("audit again")
        XCTAssertEqual(t.segments.map(\.text), ["Hello.", "Um um um.", "World."])
    }

    /// 訳が 1 つも無いのに残った訳す先の記録 (訳し直しを中止した) は外し、設定の言語に戻す
    func testClearingAPendingTranslationLanguage() {
        var t = Transcript(sourceName: "a", segments: [seg(0, "Hello.")], language: "en")
        t.translationLanguage = "fr"
        XCTAssertTrue(t.clearTranslationLanguageIfUntranslated())
        XCTAssertNil(t.translationLanguage)
        XCTAssertEqual(t.translationTarget(default: "de"), "de")
        XCTAssertFalse(t.clearTranslationLanguageIfUntranslated())
        // 訳が在る時は外さない
        t.segments[0].translation = "Bonjour."
        t.translationLanguage = "fr"
        XCTAssertFalse(t.clearTranslationLanguageIfUntranslated())
        XCTAssertEqual(t.translationLanguage, "fr")
    }

    /// 行の「訳」: 訳の無い結果は、文を頼んだ時の言語で訳す (頼んでから訳し始めるまでに設定の言語が変わっても変えない。
    /// 文の選び方も、その言語で決めてある)。待ちに文が在る間に頼んだ文も、待っている言語にそろえる。
    /// 訳の在る結果は、今までと同じく、その結果の言語
    func testLineTranslationUsesTheLanguageChosenAtTheClick() {
        var t = Transcript(sourceName: "a", segments: [seg(0, "Hello."), seg(2, "World.")], language: "en")
        // 押した時: 待ちは空、設定は fr
        let atClick = t.lineTranslationTarget(queued: nil, default: "fr")
        XCTAssertEqual(atClick, "fr")
        // 訳し始める時: 設定は de に変わった。頼んだ時の fr で訳す
        XCTAssertEqual(t.lineTranslationTarget(queued: atClick, default: "de"), "fr")
        // 待ちに文が在る間に、設定を de にしてから別の文を押した: 待っている fr にそろえる
        XCTAssertEqual(t.lineTranslationTarget(queued: "fr", default: "de"), "fr")
        // 訳の在る結果は、その結果の言語 (頼んだ時の言語・設定の言語より先)
        t.segments[0].translation = "Hallo."
        t.translationLanguage = "de"
        XCTAssertEqual(t.lineTranslationTarget(queued: "fr", default: "es"), "de")
        XCTAssertEqual(t.lineTranslationTarget(queued: nil, default: "es"), "de")
        // 言語の記録の無い古い結果の訳は日本語
        t.translationLanguage = nil
        XCTAssertEqual(t.lineTranslationTarget(queued: "fr", default: "es"), "ja")
    }

    /// 中国語の訳の「・」「ー」と、句読点だけ違う写しは、捨てない
    func testPlausibilityIgnoresKanaMarksAndPunctuationOnlyCopies() {
        XCTAssertTrue(Translator.isPlausible("史蒂夫・乔布斯", source: "スティーブ・ジョブズ", target: "zh"))
        XCTAssertTrue(Translator.isPlausible("史蒂夫·乔布斯", source: "スティーブ・ジョブズ", target: "zh"))
        XCTAssertTrue(Translator.isPlausible("咖啡ー杯", source: "コーヒー一杯", target: "zh"))
        XCTAssertFalse(Translator.isPlausible("これは日本語です", source: "This is Japanese.", target: "zh"))
        XCTAssertFalse(Translator.isPlausible("スーパー", source: "Supermarket", target: "zh"))
        XCTAssertTrue(Translator.isPlausible("NVIDIA", source: "NVIDIA.", target: "ko"))
        XCTAssertTrue(Translator.isPlausible("Hello there", source: "Hello there!", target: "ko"))
        XCTAssertTrue(Translator.isPlausible("Roblox Studio", source: "Roblox Studio!", target: "th"))
        XCTAssertFalse(Translator.isPlausible("Bonjour", source: "Hello", target: "ko"))
        XCTAssertFalse(Translator.isPlausible("Hello", source: "Hello there", target: "ru"))
    }

    func testOldJSONHasNoTranslationLanguage() throws {
        let old = #"{"sourceName":"a","segments":[],"duration":1,"elapsed":0,"translationModel":"m"}"#
        let t = try JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        XCTAssertNil(t.translationLanguage)
        var withLanguage = t
        withLanguage.translationLanguage = "ko"
        let back = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(withLanguage))
        XCTAssertEqual(back.translationLanguage, "ko")
        XCTAssertEqual(back, withLanguage)
        XCTAssertFalse(Exporter.json(t).contains("translationLanguage"), "not written when unset")
    }

    // MARK: 書き出し

    private func englishResult() -> Transcript {
        var t = Transcript(sourceName: "talk", segments: [seg(0, "こんにちは。"), seg(2, "Already English.", language: "en")],
                           language: "ja", model: "m", duration: 4, elapsed: 1)
        t.segments[0].translation = "Hello."
        t.translationModel = "Qwen3.5 4B"
        t.translationLanguage = "en"
        return t
    }

    func testExportForEnglishTarget() {
        L10n.language = .en
        XCTAssertEqual(ExportContent.translation.displayName(target: "en"), "English translation")
        XCTAssertEqual(ExportContent.bilingual.displayName(target: "en"), "Bilingual (original + English)")
        XCTAssertEqual(ExportContent.translation.displayName(target: "ja"), "Japanese translation")
        XCTAssertEqual(ExportContent.original.displayName(target: "en"), "Original")
        XCTAssertEqual(ExportContent.translation.fileSuffix(target: "en"), ".en")
        XCTAssertEqual(ExportContent.translation.fileSuffix(target: "ja"), ".ja")
        XCTAssertEqual(ExportContent.bilingual.fileSuffix(target: "en"), ".bilingual")
        XCTAssertEqual(ExportContent.original.fileSuffix(target: "en"), "")
        let t = englishResult()
        // 訳した言語は、結果の記録から取る
        let csv = Exporter.csv(t, content: .bilingual)
        XCTAssertEqual(csv, "start,end,text,translation\n0.000,2.000,\"こんにちは。\",\"Hello.\"\n"
                       + "2.000,4.000,\"Already English.\",\"Already English.\"\n")
        let md = Exporter.markdown(t, content: .bilingual)
        XCTAssertTrue(md.contains("| Time | Original | English translation |"), md)
        XCTAssertEqual(Exporter.txt(t, content: .translation), "Hello.\nAlready English.\n")
        // 渡した言語が先
        XCTAssertTrue(Exporter.csv(t, content: .bilingual, target: "ja").hasPrefix("start,end,text,japanese\n"))
        XCTAssertTrue(Exporter.render(t, as: .md, content: .bilingual, target: "ja").contains("| Time | Original | Japanese translation |"))
    }

    func testJapaneseExportNamesStayTheSame() {
        L10n.language = .ja
        XCTAssertEqual(ExportContent.translation.displayName(target: "ja"), "日本語訳")
        XCTAssertEqual(ExportContent.bilingual.displayName(target: "ja"), "対訳 (原文 + 日本語)")
        XCTAssertEqual(ExportContent.translation.displayName(target: "en"), "英語訳")
        let t = Transcript(sourceName: "a", segments: [seg(0, "Hello.")], language: "en")
        XCTAssertTrue(Exporter.markdown(t, content: .bilingual).contains("| 時刻 | 原文 | 日本語訳 |"))
    }

    // MARK: 一覧の行

    func testRowsFollowTheTarget() {
        let job = UUID()
        let t = Transcript(sourceName: "a", segments: [seg(0, "こんにちは。"), seg(2, "Hello.", language: "en")], language: "ja",
                           duration: 4)
        let cache = TranscriptRowCache()
        let ja = cache.items(of: t, job: job, done: true, bilingual: false, query: "")
        XCTAssertEqual(ja.map(\.canTranslate), [false, true])
        XCTAssertFalse(cache.lastItemsWasAppend)
        _ = cache.items(of: t, job: job, done: true, bilingual: false, query: "", target: "ja")
        let en = cache.items(of: t, job: job, done: true, bilingual: false, query: "", target: "en")
        XCTAssertEqual(en.map(\.canTranslate), [true, false], "the Japanese line can be translated into English")
        XCTAssertNotEqual(ja, en, "a different target builds the rows again")
        let bilingual = cache.items(of: t, job: job, done: true, bilingual: true, query: "", target: "en")
        XCTAssertEqual(bilingual.map(\.translation), [nil, "Hello."])
        XCTAssertEqual(bilingual.map(\.isOriginalInTarget), [false, true])
        XCTAssertEqual(bilingual.map(\.canTranslate), [true, false])
        // 翻訳の状況も訳す先ごと
        XCTAssertEqual(cache.summary(of: t, job: job, done: true).stats.translatable, 1)
        XCTAssertEqual(cache.summary(of: t, job: job, done: true, target: "en").stats.translatable, 1)
        let japaneseOnly = Transcript(sourceName: "b", segments: [seg(0, "こんにちは。")], language: "ja")
        XCTAssertEqual(cache.summary(of: japaneseOnly, job: job, done: true).stats.translatable, 0)
        XCTAssertEqual(cache.summary(of: japaneseOnly, job: job, done: true, target: "en").stats.translatable, 1)
    }

    func testRecordedLanguageChangeRebuildsRows() {
        let job = UUID()
        var t = Transcript(sourceName: "a", segments: [seg(0, "Hello.")], language: "en", duration: 10)
        let cache = TranscriptRowCache()
        _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        t.translationLanguage = "fr"
        t.segments.append(seg(2, "World."))
        _ = cache.items(of: t, job: job, done: false, bilingual: false, query: "")
        XCTAssertFalse(cache.lastItemsWasAppend, "the recorded language changed, so it is not only an append")
    }

    // MARK: 練習の隠し方

    func testHiddenTextFollowsTheTarget() {
        XCTAssertFalse(HiddenText.canHide(.source, language: "ja"))
        XCTAssertTrue(HiddenText.canHide(.source, language: "ja", target: "en"))
        XCTAssertFalse(HiddenText.canHide(.source, language: "en", target: "en"))
        XCTAssertTrue(HiddenText.hidesSource(.source, language: "ja", revealed: false, target: "en"))
        XCTAssertTrue(HiddenText.hidesTranslation(.sourceAndTranslation, language: nil, revealed: false, target: "en"))
        XCTAssertFalse(HiddenText.hidesTranslation(.sourceAndTranslation, language: "en", revealed: false, target: "en"))
        XCTAssertTrue(HiddenText.isInTarget(language: "ja"))
        XCTAssertFalse(HiddenText.isInTarget(language: "ja", target: "ko"))
    }
}
