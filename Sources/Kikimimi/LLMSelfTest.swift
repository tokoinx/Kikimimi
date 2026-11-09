import Foundation
import KikimimiCore
import KikimimiLLM
import KikimimiWhisper

/// `Kikimimi --selftest-llm <GGUF> [--cpu]`
///
/// 画面を出さずに、LLM の読み込み・翻訳・監査をひと通り試して結果を表示する (動作確認・CI 用)。
/// whisper.framework と llama.framework を同じプロセスで使えることの確認も兼ねる。
enum LLMSelfTest {
    static func run(modelPath: String, useGPU: Bool) -> Int32 {
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            log("usage: Kikimimi --selftest-llm <model.gguf> [--cpu]")
            return 2
        }
        log("whisper.cpp: " + WhisperContext.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        log("llama.cpp:   " + LlamaEngine.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            var clock = Date()
            let engine = try LlamaEngine(modelPath: modelPath, options: LlamaOptions(gpuLayers: useGPU ? -1 : 0))
            log("loaded: \(engine.modelDescription), context \(engine.contextLength) tokens, \(engine.chatFormatDescription), \(seconds(since: clock)) (\(useGPU ? "GPU" : "CPU"))")

            // 生成そのものの確認: 文法で形を決めた答えが、そのとおりに返るか (乱数の重みのモデルでも成り立つ)
            clock = Date()
            let shaped = try engine.generate(
                LLMPrompt(system: "Answer with two short lines.", user: "[1] hello\n[2] world",
                          grammar: "root ::= \"[1] \" [a-z] [a-z]? \"\\n\" \"[2] \" [a-z] [a-z]? \"\\n\"", maxTokens: 32),
                shouldCancel: { false })
            let shapeOK = shaped.range(of: #"^\[1\] [a-z]{1,2}\n\[2\] [a-z]{1,2}\n$"#, options: .regularExpression) != nil
            log("generate: \(shaped.debugDescription), \(seconds(since: clock))")
            guard shapeOK else {
                log("SELFTEST FAILED: the grammar-shaped answer came back malformed")
                return 1
            }

            let segments = [
                TranscriptSegment(start: 0, end: 3, text: "Welcome to today's session about building games in Roblocks Studio."),
                TranscriptSegment(start: 3, end: 6, text: "今日はよろしくお願いします。"),
                TranscriptSegment(start: 6, end: 9, text: "First, we will open a new place and add a part."),
                TranscriptSegment(start: 9, end: 12, text: "First, we will open a new place and add a part."),
                TranscriptSegment(start: 12, end: 15, text: "Then we press the play button to test it."),
            ]

            clock = Date()
            var translations: [UUID: String] = [:]
            let failed = try Translator.translate(segments, language: "en", generator: engine, shouldCancel: { false }) { batch, _, _ in
                for result in batch { translations[result.head] = result.text }
            }
            log("translate: \(translations.count) translated, \(failed) failed, \(seconds(since: clock))")
            for s in segments {
                log("  \(s.text)\n    => \(translations[s.id] ?? "(not translated)")")
            }

            clock = Date()
            let report = try Auditor.audit(segments, language: "en", options: AuditOptions(glossary: "Roblox Studio"),
                                           generator: engine, modelName: engine.modelDescription, shouldCancel: { false })
            log("audit: \(report.changes.count) findings, \(seconds(since: clock))")
            for c in report.changes {
                let state = c.isConfident ? "auto" : "suggest"
                log("  [\(state)] \(c.kind.rawValue) \(TimeFormat.short(c.original.start)) \(c.original.text)"
                    + (c.replacement.map { " -> \($0)" } ?? "") + " (\(c.reason))")
            }

            let duplicateRemoved = report.changes.contains { $0.original.id == segments[3].id && $0.kind == .delete && $0.isConfident }
            let japaneseKept = translations[segments[1].id] == nil
            guard duplicateRemoved, japaneseKept, translations.count + failed == 4 else {
                log("SELFTEST FAILED: duplicate removed=\(duplicateRemoved), japanese kept=\(japaneseKept)")
                return 1
            }
            log("SELFTEST OK")
            return 0
        } catch {
            log("SELFTEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(date))
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
