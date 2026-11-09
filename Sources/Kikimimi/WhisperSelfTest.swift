import Foundation
import KikimimiCore
import KikimimiWhisper
#if canImport(Darwin)
import Darwin
#endif

/// `Kikimimi --selftest-whisper <音声> [--model <bin>] [--vad <bin>] [--languages ja,en] [--from 秒] [--to 秒]
///  [--cpu] [--greedy] [--hint 語彙] [--report <json>] [--expect <json>]`
///
/// 画面を出さずに文字起こしをして、区切りごとの言語の判定・文字にした範囲・点検と直し・区間ごとの言語・時間・メモリを表示する
/// (「日本語＋英語」の動作確認・CI 用)。モデルと VAD は、指定が無ければアプリが取得したもの。
/// --expect の JSON (`{"intervals": [{"start": 0, "end": 10, "language": "en"}], "maxSegmentSeconds": 30}`) を
/// 満たさなければ 1 で終わる。
enum WhisperSelfTest {
    struct Expectation: Decodable {
        struct Interval: Decodable {
            var start: Double
            var end: Double
            var language: String
        }

        var intervals: [Interval]
        var maxSegmentSeconds: Double?
        /// 切り替わりの位置は ±1.5 秒ずれうるので、区間の両端からこれだけ内側だけを確かめる
        var margin: Double?
    }

    /// --report に書く内容
    struct Output: Encodable {
        struct Segment: Encodable {
            var start: Double
            var end: Double
            var language: String?
            var text: String
        }

        var audio: String
        var model: String
        var languages: [String]
        /// --from (秒)。segments と report の時刻は、どちらもファイルの始めから数える
        var from: Double
        var audioSeconds: Double
        var wallSeconds: Double
        var peakFootprintMB: Double?
        var language: String?
        var segments: [Segment]
        var report: MixedReport?
    }

    static func run(arguments args: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let audioPath = value("--selftest-whisper"), FileManager.default.fileExists(atPath: audioPath) else {
            log("usage: Kikimimi --selftest-whisper <audio> [--model <ggml.bin>] [--vad <silero.bin>] [--languages ja,en]"
                + " [--from s] [--to s] [--cpu] [--greedy] [--hint words] [--report out.json] [--expect expect.json]")
            return 2
        }
        let store = ModelStore()
        let savedID = UserDefaults.standard.string(forKey: "modelID") ?? ModelCatalog.defaultModelID
        let spec = ModelCatalog.spec(id: savedID) ?? ModelCatalog.spec(id: ModelCatalog.defaultModelID) ?? ModelCatalog.all[0]
        let modelPath = value("--model") ?? (store.isInstalled(spec) ? store.url(for: spec).path : nil)
        guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else {
            log("SELFTEST FAILED: no speech model. Download one in the app, or pass --model <ggml.bin>")
            return 2
        }
        let vadPath: String? = value("--vad") ?? (store.isVADInstalled ? store.vadURL.path : nil)
        let codes = (value("--languages") ?? "ja,en").replacingOccurrences(of: "+", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let candidates = codes.count >= 2 ? codes : []
        let language = codes.first ?? "ja"
        let useGPU = !args.contains("--cpu")
        // --from / --to は秒 (149) か [時:]分:秒 (2:29)。読めない値で黙ってファイル全体を文字にしない
        var cut: [String: Double] = [:]
        for name in ["--from", "--to"] where args.contains(name) {
            guard let text = value(name), let seconds = Self.seconds(text) else {
                log("usage: \(name) takes seconds (149) or m:ss (2:29), not \"\(value(name) ?? "")\"")
                return 2
            }
            cut[name] = seconds
        }

        log("whisper.cpp: " + WhisperContext.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        log("model: \(modelPath) (\(useGPU ? "GPU" : "CPU"))")
        log("VAD: \(vadPath ?? "none")")
        log("languages: \(candidates.isEmpty ? language : candidates.joined(separator: "+"))")

        do {
            var clock = Date()
            // 範囲が決まっていれば、そこだけを読む (2 時間の録音の全体を読むと、8 GB の Mac では数分と 0.5 GB かかる)
            let fromSeconds = max(0, cut["--from"] ?? 0)
            let toSeconds = cut["--to"].map { max($0, fromSeconds) }
            log("reading \((audioPath as NSString).lastPathComponent) …")
            let samples = try decode(URL(fileURLWithPath: audioPath), from: fromSeconds, to: toSeconds)
            guard !samples.isEmpty else {
                log("SELFTEST FAILED: no audio in that range (check --from / --to against the length of the recording)")
                return 2
            }
            let rate = Double(MixedLanguageRules.sampleRate)
            let offset = fromSeconds
            let audioSeconds = Double(samples.count) / rate
            log(String(format: "audio: %@, %.1f s from %.1f s (decoded in %.1f s)", (audioPath as NSString).lastPathComponent,
                       audioSeconds, offset, Date().timeIntervalSince(clock)))

            clock = Date()
            let context = try WhisperContext(modelPath: modelPath, useGPU: useGPU)
            log(String(format: "loaded in %.1f s", Date().timeIntervalSince(clock)))
            let options = WhisperOptions(language: language, languageCandidates: candidates,
                                         useBeamSearch: !args.contains("--greedy"), vadModelPath: vadPath,
                                         initialPrompt: value("--hint"))
            var peak = footprintMB() ?? 0
            var nextReport = 0.05
            clock = Date()
            let output = try context.transcribe(samples: samples, options: options, onProgress: { p in
                peak = max(peak, footprintMB() ?? 0)
                if p >= nextReport {
                    log(String(format: "  … %3.0f%%  %.0f s", p * 100, Date().timeIntervalSince(clock)))
                    nextReport = (p / 0.05).rounded(.down) * 0.05 + 0.05
                }
            }, onSegment: { s in
                log(String(format: "  [%@] %@ %@", TimeFormat.short(s.start + offset), tag(s.language), s.text))
            })
            let wall = Date().timeIntervalSince(clock)
            peak = max(peak, footprintMB() ?? 0)

            if let r = output.report { printReport(r, offset: offset) }
            log("result:")
            for s in output.segments {
                log(String(format: "  [%@-%@] %@ %@", TimeFormat.short(s.start + offset), TimeFormat.short(s.end + offset),
                           tag(s.language), s.text))
            }
            let transcript = Transcript(sourceName: "", segments: output.segments, language: output.language)
            log(String(format: "summary: %@, %d segments, %.1f s for %.1f s of audio (%.2f x real time), peak memory %.0f MB",
                       transcript.languageLabel ?? "-", output.segments.count, wall, audioSeconds,
                       audioSeconds > 0 ? wall / audioSeconds : 0, peak))

            if let path = value("--report") {
                let out = Output(audio: audioPath, model: modelPath, languages: codes, from: offset, audioSeconds: audioSeconds,
                                 wallSeconds: wall, peakFootprintMB: peak > 0 ? peak : nil, language: output.language,
                                 segments: output.segments.map {
                                     Output.Segment(start: $0.start + offset, end: $0.end + offset, language: $0.language,
                                                    text: $0.text)
                                 },
                                 report: output.report.map { shifted($0, by: offset) })
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(out).write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                log("report: \(path)")
            }
            if let path = value("--expect") {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let expectation = try JSONDecoder().decode(Expectation.self, from: data)
                let failures = check(output.segments, offset: offset, against: expectation, candidates: candidates)
                guard failures.isEmpty else {
                    for f in failures { log("SELFTEST FAILED: \(f)") }
                    return 1
                }
            }
            log("SELFTEST OK")
            return 0
        } catch {
            log("SELFTEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    /// 期待と合っているか (合わないものの説明を返す)
    static func check(_ segments: [TranscriptSegment], offset: Double, against e: Expectation,
                      candidates: [String]) -> [String] {
        var failures: [String] = []
        let margin = e.margin ?? 1.5
        for interval in e.intervals {
            let a = interval.start + margin, b = interval.end - margin
            guard a < b else { continue }
            let inside = segments.filter { s in
                let mid = (s.start + s.end) / 2 + offset
                return mid >= a && mid <= b
            }
            if inside.isEmpty {
                failures.append(String(format: "no text in %.1f-%.1f s (expected %@)", interval.start, interval.end,
                                       interval.language))
                continue
            }
            for s in inside {
                let spoken = s.language ?? Script.spokenLanguage(of: s.text, among: candidates.isEmpty ? ["ja", "en"] : candidates,
                                                                fallback: "?")
                if spoken != interval.language {
                    failures.append(String(format: "%.1f-%.1f s is %@, expected %@: %@", s.start + offset, s.end + offset,
                                           spoken, interval.language, s.text))
                }
            }
        }
        if let longest = e.maxSegmentSeconds {
            for s in segments where s.duration > longest {
                failures.append(String(format: "segment %.1f-%.1f s is longer than %.0f s", s.start + offset, s.end + offset, longest))
            }
        }
        return failures
    }

    /// 秒数 (149, 149.5) か [時:]分:秒 (2:29, 1:02:29.5) を秒にする。0 以上の有限の値でなければ nil
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            guard let v = Double(part), v.isFinite, v >= 0 else { return nil }
            // 分・秒は 60 未満、時・分は整数
            if i > 0, v >= 60 { return nil }
            if i < parts.count - 1, v != v.rounded() { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// 診断の記録の時刻に offset (--from) を足す (長さ・秒数はそのまま)
    static func shifted(_ report: MixedReport, by offset: Double) -> MixedReport {
        guard offset != 0 else { return report }
        var r = report
        for i in r.chunks.indices {
            r.chunks[i].start += offset
            r.chunks[i].end += offset
        }
        for i in r.switches.indices {
            r.switches[i].start += offset
            r.switches[i].end += offset
            r.switches[i].bracketStart += offset
            r.switches[i].bracketEnd += offset
            r.switches[i].cut += offset
        }
        for i in r.runs.indices {
            r.runs[i].start += offset
            r.runs[i].end += offset
        }
        for i in r.flagged.indices {
            r.flagged[i].start += offset
            r.flagged[i].end += offset
        }
        for i in r.repairs.indices {
            r.repairs[i].start += offset
            r.repairs[i].end += offset
        }
        return r
    }

    private static func printReport(_ r: MixedReport, offset: Double) {
        func t(_ seconds: Double) -> String { String(format: "%.2f", seconds + offset) }
        log(String(format: "VAD: %@ in %.1f s, %.1f s of speech", r.usedVAD ? "on" : "off", r.vadSeconds, r.speechSeconds))
        log("chunks (\(r.chunks.count)):")
        for c in r.chunks {
            let detected = c.detected.map { d in String(format: "%@ %.3f", d, c.confidence ?? 0) } ?? "not detected"
            log("  \(t(c.start))-\(t(c.end)) speech \(String(format: "%.1f", c.speech)) s: \(detected)"
                + (c.trusted ? "" : " (untrusted)") + " -> \(c.language)")
        }
        for s in r.switches {
            if s.kind == "island" {
                log("  \(s.tail) inside \(s.head) in \(t(s.start))-\(t(s.end)): \(t(s.cut))-\(t(s.bracketEnd))")
            } else {
                log("  switch without a pause in \(t(s.start))-\(t(s.end)): \(s.head) -> \(s.tail) at \(t(s.cut))"
                    + " (searched \(t(s.bracketStart))-\(t(s.bracketEnd)))")
            }
        }
        log("runs (\(r.runs.count)):")
        for run in r.runs {
            log("  \(t(run.start))-\(t(run.end)) \(run.language): \(run.segments) segments, \(String(format: "%.1f", run.seconds)) s")
        }
        if !r.flagged.isEmpty {
            log("flagged (\(r.flagged.count)):")
            for f in r.flagged { log("  \(t(f.start))-\(t(f.end)) \(f.flags.joined(separator: ",")): \(f.text)") }
        }
        if !r.repairs.isEmpty {
            log("repairs (\(r.repairs.count)):")
            for p in r.repairs {
                let detected = p.detected.map { d in String(format: "%@ %.3f", d, p.confidence ?? 0) } ?? "-"
                log("  \(t(p.start))-\(t(p.end)) in a \(p.runLanguage) run: detected \(detected), "
                    + (p.decodedAs.isEmpty ? "kept" : "decoded as \(p.decodedAs.joined(separator: "+")), "
                       + (p.accepted ? "replaced" : "kept the original")))
                if p.accepted { log("    before: \(p.before)\n    after:  \(p.after)") }
            }
        }
        log("language detections: \(r.detections) chunks + \(r.refinementDetections) refinement + \(r.islandDetections) island search"
            + " + \(r.repairDetections) repair; decodes: \(r.decodes) runs + \(r.repairDecodes) repair"
            + (r.repairsSkipped > 0 ? "; \(r.repairsSkipped) flagged regions skipped (over the repair limit)" : ""))
    }

    private static func tag(_ language: String?) -> String {
        switch language {
        case "ja": return "日"
        case "en": return "英"
        case let l?: return l
        default: return "-"
        }
    }

    /// 音声ファイルを 16 kHz モノラルにする (アプリと同じ AVFoundation の読み込み)
    private static func decode(_ url: URL, from: Double, to: Double?) throws -> [Float] {
        final class Result: @unchecked Sendable {
            var samples: [Float] = []
            var error: Error?
        }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.samples = try await AudioDecoder.decode(url: url, from: from, to: to) } catch { result.error = error }
            done.signal()
        }
        // 読み込みが返ってこないとき (CI で何十分も待たないように)
        guard done.wait(timeout: .now() + 900) == .success else {
            throw AudioDecoder.DecodeError.cannotRead(url.lastPathComponent)
        }
        if let error = result.error { throw error }
        return result.samples
    }

    /// このプロセスが今使っているメモリ (MB。アクティビティモニタの「メモリ」と同じ phys_footprint)
    private static func footprintMB() -> Double? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
        #else
        return nil
        #endif
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
