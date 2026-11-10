import XCTest
@testable import KikimimiCore

// 「日本語＋英語」の、監査で見つけた場面と、乱数で作った録音での確認。
// PropEngine は、発話ごとの正解を持つ台本どおりの whisper。文字にした部分に目印 ([pN]) を付けるので、
// どの発話のどこを正しい言語で文字にしたかを秒数で測れる

private func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }

private func vadLevels(_ spans: [Range<Int>], total: Int) -> [Float] {
    var levels = [Float](repeating: 0.05, count: total / 512 + 1)
    for span in spans {
        for k in (span.lowerBound / 512)..<min(levels.count, span.upperBound / 512) { levels[k] = 0.9 }
    }
    return levels
}

/// language の発話 (length 秒、間は pause 秒) を a から b まで並べる
private func utterances(_ a: Double, _ b: Double, _ language: String, length: Double = 4.7, pause: Double = 0.3,
                        lp: Double = -0.15) -> [PropEngine.Utterance] {
    var out: [PropEngine.Utterance] = []
    var t = a
    while t < b - 0.05 {
        let end = min(b, t + length)
        out.append(PropEngine.Utterance(range: s(t)..<s(end), language: language, lp: lp))
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

/// 決定的な乱数 (SplitMix64)
private struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func double(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

private enum PropError: Error { case tooManyCalls }

/// 発話ごとの正解を持ち、文字にした部分に目印 ([pN]) を付けて、どの発話のどこを正しい言語で文字にしたかを追える whisper
private final class PropEngine: MixedEngine {
    struct Utterance {
        var range: Range<Int>
        var language: String
        var lp: Double = -0.15
    }
    enum Cross { case drop, pseudo, translate }
    enum Model { case proportional, whisperLike, halfHalf }

    var utterances: [Utterance]
    var spans: [Range<Int>]
    var useVAD = true
    var cross: [String: Cross] = ["en": .drop, "ja": .drop]
    var fixedWindows: Double? = nil
    var model: Model = .whisperLike
    var minorityProbability: Float = 0.01
    /// 判定の揺れ (範囲ごとに決まった値を足す)
    var jitter: Double = 0
    /// 話していない範囲の判定 (nil なら答えない)
    var silentGuess: Float? = nil
    var emptyDecodes: Set<String> = []

    // 記録
    struct Piece { var utterance: Int; var range: Range<Int>; var language: String }
    var pieces: [Piece] = []
    var decodeLog: [(range: Range<Int>, language: String, segments: [DecodedSegment])] = []
    var detectLog: [Range<Int>] = []
    var maxCalls = 50_000

    init(utterances: [Utterance]) {
        self.utterances = utterances
        self.spans = utterances.map(\.range)
    }

    static func whisperLike(_ ja: Int, _ en: Int, _ range: Range<Int>) -> Float? {
        guard ja + en > 0 else { return nil }
        let share = Float(ja) / Float(ja + en)
        if share >= 0.75 { return 1 - (0.0002 + 0.4 * (1 - share)) }
        if share <= 0.25 { return share > 0 ? 0.0002 + 0.4 * share : 0.0001 }
        return share
    }

    static func halfHalf(_ ja: Int, _ en: Int, _ range: Range<Int>) -> Float? {
        guard ja + en > 0 else { return nil }
        let share = Float(ja) / Float(ja + en)
        if share >= 0.75 { return 0.9999 }
        if share <= 0.25 { return 0.0001 }
        if share > 0.35 && share < 0.65 { return share >= 0.5 ? 0.954 : 0.046 }
        return share
    }

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

    func speechMap(of samples: [Float]) throws -> SpeechMap? {
        guard useVAD else { return nil }
        return SpeechMap(spans: spans, levels: vadLevels(spans, total: samples.count), totalSamples: samples.count)
    }

    static func overlap(_ a: Range<Int>, _ b: Range<Int>) -> Int {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    static func hash(_ r: Range<Int>) -> Double {
        var x = UInt64(truncatingIfNeeded: r.lowerBound) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: r.upperBound) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= x >> 29
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 32
        return Double(x >> 11) / Double(1 << 53)
    }

    func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]? {
        detectLog.append(range)
        if detectLog.count + decodeLog.count > maxCalls { throw PropError.tooManyCalls }
        precondition(!range.isEmpty, "empty detect range")
        precondition(range.lowerBound >= 0 && range.upperBound <= samples.count, "detect range outside the audio")
        var ja = 0, en = 0
        for u in utterances {
            if u.language == "ja" { ja += Self.overlap(u.range, range) } else { en += Self.overlap(u.range, range) }
        }
        var pja: Float
        if ja + en == 0 {
            guard let p = silentGuess else { return nil }
            pja = p
        } else {
            let share = Float(ja) / Float(ja + en)
            switch model {
            case .proportional:
                pja = share
                if share >= 0.75 { pja = 1 - minorityProbability } else if share <= 0.25 { pja = share > 0 ? minorityProbability : 0.0001 }
            case .whisperLike:
                pja = PropEngine.whisperLike(ja, en, range) ?? 0.5
            case .halfHalf:
                pja = PropEngine.halfHalf(ja, en, range) ?? 0.5
            }
        }
        if jitter > 0 {
            pja = Float(min(0.9999, max(0.0001, Double(pja) + jitter * (2 * Self.hash(range) - 1))))
        }
        let p: [String: Float] = ["ja": pja, "en": 1 - pja]
        return candidates.map { p[$0] ?? 0 }
    }

    private func piece(_ index: Int, _ a: Int, _ e: Int, language: String) -> (text: String, lp: Double)? {
        let u = utterances[index]
        if u.language == language {
            let text = PropEngine.text(seconds: Double(e - a) / 16_000, language: language, seed: a)
            pieces.append(Piece(utterance: index, range: a..<e, language: language))
            return ("[p\(pieces.count - 1)] " + text, u.lp)
        }
        switch cross[language] ?? .drop {
        case .drop: return nil
        case .pseudo: return ("The heat is not too high.", -1.1)
        case .translate:
            return (PropEngine.text(seconds: Double(e - a) / 16_000, language: language, seed: a &+ 7), -0.2)
        }
    }

    func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment] {
        precondition(!range.isEmpty, "empty decode range")
        precondition(range.lowerBound >= 0 && range.upperBound <= samples.count, "decode range outside the audio")
        if detectLog.count + decodeLog.count > maxCalls { throw PropError.tooManyCalls }
        var out: [DecodedSegment] = []
        defer {
            onProgress(1)
            decodeLog.append((range, language, out))
        }
        if emptyDecodes.contains(language) { return [] }
        if let window = fixedWindows {
            var t = range.lowerBound
            while t < range.upperBound {
                let end = min(range.upperBound, t + s(window))
                var texts: [String] = []
                var sum = 0.0, weight = 0.0
                for (i, u) in utterances.enumerated() {
                    let a = max(u.range.lowerBound, t), e = min(u.range.upperBound, end)
                    guard e - a >= 16_000, let p = piece(i, a, e, language: language) else { continue }
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
        for (i, u) in utterances.enumerated() {
            let a = max(u.range.lowerBound, range.lowerBound), e = min(u.range.upperBound, range.upperBound)
            guard e - a >= 16_000 else { continue }
            var t = a
            while t < e {
                let end = min(e, t + 8 * 16_000)
                if let p = piece(i, t, end, language: language) {
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

    /// 文の目印から、正しい言語で文字にした部分 (発話ごとの範囲) を集める
    func coverage(of texts: [String]) -> [Int: [Range<Int>]] {
        var out: [Int: [Range<Int>]] = [:]
        for text in texts {
            var rest = Substring(text)
            while let open = rest.range(of: "[p") {
                rest = rest[open.upperBound...]
                guard let close = rest.firstIndex(of: "]"), let n = Int(rest[..<close]), n < pieces.count else { continue }
                out[pieces[n].utterance, default: []].append(pieces[n].range)
            }
        }
        return out
    }

    /// 範囲の合計の長さ (重なりは 1 回) と、重なって二重になっている長さ
    static func union(_ ranges: [Range<Int>]) -> (covered: Int, doubled: Int) {
        var covered = 0, total = 0
        var end = Int.min
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            total += r.count
            if r.upperBound > end {
                covered += r.upperBound - max(end, r.lowerBound)
                end = r.upperBound
            }
        }
        return (covered, total - covered)
    }
}

/// 乱数で作った録音
private struct Scenario {
    var engine: PropEngine
    var total: Int
    var note: String

    static func random(seed: UInt64) -> Scenario {
        var rng = Rng(seed)
        let style = rng.int(6)
        let length = rng.double(20, style == 5 ? 400 : 160)
        var u: [PropEngine.Utterance] = []
        var t = rng.double(0, 2)
        var language = rng.chance(0.5) ? "en" : "ja"
        // 言語の入れ替わり方: 0 = ブロックごと, 1 = 英語の中に短い日本語, 2 = 日本語の中に短い英語, 3 = でたらめ, 4 = 1 言語, 5 = 長い録音
        let host = language
        while t < length - 1 {
            var len = rng.double(0.4, 9)
            var lang = language
            switch style {
            case 0, 5:
                if rng.chance(0.12) { language = language == "en" ? "ja" : "en" }
                lang = language
            case 1, 2:
                let h = style == 1 ? "en" : "ja"
                if rng.chance(0.2) {
                    lang = h == "en" ? "ja" : "en"
                    len = rng.double(0.8, 5.5)
                } else {
                    lang = h
                }
            case 3:
                lang = rng.chance(0.5) ? "en" : "ja"
            default:
                lang = host
            }
            let end = min(length, t + len)
            guard end - t >= 0.3 else { break }
            let lp = rng.chance(0.12) ? rng.double(-1.4, -0.4) : -0.15
            u.append(.init(range: s(t)..<s(end), language: lang, lp: lp))
            // 間: 無い (0) こともある
            let r = rng.unit()
            let gap = r < 0.25 ? 0 : (r < 0.8 ? rng.double(0.1, 0.6) : rng.double(0.6, 6))
            t = end + gap
        }
        let engine = PropEngine(utterances: u)
        // VAD の区間: 短い間はつなぐ
        let join = rng.pick([0.0, 0.05, 0.2, 0.45])
        var spans: [Range<Int>] = []
        for x in u {
            if let last = spans.last, x.range.lowerBound - last.upperBound <= s(join) {
                spans[spans.count - 1] = last.lowerBound..<x.range.upperBound
            } else {
                spans.append(x.range)
            }
        }
        engine.spans = spans
        engine.useVAD = !rng.chance(0.2)
        engine.model = rng.pick([.proportional, .whisperLike, .whisperLike, .halfHalf])
        engine.minorityProbability = Float(rng.pick([0.0001, 0.01, 0.05]))
        engine.jitter = rng.pick([0, 0, 0.002, 0.03, 0.2])
        engine.silentGuess = rng.chance(0.3) ? Float(rng.pick([0.02, 0.5, 0.98])) : nil
        let crosses: [PropEngine.Cross] = [.drop, .drop, .pseudo, .translate]
        engine.cross = ["en": rng.pick(crosses), "ja": rng.pick(crosses)]
        engine.fixedWindows = rng.chance(0.45) ? rng.pick([8.0, 5.0, 12.0, 27.0]) : nil
        if rng.chance(0.05) { engine.emptyDecodes = [rng.pick(["ja", "en"])] }
        let total = s(length + rng.double(0, 3))
        let note = "seed \(seed) style \(style) vad \(engine.useVAD) model \(engine.model) minority \(engine.minorityProbability)"
            + " jitter \(engine.jitter) silent \(String(describing: engine.silentGuess)) cross \(engine.cross)"
            + " windows \(String(describing: engine.fixedWindows)) empty \(engine.emptyDecodes) join \(join)"
        return Scenario(engine: engine, total: total, note: note)
    }
}

/// 監査で見つけた場面 (どれも、直す前は失敗した) と、乱数で作った録音での決まりごとの確認
final class MixedLanguagePropertyTests: XCTestCase {
    private func ja(_ a: Double, _ b: Double, lp: Double = -0.15) -> PropEngine.Utterance { .init(range: s(a)..<s(b), language: "ja", lp: lp) }
    private func en(_ a: Double, _ b: Double, lp: Double = -0.15) -> PropEngine.Utterance { .init(range: s(a)..<s(b), language: "en", lp: lp) }
    private func fill(_ a: Double, _ b: Double, _ language: String) -> [PropEngine.Utterance] { utterances(a, b, language) }

    /// 正しい言語で文字になった秒数 (発話 index)
    private func covered(_ engine: PropEngine, _ out: MixedPipeline.Output, _ index: Int) -> Double {
        Double(PropEngine.union(engine.coverage(of: out.segments.map(\.text))[index] ?? []).covered) / 16_000
    }

    // MARK: - 1. 何も出ない切れ端が、直し全体を取りやめさせる

    /// VAD なし。日本語の講演: 35〜39.7 秒は whisper の自信の低い日本語の文 (点検に引っかかる)、40〜43.4 秒は間、
    /// 43.4〜47.9 秒は英語 (区切りの 1/4 以下なので、区切りの判定は日本語)。5 秒ごとの区間は切り替わりをまたぐ:
    /// 40〜45 秒の区間は、間と、英語を日本語で文字にした崩れた文。
    /// 直しは切り替わりを正しく見つける (間の中。日本語 〜41.6 秒 / 英語 41.6 秒〜) が、英語の部分を、重なる元の区間
    /// (40〜45 秒) の始まりまで広げたときにできる日本語の切れ端 (40〜41.6 秒。間だけ) から何も出ないので、
    /// 「元の文を消す」とみなして直し全体を捨てる。英語は崩れた文のまま残る (0e638a8 の前は英語で文字にし直していた)
    func testASilentSliverDoesNotCancelTheWholeRepair() throws {
        var u = fill(0, 34.7, "ja")
        u.append(ja(35.0, 39.7, lp: -0.9))
        let english = u.count
        u.append(en(43.4, 47.9))
        u += fill(50.5, 75, "ja")
        let engine = PropEngine(utterances: u)
        engine.useVAD = false
        engine.model = .halfHalf
        engine.fixedWindows = 5
        engine.cross = ["ja": .pseudo, "en": .drop]
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(75)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertEqual(out.report.runs.map(\.language), ["ja"], text)
        XCTAssertGreaterThan(covered(engine, out, english), 4.0, text)
        XCTAssertFalse(out.segments.contains { $0.text.contains("heat") }, text)
    }

    // MARK: - 2. 日本語にはさまれた英語を、分けて判定し直しても探さない

    /// 18.5 秒の部分: 日本語 6.5 秒 → 英語 4.85 秒 → 日本語 6.85 秒 (間は 0.15 秒)。全体の判定は日本語 0.73。
    /// 両端は日本語なので切り替わりは無い。中ほどの英語を島として分け出すこと (0e638a8 の前は分け出していた)
    func testLocateFindsEnglishBetweenJapaneseEnds() throws {
        let u = [ja(5.5, 12.0), en(12.15, 17.0), ja(17.15, 24.0)]
        let engine = PropEngine(utterances: u)
        engine.model = .whisperLike
        let samples = [Float](repeating: 0, count: s(25))
        let map = try XCTUnwrap(engine.speechMap(of: samples))
        let piece = SpeechChunk(range: s(5.5)..<s(24.0), spans: map.spans)
        let detect: (Range<Int>) throws -> LanguageGuess? = { range in
            try engine.detectLanguage(samples, range: range, candidates: ["ja", "en"]).flatMap {
                LanguageGuess(probabilities: $0, candidates: ["ja", "en"])
            }
        }
        let whole = try XCTUnwrap(detect(piece.range))
        XCTAssertEqual(whole.language, "ja")
        XCTAssertLessThan(whole.confidence, 0.75)
        let out = try SwitchSearch.locate(piece, guess: whole, map: map, detect: detect)
        let parts = out.parts.map { String(format: "%.2f-%.2f %@ %.4f", Double($0.chunk.range.lowerBound) / 16_000,
                                           Double($0.chunk.range.upperBound) / 16_000, $0.guess?.language ?? "-",
                                           $0.guess?.confidence ?? -1) }.joined(separator: ", ")
        XCTAssertTrue(out.parts.contains { $0.guess?.language == "en" }, parts)
    }

    /// 同じ場面を全体で: 日本語の講演の途中の英語の引用 4.85 秒。8 秒ごとの区間は切り替わりをまたぐので、
    /// 日本語で文字にしても抜けの点検に残らない。英語として文字にすること
    func testEnglishQuoteInsideAJapaneseChunkIsDecodedAsEnglish() throws {
        var u = fill(0, 4.5, "ja")
        u.append(ja(5.5, 12.0))
        let english = u.count
        u.append(en(12.15, 17.0))
        u.append(ja(17.15, 24.0))
        u += fill(25.0, 27.5, "ja")
        u += fill(29.5, 56, "ja")
        u += fill(57.5, 80, "ja")
        for vad in [true, false] {
            let engine = PropEngine(utterances: u)
            engine.useVAD = vad
            engine.model = .whisperLike
            engine.fixedWindows = 8
            let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(80)), engine: engine,
                                            options: MixedPipeline.Options(candidates: ["ja", "en"]))
            let text = "VAD \(vad)\n" + describe(out)
            XCTAssertGreaterThan(covered(engine, out, english), 3.5, text)
        }
    }

    // MARK: - 3. 上限を超えた区切りの島探し

    /// 最初の 60 秒で分けて判定し直す回数を使い切る。その後の英語の講義の区切りには、日本語の一言が前半と後半に 1 つずつ。
    /// 区切りは英語 0.93 前後 (分け直すべきだが上限を超えている)。半分にした 2 つが同じくらい日本語らしいので、
    /// 雑音とみなして探さない。そのうえ、その区切りを「混ざっていない区切り」に数えるので、しきい値が上がり、
    /// 後の区切りの一言 (1 つだけ。testOverBudgetChunksAreStillSearchedForIslands と同じ) も探さなくなる
    func testIslandsInBothHalvesOfOverBudgetChunksDoNotStopLaterSearches() throws {
        var u: [PropEngine.Utterance] = []
        for k in 0..<6 { u.append(k % 2 == 0 ? en(Double(k) * 10, Double(k) * 10 + 10) : ja(Double(k) * 10, Double(k) * 10 + 10)) }
        u += fill(61, 73, "en")
        var remarks: [Int] = []
        var t = 74.0
        for _ in 0..<4 {
            // 25 秒の区切り: 英語 5.7 / 日本語 2.2 / 英語 8.5 / 日本語 2.2 / 英語 5.2 (間は 0.3 秒)
            u.append(en(t, t + 5.7))
            remarks.append(u.count)
            u.append(ja(t + 6.0, t + 8.2))
            u += fill(t + 8.5, t + 17.0, "en")
            remarks.append(u.count)
            u.append(ja(t + 17.3, t + 19.5))
            u.append(en(t + 19.8, t + 25.0))
            t += 26
        }
        // 一言が 1 つだけの区切り
        u += fill(t, t + 9.7, "en")
        let single = u.count
        u.append(ja(t + 10.0, t + 12.6))
        u += fill(t + 12.9, t + 25, "en")
        u += fill(t + 26, t + 50, "en")
        let engine = PropEngine(utterances: u)
        engine.spans = [s(0)..<s(30), s(30)..<s(60)] + engine.spans.filter { $0.lowerBound >= s(61) }
        engine.model = .whisperLike
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(t + 51)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        let text = describe(out)
        XCTAssertGreaterThan(covered(engine, out, single), 1.5, "一言が 1 つだけの区切り\n" + text)
        for r in remarks { XCTAssertGreaterThan(covered(engine, out, r), 1.2, "前半と後半の一言 (発話 \(r))\n" + text) }
    }

    /// 上の場面の後ろ半分だけ (一言が 1 つだけの区切り) なら見つかる: しきい値が上がったせいで探さなくなったことの確かめ
    func testTheSingleRemarkIsFoundWithoutTheEarlierChunks() throws {
        var u: [PropEngine.Utterance] = []
        for k in 0..<6 { u.append(k % 2 == 0 ? en(Double(k) * 10, Double(k) * 10 + 10) : ja(Double(k) * 10, Double(k) * 10 + 10)) }
        u += fill(61, 73, "en")
        let t = 74.0
        u += fill(t, t + 9.7, "en")
        let single = u.count
        u.append(ja(t + 10.0, t + 12.6))
        u += fill(t + 12.9, t + 25, "en")
        u += fill(t + 26, t + 50, "en")
        let engine = PropEngine(utterances: u)
        engine.spans = [s(0)..<s(30), s(30)..<s(60)] + engine.spans.filter { $0.lowerBound >= s(61) }
        engine.model = .whisperLike
        let out = try MixedPipeline.run(samples: [Float](repeating: 0, count: s(t + 51)), engine: engine,
                                        options: MixedPipeline.Options(candidates: ["ja", "en"]))
        XCTAssertGreaterThan(covered(engine, out, single), 1.5, describe(out))
    }

    // MARK: - 乱数で作った録音

    /// 乱数で作った 150 通りの録音 (20〜400 秒。言語の入れ替わり・短い差し込み・VAD の有無・判定の揺れ・区間の切れ方を変える) で、
    /// どんな入力でも守る決まりごとを確かめる: 落ちない・止まる・空の範囲を whisper に渡さない (PropEngine の precondition)・
    /// 区間は音声の中で時刻の順・文字にする範囲はすき間なく全体を覆う・判定と直しの回数の記録が実際と合う・
    /// 直しは上限を超えない・中身を空にする直しを受け入れない
    func testInvariantsHoldOnRandomRecordings() throws {
        for seed in UInt64(0)..<150 {
            let scenario = Scenario.random(seed: seed)
            let engine = scenario.engine
            let samples = [Float](repeating: 0, count: scenario.total)
            let out = try MixedPipeline.run(samples: samples, engine: engine, options: MixedPipeline.Options(candidates: ["ja", "en"]))
            let note = scenario.note
            let audio = Double(scenario.total) / 16_000
            var seen = Set<String>()
            var previous = -1.0
            for segment in out.segments {
                XCTAssertTrue(segment.start >= 0 && segment.end <= audio + 1e-6 && segment.end >= segment.start, note)
                XCTAssertGreaterThanOrEqual(segment.start, previous, note)
                previous = segment.start
                XCTAssertTrue(seen.insert("\(segment.start)|\(segment.text)").inserted, note)
            }
            let runs = out.report.runs
            if let first = runs.first, let last = runs.last {
                XCTAssertEqual(first.start, 0, note)
                XCTAssertEqual(last.end, audio, accuracy: 1e-9, note)
                for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertEqual(a.end, b.start, note) }
                XCTAssertTrue(runs.allSatisfy { $0.end > $0.start }, note)
            }
            let map = (try? engine.speechMap(of: samples)) ?? SpeechMap.withoutVAD(samples)
            let limit = max(Int(Double(map.totalSpeechSamples) * MixedLanguageRules.repairSpeechShare),
                            MixedLanguageRules.samples(MixedLanguageRules.repairMinimumSeconds))
            let repaired = engine.decodeLog.dropFirst(out.report.decodes).reduce(0) { $0 + map.speechSamples(in: $1.range) }
            XCTAssertLessThanOrEqual(repaired, limit, note)
            XCTAssertEqual(out.report.repairDecodes, engine.decodeLog.count - out.report.decodes, note)
            XCTAssertEqual(out.report.detections + out.report.refinementDetections + out.report.islandDetections
                            + out.report.repairDetections, engine.detectLog.count, note)
            XCTAssertFalse(out.report.repairs.contains { $0.accepted && $0.after.isEmpty && !$0.before.isEmpty }, note)
        }
    }
}
