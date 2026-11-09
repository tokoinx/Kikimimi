import Foundation

/// 「日本語＋英語」の文字起こしで使う、音声認識の部品 (whisper.cpp)。テストでは台本どおりに答える偽物を使う
public protocol MixedEngine: AnyObject {
    /// 音声全体の発話の区間 (VAD)。VAD を使わない設定なら nil。VAD を使う設定で動かなければ、エラーを投げる
    func speechMap(of samples: [Float]) throws -> SpeechMap?
    /// range の言語を判定する。candidates と同じ順の確率 (判定できなければ nil)
    func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]?
    /// range を language で文字にする。時刻は音声全体の秒。
    /// onProgress は 0...1 (この範囲の中の進み具合)、onSegment は文字にできた区間を順に受け取る
    func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment]
}

public enum MixedPipelineError: Error, Equatable {
    case cancelled
}

/// 診断用の記録 (`--selftest-whisper` が出す)。数値は秒
public struct MixedReport: Codable, Hashable, Sendable {
    public struct Run: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var language: String
        public var speech: Double
        public var segments: Int
        public var seconds: Double
    }

    public struct Flagged: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var flags: [String]
        public var text: String
    }

    public struct Repair: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var runLanguage: String
        public var detected: String?
        public var confidence: Double?
        /// 文字にし直した部分と、その言語
        public var decodedAs: [String]
        public var accepted: Bool
        public var before: String
        public var after: String
    }

    public var usedVAD = false
    public var candidates: [String] = []
    public var audioSeconds = 0.0
    public var speechSeconds = 0.0
    public var vadSeconds = 0.0
    public var chunks: [LanguagePlanner.Decision] = []
    public var switches: [SwitchSearch.Found] = []
    public var runs: [Run] = []
    public var flagged: [Flagged] = []
    public var repairs: [Repair] = []
    /// 判定の回数 (区切りごと・分けて判定し直した分・直しの分)
    public var detections = 0
    public var refinementDetections = 0
    /// 区切りの中ほどに挟まった別の言語 (島) を探した判定の回数
    public var islandDetections = 0
    public var repairDetections = 0
    /// 上限を超えたため、点検に引っかかったのに見なかったところの数
    public var repairsSkipped = 0
    /// whisper で文字にした回数 (範囲ごと・直しの分)
    public var decodes = 0
    public var repairDecodes = 0
    /// 区間の言語ごとの秒数
    public var languageSeconds: [String: Double] = [:]

    public init() {}
}

/// 「日本語＋英語」の文字起こし: VAD → 区切り → 区切りごとの言語判定 (混ざっていれば切り替わりを探す) →
/// 同じ言語の区切りをつないで、その言語で文字にする → 安い点検で引っかかったところを、別の言語なら文字にし直す。
///
/// 言語は candidates (["ja", "en"]) の中からだけ選ぶ (候補を絞らない判定は、短い音声で中国語・韓国語などを作り出す)。
public enum MixedPipeline {
    private typealias R = MixedLanguageRules

    public struct Options: Sendable {
        public var candidates: [String]
        /// 語彙のヒント (言語ごとに `GlossaryHint` で合わせて渡す)
        public var glossary: String?
        public var filterHallucinations: Bool
        /// 必ず切る位置 (話者の切り替わり。サンプル番号)
        public var forcedCuts: [Int]

        public init(candidates: [String], glossary: String? = nil, filterHallucinations: Bool = true, forcedCuts: [Int] = []) {
            self.candidates = candidates
            self.glossary = glossary
            self.filterHallucinations = filterHallucinations
            self.forcedCuts = forcedCuts
        }
    }

    public struct Output: Sendable {
        public var segments: [TranscriptSegment]
        /// いちばん長く話されていた言語 (区間が無ければ nil)
        public var language: String?
        public var report: MixedReport
    }

    public static func run<Engine: MixedEngine>(samples: [Float], engine: Engine, options: Options,
                                                 onProgress: (Double) -> Void = { _ in },
                                                 onSegment: (TranscriptSegment) -> Void = { _ in },
                                                 shouldCancel: () -> Bool = { false }) throws -> Output {
        let candidates = options.candidates.isEmpty ? ["ja"] : options.candidates
        var report = MixedReport()
        report.candidates = candidates
        report.audioSeconds = R.seconds(samples.count)
        guard !samples.isEmpty else { return Output(segments: [], language: nil, report: report) }

        var reported = 0.0
        func progress(_ value: Double) {
            let v = min(1, max(reported, value))
            if v > reported {
                reported = v
                onProgress(v)
            }
        }
        func checkCancel() throws {
            if shouldCancel() { throw MixedPipelineError.cancelled }
        }

        // 1. VAD
        let vadStarted = Date()
        let vadMap = try engine.speechMap(of: samples)
        report.vadSeconds = Date().timeIntervalSince(vadStarted)
        let useVAD = vadMap != nil
        let map = vadMap ?? SpeechMap.withoutVAD(samples)
        report.usedVAD = useVAD
        try checkCancel()
        progress(R.progressAfterVAD)

        // 2. 区切り
        let chunks = useVAD ? SpeechChunker.chunks(map, forcedCuts: options.forcedCuts) : SpeechChunker.fixedChunks(map)
        let totalSpeech = max(1, chunks.reduce(0) { $0 + $1.speechSamples })
        report.speechSeconds = R.seconds(chunks.reduce(0) { $0 + $1.speechSamples })
        var detectedSpeech = 0
        var decodedSpeech = 0
        func reportWork() {
            let work = (R.progressDetectShare * Double(detectedSpeech) + R.progressDecodeShare * Double(decodedSpeech))
                / Double(totalSpeech)
            progress(R.progressAfterVAD + (1 - R.progressAfterVAD - R.progressRepairShare) * min(1, work))
        }

        func detect(_ range: Range<Int>) throws -> LanguageGuess? {
            try checkCancel()
            guard let probs = try engine.detectLanguage(samples, range: range, candidates: candidates) else { return nil }
            return LanguageGuess(probabilities: probs, candidates: candidates)
        }

        // 画面への途中表示は、今の「日本語」と同じふるいを通す
        var stream = RepetitionFilter.Streaming()
        func live(_ raw: DecodedSegment) {
            guard let segment = transcriptSegment(raw, candidates: candidates, filter: options.filterHallucinations) else { return }
            if options.filterHallucinations, !stream.accept(segment) { return }
            onSegment(segment)
        }

        var decoded: [(run: DecodeRun, segments: [DecodedSegment])] = []
        func decodeRun(_ run: DecodeRun) throws {
            try checkCancel()
            let started = Date()
            let base = decodedSpeech
            let segments = try engine.decode(samples, range: run.range, language: run.language,
                                             hint: GlossaryHint.hint(options.glossary, for: run.language), useVAD: useVAD,
                                             onProgress: { p in
                                                 decodedSpeech = base + Int(Double(run.speechSamples) * min(1, max(0, p)))
                                                 reportWork()
                                             },
                                             onSegment: live)
            try checkCancel()
            decodedSpeech = base + run.speechSamples
            reportWork()
            report.decodes += 1
            report.runs.append(MixedReport.Run(start: R.seconds(run.range.lowerBound), end: R.seconds(run.range.upperBound),
                                               language: run.language, speech: R.seconds(run.speechSamples),
                                               segments: segments.count, seconds: Date().timeIntervalSince(started)))
            decoded.append((run, segments))
        }

        // 3. 区切りごとに判定し、言語が決まった範囲から文字にする
        var planner = LanguagePlanner(candidates: candidates, totalSamples: samples.count)
        var extraDetections = 0
        var islandDetections = 0
        // 言語ごとの、混ざっていない区切りの「別の言語の確率」(島を探すしきい値を、このファイルに合わせて決める)
        var cleanOther: [String: [Double]] = [:]
        func islandThreshold(_ host: String) -> Double {
            let values = cleanOther[host] ?? []
            guard values.count >= R.islandMedianMinSamples, let median = DecodeCheck.median(values) else {
                return R.islandDefaultOther
            }
            return max(R.islandMinimumOther, R.islandMedianFactor * median)
        }
        for (index, chunk) in chunks.enumerated() {
            var guess: LanguageGuess? = nil
            if chunk.speechSeconds >= R.minDetectSpeechSeconds {
                guess = try detect(chunk.range)
                report.detections += 1
            }
            var parts = [SwitchSearch.Part(chunk: chunk, guess: guess)]
            var refined = false
            // 分けて判定し直すべきなのに、回数の上限を超えたので分けなかった (確からしさ 0.90〜0.97)
            var overBudget = false
            if SwitchSearch.needsRefinement(guess, speechSeconds: chunk.speechSeconds) {
                let budget = R.refineBudgetPerChunk * Double(index + 1) + R.refineBudgetBase
                if Double(extraDetections) < budget || (guess?.confidence ?? 0) < R.overBudgetRefineBelow {
                    let outcome = try SwitchSearch.refine(chunk, guess: guess, map: map,
                                                          islandThreshold: { R.islandHosts.contains($0) ? islandThreshold($0) : nil },
                                                          detect: detect)
                    extraDetections += outcome.detections
                    report.refinementDetections += outcome.detections
                    report.switches += outcome.switches
                    parts = outcome.parts
                    refined = true
                } else {
                    overBudget = true
                }
            }
            if !refined, let g = guess {
                // 確かそうでも、別の言語の確率がこのファイルのふつうより高ければ、中ほどに短い別の言語が挟まっていないか探す。
                // 上限を超えて分けなかった区切りも探す (2〜4 秒の日本語の一言は、区切りを 0.93〜0.97 に下げる。
                // 探さなければ、英語で文字にしたときに訳されずに消え、点検にも何も残らない)
                let threshold = islandThreshold(g.language)
                let budget = R.islandBudgetPerChunk * Double(index + 1) + R.islandBudgetBase
                var foundIsland = false
                if SwitchSearch.needsIslandSearch(g, speechSeconds: chunk.speechSeconds, threshold: threshold),
                   Double(islandDetections) < budget {
                    let outcome = try SwitchSearch.islands(chunk, host: g, map: map, floor: threshold, contrast: overBudget,
                                                           detect: detect)
                    islandDetections += outcome.detections
                    report.islandDetections += outcome.detections
                    report.switches += outcome.switches
                    parts = outcome.parts
                    refined = true
                    foundIsland = outcome.parts.contains { $0.guess?.language != g.language }
                }
                // 島が見つかった区切りは数えない (相づちの多い録音で中央値が上がり、後の島を探さなくなる)
                if !foundIsland { cleanOther[g.language, default: []].append(1 - g.confidence) }
            }
            detectedSpeech += chunk.speechSamples
            reportWork()
            for part in parts {
                for run in planner.add(part.chunk, guess: part.guess, majority: refined) { try decodeRun(run) }
            }
        }
        for run in planner.finish() { try decodeRun(run) }
        report.chunks = planner.decisions

        // 4. 点検と直し
        let check = DecodeCheck(speech: useVAD ? map : nil, segments: decoded.flatMap(\.segments))
        let repairLimit = max(Int(Double(map.totalSpeechSamples) * R.repairSpeechShare), R.samples(R.repairMinimumSeconds))
        var repairedSpeech = 0
        let repairDetectionLimit = Int(R.repairDetectionsPerChunk * Double(chunks.count) + R.repairDetectionsBase)
        var finals: [DecodedSegment] = []
        let regions = decoded.map { repairRegions(run: $0.run, segments: $0.segments, map: map, check: check, report: &report) }
        let totalRegions = max(1, regions.reduce(0) { $0 + $1.count })
        var doneRegions = 0
        for ((run, segments), runRegions) in zip(decoded, regions) {
            var result = segments
            for pieces in runRegions {
                try checkCancel()
                doneRegions += 1
                guard report.repairDetections < repairDetectionLimit, repairedSpeech < repairLimit else {
                    report.repairsSkipped += 1
                    continue
                }
                if let repaired = try repair(pieces, run: run, current: result, map: map, check: check,
                                             detect: detect, detectionLimit: repairDetectionLimit,
                                             engine: engine, samples: samples, options: options,
                                             useVAD: useVAD, repairedSpeech: &repairedSpeech, repairLimit: repairLimit,
                                             report: &report) {
                    result = repaired
                }
                progress(1 - R.progressRepairShare + R.progressRepairShare * 0.9 * Double(doneRegions) / Double(totalRegions))
            }
            finals += result
        }
        progress(1 - R.progressRepairShare * 0.1)

        // 5. 仕上げ (今の「日本語」と同じフィルタ)
        finals.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var out = finals.compactMap { transcriptSegment($0, candidates: candidates, filter: options.filterHallucinations) }
        if options.filterHallucinations { out = RepetitionFilter.clean(out) }
        var seconds: [String: Double] = [:]
        for s in out { seconds[s.language ?? candidates[0], default: 0] += s.duration }
        report.languageSeconds = seconds
        // 同じ長さなら候補の順 (先頭の言語) を優先する
        let rank = { (code: String) in candidates.firstIndex(of: code) ?? candidates.count }
        let dominant = seconds.max { a, b in a.value != b.value ? a.value < b.value : rank(a.key) > rank(b.key) }?.key
        return Output(segments: out, language: dominant, report: report)
    }

    /// whisper の区間を、文字起こしの区間にする (1 区間の中の繰り返しをまとめ、定番の誤認識を除き、文字から言語を決める)
    static func transcriptSegment(_ raw: DecodedSegment, candidates: [String], filter: Bool) -> TranscriptSegment? {
        var text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if filter { text = RepetitionFilter.collapseInlineRepeats(text) }
        if text.isEmpty || (filter && HallucinationFilter.shouldDrop(text: text, noSpeechProbability: raw.noSpeechProbability)) {
            return nil
        }
        return TranscriptSegment(start: raw.start, end: raw.end, text: text,
                                 language: Script.spokenLanguage(of: text, among: candidates, fallback: raw.language))
    }

    /// 直す範囲: 点検で引っかかった区間 (間が 1 秒未満ならまとめる) と、抜けているところ。前後を少し広げ、範囲の中に収める。
    /// 28 秒より長い範囲は、区切りと同じように、すき間なく分ける (whisper の言語判定は先頭の 30 秒しか聞かない)。
    /// 1 つの範囲を分けたものは 1 つの配列にまとめて返す: 判定は分けたまま、入れ替えはまとめて行う
    /// (whisper の区間は分けた境目をまたぐので、別々に入れ替えると、またいだ文が欠けたり二重になったりする)
    private static func repairRegions(run: DecodeRun, segments: [DecodedSegment], map: SpeechMap, check: DecodeCheck,
                                      report: inout MixedReport) -> [[Range<Int>]] {
        let pad = R.samples(R.repairPadSeconds)
        var regions: [Range<Int>] = []
        var current: Range<Int>? = nil
        let mergeGap = R.samples(R.repairMergeGapSeconds)
        for s in segments {
            let flags = check.flags(s)
            guard !flags.isEmpty else { continue }
            report.flagged.append(MixedReport.Flagged(start: s.start, end: s.end, flags: flags.map(\.rawValue).sorted(),
                                                      text: String(s.text.prefix(120))))
            let r = R.samples(s.start)..<max(R.samples(s.start) + 1, R.samples(s.end))
            if let c = current, r.lowerBound - c.upperBound < mergeGap {
                current = c.lowerBound..<max(c.upperBound, r.upperBound)
            } else {
                if let c = current { regions.append(c) }
                current = r
            }
        }
        if let c = current { regions.append(c) }
        for gap in check.uncovered(in: run.range, segments: segments) {
            report.flagged.append(MixedReport.Flagged(start: R.seconds(gap.lowerBound), end: R.seconds(gap.upperBound),
                                                      flags: [DecodeFlag.uncovered.rawValue], text: ""))
            regions.append(gap)
        }
        // 広げて範囲の中に収め、重なりをまとめる
        let padded = regions.map { r in
            max(run.range.lowerBound, r.lowerBound - pad)..<min(run.range.upperBound, r.upperBound + pad)
        }.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in padded {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        let maxLength = R.samples(R.maxChunkSeconds)
        var out: [[Range<Int>]] = []
        for r in merged {
            guard r.count > maxLength else {
                out.append([r])
                continue
            }
            let inside = SpeechMap(spans: map.spans(in: r), levels: map.levels, hop: map.hop,
                                   totalSamples: map.totalSamples, fromVAD: map.fromVAD)
            let pieces = SpeechChunker.chunks(inside)
            guard pieces.count > 1 else {
                out.append([r])
                continue
            }
            // すき間なく分ける (境目は間の真ん中)
            var group: [Range<Int>] = []
            var start = r.lowerBound
            for k in pieces.indices {
                let end = k + 1 < pieces.count
                    ? max(start, (pieces[k].range.upperBound + pieces[k + 1].range.lowerBound) / 2) : r.upperBound
                if end > start { group.append(start..<end) }
                start = end
            }
            out.append(group.isEmpty ? [r] : group)
        }
        return out
    }

    /// 1 か所を直す: 判定し直して別の言語のところがあれば、そこを、重なる元の区間の全体まで広げて、部分ごとの言語で
    /// 文字にし直し、良くなったときだけ入れ替える (英語 → 日本語 → 英語 のように中ほどに別の言語が挟まっていれば、
    /// そのまわりだけ)。pieces は直す範囲をすき間なく分けたもの (28 秒以下なら 1 つ)。判定は分けたまま行う
    private static func repair<Engine: MixedEngine>(_ pieces: [Range<Int>], run: DecodeRun, current: [DecodedSegment],
                                                    map: SpeechMap, check: DecodeCheck,
                                                    detect: (Range<Int>) throws -> LanguageGuess?, detectionLimit: Int,
                                                    engine: Engine, samples: [Float], options: Options, useVAD: Bool,
                                                    repairedSpeech: inout Int, repairLimit: Int,
                                                    report: inout MixedReport) throws -> [DecodedSegment]? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        let region = first.lowerBound..<last.upperBound
        let inRegion = current.filter { region.contains(R.samples(($0.start + $0.end) / 2)) }
        var entry = MixedReport.Repair(start: R.seconds(region.lowerBound), end: R.seconds(region.upperBound),
                                       runLanguage: run.language, detected: nil, confidence: nil, decodedAs: [],
                                       accepted: false, before: Transcript.join(inRegion.map(\.text)), after: "")
        defer { report.repairs.append(entry) }

        // 1. 言語ごとの計画 (範囲全体をすき間なく)
        var plan: [(range: Range<Int>, language: String)] = []
        var limited = false
        for piece in pieces {
            var part: [(range: Range<Int>, language: String)] = [(piece, run.language)]
            if report.repairDetections < detectionLimit {
                let guess = try detect(piece)
                report.repairDetections += 1
                if let guess {
                    // 記録には、別の言語と出た部分の判定を残す
                    if entry.detected == nil || (entry.detected == run.language && guess.language != run.language) {
                        entry.detected = guess.language
                        entry.confidence = guess.confidence
                    }
                    part = try piecePlan(piece, guess: guess, runLanguage: run.language, map: map, detect: detect,
                                         report: &report)
                }
            } else {
                limited = true
            }
            for p in part {
                if let l = plan.last, l.language == p.language, l.range.upperBound == p.range.lowerBound {
                    plan[plan.count - 1] = (l.range.lowerBound..<p.range.upperBound, p.language)
                } else {
                    plan.append(p)
                }
            }
        }
        if limited { report.repairsSkipped += 1 }
        // 判定も同じ言語なら、言語の取り違えではない (音楽・雑音・本当の繰り返し): 元のまま
        guard plan.contains(where: { $0.language != run.language }) else { return nil }

        // 2. 文字にし直す範囲と、その中の言語ごとの部分
        let spans = redecodeSpans(plan, runLanguage: run.language, segments: current, within: region)
        guard let firstSpan = spans.first, let lastSpan = spans.last else { return nil }
        let parts = spans.flatMap { span in
            absorbShortParts(plan.compactMap { p -> (range: Range<Int>, language: String)? in
                let a = max(p.range.lowerBound, span.lowerBound), b = min(p.range.upperBound, span.upperBound)
                return a < b ? (a..<b, p.language) : nil
            }, map: map)
        }
        let inSpans: (DecodedSegment) -> Bool = { s in
            let mid = R.samples((s.start + s.end) / 2)
            return spans.contains { $0.contains(mid) }
        }
        let old = current.filter(inSpans)
        entry.start = R.seconds(firstSpan.lowerBound)
        entry.end = R.seconds(lastSpan.upperBound)
        entry.before = Transcript.join(old.map(\.text))
        // 文字にし直す分だけを、上限から引く
        let redecode = spans.reduce(0) { $0 + map.speechSamples(in: $1) }
        guard repairedSpeech + redecode <= repairLimit else {
            report.repairsSkipped += 1
            return nil
        }
        repairedSpeech += redecode

        // 3. 文字にし直して比べる。仕上げのフィルタで消える文しか無いなら、元の文を消さない (点検は文を消さない)
        let kept = { (list: [DecodedSegment]) in
            list.filter { transcriptSegment($0, candidates: options.candidates, filter: options.filterHallucinations) != nil }
        }
        let keptOld = kept(old)
        let keepOverlap = R.samples(R.repairKeepOverlapSeconds)
        var fresh: [DecodedSegment] = []
        for part in parts {
            let got = try engine.decode(samples, range: part.range, language: part.language,
                                        hint: GlossaryHint.hint(options.glossary, for: part.language), useVAD: useVAD,
                                        onProgress: { _ in }, onSegment: { _ in })
            fresh += got
            report.repairDecodes += 1
            entry.decodedAs.append(part.language)
            // 部分ごとにも: 何も残らない部分が、そこに重なっていた元の文を消さない
            let erased = kept(got).isEmpty && keptOld.contains { s in
                let a = max(part.range.lowerBound, R.samples(s.start)), b = min(part.range.upperBound, R.samples(s.end))
                return a < b && map.speechSamples(in: a..<b) >= keepOverlap
            }
            if erased {
                entry.after = Transcript.join(fresh.map(\.text))
                return nil
            }
        }
        entry.after = Transcript.join(fresh.map(\.text))
        guard !kept(fresh).isEmpty || keptOld.isEmpty else { return nil }
        guard check.isBetter(fresh, than: old, in: spans) else { return nil }
        entry.accepted = true
        return current.filter { !inSpans($0) } + fresh
    }

    /// 直す範囲の 1 つの部分 (28 秒以下) の、言語ごとの計画。
    /// 確からしさが低ければ、別の言語と出ていても、先に切り替わりと島を探す (英語と日本語が半分ずつでも 0.954 と出る。
    /// 全体を別の言語で文字にし直すと、もとの言語の文が消える)。何も見つからなければ、部分の判定 (両端がそろっていれば、
    /// 両端の言語の判定のうちいちばん確かなもの) が別の言語で `repairConfidence` 以上のときだけ、全体をその言語にする
    private static func piecePlan(_ piece: Range<Int>, guess: LanguageGuess, runLanguage: String, map: SpeechMap,
                                  detect: (Range<Int>) throws -> LanguageGuess?,
                                  report: inout MixedReport) throws -> [(range: Range<Int>, language: String)] {
        var decided = guess
        if piece.count >= R.samples(R.bisectMinSeconds), guess.confidence < R.bisectBelow {
            let found = try SwitchSearch.locate(SpeechChunk(range: piece, spans: map.spans(in: piece)), guess: guess,
                                                map: map, detect: detect)
            report.repairDetections += found.detections
            if found.parts.count > 1 { return contiguousPlan(found.parts, in: piece, fallback: runLanguage) }
            if let g = found.parts.first?.guess { decided = g }
        }
        if decided.language != runLanguage, decided.confidence >= R.repairConfidence { return [(piece, decided.language)] }
        return [(piece, runLanguage)]
    }

    /// 文字にし直す範囲: 別の言語の部分を、そこに重なる元の区間の全体まで広げたもの (直す範囲の中に収める)。
    /// 元の区間の途中で切ると、切った外側の文が消える (または、元の文が残って二重になる)。広げた分は計画どおりの言語で文字にする
    static func redecodeSpans(_ plan: [(range: Range<Int>, language: String)], runLanguage: String,
                              segments: [DecodedSegment], within region: Range<Int>) -> [Range<Int>] {
        let lines = segments.compactMap { s -> Range<Int>? in
            let a = max(region.lowerBound, R.samples(s.start)), b = min(region.upperBound, R.samples(s.end))
            return a < b ? a..<b : nil
        }
        var spans = plan.filter { $0.language != runLanguage && !$0.range.isEmpty }.map(\.range)
        var changed = true
        while changed {
            changed = false
            spans.sort { $0.lowerBound < $1.lowerBound }
            var joined: [Range<Int>] = []
            for span in spans {
                var r = span
                for line in lines where line.overlaps(r) && (line.lowerBound < r.lowerBound || line.upperBound > r.upperBound) {
                    r = min(r.lowerBound, line.lowerBound)..<max(r.upperBound, line.upperBound)
                    changed = true
                }
                if let l = joined.last, r.lowerBound <= l.upperBound {
                    joined[joined.count - 1] = l.lowerBound..<max(l.upperBound, r.upperBound)
                } else {
                    joined.append(r)
                }
            }
            spans = joined
        }
        return spans
    }

    /// 発話が `minDetectSpeechSeconds` に満たない部分は、となりの部分に含める
    /// (広げた分のわずかな切れ端を別に文字にすると、何も出ないか、定番の誤認識になる)
    static func absorbShortParts(_ parts: [(range: Range<Int>, language: String)],
                                 map: SpeechMap) -> [(range: Range<Int>, language: String)] {
        var out = parts
        let minSpeech = R.samples(R.minDetectSpeechSeconds)
        var k = 0
        while out.count > 1, k < out.count {
            guard map.speechSamples(in: out[k].range) < minSpeech else {
                k += 1
                continue
            }
            // 前の部分があれば前に、無ければ次に含める
            if k > 0 {
                out[k - 1].range = out[k - 1].range.lowerBound..<out[k].range.upperBound
                out.remove(at: k)
                k -= 1
            } else {
                out[1].range = out[0].range.lowerBound..<out[1].range.upperBound
                out.remove(at: 0)
            }
        }
        // 同じ言語がとなり合えばまとめる
        var merged: [(range: Range<Int>, language: String)] = []
        for p in out {
            if let l = merged.last, l.language == p.language {
                merged[merged.count - 1].range = l.range.lowerBound..<p.range.upperBound
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    /// 判定し直した部分を、すき間なく並んだ (言語, 範囲) にする。部分と部分の境目は間の真ん中。
    /// 信じられない短い部分は fallback (直す範囲の、もとの言語)
    static func contiguousPlan(_ parts: [SwitchSearch.Part], in region: Range<Int>,
                               fallback: String) -> [(range: Range<Int>, language: String)] {
        var plan: [(range: Range<Int>, language: String)] = []
        var start = region.lowerBound
        for k in parts.indices {
            let part = parts[k]
            var language = fallback
            if let g = part.guess,
               LanguagePlanner.isTrusted(g, speechSeconds: part.chunk.speechSeconds)
                || part.chunk.speechSeconds >= R.majorityMinSpeechSeconds {
                language = g.language
            }
            let end = k + 1 < parts.count
                ? min(region.upperBound, max(start, (part.chunk.range.upperBound + parts[k + 1].chunk.range.lowerBound) / 2))
                : region.upperBound
            if let last = plan.last, last.language == language {
                plan[plan.count - 1] = (last.range.lowerBound..<end, language)
            } else if end > start {
                plan.append((start..<end, language))
            }
            start = end
        }
        return plan
    }
}
