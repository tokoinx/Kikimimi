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

        log("whisper.cpp: " + WhisperContext.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        log("model: \(modelPath) (\(useGPU ? "GPU" : "CPU"))")
        log("VAD: \(vadPath ?? "none")")
        log("languages: \(candidates.isEmpty ? language : candidates.joined(separator: "+"))")

        do {
            var clock = Date()
            var samples = try decode(URL(fileURLWithPath: audioPath))
            let rate = Double(MixedLanguageRules.sampleRate)
            let from = value("--from").flatMap(Double.init).map { max(0, min(samples.count, Int($0 * rate))) } ?? 0
            let to = value("--to").flatMap(Double.init).map { max(from, min(samples.count, Int($0 * rate))) } ?? samples.count
            if from > 0 || to < samples.count { samples = Array(samples[from..<to]) }
            let offset = Double(from) / rate
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
                let out = Output(audio: audioPath, model: modelPath, languages: codes, audioSeconds: audioSeconds,
                                 wallSeconds: wall, peakFootprintMB: peak > 0 ? peak : nil, language: output.language,
                                 segments: output.segments.map {
                                     Output.Segment(start: $0.start + offset, end: $0.end + offset, language: $0.language,
                                                    text: $0.text)
                                 },
                                 report: output.report)
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
            log("  switch without a pause in \(t(s.start))-\(t(s.end)): \(s.head) -> \(s.tail) at \(t(s.cut))"
                + " (searched \(t(s.bracketStart))-\(t(s.bracketEnd)))")
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
        log("language detections: \(r.detections) chunks + \(r.refinementDetections) refinement + \(r.repairDetections) repair;"
            + " decodes: \(r.decodes) runs + \(r.repairDecodes) repair")
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
    private static func decode(_ url: URL) throws -> [Float] {
        final class Result: @unchecked Sendable {
            var samples: [Float] = []
            var error: Error?
        }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.samples = try await AudioDecoder.decode(url: url) } catch { result.error = error }
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
