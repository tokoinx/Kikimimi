import XCTest
@testable import KikimimiCore

/// 「日本語＋英語」の島探しと直しの試験 (2 回目の見直しで見つかった場面)。
/// 発話ごとの正解を持ち、台本どおりに答える whisper を使う
final class MixedLanguageRepairTests: XCTestCase {
    // MARK: - 島探し

    func testOverBudgetChunksAreStillSearchedForIslands() throws {
        // 最初の 60 秒は、英語と日本語が 10 秒ごとに、間を空けずに入れ替わる (二分探索で切り替わりを探し、
        // 分けて判定し直す回数の上限を使い切る)。その後の英語の講義の 74〜99 秒の区切り (前後に 1 秒の間) に、
        // 2.6 秒の日本語の一言。区切りは英語 0.95 ほど (分け直すべきだが、上限を超えている)。
        // 英語で文字にすると日本語は消え、点検にも何も残らない (本物の turbo と同じ。抜けとみなす 3 秒に足りない)。
        // 島として見つける (区切りを分け直したときに中で探した回数は、島の回数に数えない)
        var u: [FlexibleEngine.Utterance] = []
        for k in 0..<6 {
            u.append(.init(range: s(Double(k) * 10)..<s(Double(k) * 10 + 10), language: k % 2 == 0 ? "en" : "ja"))
        }
        u += utterances(61, 73, "en")
        u += utterances(74, 83.7, "en")
        u.append(.init(range: s(84.0)..<s(86.6), language: "ja", tag: "J"))
        u += utterances(86.9, 99, "en")
        u += utterances(100, 124, "en")
        u += utterances(125, 140, "en")
        let engine = FlexibleEngine(utterances: u)
        engine.spans = [s(0)..<s(30), s(30)..<s(60)] + engine.spans.filter { $0.lowerBound >= s(61) }
        engine.detectModel = FlexibleEngine.whisperLike
        let samples = [Float](repeating: 0, count: s(140))
        // 一言を含む区切りの判定は、分け直すべき (0.97 未満) だが、上限を超えても分け直す (0.90 未満) ほど低くはない
        let map = try XCTUnwrap(engine.speechMap(of: samples))
        let chunk = try XCTUnwrap(SpeechChunker.chunks(map).first { $0.range.contains(s(85)) })
        let english = 1 - Double(try XCTUnwrap(engine.detectLanguage(samples, range: chunk.range, candidates: ["ja"])).first ?? 0)
        XCTAssertTrue((0.90..<0.97).contains(english), "\(english)")

        let out = try MixedPipeline.run(samples: samples, engine: engine, options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[J]") && $0.language == "ja" }, text)
        XCTAssertGreaterThan(out.report.islandDetections, 0, text)
    }

    func testNoiseSpreadOverAChunkIsNotSearchedForIslands() {
        // 雑音の多い 26 秒の英語の区切り: どこを聞いても日本語 0.12 (または 0.30)。両端も全体と同じくらい揺れているので、
        // 島は探さない (探すと 1 つの区切りで判定 45 回)
        var spans: [Range<Int>] = []
        var t = 0.5
        for k in 0..<5 {
            let length = 4.0 + Double(k % 3)
            spans.append(s(t)..<s(t + length))
            t += length + 0.3 + 0.15 * Double(k % 2)
        }
        let map = SpeechMap(spans: spans, totalSamples: s(t + 1))
        let chunk = SpeechChunk(range: spans[0].lowerBound..<spans[spans.count - 1].upperBound, spans: spans)
        for p in [0.12, 0.30] {
            let noisy = LanguageGuess(language: "en", confidence: 1 - p)
            let out = SwitchSearch.refine(chunk, guess: noisy, map: map, islandThreshold: { $0 == "en" ? 0.005 : nil },
                                          detect: { _ in noisy })
            XCTAssertLessThanOrEqual(out.detections, 16, "P(ja) \(p)")
            XCTAssertTrue(out.parts.allSatisfy { $0.guess?.language == "en" })
        }
    }

    func testLocateStillFindsAnIslandBetweenCleanEnds() throws {
        // 12 秒の英語の部分の中ほどに 2 秒の日本語。全体は英語 0.9 前後で揺れるが、両端ははっきり英語: 島を探して見つける
        let spans = [s(0)..<s(4.8), s(5.0)..<s(7.0), s(7.2)..<s(12)]
        let levels = vadLevels(spans, total: s(13))
        let map = SpeechMap(spans: spans, levels: levels, totalSamples: s(13))
        let piece = SpeechChunk(range: s(0)..<s(12), spans: spans)
        let japanese = s(5.0)..<s(7.0)
        let detect: (Range<Int>) -> LanguageGuess? = { range in
            let ja = max(0, min(range.upperBound, japanese.upperBound) - max(range.lowerBound, japanese.lowerBound))
            let share = Double(ja) / Double(range.count)
            let pja = share >= 0.75 ? 0.99 : (share <= 0.25 ? 0.0002 + 0.4 * share : share)
            return pja >= 0.5 ? LanguageGuess(language: "ja", confidence: pja) : LanguageGuess(language: "en", confidence: 1 - pja)
        }
        let whole = try XCTUnwrap(detect(piece.range))
        XCTAssertEqual(whole.language, "en")
        let out = SwitchSearch.locate(piece, guess: whole, map: map, detect: detect)
        let island = try XCTUnwrap(out.parts.first { $0.guess?.language == "ja" }, String(describing: out.parts))
        XCTAssertEqual(Double(island.chunk.range.lowerBound) / 16_000, 5.0, accuracy: 0.3)
        XCTAssertEqual(Double(island.chunk.range.upperBound) / 16_000, 7.0, accuracy: 0.3)
    }

    func testNearlySilentWindowsAreWidenedBeforeDetecting() {
        // 日本語の講演の 5 秒の部分: 先頭の 2 秒は 0.4 秒しか話していない。そのままの窓の判定は (無音に近いので) 英語と出て、
        // 無い切り替わりを作る。窓を 1 秒話すまで広げてから判定する
        let spans = [s(0)..<s(0.4), s(2.5)..<s(3.5), s(3.8)..<s(5.0)]
        let map = SpeechMap(spans: spans, levels: vadLevels(spans, total: s(6)), totalSamples: s(6))
        var windows: [Range<Int>] = []
        let detect: (Range<Int>) -> LanguageGuess? = { range in
            windows.append(range)
            return map.speechSamples(in: range) < s(1) ? LanguageGuess(language: "en", confidence: 0.98)
                : LanguageGuess(language: "ja", confidence: 0.99)
        }
        let b = SwitchSearch.bisect(s(0)..<s(5), map: map, detect: detect)
        XCTAssertNil(b.cut)
        XCTAssertEqual(b.head?.language, "ja")
        XCTAssertEqual(b.tail?.language, "ja")
        XCTAssertTrue(windows.allSatisfy { map.speechSamples(in: $0) >= s(1) }, String(describing: windows))
        // 窓は話しているところまでしか広げない (範囲の端はそのまま)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertLessThanOrEqual(windows.first?.upperBound ?? 0, s(3.5))
    }

    func testLocateTrustsAgreeingEndsOverAnUnsureWholeGuess() {
        // 6 秒の英語の部分: 全体の判定だけが日本語 0.6 に揺れ、先頭・末尾・中ほどの窓はどれも英語 0.999。島も無い
        let map = SpeechMap(spans: [s(30)..<s(36)], totalSamples: s(40))
        let piece = SpeechChunk(range: s(30)..<s(36), spans: map.spans)
        let out = SwitchSearch.locate(piece, guess: LanguageGuess(language: "ja", confidence: 0.6), map: map,
                                      detect: { _ in LanguageGuess(language: "en", confidence: 0.999) })
        XCTAssertEqual(out.parts.count, 1)
        XCTAssertEqual(out.parts.first?.guess?.language, "en")
        XCTAssertEqual(MixedPipeline.contiguousPlan(out.parts, in: piece.range, fallback: "ja").map(\.language), ["en"])
    }

    // MARK: - 直し

    func testHalfHalfRegionInAnEnglishRunKeepsTheEnglishSentence() throws {
        // 英語の講義: whisper の自信の低い英語の文 E (点検に引っかかる) のすぐ後に、英語で文字にすると消える 5 秒の日本語 J。
        // 2 つはまとまって 10 秒ほどの直す範囲になり、範囲全体の判定は日本語 0.954 (半分ずつ)。
        // 全体を日本語で文字にし直さず、切り替わりを探して、それぞれの言語で文字にする
        var u: [FlexibleEngine.Utterance] = []
        u += utterances(0, 19.7, "en")
        u += utterances(21, 30.7, "en")
        u.append(.init(range: s(31)..<s(35.7), language: "en", lp: -0.9, tag: "E"))
        u.append(.init(range: s(36)..<s(41), language: "ja", tag: "J"))
        u += utterances(41.3, 48.5, "en")
        u += utterances(50, 80, "en")
        let engine = FlexibleEngine(utterances: u)
        engine.detectModel = FlexibleEngine.halfHalf
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(81)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertEqual(out.report.runs.map(\.language), ["en"], text)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[J]") && $0.language == "ja" }, text)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[E]") && $0.language == "en" }, text)
    }

    func testHalfHalfRegionInAJapaneseRunKeepsTheJapaneseSentence() throws {
        // 同じことを日本語の番 (副講師の話) で: 自信の低い日本語の文 J2 の後に、日本語で文字にすると消える 5 秒の英語 E2
        var u: [FlexibleEngine.Utterance] = []
        u += utterances(0, 19.7, "ja")
        u += utterances(21, 30.7, "ja")
        u.append(.init(range: s(31)..<s(35.7), language: "ja", lp: -0.9, tag: "J2"))
        u.append(.init(range: s(36)..<s(41), language: "en", tag: "E2"))
        u += utterances(41.3, 48.5, "ja")
        u += utterances(50, 80, "ja")
        let engine = FlexibleEngine(utterances: u)
        engine.detectModel = FlexibleEngine.halfHalf
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(81)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertEqual(out.report.runs.map(\.language), ["ja"], text)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[E2]") && $0.language == "en" }, text)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[J2]") && $0.language == "ja" }, text)
    }

    func testAnUnsureOtherLanguageGuessDoesNotRedecodeTheRegion() throws {
        // 30〜38 秒: whisper の自信の低い英語の文 (点検に引っかかる)。その範囲全体の判定だけが日本語 0.6 に揺れ、
        // 4 秒・2 秒の窓はどれも英語。日本語で文字にし直すと、英語を日本語に訳したような (点検に引っかからない) 文になる。
        // 確からしさの低い判定では文字にし直さない
        var u: [FlexibleEngine.Utterance] = []
        u += utterances(0, 19.7, "en")
        u += utterances(20.7, 29.7, "en")
        u.append(.init(range: s(30)..<s(38), language: "en", lp: -0.9, tag: "E"))
        u += utterances(38.3, 48, "en")
        u += utterances(49, 80, "en")
        let engine = FlexibleEngine(utterances: u)
        engine.cross["ja"] = .translate
        let region = s(29.8)..<s(38.2)
        engine.detectModel = { ja, en, range in
            if range == region { return 0.6 }
            return FlexibleEngine.whisperLike(ja, en, range)
        }
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(80)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertEqual(out.report.runs.map(\.language), ["en"], text)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[E]") && $0.language == "en" }, text)
        XCTAssertFalse(out.report.repairs.contains(where: \.accepted), text)
    }

    func testAnEmptyPartDoesNotDeleteItsLine() throws {
        // whisper の 8 秒の区間は切り替わりをまたぐ: 40〜48 秒の区間に、英語 4 秒と、日本語 4 秒の訳のような英文
        // (点検に引っかかる)。切り替わりを見つけて日本語の部分を文字にし直すと、何も返らない。元の文を消さない
        var u: [FlexibleEngine.Utterance] = []
        u += utterances(0, 19.7, "en")
        u += utterances(20.7, 39.7, "en")
        u.append(.init(range: s(40)..<s(43.8), language: "en", tag: "A"))
        u.append(.init(range: s(44)..<s(48), language: "ja", tag: "J"))
        u += utterances(49, 76, "en")
        u += utterances(77, 90, "en")
        let engine = FlexibleEngine(utterances: u)
        engine.fixedWindows = 8
        engine.cross["en"] = .pseudo
        engine.minorityProbability = 0.0001
        engine.emptyDecodes = ["ja"]
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(90)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertEqual(out.report.runs.map(\.language), ["en"], text)
        XCTAssertTrue(out.segments.contains { $0.start < 47 && $0.end > 45 && $0.text.contains("heat") }, text)
        XCTAssertFalse(out.report.repairs.contains(where: \.accepted), text)
    }

    /// 英語の講義: 20.7〜49.7 秒は whisper の自信の低い会場の質問 (8 秒の区間がどれも点検に引っかかり、28 秒より長い
    /// 直す範囲になる)。50.7〜56.4 秒は日本語の一言 (区切りの 2 割で、区切りの判定は英語)。8 秒の区間は切り替わりをまたぎ、
    /// 48〜56 秒の区間は、質問の最後の 1.7 秒を持ち、日本語を飛ばす
    private func questionThenRemark(shift: Double = 0) -> FlexibleEngine {
        var u: [FlexibleEngine.Utterance] = []
        u += utterances(0, 19.7 + shift, "en")
        u += utterances(20.7 + shift, 49.7 + shift, "en", lp: -0.9)
        u[u.count - 1].tag = "Q"
        u.append(.init(range: s(50.7 + shift)..<s(56.4 + shift), language: "ja", tag: "J"))
        u += utterances(56.7 + shift, 77 + shift, "en")
        u += utterances(78 + shift, 100 + shift, "en")
        let engine = FlexibleEngine(utterances: u)
        engine.minorityProbability = 0.0001
        engine.fixedWindows = 8
        return engine
    }

    func testALineCrossingThePiecesOfALongRegionKeepsItsWords() throws {
        // 長い直す範囲は分けて判定するが、入れ替えはまとめて行う: 分けた境目 (50.2 秒) をまたぐ 48〜56 秒の区間の、
        // 質問の部分 (48.0〜49.7 秒) も文字にし直して残す
        for length in [100.0, 560.0] {
            let engine = questionThenRemark()
            if length > 100 {
                engine.utterances += utterances(101, length, "en")
                engine.spans = engine.utterances.map(\.range)
            }
            let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(length)), engine: engine,
                                            options: MixedPipeline.Options(candidates: ["ja", "en"]))
            let text = describe(out)
            XCTAssertTrue(out.segments.contains { $0.text.contains("[J]") && $0.language == "ja" }, text)
            XCTAssertTrue(out.segments.contains { $0.language == "en" && $0.text.contains("[Q]") && $0.start < 48.5 && $0.end > 49.5 },
                          text)
        }
    }

    func testALineCrossingThePiecesIsNotShownTwice() throws {
        // 4 秒ずらすと、境目をまたぐ区間の真ん中は英語の側に入る。日本語の一言の訳のような英文を、日本語の文と並べて残さない
        let engine = questionThenRemark(shift: 4)
        engine.cross["en"] = .pseudo
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(104)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertEqual(out.report.runs.map(\.language), ["en"], text)
        XCTAssertTrue(out.segments.contains { $0.text.contains("[J]") && $0.language == "ja" }, text)
        XCTAssertFalse(out.segments.contains { $0.text.contains("heat") }, text)
    }

    func testRedecodeSpansCoverEveryLineTheyTouch() {
        // 日本語の部分 44〜48.2 秒に、40〜48 秒の区間が重なる: 文字にし直す範囲は 40 秒から (32〜40 秒の区間には重ならない)
        let plan: [(range: Range<Int>, language: String)] = [(s(39.8)..<s(43.98), "en"), (s(43.98)..<s(48.2), "ja")]
        let lines = [DecodedSegment(start: 32, end: 40, text: "a", language: "en"),
                     DecodedSegment(start: 40, end: 48, text: "b", language: "en")]
        XCTAssertEqual(MixedPipeline.redecodeSpans(plan, runLanguage: "en", segments: lines, within: s(39.8)..<s(48.2)),
                       [s(40)..<s(48.2)])
        // 区間に重ならない日本語は、そのまま
        XCTAssertEqual(MixedPipeline.redecodeSpans(plan, runLanguage: "en", segments: [lines[0]], within: s(39.8)..<s(48.2)),
                       [s(43.98)..<s(48.2)])
        // 広げた分のわずかな切れ端は、となりの部分に含める
        let map = SpeechMap(spans: [s(39.8)..<s(48.2)], totalSamples: s(50))
        let parts = MixedPipeline.absorbShortParts([(s(39.8)..<s(40.2), "en"), (s(40.2)..<s(48.2), "ja")], map: map)
        XCTAssertEqual(parts.map(\.language), ["ja"])
        XCTAssertEqual(parts.first?.range, s(39.8)..<s(48.2))
    }
}

// MARK: - 台本どおりに答える whisper (発話ごとの正解つき)

private func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }

private func vadLevels(_ spans: [Range<Int>], total: Int) -> [Float] {
    var levels = [Float](repeating: 0.05, count: total / 512 + 1)
    for span in spans {
        for k in (span.lowerBound / 512)..<min(levels.count, span.upperBound / 512) { levels[k] = 0.9 }
    }
    return levels
}

private final class FlexibleEngine: MixedEngine {
    struct Utterance {
        var range: Range<Int>
        var language: String
        /// その言語で文字にしたときの、対数確率の平均
        var lp: Double = -0.15
        /// 文に付ける目印 (試験で文を探すため)
        var tag: String? = nil
    }

    /// 別の言語の発話を、指定した言語で文字にしたときの結果
    enum Cross { case drop, pseudo, translate }

    var utterances: [Utterance]
    var spans: [Range<Int>]
    var cross: [String: Cross] = ["en": .drop, "ja": .drop]
    /// 区間の長さ (秒)。nil なら発話ごと (8 秒で切る)。本物の whisper のように切り替わりをまたがせるときに使う
    var fixedWindows: Double? = nil
    /// 判定: (日本語のサンプル数, 英語のサンプル数, 範囲) → 日本語の確率 (nil なら答えない)
    var detectModel: ((Int, Int, Range<Int>) -> Float?)? = nil
    /// detectModel が無いとき、少ない側 (1/4 以下) の確率
    var minorityProbability: Float = 0.01
    /// この言語で文字にすると、何も返らない
    var emptyDecodes: Set<String> = []

    init(utterances: [Utterance]) {
        self.utterances = utterances
        self.spans = utterances.map(\.range)
    }

    /// whisper のような判定: 少ない側が 1/4 以下なら、割合よりずっと低い確率でしか聞き取らない
    static func whisperLike(_ ja: Int, _ en: Int, _ range: Range<Int>) -> Float? {
        guard ja + en > 0 else { return nil }
        let share = Float(ja) / Float(ja + en)
        if share >= 0.75 { return 1 - (0.0002 + 0.4 * (1 - share)) }
        if share <= 0.25 { return share > 0 ? 0.0002 + 0.4 * share : 0.0001 }
        return share
    }

    /// 半分ずつなら、多い側を 0.954 と判定する (本物の turbo で測った値)
    static func halfHalf(_ ja: Int, _ en: Int, _ range: Range<Int>) -> Float? {
        guard ja + en > 0 else { return nil }
        let share = Float(ja) / Float(ja + en)
        if share >= 0.75 { return 0.9999 }
        if share <= 0.25 { return 0.0001 }
        if share > 0.35 && share < 0.65 { return share >= 0.5 ? 0.954 : 0.046 }
        return share
    }

    func speechMap(of samples: [Float]) throws -> SpeechMap? {
        SpeechMap(spans: spans, levels: vadLevels(spans, total: samples.count), totalSamples: samples.count)
    }

    private static func overlap(_ a: Range<Int>, _ b: Range<Int>) -> Int {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]? {
        var ja = 0, en = 0
        for u in utterances {
            if u.language == "ja" { ja += Self.overlap(u.range, range) } else { en += Self.overlap(u.range, range) }
        }
        let pja: Float
        if let model = detectModel {
            guard let p = model(ja, en, range) else { return nil }
            pja = p
        } else {
            guard ja + en > 0 else { return nil }
            var p = Float(ja) / Float(ja + en)
            if p >= 0.75 { p = 1 - minorityProbability } else if p <= 0.25 { p = p > 0 ? minorityProbability : 0.0001 }
            pja = p
        }
        let p: [String: Float] = ["ja": pja, "en": 1 - pja]
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

    /// 発話 u の a..<e を language で文字にした文 (nil なら飛ばす)
    private func piece(_ u: Utterance, _ a: Int, _ e: Int, language: String) -> (text: String, lp: Double)? {
        if u.language == language {
            let text = Self.text(seconds: Double(e - a) / 16_000, language: language, seed: a)
            return (u.tag.map { "[\($0)] " + text } ?? text, u.lp)
        }
        switch cross[language] ?? .drop {
        case .drop: return nil
        case .pseudo: return ("The heat is not too high.", -1.1)
        case .translate:
            let text = Self.text(seconds: Double(e - a) / 16_000, language: language, seed: a &+ 7)
            return (u.tag.map { "[\($0)>\(language)] " + text } ?? text, -0.2)
        }
    }

    func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment] {
        var out: [DecodedSegment] = []
        defer { onProgress(1) }
        if emptyDecodes.contains(language) { return [] }
        if let window = fixedWindows {
            var t = range.lowerBound
            while t < range.upperBound {
                let end = min(range.upperBound, t + s(window))
                var texts: [String] = []
                var sum = 0.0, weight = 0.0
                for u in utterances {
                    let a = max(u.range.lowerBound, t), e = min(u.range.upperBound, end)
                    guard e - a >= 16_000, let p = piece(u, a, e, language: language) else { continue }
                    texts.append(p.text)
                    sum += p.lp * Double(e - a)
                    weight += Double(e - a)
                }
                if !texts.isEmpty {
                    let segment = DecodedSegment(start: Double(t) / 16_000, end: Double(end) / 16_000,
                                                 text: texts.joined(separator: " "), tokenCount: 24,
                                                 meanLogProb: sum / weight, language: language)
                    onSegment(segment)
                    out.append(segment)
                }
                t = end
            }
            return out
        }
        for u in utterances {
            let a = max(u.range.lowerBound, range.lowerBound), e = min(u.range.upperBound, range.upperBound)
            guard e - a >= 16_000 else { continue }
            var t = a
            while t < e {
                let end = min(e, t + 8 * 16_000)
                if let p = piece(u, t, end, language: language) {
                    let segment = DecodedSegment(start: Double(t) / 16_000, end: Double(end) / 16_000, text: p.text,
                                                 tokenCount: 12, meanLogProb: p.lp, language: language)
                    onSegment(segment)
                    out.append(segment)
                }
                t = end
            }
        }
        return out
    }
}

/// language の発話 (length 秒、間は pause 秒) を a から b まで並べる
private func utterances(_ a: Double, _ b: Double, _ language: String, length: Double = 4.7, pause: Double = 0.3,
                        lp: Double = -0.15) -> [FlexibleEngine.Utterance] {
    var out: [FlexibleEngine.Utterance] = []
    var t = a
    while t < b - 0.05 {
        let end = min(b, t + length)
        out.append(FlexibleEngine.Utterance(range: s(t)..<s(end), language: language, lp: lp))
        t = end + pause
    }
    return out
}

/// 失敗したときに見る記録
private func describe(_ out: MixedPipeline.Output) -> String {
    var lines = out.segments.map { String(format: "  %.2f-%.2f %@ %@", $0.start, $0.end, $0.language ?? "?", String($0.text.prefix(50))) }
    lines.append("runs: " + out.report.runs.map { String(format: "%.2f-%.2f %@", $0.start, $0.end, $0.language) }.joined(separator: ", "))
    lines.append("chunks: " + out.report.chunks.map { String(format: "%.2f-%.2f %@ %.4f", $0.start, $0.end, $0.language, $0.confidence ?? -1) }
        .joined(separator: ", "))
    lines.append("flagged: " + out.report.flagged.map { String(format: "%.2f-%.2f %@", $0.start, $0.end, $0.flags.joined(separator: "+")) }
        .joined(separator: ", "))
    for r in out.report.repairs {
        lines.append(String(format: "repair %.2f-%.2f run %@ detected %@ %.4f as %@ accepted %@", r.start, r.end, r.runLanguage,
                            r.detected ?? "-", r.confidence ?? -1, r.decodedAs.joined(separator: ","), r.accepted ? "yes" : "no"))
    }
    lines.append("detections \(out.report.detections) refine \(out.report.refinementDetections) island \(out.report.islandDetections)"
                 + " repair \(out.report.repairDetections)")
    return lines.joined(separator: "\n")
}
