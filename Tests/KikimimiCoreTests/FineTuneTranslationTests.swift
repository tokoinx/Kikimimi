import Foundation
import XCTest
@testable import KikimimiCore

/// 追加学習 (U7): 差分を監査用と翻訳用に分ける・翻訳の学習の例を訳の記憶から作る
final class FineTuneTranslationTests: XCTestCase {
    // MARK: 差分の置き場

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kikimimi-adapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// GGUF の印 (先頭 4 バイト) と、小さすぎない大きさを持つ、偽の差分のファイル
    private func fakeAdapter(in directory: URL, name: String, fill: UInt8) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(ModelFile.ggufMagic + [UInt8](repeating: fill, count: 2_000)).write(to: url)
        return url
    }

    func testAdapterFileNamesAreSeparatedByKind() {
        let files = AdapterFiles(directory: URL(fileURLWithPath: "/tmp/Adapters"))
        XCTAssertEqual(files.url(forModelKey: "qwen3.5-4b", kind: .audit).lastPathComponent, "qwen3.5-4b.lora.gguf")
        XCTAssertEqual(files.url(forModelKey: "qwen3.5-4b", kind: .translation).lastPathComponent,
                       "qwen3.5-4b.translation.lora.gguf")
        // 名前に使えない文字は、前と同じく「-」にする
        XCTAssertEqual(files.url(forModelKey: "a/b:c", kind: .translation).lastPathComponent, "a-b-c.translation.lora.gguf")
    }

    func testInstallAndRemoveTouchOnlyTheirKind() throws {
        let root = try temporaryDirectory()
        let files = AdapterFiles(directory: root.appendingPathComponent("Adapters"))
        let audit = try fakeAdapter(in: root, name: "audit.lora.gguf", fill: 1)
        let translation = try fakeAdapter(in: root, name: "translation.lora.gguf", fill: 2)
        XCTAssertFalse(files.has(forModelKey: "m", kind: .audit))
        XCTAssertFalse(files.has(forModelKey: "m", kind: .translation))

        try files.install(from: audit, forModelKey: "m", kind: .audit)
        XCTAssertTrue(files.has(forModelKey: "m", kind: .audit))
        XCTAssertFalse(files.has(forModelKey: "m", kind: .translation))

        try files.install(from: translation, forModelKey: "m", kind: .translation)
        XCTAssertTrue(files.has(forModelKey: "m", kind: .translation))
        XCTAssertEqual(try Data(contentsOf: files.url(forModelKey: "m", kind: .translation)), try Data(contentsOf: translation))
        XCTAssertEqual(try Data(contentsOf: files.url(forModelKey: "m", kind: .audit)), try Data(contentsOf: audit))

        // 入れ替え: 同じ種類の置き場だけが変わる
        try files.install(from: audit, forModelKey: "m", kind: .translation)
        XCTAssertEqual(try Data(contentsOf: files.url(forModelKey: "m", kind: .translation)), try Data(contentsOf: audit))

        // 外す: その種類だけ
        try files.remove(forModelKey: "m", kind: .translation)
        XCTAssertFalse(files.has(forModelKey: "m", kind: .translation))
        XCTAssertTrue(files.has(forModelKey: "m", kind: .audit))
        try files.remove(forModelKey: "m", kind: .audit)
        XCTAssertFalse(files.has(forModelKey: "m", kind: .audit))
        // 無い物を外しても失敗しない
        XCTAssertNoThrow(try files.remove(forModelKey: "m", kind: .audit))
        // 置き場に、写す途中のファイルが残っていない
        let left = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        XCTAssertEqual(left, [])
    }

    func testAuditGetsAuditAdapterAndTranslationGetsOnlyTranslationAdapter() {
        func url(_ kind: AdapterKind) -> URL { URL(fileURLWithPath: "/a/m" + kind.fileSuffix) }
        let both: Set<AdapterKind> = [.audit, .translation]
        XCTAssertEqual(AdapterFiles.activePath(for: .audit, enabled: true, installed: both, url: url), "/a/m.lora.gguf")
        XCTAssertEqual(AdapterFiles.activePath(for: .translation, enabled: true, installed: both, url: url),
                       "/a/m.translation.lora.gguf")
        // 翻訳用が無い時、翻訳は差分なし (監査用を渡さない)
        XCTAssertNil(AdapterFiles.activePath(for: .translation, enabled: true, installed: [.audit], url: url))
        XCTAssertEqual(AdapterFiles.activePath(for: .audit, enabled: true, installed: [.audit], url: url), "/a/m.lora.gguf")
        // 監査用が無い時、監査は差分なし (翻訳用を渡さない)
        XCTAssertNil(AdapterFiles.activePath(for: .audit, enabled: true, installed: [.translation], url: url))
        // 使う設定が切なら、どちらも渡さない
        XCTAssertNil(AdapterFiles.activePath(for: .audit, enabled: false, installed: both, url: url))
        XCTAssertNil(AdapterFiles.activePath(for: .translation, enabled: false, installed: both, url: url))
    }

    // MARK: 翻訳の学習の例

    private func entry(_ source: String, _ translation: String, target: String = "ja", language: String? = "en",
                       heldOut: Bool = false) -> RememberedTranslation {
        RememberedTranslation(source: source, sourceLanguage: language, target: target, translation: translation, heldOut: heldOut)
    }

    func testSingleRecordMatchesTheAppPromptExactly() {
        let memory = TranslationMemory(sentences: [entry("The cat sat on the mat.", "猫がマットに座った。")])
        let training = FineTuneData.translationRecords(memories: [memory], detector: nil)
        XCTAssertEqual(training.records.count, 1)
        let m = training.records[0].messages
        let shots = TranslationExamples.examples(for: "ja")
        XCTAssertFalse(shots.isEmpty)
        // system・(手本の user・assistant) × 手本の数・問い・答え
        XCTAssertEqual(m.map(\.role), ["system"] + shots.flatMap { _ in ["user", "assistant"] } + ["user", "assistant"])
        XCTAssertEqual(m[0].content, Translator.systemPrompt(language: "en", target: "ja"))
        XCTAssertEqual(m[1].content, shots[0].user)
        XCTAssertEqual(m[2].content, shots[0].assistant)
        XCTAssertEqual(m[m.count - 2].content, Translator.userPrompt(lines: ["The cat sat on the mat."], context: [], glossary: nil))
        XCTAssertEqual(m.last?.content, "[1] 猫がマットに座った。\n")
    }

    /// アプリが翻訳で LLM に送る会話 (`Translator.checkedTranslateLines` が作る LLMPrompt の system・手本・user) と、
    /// 学習の例の、最後の答えより前が同じ (訳す先・行の数・訳語の対を変えて見る)
    func testRecordsMatchTheConversationTheAppSends() throws {
        let pair = TermPair(source: "hostile fire", translation: "敵の攻撃", target: "ja")
        var sentences: [RememberedTranslation] = []
        for target in ["ja", "th", "ru", "en", "zh"] {
            let language = target == "en" ? "ja" : "en"
            for k in 1...4 {
                let source = target == "en" ? "日本語の文 \(k) です (\(target))。" : "We came under hostile fire, line \(k) for \(target)."
                sentences.append(entry(source, "訳 \(target) \(k)", target: target, language: language))
            }
        }
        let training = FineTuneData.translationRecords(memories: [TranslationMemory(sentences: sentences, terms: [pair])],
                                                       detector: nil)
        // 1 行の例 4 + まとめた例 2 (2 行・2 行)
        XCTAssertEqual(training.records.count, 5 * (4 + 2))
        for record in training.records {
            let m = record.messages
            let lines = m[m.count - 2].content.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return String(line[line.index(close, offsetBy: 2)...])
            }
            let target = sentences.first { $0.source == lines[0] }?.target ?? "?"
            let language = target == "en" ? "ja" : "en"
            // アプリは、訳す先の訳語の対だけを渡す (`TranslationMemory.lookup(target:)`)
            let fake = FakeGenerator { _ in "" }
            _ = try Translator.checkedTranslateLines(lines, context: [], language: language, target: target,
                                                     system: Translator.systemPrompt(language: language, target: target),
                                                     options: TranslationOptions(), terms: target == "ja" ? [pair] : [], generator: fake,
                                                     shouldCancel: { false })
            let prompt = try XCTUnwrap(fake.prompts.first)
            var sent = [FineTuneData.Message(role: "system", content: prompt.system)]
            for example in prompt.examples {
                sent.append(FineTuneData.Message(role: "user", content: example.user))
                sent.append(FineTuneData.Message(role: "assistant", content: example.assistant))
            }
            sent.append(FineTuneData.Message(role: "user", content: prompt.user))
            XCTAssertEqual(Array(m.dropLast()), sent, "target \(target), \(lines.count) lines")
            XCTAssertEqual(m.last?.role, "assistant")
        }
    }

    func testHeldOutSentencesAreNeverUsedEvenFromAnotherMemory() {
        let user = TranslationMemory(sentences: [
            entry("First sentence here.", "一つ目。"),
            entry("Held out sentence.", "取り分け。", heldOut: true),
        ])
        // 見立ての記憶に、同じ文が取り分けでなく在っても使わない
        let other = TranslationMemory(sentences: [entry("Held  out sentence.", "別の訳。")])
        let training = FineTuneData.translationRecords(memories: [user, other], detector: nil)
        let all = training.records.flatMap(\.messages).map(\.content).joined(separator: "\n")
        XCTAssertFalse(all.contains("Held out"))
        XCTAssertFalse(all.contains("取り分け"))
        XCTAssertEqual(training.heldOut, 1)
        XCTAssertEqual(training.records.count, 1)
    }

    func testBatchedRecordsAreNumberedAndEachSentenceIsUsedAtMostTwice() {
        // en → ja を 6 文、en → de を 1 文
        let ja = (1...6).map { entry("Sentence number \($0).", "文 \($0)。") }
        let memory = TranslationMemory(sentences: ja + [entry("Only one for German.", "Nur einer.", target: "de")])
        let training = FineTuneData.translationRecords(memories: [memory], detector: nil)
        // ja: 1 行の例 6 + まとめた例 (2 行・3 行。残りの 1 行は、前のまとまりに足して 4 行) = 2。de: 1 行の例 1
        XCTAssertEqual(training.examplesByTarget, ["ja": 8, "de": 1])
        XCTAssertEqual(training.sentencesByTarget, ["ja": 6, "de": 1])
        XCTAssertEqual(training.records.count, 9)
        let batched = training.records.filter { $0.messages.last!.content.contains("[2] ") }
        XCTAssertEqual(batched.count, 2)
        XCTAssertEqual(batched[0].messages[batched[0].messages.count - 2].content,
                       Translator.userPrompt(lines: ["Sentence number 1.", "Sentence number 2."], context: [], glossary: nil))
        XCTAssertEqual(batched[0].messages.last?.content, "[1] 文 1。\n[2] 文 2。\n")
        XCTAssertEqual(batched[1].messages.last?.content, "[1] 文 3。\n[2] 文 4。\n[3] 文 5。\n[4] 文 6。\n")
        // 1 つの文は、1 行の例に 1 回、まとめた例に多くて 1 回
        for k in 1...6 {
            let uses = training.records.filter { $0.messages[$0.messages.count - 2].content.contains("Sentence number \(k).") }.count
            XCTAssertEqual(uses, 2)
        }
        // 訳す先の違う文は、まとめない。訳す先の指示文が付く
        let german = training.records.filter { $0.messages.last!.content.contains("Nur einer.") }
        XCTAssertEqual(german.count, 1)
        XCTAssertEqual(german[0].messages[0].content, Translator.systemPrompt(language: "en", target: "de"))
    }

    func testDifferentSourceLanguagesAreNotBatchedTogether() {
        let memory = TranslationMemory(sentences: [
            entry("English line one.", "英語 1。"),
            entry("日本語の文です。", "A Japanese line.", target: "en", language: "ja"),
            entry("English line two.", "英語 2。"),
        ])
        let training = FineTuneData.translationRecords(memories: [memory], detector: nil)
        let batched = training.records.filter { $0.messages.last!.content.contains("[2] ") }
        XCTAssertEqual(batched.count, 1)
        XCTAssertEqual(batched[0].messages.last?.content, "[1] 英語 1。\n[2] 英語 2。\n")
        let ja = training.records.first { $0.messages.last!.content.contains("A Japanese line.") }
        XCTAssertEqual(ja?.messages[0].content, Translator.systemPrompt(language: "ja", target: "en"))
    }

    func testSourceLanguageFallsBackToDetectorThenEnglish() {
        let memory = TranslationMemory(sentences: [entry("Bonjour tout le monde.", "皆さん、こんにちは。", language: nil)])
        let detected = FineTuneData.translationRecords(memories: [memory], detector: { _ in "fr" })
        XCTAssertEqual(detected.records[0].messages[0].content, Translator.systemPrompt(language: "fr", target: "ja"))
        let unknown = FineTuneData.translationRecords(memories: [memory], detector: { _ in nil })
        XCTAssertEqual(unknown.records[0].messages[0].content, Translator.systemPrompt(language: "en", target: "ja"))
    }

    func testTermsAppearOnlyForLinesThatContainThem() {
        let pair = TermPair(source: "hostile fire", translation: "敵の攻撃", target: "ja")
        let memory = TranslationMemory(sentences: [
            entry("We came under hostile fire.", "敵の攻撃を受けた。"),
            entry("Nothing special here.", "特に何もない。"),
        ], terms: [pair])
        let training = FineTuneData.translationRecords(memories: [memory], detector: nil)
        let withTerm = training.records.first { $0.messages[$0.messages.count - 2].content == Translator.userPrompt(
            lines: ["We came under hostile fire."], context: [], glossary: nil, terms: [pair]) }
        XCTAssertNotNil(withTerm)
        XCTAssertTrue(withTerm?.messages.dropLast().last?.content.contains("Terms (always translate the left as the right):\nhostile fire => 敵の攻撃") == true)
        let without = training.records.first { $0.messages.last!.content == "[1] 特に何もない。\n" }
        XCTAssertEqual(without?.messages.dropLast().last?.content,
                       Translator.userPrompt(lines: ["Nothing special here."], context: [], glossary: nil))
        // まとめた例には、行に出る対が付く
        let batched = training.records.first { $0.messages.last!.content.contains("[2] ") }
        XCTAssertTrue(batched?.messages.dropLast().last?.content.contains("hostile fire => 敵の攻撃") == true)
        // 訳語の対は、別の記憶に在っても使う (足し合わせる)
        let split = FineTuneData.translationRecords(
            memories: [TranslationMemory(sentences: memory.sentences), TranslationMemory(terms: [pair])], detector: nil)
        XCTAssertEqual(split.records.map(\.messages), training.records.map(\.messages))
    }

    func testJSONLinesShape() throws {
        let memory = TranslationMemory(sentences: [entry("Line\nwith a break.", "改行の\nある訳。")])
        let training = FineTuneData.translationRecords(memories: [memory], detector: nil)
        let text = FineTuneData.jsonl(training.records)
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any]
        let messages = object?["messages"] as? [[String: String]]
        // 1 行に収める (改行は空白に)
        XCTAssertEqual(messages?.last?["content"], "[1] 改行の ある訳。\n")
        XCTAssertTrue(messages?.dropLast().last?["content"]?.hasSuffix("[1] Line with a break.") == true)
    }
}
