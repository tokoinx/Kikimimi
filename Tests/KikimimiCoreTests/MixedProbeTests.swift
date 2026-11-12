import XCTest
@testable import KikimimiCore

/// 日本語と英語が混ざった録音かを、文字にする前に確かめる (MixedProbe) の試験。
/// 発話ごとの言語を持ち、台本どおりに答える whisper を使う
final class MixedProbeTests: XCTestCase {
    private func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }

    /// 台本どおりに答える whisper。判定は、範囲の発話のうち日本語の割合で決まる
    /// (どちらか一方だけなら 0.99、混ざっていれば割合のとおり。本物の turbo より素直)
    private final class ScriptEngine: MixedEngine {
        struct Utterance {
            var range: Range<Int>
            var language: String
        }

        let utterances: [Utterance]
        var useVAD = true
        var detections = 0
        var detectedRanges: [Range<Int>] = []
        var vadCalls = 0

        init(_ utterances: [Utterance]) {
            self.utterances = utterances
        }

        func speechMap(of samples: [Float]) throws -> SpeechMap? {
            vadCalls += 1
            guard useVAD else { return nil }
            return SpeechMap(spans: utterances.map(\.range), totalSamples: samples.count)
        }

        func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]? {
            detections += 1
            detectedRanges.append(range)
            var ja = 0, en = 0
            for u in utterances {
                let overlap = max(0, min(range.upperBound, u.range.upperBound) - max(range.lowerBound, u.range.lowerBound))
                if u.language == "ja" { ja += overlap } else { en += overlap }
            }
            guard ja + en > 0 else { return nil }
            var pja = Double(ja) / Double(ja + en)
            if pja == 1 { pja = 0.99 }
            if pja == 0 { pja = 0.01 }
            return candidates.map { $0 == "ja" ? Float(pja) : Float(1 - pja) }
        }

        func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                    onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment] {
            var out: [DecodedSegment] = []
            for u in utterances where u.range.overlaps(range) {
                let seconds = Double(u.range.count) / 16_000
                let text: String
                if language == "ja" {
                    text = String(repeating: u.language == "ja" ? "日本語の文です" : "英語を訳した", count: max(1, Int(seconds)))
                } else {
                    text = String(repeating: u.language == "en" ? "This is English. " : "nihongo ", count: max(1, Int(seconds)))
                        .trimmingCharacters(in: .whitespaces)
                }
                let segment = DecodedSegment(start: Double(u.range.lowerBound) / 16_000, end: Double(u.range.upperBound) / 16_000,
                                             text: text, tokenCount: 10, meanLogProb: -0.2, language: language)
                onSegment(segment)
                out.append(segment)
            }
            onProgress(1)
            return out
        }
    }

    /// 言語のまとまり (秒) を、5 秒の発話と 0.5 秒の間に分ける。まとまりとまとまりの間は 2 秒あける
    private func blocks(_ list: [(seconds: Double, language: String)]) -> (utterances: [ScriptEngine.Utterance], total: Int) {
        var out: [ScriptEngine.Utterance] = []
        var t = 0.5
        for block in list {
            let end = t + block.seconds
            while t + 1 < end {
                let length = min(5, end - t)
                out.append(.init(range: s(t)..<s(t + length), language: block.language))
                t += length + 0.5
            }
            t = end + 2
        }
        return (out, s(t + 1))
    }

    private func probe(_ list: [(seconds: Double, language: String)], preferred: String = "ja") throws -> MixedProbe.Result {
        let b = blocks(list)
        let engine = ScriptEngine(b.utterances)
        return try MixedProbe.run(samples: [Float](repeating: 0, count: b.total), engine: engine, preferred: preferred)
    }

    // MARK: - 1 つの言語の録音

    func testJapaneseOnlyIsNotMixed() throws {
        let r = try probe(Array(repeating: (27.0, "ja"), count: 40))
        XCTAssertEqual(r.decision, .notMixed)
        XCTAssertEqual(r.probes.count, MixedProbe.maxProbes)
        XCTAssertEqual(r.probeableChunks, 40)
        XCTAssertEqual(r.trusted["ja"], MixedProbe.maxProbes)
        XCTAssertNil(r.trusted["en"])
        XCTAssertEqual(r.majority, "ja")
        XCTAssertEqual(r.evidence, 0)
        XCTAssertTrue(r.candidates.isEmpty)
    }

    func testEnglishOnlyIsNotMixed() throws {
        let r = try probe(Array(repeating: (27.0, "en"), count: 10), preferred: "en")
        XCTAssertEqual(r.decision, .notMixed)
        XCTAssertEqual(r.probes.count, 10)
        XCTAssertEqual(r.trusted["en"], 10)
        XCTAssertEqual(r.majority, "en")
        XCTAssertEqual(r.evidence, 0)
    }

    // MARK: - 混ざった録音

    func testAlternatingBlocksAreMixed() throws {
        var list: [(seconds: Double, language: String)] = []
        for k in 0..<12 { list.append((27, k % 2 == 0 ? "en" : "ja")) }
        let r = try probe(list)
        XCTAssertEqual(r.decision, .mixed)
        XCTAssertEqual(r.trusted["ja"], 6)
        XCTAssertEqual(r.trusted["en"], 6)
        // 利用者の言語が先
        XCTAssertEqual(r.candidates, ["ja", "en"])
        XCTAssertEqual(try probe(list, preferred: "en").candidates, ["en", "ja"])
    }

    func testAutoPutsTheMajorityLanguageFirst() throws {
        // 英語 9 まとまり、日本語 3 まとまり (少ない側が 25%)
        var list: [(seconds: Double, language: String)] = []
        for k in 0..<12 { list.append((27, k % 4 == 1 ? "ja" : "en")) }
        let r = try probe(list, preferred: "auto")
        XCTAssertEqual(r.decision, .mixed)
        XCTAssertEqual(r.trusted["en"], 9)
        XCTAssertEqual(r.trusted["ja"], 3)
        XCTAssertEqual(r.majority, "en")
        XCTAssertEqual(r.evidence, 3)
        XCTAssertEqual(r.candidates, ["en", "ja"])
    }

    func testInterpreterTurnsInEveryChunkAreMixed() throws {
        // 英語の講師と日本語の通訳が 4 秒ずつ交代し (間 0.3 秒)、6 つの発話 (英語 3、日本語 3) ごとに 1 秒の間がある。
        // 区切りは 1 秒の間で分かれ、どの区切りにも両方の言語が半分ずつ入る。
        // どの判定も確かでなく (0.5)、どちらかの言語と信じられる区切りは 1 つも無いが、混ざっている
        var u: [ScriptEngine.Utterance] = []
        var t = 0.5
        for k in 0..<120 {
            u.append(.init(range: s(t)..<s(t + 4), language: k % 2 == 0 ? "en" : "ja"))
            t += k % 6 == 5 ? 5 : 4.3
        }
        let engine = ScriptEngine(u)
        let r = try MixedProbe.run(samples: [Float](repeating: 0, count: s(t + 1)), engine: engine, preferred: "ja")
        XCTAssertEqual(r.decision, .mixed, String(describing: r.probes))
        XCTAssertGreaterThanOrEqual(r.probes.count, 10)
        XCTAssertEqual(r.trustedCount, 0)
        XCTAssertTrue(r.probes.allSatisfy { ($0.confidence ?? 1) < 0.75 })
        XCTAssertEqual(r.evidence, r.probes.count)
        XCTAssertEqual(r.candidates, ["ja", "en"])
    }

    func testEnglishLectureWithShortJapaneseRemarksIsNotMixed() throws {
        // 英語の講義 (5 秒の発話と 0.3 秒の間) の 6 か所に、1〜3 秒の日本語の一言 (1, 2, 3, 1, 2, 3 秒)。
        // 1〜2 秒の一言は、前後の英語と同じ区切りに入るか、発話 3 秒未満の区切りになって確かめる区切りに入らない
        // (英語に混ざった区切りは、英語が多ければ英語。少し低い確からしさなら「信じられない」)。
        // 3 秒の一言は、それだけで 1 つの区切りになると、確かめる区切りに入り「信じられる日本語」になりうる。
        // ここでは均等に選んだ区切りに 1 つ入る (日本語 0.99)。英語の区切りに入った一言は、2 秒の一言と 5 秒の英語の区切り
        // (日本語 0.29) が「日本語がある区切り」になり、1 秒の一言の区切り (日本語 0.17、0.13) は数えない。
        // 日本語がある区切りは 24 個のうち 2 個 (8%、10% 未満) なので「混ざっていない」
        // (今までどおり「英語」で文字にする。一言を拾うには「日本語＋英語」を選ぶ。島として探す)。
        // 前の決まり (信じられる判定だけを数える) では 1 個だった。日本語がある区切りが多い録音 (2 個以上、かつ 10% 以上) なら
        // 「混ざっている」になる
        var u: [ScriptEngine.Utterance] = []
        var t = 0.5
        var remarks = 0
        for k in 0..<30 {
            u.append(.init(range: s(t)..<s(t + 5), language: "en"))
            t += 5.3
            if k % 5 == 2 {
                let length = 1.0 + Double(remarks % 3)
                u.append(.init(range: s(t)..<s(t + length), language: "ja"))
                t += length + 0.3
                remarks += 1
            }
        }
        XCTAssertEqual(remarks, 6)
        let engine = ScriptEngine(u)
        let r = try MixedProbe.run(samples: [Float](repeating: 0, count: s(t + 1)), engine: engine, preferred: "en")
        XCTAssertEqual(r.decision, .notMixed, String(describing: r.probes))
        XCTAssertEqual(r.trusted["ja"], 1)
        XCTAssertTrue(r.probes.filter { $0.detected == "ja" && $0.trusted }.allSatisfy { $0.speech >= 3 })
        XCTAssertGreaterThanOrEqual(r.trusted["en"] ?? 0, 4)
        XCTAssertEqual(r.majority, "en")
        XCTAssertEqual(r.detectedCount, 24)
        XCTAssertEqual(r.evidence, 2)
        XCTAssertLessThan(Double(r.evidence), MixedProbe.minEvidenceShare * Double(r.detectedCount))
    }

    // MARK: - 確かめない場合

    func testShortRecordingIsSkipped() throws {
        // 発話 3 秒以上の区切りが 3 つだけ (2 秒の発話だけの区切りは数えない)
        var u: [ScriptEngine.Utterance] = []
        for k in 0..<3 { u.append(.init(range: s(Double(k) * 40)..<s(Double(k) * 40 + 10), language: k == 1 ? "ja" : "en")) }
        u.append(.init(range: s(130)..<s(132), language: "ja"))
        let engine = ScriptEngine(u)
        let r = try MixedProbe.run(samples: [Float](repeating: 0, count: s(140)), engine: engine, preferred: "ja")
        XCTAssertEqual(r.decision, .skippedTooShort)
        XCTAssertEqual(r.probeableChunks, 3)
        XCTAssertEqual(engine.detections, 0)
    }

    func testWithoutVADIsSkipped() throws {
        let b = blocks([(27, "en"), (27, "ja"), (27, "en"), (27, "ja"), (27, "en")])
        let engine = ScriptEngine(b.utterances)
        engine.useVAD = false
        let r = try MixedProbe.run(samples: [Float](repeating: 0, count: b.total), engine: engine, preferred: "ja")
        XCTAssertEqual(r.decision, .skippedNoVAD)
        XCTAssertEqual(engine.detections, 0)
    }

    func testCancelStopsTheProbe() {
        let b = blocks(Array(repeating: (27.0, "ja"), count: 10))
        let engine = ScriptEngine(b.utterances)
        var calls = 0
        XCTAssertThrowsError(try MixedProbe.run(samples: [Float](repeating: 0, count: b.total), engine: engine,
                                                preferred: "ja", shouldCancel: {
                                                    calls += 1
                                                    return calls > 3
                                                })) { error in
            XCTAssertEqual(error as? MixedPipelineError, .cancelled)
        }
        XCTAssertLessThan(engine.detections, 10)
    }

    // MARK: - 決まりの境目

    private func probes(ja: Int, en: Int, untrusted: Int = 0, uncertain: Double = 0.6) -> [MixedProbe.Probe] {
        var out: [MixedProbe.Probe] = []
        for _ in 0..<ja { out.append(.init(start: 0, end: 1, speech: 5, detected: "ja", confidence: 0.99, trusted: true)) }
        for _ in 0..<en { out.append(.init(start: 0, end: 1, speech: 5, detected: "en", confidence: 0.99, trusted: true)) }
        for _ in 0..<untrusted {
            out.append(.init(start: 0, end: 1, speech: 5, detected: "ja", confidence: uncertain, trusted: false))
        }
        return out
    }

    func testMinorityThresholds() {
        func decide(ja: Int, en: Int, untrusted: Int = 0, probeable: Int = 24) -> MixedProbe.Decision {
            MixedProbe.decide(probes(ja: ja, en: en, untrusted: untrusted), probeableChunks: probeable, preferred: "ja").decision
        }
        // 2 個で、ちょうど 10%: 混ざっている
        XCTAssertEqual(decide(ja: 18, en: 2), .mixed)
        // 2 個でも 10% 未満 (2 / 21): 混ざっていない
        XCTAssertEqual(decide(ja: 19, en: 2), .notMixed)
        // 1 個だけ (割合は 20% でも): 混ざっていない
        XCTAssertEqual(decide(ja: 4, en: 1), .notMixed)
        // 確かでない判定 (日本語 0.6 = 英語 0.4) も、英語がある区切りとして数える (2 + 4 = 6 / 24)
        XCTAssertEqual(decide(ja: 18, en: 2, untrusted: 4), .mixed)
        // 英語の録音に、確かでない判定 (日本語 0.6) が 4 / 24 (17%)。
        // 前の決まり (信じられる判定だけを数える) では「混ざっていない」だったが、確かでない区切りは混ざっている証なので
        // 今は「混ざっている」 (1 つの言語の録音では、区切りの判定は 0.977 以上で、こうはならない)
        XCTAssertEqual(decide(ja: 0, en: 20, untrusted: 4), .mixed)
        // 判定できる区切りが 4 つ: 確かめる。3 つ: 確かめない
        XCTAssertEqual(decide(ja: 2, en: 2, probeable: 4), .mixed)
        XCTAssertEqual(decide(ja: 2, en: 1, probeable: 3), .skippedTooShort)
    }

    func testUncertainChunksCountAsEvidence() {
        func result(en: Int, uncertain: Int, confidence: Double = 0.6) -> MixedProbe.Result {
            MixedProbe.decide(probes(ja: 0, en: en, untrusted: uncertain, uncertain: confidence), probeableChunks: en + uncertain,
                              preferred: "en")
        }
        // 1 つの言語の録音で、確かでない区切りが 12 個のうち 1 個: 混ざっていない
        XCTAssertEqual(result(en: 11, uncertain: 1).decision, .notMixed)
        XCTAssertEqual(result(en: 11, uncertain: 1).evidence, 1)
        // 24 個のうち 2 個 (8%、10% 未満): 混ざっていない。3 個 (12.5%): 混ざっている
        XCTAssertEqual(result(en: 22, uncertain: 2).decision, .notMixed)
        XCTAssertEqual(result(en: 21, uncertain: 3).decision, .mixed)
        XCTAssertEqual(result(en: 21, uncertain: 3).majority, "en")
        XCTAssertEqual(result(en: 21, uncertain: 3).evidence, 3)
        // 英語と判定されても、日本語の確率が 0.25 以上 (英語 0.75 以下) なら数える。0.25 未満なら数えない
        func english(_ confidence: Double, count: Int) -> MixedProbe.Result {
            var list = probes(ja: 0, en: 21)
            for _ in 0..<count {
                list.append(.init(start: 0, end: 1, speech: 5, detected: "en", confidence: confidence, trusted: false))
            }
            return MixedProbe.decide(list, probeableChunks: list.count, preferred: "en")
        }
        XCTAssertEqual(english(0.75, count: 3).decision, .mixed)
        XCTAssertEqual(english(0.80, count: 3).decision, .notMixed)
        XCTAssertEqual(english(0.80, count: 3).evidence, 0)
        // 判定できなかった区切りは、どちらの数にも入らない (2 / 20 = 10%)
        var list = probes(ja: 0, en: 18, untrusted: 2)
        for _ in 0..<4 { list.append(.init(start: 0, end: 1, speech: 5, detected: nil, confidence: nil, trusted: false)) }
        let r = MixedProbe.decide(list, probeableChunks: list.count, preferred: "en")
        XCTAssertEqual(r.detectedCount, 20)
        XCTAssertEqual(r.decision, .mixed)
    }

    func testMajorityIsTheLargerSumOfProbability() {
        // 信じられる判定は日本語が多くても、確率の合計は英語が多い: 多い側は英語、日本語がある区切りを数える
        var list = probes(ja: 3, en: 0)
        for _ in 0..<9 { list.append(.init(start: 0, end: 1, speech: 5, detected: "en", confidence: 0.7, trusted: false)) }
        let r = MixedProbe.decide(list, probeableChunks: list.count, preferred: "auto")
        XCTAssertEqual(r.majority, "en")
        XCTAssertEqual(r.evidence, 12)
        XCTAssertEqual(r.decision, .mixed)
        XCTAssertEqual(r.candidates, ["en", "ja"])
        // 同じ合計なら利用者の言語 (自動判定なら日本語)
        let tie = probes(ja: 2, en: 2)
        XCTAssertEqual(MixedProbe.decide(tie, probeableChunks: 4, preferred: "en").majority, "en")
        XCTAssertEqual(MixedProbe.decide(tie, probeableChunks: 4, preferred: "auto").majority, "ja")
        XCTAssertEqual(MixedProbe.decide(tie, probeableChunks: 4, preferred: "auto").candidates, ["ja", "en"])
    }

    func testProbeChunksAreSpreadOverTheWholeRecording() {
        var chunks: [SpeechChunk] = []
        for k in 0..<240 {
            let range = s(Double(k) * 30)..<s(Double(k) * 30 + 20)
            chunks.append(SpeechChunk(range: range, spans: [range]))
        }
        // 発話 2 秒の区切りは選ばない
        let short = s(7300)..<s(7302)
        chunks.append(SpeechChunk(range: short, spans: [short]))
        let picked = MixedProbe.probeChunks(chunks)
        XCTAssertEqual(picked.probeable, 240)
        XCTAssertEqual(picked.selected.count, MixedProbe.maxProbes)
        XCTAssertEqual(picked.selected.first?.range.lowerBound, s(5 * 30))
        XCTAssertEqual(picked.selected.last?.range.lowerBound, s(235 * 30))
        XCTAssertEqual(Set(picked.selected.map(\.range.lowerBound)).count, MixedProbe.maxProbes)
    }

    // MARK: - 切り替えたときの結果

    func testSwitchingGivesTheSameResultAsChoosingJapaneseEnglish() throws {
        var list: [(seconds: Double, language: String)] = []
        for k in 0..<10 { list.append((27, k % 2 == 0 ? "en" : "ja")) }
        let b = blocks(list)
        let samples = [Float](repeating: 0, count: b.total)

        let chosen = try MixedPipeline.run(samples: samples, engine: ScriptEngine(b.utterances),
                                           options: MixedPipeline.Options(candidates: ["ja", "en"]))

        let base = ScriptEngine(b.utterances)
        let engine = ReusingMixedEngine(base)
        let r = try MixedProbe.run(samples: samples, engine: engine, preferred: "ja")
        XCTAssertEqual(r.decision, .mixed)
        let probeDetections = base.detections
        let switched = try MixedPipeline.run(samples: samples, engine: engine,
                                             options: MixedPipeline.Options(candidates: r.candidates))
        func lines(_ out: MixedPipeline.Output) -> [String] {
            out.segments.map { "\($0.start)-\($0.end) \($0.language ?? "-") \($0.text)" }
        }
        XCTAssertEqual(lines(switched), lines(chosen))
        XCTAssertFalse(chosen.segments.isEmpty)
        XCTAssertEqual(switched.report.runs.map(\.language), chosen.report.runs.map(\.language))
        XCTAssertEqual(switched.report.detections, chosen.report.detections)
        // VAD は 1 回だけ。確かめたときの判定は使い回す
        XCTAssertEqual(base.vadCalls, 1)
        XCTAssertGreaterThan(probeDetections, 0)
        XCTAssertEqual(base.detections, Set(base.detectedRanges).count)
    }
}
