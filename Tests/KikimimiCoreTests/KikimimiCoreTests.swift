import XCTest
@testable import KikimimiCore

final class TimeFormatTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(TimeFormat.srt(61.25), "00:01:01,250")
        XCTAssertEqual(TimeFormat.vtt(3725.5), "01:02:05.500")
        XCTAssertEqual(TimeFormat.short(59), "00:59")
        XCTAssertEqual(TimeFormat.short(3725), "1:02:05")
        XCTAssertEqual(TimeFormat.srt(-1), "00:00:00,000")
        XCTAssertEqual(TimeFormat.bytes(574_000_000), "574 MB")
        XCTAssertEqual(TimeFormat.bytes(1_620_000_000), "1.6 GB")
    }
}

final class ExporterTests: XCTestCase {
    private func sample() -> Transcript {
        Transcript(sourceName: "会議",
                   segments: [TranscriptSegment(start: 0, end: 1.5, text: "こんにちは"),
                              TranscriptSegment(start: 61.25, end: 3725.5, text: "さよう\"なら")],
                   language: "ja", model: "large-v3-turbo-q5_0", duration: 3726, elapsed: 10)
    }

    func testSRT() {
        let s = Exporter.srt(sample())
        XCTAssertTrue(s.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nこんにちは\n"))
        XCTAssertTrue(s.contains("2\n00:01:01,250 --> 01:02:05,500\nさよう\"なら"))
    }

    func testVTT() {
        XCTAssertTrue(Exporter.vtt(sample()).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nこんにちは"))
    }

    func testTxtMdCsvJson() {
        let t = sample()
        XCTAssertEqual(Exporter.txt(t), "こんにちは\nさよう\"なら\n")
        XCTAssertEqual(t.text(withTimestamps: true), "[00:00] こんにちは\n[01:01] さよう\"なら")
        let md = Exporter.markdown(t)
        XCTAssertTrue(md.hasPrefix("# 会議\n\n言語: 日本語 / 長さ: 1:02:06 / モデル: large-v3-turbo-q5_0\n"), md)
        XCTAssertTrue(md.contains("- **01:01** さよう\"なら"))
        let csv = Exporter.csv(t)
        XCTAssertEqual(csv.split(separator: "\n")[0], "start,end,text")
        XCTAssertTrue(csv.contains("61.250,3725.500,\"さよう\"\"なら\""))
        let json = Exporter.json(t)
        XCTAssertTrue(json.contains("\"sourceName\" : \"会議\""))
        let decoded = try? JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.segments.count, 2)
        XCTAssertEqual(decoded?.language, "ja")
        XCTAssertEqual(t.realTimeFactor.map { ($0 * 1000).rounded() / 1000 }, 0.003)
        XCTAssertNil(Transcript(sourceName: "x").realTimeFactor)
    }
}

final class CatalogTests: XCTestCase {
    func testCatalog() {
        XCTAssertEqual(ModelCatalog.all.filter(\.recommended).map(\.id), [ModelCatalog.defaultModelID])
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        let turbo = ModelCatalog.spec(id: "large-v3-turbo-q5_0")
        XCTAssertEqual(turbo?.fileName, "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(turbo?.downloadURL.absoluteString,
                       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(ModelCatalog.vadURL.lastPathComponent, ModelCatalog.vadFileName)
        XCTAssertNil(ModelCatalog.spec(id: "nope"))
    }

    func testLanguages() {
        XCTAssertEqual(Languages.all.first?.code, "auto")
        XCTAssertEqual(Languages.name(for: "ja"), "日本語")
        XCTAssertEqual(Languages.name(for: "xx"), "xx")
        XCTAssertEqual(Languages.name(for: nil), "—")
        XCTAssertTrue(Languages.isKnown("en"))
    }

    func testModelFileValidation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.bin")
        var bytes: [UInt8] = [0x6c, 0x6d, 0x67, 0x67]
        bytes += [UInt8](repeating: 1, count: 200_000)
        try Data(bytes).write(to: good)
        XCTAssertTrue(ModelFile.isValidModel(at: good))
        XCTAssertFalse(ModelFile.isValidModel(at: good, minimumBytes: 10_000_000))
        let html = dir.appendingPathComponent("html.bin")
        try Data(("<html>" + String(repeating: "x", count: 200_000)).utf8).write(to: html)
        XCTAssertFalse(ModelFile.isValidModel(at: html))
        XCTAssertFalse(ModelFile.isValidModel(at: dir.appendingPathComponent("missing.bin")))
    }
}

final class HallucinationFilterTests: XCTestCase {
    func testDropsStockPhrasesOnlyWhenLikelySilence() {
        XCTAssertTrue(HallucinationFilter.shouldDrop(text: "ご視聴ありがとうございました。", noSpeechProbability: 0.6))
        XCTAssertFalse(HallucinationFilter.shouldDrop(text: "ご視聴ありがとうございました。", noSpeechProbability: 0.01))
        XCTAssertTrue(HallucinationFilter.shouldDrop(text: " Thank you for watching! ", noSpeechProbability: 0.3))
        XCTAssertFalse(HallucinationFilter.shouldDrop(text: "今日はご視聴ありがとうございました、では本題です", noSpeechProbability: 0.9))
    }

    func testDropsNoiseOnly() {
        XCTAssertTrue(HallucinationFilter.shouldDrop(text: "♪", noSpeechProbability: 0))
        XCTAssertTrue(HallucinationFilter.shouldDrop(text: "(音楽)", noSpeechProbability: 0))
        XCTAssertTrue(HallucinationFilter.shouldDrop(text: "【拍手】", noSpeechProbability: 0))
        XCTAssertTrue(HallucinationFilter.shouldDrop(text: "  ", noSpeechProbability: 0))
        XCTAssertFalse(HallucinationFilter.shouldDrop(text: "(笑) それは面白いですね", noSpeechProbability: 0))
        XCTAssertFalse(HallucinationFilter.shouldDrop(text: "はい。", noSpeechProbability: 0.5))
    }
}

final class WAVTests: XCTestCase {
    func testRoundTrip() throws {
        let samples: [Float] = (0..<16000).map { sinf(Float($0) * 2 * .pi * 440 / 16000) * 0.5 }
        let data = WAV.encode(samples: samples, sampleRate: 16000)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        let (decoded, rate) = try WAV.decode(data)
        XCTAssertEqual(rate, 16000)
        XCTAssertEqual(decoded.count, samples.count)
        for i in stride(from: 0, to: samples.count, by: 997) {
            XCTAssertEqual(decoded[i], samples[i], accuracy: 1.0 / 16000)
        }
        XCTAssertThrowsError(try WAV.decode(Data("not a wav".utf8)))
    }

    func testClipping() throws {
        let (decoded, _) = try WAV.decode(WAV.encode(samples: [2, -2, 0], sampleRate: 8000))
        XCTAssertEqual(decoded[0], 32767.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(decoded[1], -32767.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(decoded[2], 0)
    }

    func testCancelFlag() {
        let f = CancelFlag()
        XCTAssertFalse(f.isSet)
        f.set()
        XCTAssertTrue(f.isSet)
    }
}

final class RepetitionFilterTests: XCTestCase {
    private func segs(_ texts: [String]) -> [TranscriptSegment] {
        texts.enumerated().map { TranscriptSegment(start: Double($0.offset) * 2, end: Double($0.offset) * 2 + 2, text: $0.element) }
    }

    func testCollapsesRunawayRunsLikeTheLectureRecording() {
        // 講演の録音で実際に起きた形: 同じ文が数百回つづき、句読点だけ違う文に移ってまた続く
        var texts: [String] = ["はい、どういう意味になるのか?"]
        texts += Array(repeating: "どういう意味になるのか?", count: 45)
        texts += Array(repeating: "自分の意味になるのか?", count: 70)
        texts += Array(repeating: "自分の意味になるか?", count: 121)
        texts += ["全ての意味になるか?"]
        texts += Array(repeating: "自分の意味になるか?", count: 486)
        texts += ["若いですか?", "年取ってますか?"]
        let out = RepetitionFilter.clean(segs(texts)).map(\.text)
        XCTAssertEqual(out, ["はい、どういう意味になるのか?", "どういう意味になるのか?", "自分の意味になるのか?",
                             "自分の意味になるか?", "全ての意味になるか?", "自分の意味になるか?",
                             "若いですか?", "年取ってますか?"])
    }

    func testKeepsGenuineRepetition() {
        // 実際に 3 回言った言葉や、句読点違いの短い相づちは残す
        let texts = ["please help help help", "help each other", "help each other", "help each other", "はい", "はい。", "次へ"]
        XCTAssertEqual(RepetitionFilter.clean(segs(texts)).map(\.text), texts)
    }

    func testCollapsesAlternatingLoops() {
        var texts: [String] = ["how does this fit"]
        for _ in 0..<6 { texts += ["what is the view", "of you"] }
        texts += ["それの過去の教育で"]
        XCTAssertEqual(RepetitionFilter.clean(segs(texts)).map(\.text),
                       ["how does this fit", "what is the view", "of you", "それの過去の教育で"])
        // 2 周までは残す
        let two = ["A です", "B です", "A です", "B です", "C です"]
        XCTAssertEqual(RepetitionFilter.clean(segs(two)).map(\.text), two)
    }

    func testCollapsesRepeatsInsideOneSegment() {
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("音楽の音楽の音楽の音楽の音楽の音楽の"), "音楽の")
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("そういめは、チャイニーズレて、チャイニーズレて、チャイニーズレて、チャイニーズレて、終わり"),
                       "そういめは、チャイニーズレて、終わり")
        // 2 文字の繰り返し (どんどんどんどん) や 3 回までの繰り返しはそのまま
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("どんどんどんどん強める"), "どんどんどんどん強める")
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("20世紀の20世紀の20世紀の世界"), "20世紀の20世紀の20世紀の世界")
        // 数字や記号だけの繰り返しは縮めない (金額・数値が変わってしまうため)
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("予算は1,000,000,000,000円です"), "予算は1,000,000,000,000円です")
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("番号は100000000000000です"), "番号は100000000000000です")
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("......... と ーーーーーーーーーーーー"), "......... と ーーー")
        // 数字の繰り返しの後ろにある、文字の繰り返しはまとめる
        XCTAssertEqual(RepetitionFilter.collapseInlineRepeats("0,000,000,000,000 dollars dollars dollars dollars "), "0,000,000,000,000 dollars ")
        // 中身が全部繰り返しだった区間は 1 回分になり、空にはならない
        XCTAssertEqual(RepetitionFilter.clean(segs(["塗装を塗装を塗装を塗装を塗装を"])).map(\.text), ["塗装を"])
    }

    func testStreamingShowsAtMostThreeInARow() {
        var stream = RepetitionFilter.Streaming()
        let shown = (0..<10).map { _ in stream.accept("自分の意味になるか?") }
        XCTAssertEqual(shown, [true, true, true, false, false, false, false, false, false, false])
        XCTAssertTrue(stream.accept("若いですか?"))
        XCTAssertTrue(stream.accept("自分の意味になるか?"))
    }

    func testTimestampsOfKeptSegmentsAreUnchanged() {
        var texts: [String] = ["A"]
        texts += Array(repeating: "B", count: 5)
        texts += ["C"]
        let input = segs(texts)
        let out = RepetitionFilter.clean(input)
        XCTAssertEqual(out.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(out[1].start, input[1].start)
        XCTAssertEqual(out[2].start, input[6].start)
    }
}
