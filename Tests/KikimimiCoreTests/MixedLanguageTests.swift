import Foundation
import XCTest
@testable import KikimimiCore

/// 「日本語＋英語」(区切りごとの言語判定) の決まりごと。数値の手本は、試作 (英語と日本語の朗読を交互に並べた 208 秒の録音) の結果
final class MixedLanguageTests: XCTestCase {
    private func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }
    private func sec(_ samples: Int) -> Double { (Double(samples) / 16_000 * 100).rounded() / 100 }

    /// 試作の録音を、今のアプリの VAD の設定で区切ったもの (57 個)
    private let mixSpans: [(Double, Double)] = [
        (0.64, 4.13), (4.25, 7.72), (7.93, 10.98), (11.04, 13.41), (13.56, 15.75), (16.06, 19.3), (19.48, 21.09),
        (21.12, 23.65), (24.44, 28.68), (28.7, 32.48), (33.37, 36.61), (37.05, 38.56), (38.68, 40.96), (41.34, 44.13),
        (44.51, 47.01), (47.45, 50.15), (50.59, 51.91), (52.12, 53.6), (54.43, 55.62), (55.77, 61.83), (62.14, 66.18),
        (66.24, 68.58), (68.96, 71.14), (71.42, 77.7), (77.95, 80.87), (81.02, 85.38), (85.66, 88.96), (89.15, 90.28),
        (90.97, 94.95), (95.32, 99.65), (99.9, 104.29), (104.57, 109), (109.72, 113.92), (114.14, 118.92),
        (119.2, 124.1), (124.51, 126.05), (126.49, 131.08), (131.13, 132.26), (132.44, 138.79), (139, 145.22),
        (145.47, 152.8), (153.18, 154.08), (154.33, 160.48), (161.24, 164.9), (165.08, 166.34), (166.68, 168.71),
        (168.92, 170.53), (170.75, 171.91), (172.06, 176.58), (176.67, 178.79), (179.2, 182.53), (182.65, 187.62),
        (187.8, 188.96), (189.95, 192.16), (192.25, 195.04), (195.29, 201.41), (201.76, 207.97),
    ]

    private var mixMap: SpeechMap {
        SpeechMap(spans: mixSpans.map { s($0.0)..<s($0.1) }, totalSamples: s(208.4))
    }

    private func bounds(_ chunks: [SpeechChunk]) -> [[Double]] {
        chunks.map { [sec($0.range.lowerBound), sec($0.range.upperBound)] }
    }

    // MARK: - 言語の一覧・文字

    func testLanguageMenu() {
        XCTAssertEqual(Languages.all.first?.code, "auto")
        XCTAssertEqual(Languages.all[1].code, "ja+en")
        XCTAssertEqual(Languages.name(for: "ja+en"), "日本語＋英語")
        XCTAssertTrue(Languages.isKnown("ja+en"))
        XCTAssertEqual(Languages.candidates(for: "ja+en"), ["ja", "en"])
        XCTAssertNil(Languages.candidates(for: "ja"))
        XCTAssertNil(Languages.candidates(for: "auto"))
    }

    func testSpokenLanguageFromScript() {
        let c = ["ja", "en"]
        XCTAssertEqual(Script.spokenLanguage(of: "こんにちは、Roblox Studio です。", among: c, fallback: "en"), "ja")
        XCTAssertEqual(Script.spokenLanguage(of: "Welcome to the session.", among: c, fallback: "ja"), "en")
        XCTAssertEqual(Script.spokenLanguage(of: "東京都", among: c, fallback: "en"), "ja")
        XCTAssertEqual(Script.spokenLanguage(of: "Roblox 開発", among: c, fallback: "en"), "en")
        XCTAssertEqual(Script.spokenLanguage(of: "123!", among: c, fallback: "ja"), "ja")
        XCTAssertEqual(Script.englishNames(["en", "ja"]), "English and Japanese")
        XCTAssertEqual(Script.englishNames(["en"]), "English")
    }

    func testGlossaryHintPerLanguage() {
        let glossary = "ロブロックス, Roblox Studio, ききみみ"
        XCTAssertEqual(GlossaryHint.hint(glossary, for: "ja"), glossary)
        XCTAssertEqual(GlossaryHint.hint(glossary, for: "en"), "Roblox Studio")
        XCTAssertNil(GlossaryHint.hint("日本語だけ、語彙", for: "en"))
        XCTAssertNil(GlossaryHint.hint("  ", for: "ja"))
        XCTAssertEqual(GlossaryHint.hint("Kikimimi、Lua；ルア\nTPIE", for: "en"), "Kikimimi, Lua, TPIE")
    }

    // MARK: - 区切り

    func testChunksMatchPrototypeP2() {
        let chunks = SpeechChunker.chunks(mixMap)
        XCTAssertEqual(bounds(chunks), [
            [0.64, 23.65], [24.44, 32.48], [33.37, 53.6], [54.43, 68.58], [68.96, 90.28], [90.97, 109],
            [109.72, 126.05], [126.49, 152.8], [153.18, 160.48], [161.24, 188.96], [189.95, 207.97],
        ])
        XCTAssertTrue(chunks.allSatisfy { $0.seconds <= MixedLanguageRules.maxChunkSeconds })
        XCTAssertFalse(chunks.contains { $0.forcedCutBefore })
    }

    func testForcedCutInsideSpeechMatchesPrototypeP2s() {
        let chunks = SpeechChunker.chunks(mixMap, forcedCuts: [s(133.74)])
        XCTAssertEqual(bounds(chunks), [
            [0.64, 23.65], [24.44, 32.48], [33.37, 53.6], [54.43, 68.58], [68.96, 90.28], [90.97, 109],
            [109.72, 133.74], [133.74, 160.48], [161.24, 188.96], [189.95, 207.97],
        ])
        XCTAssertEqual(chunks.map(\.forcedCutBefore), [false, false, false, false, false, false, false, true, false, false])
    }

    func testForcedCutInsideAPauseSplitsTheGroup() {
        let map = SpeechMap(spans: [s(0)..<s(5), s(5.3)..<s(10), s(10.3)..<s(15)], totalSamples: s(16))
        XCTAssertEqual(bounds(SpeechChunker.chunks(map)), [[0, 15]])
        let cut = SpeechChunker.chunks(map, forcedCuts: [s(5.15)])
        XCTAssertEqual(bounds(cut), [[0, 5], [5.3, 15]])
        XCTAssertEqual(cut.map(\.forcedCutBefore), [false, true])
        // 発話の端のすぐそば (0.3 秒以内) の切れ目は、その隣の間で切る
        XCTAssertEqual(bounds(SpeechChunker.chunks(map, forcedCuts: [s(9.9)])), [[0, 10], [10.3, 15]])
    }

    func testLongSingleSpanIsCutAtTheQuietestFrame() {
        // 40 秒続く発話。23.5 秒あたりがいちばん静か (32 秒あたりも静かだが、そこで切ると前が 28 秒を超える)
        var levels = [Float](repeating: 0.9, count: s(40) / 512 + 1)
        levels[s(23.5) / 512] = 0.2
        levels[s(32) / 512] = 0.1
        let map = SpeechMap(spans: [0..<s(40)], levels: levels, totalSamples: s(40))
        let chunks = SpeechChunker.chunks(map)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(sec(chunks[0].range.upperBound), 23.5, accuracy: 0.05)
        XCTAssertEqual(chunks[0].range.upperBound, chunks[1].range.lowerBound)
        XCTAssertTrue(chunks.allSatisfy { $0.seconds >= MixedLanguageRules.minSideSeconds && $0.seconds <= 28 })
        // 静かなところが無ければ、同じ長さに分ける
        let flat = SpeechChunker.chunks(SpeechMap(spans: [0..<s(40)], levels: [Float](repeating: 0.9, count: 1300),
                                                  totalSamples: s(40)))
        XCTAssertEqual(sec(flat[0].range.upperBound), 20, accuracy: 0.05)
        // 70 秒なら 3 つ
        XCTAssertEqual(SpeechChunker.chunks(SpeechMap(spans: [0..<s(70)], totalSamples: s(70))).count, 3)
    }

    func testChunkingALongRecordingWithEvenPausesDoesNotRecurseDeeply() {
        // 2 時間、2 秒の発話と 0.3 秒の間がそろって続く (どこで分けても同じ: 分け方が偏る)
        var spans: [Range<Int>] = []
        var t = 0.0
        while t < 7200 {
            spans.append(s(t)..<s(t + 2))
            t += 2.3
        }
        let chunks = SpeechChunker.chunks(SpeechMap(spans: spans, totalSamples: s(7201)))
        XCTAssertTrue(chunks.allSatisfy { $0.seconds <= MixedLanguageRules.maxChunkSeconds })
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.spans.count }, spans.count)
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertLessThan(a.range.upperBound, b.range.lowerBound) }
    }

    func testPiecesSplitAtTheTwoLongestPauses() {
        let chunk = SpeechChunker.chunks(mixMap)[7]
        XCTAssertEqual(bounds([chunk]), [[126.49, 152.8]])
        XCTAssertEqual(bounds(SpeechChunker.pieces(of: chunk)), [[126.49, 138.79], [139, 145.22], [145.47, 152.8]])
        // 2 秒未満の部分ができる間は使わない
        let short = SpeechChunk(range: s(0)..<s(10), spans: [s(0)..<s(1), s(2)..<s(10)])
        XCTAssertEqual(SpeechChunker.pieces(of: short).count, 1)
    }

    func testFixedChunksWithoutVAD() {
        var samples = [Float](repeating: 0.3, count: s(60))
        for i in s(24.0)..<s(24.1) { samples[i] = 0 }  // 24 秒のところに無音
        let map = SpeechMap.withoutVAD(samples)
        XCTAssertFalse(map.fromVAD)
        let chunks = SpeechChunker.fixedChunks(map)
        XCTAssertEqual(chunks.first?.range.lowerBound, 0)
        XCTAssertEqual(chunks.last?.range.upperBound, samples.count)
        XCTAssertEqual(sec(chunks[0].range.upperBound), 24.05, accuracy: 0.05)
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(a.range.upperBound, b.range.lowerBound) }
    }

    // MARK: - 言語の決め方

    func testTrustTable() {
        let g = { (c: Double) in LanguageGuess(language: "en", confidence: c) }
        XCTAssertTrue(LanguagePlanner.isTrusted(g(0.90), speechSeconds: 2.0))
        XCTAssertFalse(LanguagePlanner.isTrusted(g(0.89), speechSeconds: 10))
        XCTAssertTrue(LanguagePlanner.isTrusted(g(0.95), speechSeconds: 1.5))
        XCTAssertFalse(LanguagePlanner.isTrusted(g(0.94), speechSeconds: 1.5))
        XCTAssertFalse(LanguagePlanner.isTrusted(g(0.999), speechSeconds: 0.9))
        XCTAssertFalse(LanguagePlanner.isTrusted(nil, speechSeconds: 10))
        XCTAssertEqual(LanguageGuess(probabilities: [0.2, 0.6], candidates: ["ja", "en"]),
                       LanguageGuess(language: "en", confidence: 0.75))
        XCTAssertNil(LanguageGuess(probabilities: [0, 0], candidates: ["ja", "en"]))
    }

    private func chunk(_ a: Double, _ b: Double) -> SpeechChunk {
        SpeechChunk(range: s(a)..<s(b), spans: [s(a)..<s(b)])
    }

    private func plan(_ items: [(SpeechChunk, LanguageGuess?)], total: Double) -> [DecodeRun] {
        var planner = LanguagePlanner(candidates: ["ja", "en"], totalSamples: s(total))
        var runs: [DecodeRun] = []
        for (c, g) in items { runs += planner.add(c, guess: g) }
        return runs + planner.finish()
    }

    func testUntrustedChunkBorrowsAcrossShortPausesOnly() {
        let en = LanguageGuess(language: "en", confidence: 0.99)
        let ja = LanguageGuess(language: "ja", confidence: 0.99)
        let unsure = LanguageGuess(language: "ja", confidence: 0.6)
        // 前との間が 0.5 秒: 前の言語 (en)
        var runs = plan([(chunk(0, 10), en), (chunk(10.5, 15), unsure), (chunk(17, 30), ja)], total: 31)
        XCTAssertEqual(runs.map(\.language), ["en", "ja"])
        XCTAssertEqual(sec(runs[0].range.upperBound), 16)  // 15 と 17 の真ん中
        // 前との間が 1.5 秒: 次の言語 (ja)
        runs = plan([(chunk(0, 10), en), (chunk(11.5, 15), unsure), (chunk(15.3, 30), ja)], total: 31)
        XCTAssertEqual(runs.map(\.language), ["en", "ja"])
        XCTAssertEqual(sec(runs[0].range.upperBound), 10.75)
        // 一度「次」に合わせたら、その後ろも次に合わせる
        runs = plan([(chunk(0, 10), en), (chunk(11.5, 13), unsure), (chunk(13.2, 15), unsure), (chunk(15.3, 30), ja)],
                    total: 31)
        XCTAssertEqual(runs.map(\.language), ["en", "ja"])
        XCTAssertEqual(runs[1].chunks.count, 3)
        // 終わりの信じられない区切りは、前の言語
        runs = plan([(chunk(0, 10), en), (chunk(12, 13), unsure)], total: 14)
        XCTAssertEqual(runs.map(\.language), ["en"])
        // 信じられる判定が無ければ、最初の候補 (日本語)
        runs = plan([(chunk(0, 0.5), nil), (chunk(1, 3), LanguageGuess(language: "en", confidence: 0.7))], total: 4)
        XCTAssertEqual(runs.map(\.language), ["ja"])
    }

    func testRunsCoverTheWholeFileAndRespectTheCap() {
        let en = LanguageGuess(language: "en", confidence: 0.99)
        let ja = LanguageGuess(language: "ja", confidence: 0.99)
        var items: [(SpeechChunk, LanguageGuess?)] = []
        var t = 1.0
        for k in 0..<90 {  // 25 秒の区切りが 90 個 (38 分)。30 個 (12.75 分) ごとに言語が変わる
            items.append((chunk(t, t + 25), (k / 30) % 2 == 0 ? en : ja))
            t += 25.5
        }
        let runs = plan(items, total: t + 3)
        XCTAssertEqual(runs.first?.range.lowerBound, 0)
        XCTAssertEqual(runs.last?.range.upperBound, s(t + 3))
        for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertEqual(a.range.upperBound, b.range.lowerBound) }
        XCTAssertTrue(runs.allSatisfy { Double($0.range.count) / 16_000 <= MixedLanguageRules.maxRunSeconds + 1 })
        XCTAssertEqual(runs.map(\.language), ["en", "ja", "en"].flatMap { [$0, $0] })
        XCTAssertEqual(runs.reduce(0) { $0 + $1.chunks.count }, 90)
        // 上限で閉じるときも、区切りと区切りの間の真ん中で閉じる
        XCTAssertEqual(sec(runs[0].range.upperBound), 1 + 22 * 25.5 + 25 + 0.25, accuracy: 0.01)
    }

    // MARK: - 切り替わりの探索

    private final class Counter { var value = 0 }

    /// 判定の偽物: 位置 switchAt の前は head、後ろは tail。窓が切り替わりをまたぐと、多い側の言語 (近ければ取り違える)
    private func fakeDetector(switchAt: Double, head: String = "en", tail: String = "ja",
                              calls: Counter) -> (Range<Int>) -> LanguageGuess? {
        return { range in
            calls.value += 1
            let a = Double(range.lowerBound) / 16_000, b = Double(range.upperBound) / 16_000
            let before = max(0, min(b, switchAt) - a), after = max(0, b - max(a, switchAt))
            if before == 0 { return LanguageGuess(language: tail, confidence: 0.999) }
            if after == 0 { return LanguageGuess(language: head, confidence: 0.999) }
            let share = before / (before + after)
            return LanguageGuess(language: share >= 0.5 ? head : tail, confidence: 0.5 + abs(share - 0.5))
        }
    }

    func testBisectionFindsASwitchWithoutAPause() throws {
        let count = Counter()
        let map = SpeechMap(spans: [s(100)..<s(126)], totalSamples: s(130))
        let b = SwitchSearch.bisect(s(100)..<s(126), map: map, detect: fakeDetector(switchAt: 113.77, calls: count))
        XCTAssertEqual(b.head?.language, "en")
        XCTAssertEqual(b.tail?.language, "ja")
        XCTAssertLessThanOrEqual(b.detections, 2 + MixedLanguageRules.bisectMaxSteps)
        XCTAssertEqual(b.detections, count.value)
        let cut = try XCTUnwrap(b.cut)
        let bracket = try XCTUnwrap(b.bracket)
        XCTAssertGreaterThanOrEqual(cut, bracket.lowerBound - s(0.25))
        XCTAssertLessThanOrEqual(cut, bracket.upperBound + s(0.25))
        XCTAssertEqual(Double(cut) / 16_000, 113.77, accuracy: 1.6)
        // 先頭と末尾が同じ言語で、端の 2 秒も同じなら、切り替わりは無い (判定は 4 回)
        let none = Counter()
        let same = SwitchSearch.bisect(s(100)..<s(126), map: map, detect: fakeDetector(switchAt: 200, calls: none))
        XCTAssertNil(same.cut)
        XCTAssertEqual(same.detections, 4)
        XCTAssertEqual(none.value, 4)
    }

    func testBisectionFindsASwitchNearTheStart() throws {
        // 切り替わりが先頭から 1.3 秒: 先頭の 4 秒は、多い側 (後ろの日本語) に聞こえる。先頭の 2 秒で気づいて探す
        let count = Counter()
        let map = SpeechMap(spans: [s(34.72)..<s(41)], totalSamples: s(48))
        let b = SwitchSearch.bisect(s(34.72)..<s(41), map: map, detect: fakeDetector(switchAt: 36.02, calls: count))
        XCTAssertEqual(b.head?.language, "en")
        XCTAssertEqual(b.tail?.language, "ja")
        XCTAssertEqual(Double(try XCTUnwrap(b.cut)) / 16_000, 36.02, accuracy: 1.0)
        XCTAssertEqual(b.detections, count.value)
        // 末尾に寄った切り替わりも
        let tailCount = Counter()
        let t = SwitchSearch.bisect(s(100)..<s(110), map: map, detect: fakeDetector(switchAt: 108.8, calls: tailCount))
        XCTAssertEqual(t.head?.language, "en")
        XCTAssertEqual(t.tail?.language, "ja")
        XCTAssertEqual(Double(try XCTUnwrap(t.cut)) / 16_000, 108.8, accuracy: 1.0)
    }

    func testRefineSplitsAtPausesAndSwitches() {
        // 126.49–152.8 の区切り: 133.77 で間を空けずに英語 → 日本語
        let count = Counter()
        let chunk = SpeechChunker.chunks(mixMap)[7]
        let outcome = SwitchSearch.refine(chunk, guess: LanguageGuess(language: "ja", confidence: 0.873), map: mixMap,
                                          detect: fakeDetector(switchAt: 133.77, calls: count))
        XCTAssertEqual(outcome.detections, count.value)
        XCTAssertEqual(outcome.parts.map { $0.guess?.language }, ["en", "ja", "ja", "ja"])
        XCTAssertEqual(outcome.switches.count, 1)
        XCTAssertEqual(outcome.switches[0].cut, 133.77, accuracy: 1.6)
        XCTAssertEqual(outcome.parts.first?.chunk.range.lowerBound, chunk.range.lowerBound)
        XCTAssertEqual(outcome.parts.last?.chunk.range.upperBound, chunk.range.upperBound)
        XCTAssertTrue(SwitchSearch.needsRefinement(LanguageGuess(language: "ja", confidence: 0.94), speechSeconds: 4))
        XCTAssertFalse(SwitchSearch.needsRefinement(LanguageGuess(language: "ja", confidence: 0.96), speechSeconds: 20))
        XCTAssertFalse(SwitchSearch.needsRefinement(LanguageGuess(language: "ja", confidence: 0.5), speechSeconds: 3.9))
    }

    // MARK: - 点検

    func testDecodeChecks() {
        let map = SpeechMap(spans: [s(0)..<s(60)], totalSamples: s(60))
        let normal = (0..<12).map { k in
            DecodedSegment(start: Double(k) * 5, end: Double(k) * 5 + 4.5,
                           text: "This is a perfectly ordinary sentence number \(k) here.",
                           tokenCount: 12, meanLogProb: -0.15, language: "en")
        }
        let check = DecodeCheck(speech: map, segments: normal)
        XCTAssertTrue(normal.allSatisfy { check.flags($0).isEmpty })
        // 「彼は、」の暴走 (英語の音声を日本語で文字にした)
        let loop = DecodedSegment(start: 0, end: 30, text: String(repeating: "彼は、", count: 55),
                                  tokenCount: 110, meanLogProb: -0.2, language: "ja")
        XCTAssertTrue(check.flags(loop).contains(.repeating))
        // 日本語の音声を英語で文字にした、自信の低い訳のような文
        let pseudo = DecodedSegment(start: 0, end: 5, text: "The heat of the temperature is not too high.",
                                    tokenCount: 10, meanLogProb: -0.9, language: "en")
        XCTAssertTrue(check.flags(pseudo).contains(.lowConfidence))
        // 英語で文字にしたのに、かな
        let kana = DecodedSegment(start: 0, end: 5, text: "そうですね", tokenCount: 3, meanLogProb: -0.2, language: "en")
        XCTAssertTrue(check.flags(kana).contains(.wrongScript))
        // 10 秒話したのに 3 文字
        let sparse = DecodedSegment(start: 0, end: 10, text: "はい。", tokenCount: 2, meanLogProb: -0.1, language: "ja")
        XCTAssertTrue(check.flags(sparse).contains(.sparse))
        // 抜け: 20〜30 秒に区間が無い
        let holes = normal.filter { $0.start < 18 || $0.start >= 30 }
        let gaps = check.uncovered(in: 0..<s(60), segments: holes)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(sec(gaps[0].lowerBound), 19.8, accuracy: 0.01)
        XCTAssertEqual(sec(gaps[0].upperBound), 29.7, accuracy: 0.01)
        XCTAssertEqual(DecodeCheck.repetition("abcdefghijkl"), 0)
        XCTAssertGreaterThan(DecodeCheck.repetition("abcabcabcabcabcabc"), 0.5)
    }

    // MARK: - 全体の流れ (台本どおりに答える偽の whisper)

    /// 台本どおりに答える偽の whisper。blocks がそれぞれの言語で話している範囲
    private final class ScriptedEngine: MixedEngine {
        struct Block { var range: Range<Int>; var language: String }
        let blocks: [Block]
        let spans: [Range<Int>]
        var useVAD = true
        var log: [String] = []
        var cancelAfterDecodes: Int? = nil
        var cancelled = false

        init(blocks: [Block], spans: [Range<Int>]) {
            self.blocks = blocks
            self.spans = spans
        }

        func speechMap(of samples: [Float]) throws -> SpeechMap? {
            useVAD ? SpeechMap(spans: spans, totalSamples: samples.count) : nil
        }

        private func overlap(_ a: Range<Int>, _ b: Range<Int>) -> Int {
            max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        }

        /// whisper と同じく、多い側の言語が 3/4 以上なら、少ない側をほとんど聞き取らない (0.99)。それ未満は割合のまま
        func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]? {
            log.append("detect \(range.lowerBound / 16_000)")
            var ja = 0, en = 0
            for b in blocks {
                if b.language == "ja" { ja += overlap(b.range, range) } else { en += overlap(b.range, range) }
            }
            guard ja + en > 0 else { return nil }
            var pj = Float(ja) / Float(ja + en)
            if pj >= 0.75 { pj = 0.99 } else if pj <= 0.25 { pj = 0.01 }
            let p: [String: Float] = ["ja": pj, "en": 1 - pj]
            return candidates.map { p[$0] ?? 0 }
        }

        /// それらしい文 (英語は 1 秒 13 文字、日本語は 7 文字。繰り返しの無い並び)
        static func text(seconds: Double, language: String, seed: Int) -> String {
            var x = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 12_345)
            func next() -> UInt32 {
                x = x &* 1_103_515_245 &+ 12_345
                return (x >> 8) & 0xFFFF
            }
            var out = ""
            let letters = Int(seconds * (language == "en" ? 13 : 7))
            var n = 0
            while n < letters {
                if language == "en" {
                    let length = 3 + Int(next() % 6)
                    for _ in 0..<length { out.unicodeScalars.append(Unicode.Scalar(UInt8(97 + Int(next() % 26)))) }
                    out += " "
                    n += length
                } else {
                    out.unicodeScalars.append(Unicode.Scalar(0x3041 + next() % 83)!)
                    n += 1
                }
            }
            return out.trimmingCharacters(in: .whitespaces) + (language == "en" ? "." : "。")
        }

        func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                    onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment] {
            log.append("decode \(range.lowerBound / 16_000) \(language)")
            if let n = cancelAfterDecodes {
                if n == 0 { cancelled = true }
                cancelAfterDecodes = n - 1
            }
            var out: [DecodedSegment] = []
            for b in blocks {
                let a = max(b.range.lowerBound, range.lowerBound), e = min(b.range.upperBound, range.upperBound)
                guard e - a >= 16_000 else { continue }
                // whisper のように 8 秒くらいずつの区間にする
                var t = a
                var first = true
                while t < e {
                    let end = min(e, t + 8 * 16_000)
                    let seconds = Double(end - t) / 16_000
                    let text: String
                    let lp: Double
                    if b.language == language {
                        text = Self.text(seconds: seconds, language: language, seed: t)
                        lp = -0.15
                    } else if language == "ja" {
                        // 英語の音声を日本語で文字にしたときの暴走 (最初の区間だけで、あとは抜ける)
                        guard first else { break }
                        text = String(repeating: "彼は、", count: 40)
                        lp = -0.3
                    } else {
                        // 日本語の音声を英語で文字にした、訳のような文
                        text = "The heat is not too high."
                        lp = -1.1
                    }
                    let seg = DecodedSegment(start: Double(t) / 16_000, end: Double(end) / 16_000, text: text,
                                             tokenCount: 12, meanLogProb: lp, language: language)
                    onSegment(seg)
                    out.append(seg)
                    first = false
                    t = end
                }
            }
            onProgress(1)
            return out
        }
    }

    private func scripted() -> ScriptedEngine {
        let blocks = [
            ScriptedEngine.Block(range: s(0)..<s(30), language: "en"),
            ScriptedEngine.Block(range: s(30.7)..<s(50), language: "ja"),
            ScriptedEngine.Block(range: s(50.7)..<s(80), language: "en"),
            ScriptedEngine.Block(range: s(80)..<s(95), language: "ja"),
        ]
        // 5 秒ごとの発話 (中の間は 0.3 秒、切り替わりの間は 0.7 秒)。80 秒の切り替わりは発話の途中 (間が無い)
        var spans: [Range<Int>] = []
        for (a, b) in [(0.0, 30.0), (30.7, 50.0), (50.7, 95.0)] {
            var t = a
            while t < b {
                let end = min(b, t + 4.7)
                spans.append(s(t)..<s(end))
                t = end + 0.3
            }
        }
        return ScriptedEngine(blocks: blocks, spans: spans)
    }

    func testPipelineDecodesEachLanguageInItsOwnLanguage() throws {
        let engine = scripted()
        let samples = [Float](repeating: 0, count: s(96))
        var progress: [Double] = []
        var live: [TranscriptSegment] = []
        let out = try MixedPipeline.run(samples: samples, engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]),
                                        onProgress: { progress.append($0) }, onSegment: { live.append($0) })
        let langs = out.segments.map { $0.language ?? "?" }
        XCTAssertFalse(out.segments.isEmpty)
        // 英語 → 日本語 → 英語 → 日本語 の順に、それぞれの言語の文
        var order: [String] = []
        for l in langs where order.last != l { order.append(l) }
        XCTAssertEqual(order, ["en", "ja", "en", "ja"])
        XCTAssertFalse(out.segments.contains { $0.text.contains("彼は") || $0.text.contains("heat") },
                       out.segments.map(\.text).joined(separator: " / "))
        XCTAssertTrue(out.report.repairs.isEmpty)
        XCTAssertEqual(out.language, "en")
        XCTAssertTrue(out.report.usedVAD)
        XCTAssertGreaterThanOrEqual(out.report.switches.count, 1)
        // 進み具合は戻らない。途中表示は時刻の順
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertLessThanOrEqual(progress.last ?? 0, 1)
        XCTAssertEqual(live.map(\.start), live.map(\.start).sorted())
        // 判定と文字起こしは交互に進む (全体の判定を待たない)
        let firstDecode = try XCTUnwrap(engine.log.firstIndex { $0.hasPrefix("decode") })
        let lastDetect = try XCTUnwrap(engine.log.lastIndex { $0.hasPrefix("detect") })
        XCTAssertLessThan(firstDecode, lastDetect)
    }

    func testPipelineSplitsAChunkWithASwitchAtAPause() throws {
        // 英語の講義の途中の、8 秒の日本語 (前後に短い間)。1 つの区切りに入るが、区切りを分けて判定し直すと見つかる
        let blocks = [
            ScriptedEngine.Block(range: s(0)..<s(40), language: "en"),
            ScriptedEngine.Block(range: s(40)..<s(48), language: "ja"),
            ScriptedEngine.Block(range: s(48)..<s(60), language: "en"),
        ]
        let engine = ScriptedEngine(blocks: blocks, spans: [s(0)..<s(39.9), s(40.1)..<s(47.9), s(48.1)..<s(60)])
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(61)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let japanese = out.segments.filter { $0.language == "ja" }
        XCTAssertFalse(japanese.isEmpty, out.segments.map(\.text).joined(separator: " / "))
        XCTAssertEqual(japanese.first?.start ?? 0, 40, accuracy: 0.3)
        XCTAssertEqual(japanese.last?.end ?? 0, 48, accuracy: 0.3)
        XCTAssertFalse(out.segments.contains { $0.text.contains("heat") })
        XCTAssertGreaterThan(out.report.refinementDetections, 0)
        XCTAssertEqual(out.report.runs.map(\.language), ["en", "ja", "en"])
        XCTAssertTrue(out.report.repairs.isEmpty)
    }

    func testPipelineRepairsAShortInterjectionTheDetectionMissed() throws {
        // 3 秒の日本語は、区切り (英語が 8 割) の判定では聞き取られない (whisper と同じ)。
        // 英語で文字にした結果が点検に引っかかり、判定し直して日本語で文字にし直す
        let blocks = [
            ScriptedEngine.Block(range: s(0)..<s(40), language: "en"),
            ScriptedEngine.Block(range: s(40)..<s(43), language: "ja"),
            ScriptedEngine.Block(range: s(43)..<s(60), language: "en"),
        ]
        let engine = ScriptedEngine(blocks: blocks, spans: [s(0)..<s(39.9), s(40.1)..<s(42.9), s(43.1)..<s(60)])
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(61)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let japanese = out.segments.filter { $0.language == "ja" }
        XCTAssertEqual(japanese.count, 1, out.segments.map(\.text).joined(separator: " / "))
        XCTAssertEqual(japanese.first?.start ?? 0, 40, accuracy: 0.3)
        XCTAssertFalse(out.segments.contains { $0.text.contains("heat") })
        XCTAssertEqual(out.report.repairs.filter(\.accepted).count, 1)
    }

    func testPipelineRepairsAMisjudgedRegionOnlyWhenTheLanguageDiffers() throws {
        // 間を空けずに話し続ける英語の中の、4 秒の日本語: 区切りの判定 (英語 0.99) では見つからず、
        // 英語で文字にした結果 (自信の低い訳のような文) が点検に引っかかり、判定し直して日本語で文字にし直す
        let blocks = [
            ScriptedEngine.Block(range: s(0)..<s(45), language: "en"),
            ScriptedEngine.Block(range: s(45)..<s(49), language: "ja"),
            ScriptedEngine.Block(range: s(49)..<s(60), language: "en"),
        ]
        let engine = ScriptedEngine(blocks: blocks, spans: [s(0)..<s(60)])
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(60)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        XCTAssertEqual(out.segments.filter { $0.language == "ja" }.count, 1, out.segments.map(\.text).joined(separator: " / "))
        XCTAssertFalse(out.segments.contains { $0.text.contains("heat") })
        XCTAssertEqual(out.report.repairs.filter(\.accepted).count, 1)
        // ほかの区間は点検に引っかからない (直しを試していない)
        XCTAssertEqual(out.report.repairs.count, 1)
        XCTAssertEqual(out.report.runs.map(\.language), ["en"])
    }

    func testPipelineCancels() {
        let engine = scripted()
        engine.cancelAfterDecodes = 0
        XCTAssertThrowsError(try MixedPipeline.run(samples: [Float](repeating: 0, count: s(96)), engine: engine,
                                                   options: MixedPipeline.Options(candidates: ["ja", "en"]),
                                                   shouldCancel: { engine.cancelled })) { error in
            XCTAssertEqual(error as? MixedPipelineError, .cancelled)
        }
        XCTAssertEqual(engine.log.filter { $0.hasPrefix("decode") }.count, 1)
    }

    func testPipelineWithoutVAD() throws {
        let engine = scripted()
        engine.useVAD = false
        let out = try MixedPipeline.run(samples: [Float](repeating: 0.1, count: s(96)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        XCTAssertFalse(out.report.usedVAD)
        XCTAssertTrue(out.segments.contains { $0.language == "en" })
        XCTAssertTrue(out.segments.contains { $0.language == "ja" })
    }

    // MARK: - 書き出し・翻訳・監査

    private var mixedTranscript: Transcript {
        Transcript(sourceName: "seminar", segments: [
            TranscriptSegment(start: 0, end: 10, text: "Welcome to the session.", language: "en"),
            TranscriptSegment(start: 10, end: 13, text: "はい、通訳します。", language: "ja"),
            TranscriptSegment(start: 13, end: 30, text: "Let's begin.", language: "en"),
        ], language: "en", duration: 30)
    }

    func testExportsNameBothLanguagesOnlyWhenMixed() {
        let t = mixedTranscript
        XCTAssertTrue(Exporter.markdown(t).contains("言語: 英語＋日本語"))
        let csv = Exporter.csv(t)
        XCTAssertTrue(csv.hasPrefix("start,end,text,language\n"))
        XCTAssertTrue(csv.contains("\"はい、通訳します。\",ja\n"))
        XCTAssertTrue(Exporter.csv(t, content: .bilingual).hasPrefix("start,end,text,japanese,language\n"))
        // 1 つの言語の文字起こしは、これまでと同じ形
        var single = t
        single.segments = single.segments.map { var x = $0; x.language = nil; return x }
        XCTAssertTrue(Exporter.csv(single).hasPrefix("start,end,text\n"))
        XCTAssertTrue(Exporter.markdown(single).contains("言語: 英語 /"))
        XCTAssertFalse(Exporter.json(single).contains("\"language\" : \"ja\""))
    }

    func testTranslatorUsesTheLanguageOfTheLinesToTranslate() throws {
        // 日本語が主で英語がまじる文字起こし: 訳すのは英語の行なので「from English」
        let t = Transcript(sourceName: "x", segments: [
            TranscriptSegment(start: 0, end: 20, text: "今日は日本語で話します。", language: "ja"),
            TranscriptSegment(start: 20, end: 25, text: "Thank you very much.", language: "en"),
        ], language: "ja")
        let generator = FakeGenerator { _ in "[1] どうもありがとうございます。\n" }
        try Translator.translate(t.segments, language: t.language, generator: generator, shouldCancel: { false },
                                 onChunk: { _, _, _ in })
        let system = try XCTUnwrap(generator.prompts.first?.system)
        XCTAssertEqual(system, Translator.systemPrompt(language: "en"))
        XCTAssertEqual(Translator.sourceLanguage(of: t.segments), "ja")
        XCTAssertNil(Translator.sourceLanguage(of: [TranscriptSegment(start: 0, end: 1, text: "a")]))
    }

    func testAuditorPromptMentionsBothLanguagesOnlyWhenMixed() throws {
        let mixed = Auditor.systemPrompt(language: "en", mixed: ["en", "ja"])
        XCTAssertTrue(mixed.contains("The transcript mixes English and Japanese; each line is in one of them."))
        XCTAssertEqual(Auditor.systemPrompt(language: "en", mixed: nil), Auditor.systemPrompt(language: "en"))
        XCTAssertTrue(Auditor.systemPrompt(language: "en").contains("The transcript is mostly in English. Each numbered line"))
        let generator = FakeGenerator { _ in "END" }
        _ = try Auditor.review(mixedTranscript.segments, language: "en", options: AuditOptions(), generator: generator,
                               shouldCancel: { false }, onProgress: { _, _ in })
        XCTAssertEqual(generator.prompts.first?.system, mixed)
    }

    // MARK: - 文字起こし (区間の言語)

    func testTranscriptLanguages() throws {
        var t = Transcript(sourceName: "a", segments: [
            TranscriptSegment(start: 0, end: 10, text: "Hello there.", language: "en"),
            TranscriptSegment(start: 10, end: 13, text: "はい。", language: "ja"),
            TranscriptSegment(start: 13, end: 30, text: "Next topic.", language: "en"),
        ], language: "en")
        XCTAssertEqual(t.spokenLanguages, ["en", "ja"])
        XCTAssertEqual(t.languageLabel, "英語＋日本語")
        XCTAssertEqual(t.language(of: t.segments[1]), "ja")
        XCTAssertEqual(t.bilingualUnits().map(\.language), ["en", "ja", "en"])
        XCTAssertEqual(t.bilingualUnits().map(\.isOriginalJapanese), [false, true, false])

        // 区間の言語は保存して読み戻せる。言語の無い区間は、これまでと同じ形 (language の項目なし)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(Transcript.self, from: data), t)
        t.segments = [TranscriptSegment(start: 0, end: 1, text: "x")]
        let single = String(decoding: try JSONEncoder().encode(t.segments[0]), as: UTF8.self)
        XCTAssertFalse(single.contains("language"))
        XCTAssertEqual(t.languageLabel, "英語")
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","start":0,"end":1,"text":"古い"}"#
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.self, from: Data(old.utf8)).language)
        XCTAssertNil(Transcript(sourceName: "b").languageLabel)
    }
}
