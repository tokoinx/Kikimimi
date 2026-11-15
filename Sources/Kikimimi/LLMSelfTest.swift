import Foundation
import KikimimiCore
import KikimimiLLM
import KikimimiWhisper

/// `Kikimimi --selftest-llm <GGUF> [--cpu] [--strict]`
///
/// 画面を出さずに、LLM の読み込み・翻訳・監査をひと通り試して結果を表示する (動作確認・CI 用)。
/// whisper.framework と llama.framework を同じプロセスで使えることの確認も兼ねる。
/// 乱数の重みのモデル (CI) でも成り立つことだけを必ず確かめ、`--strict` では本物のモデルの答えの中身まで確かめる。
enum LLMSelfTest {
    static func run(modelPath: String, useGPU: Bool, strict: Bool) -> Int32 {
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            log("usage: Kikimimi --selftest-llm <model.gguf> [--cpu] [--strict]")
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
            // 翻訳と同じ組み立て (手本のやりとり・日本語だけ) で答えが返る。かなを外してしまうと、ここで答えられない
            let japanese = try engine.generate(
                LLMPrompt(system: "Translate into Japanese.", user: "[1] we",
                          grammar: "root ::= \"[1] \" [ぁ-ん] [ぁ-ん]? \"\\n\"", maxTokens: 8,
                          maxLineBytes: 64, examples: Translator.examples, japaneseOnly: true),
                shouldCancel: { false })
            log("japanese only: \(japanese.debugDescription)")
            guard japanese.range(of: #"^\[1\] [ぁ-ん]{1,2}\n$"#, options: .regularExpression) != nil else {
                log("SELFTEST FAILED: the Japanese-only answer came back malformed: \(japanese.debugDescription)")
                return 1
            }
            // 日本語に出てこない字 (簡体字) は外し、かな・ふつうの漢字は外さない
            let bans = ["们", "这", "欢", "あ", "日", "本"].map { ($0, engine.isExcludedFromJapanese($0)) }
            log("excluded for Japanese: " + bans.map { "\($0.0)=\($0.1.map(String.init) ?? "-")" }.joined(separator: " "))
            let wrongBans = bans.filter { text, excluded in
                guard let excluded else { return false }
                return excluded != Script.containsNonJapaneseHan(text)
            }
            guard wrongBans.isEmpty else {
                log("SELFTEST FAILED: the Japanese-only token filter is wrong for \(wrongBans.map(\.0))")
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
            if strict {
                // 本物のモデル向け: 訳せていて、どれも日本語で、聞き間違い (Roblocks → Roblox) を直せている
                let allJapanese = translations.values.allSatisfy {
                    Script.isJapanese($0) && !Script.containsNonJapaneseHan($0)
                }
                let fixedName = report.changes.contains {
                    $0.original.id == segments[0].id && $0.kind == .fix && ($0.replacement ?? "").contains("Roblox")
                }
                guard translations.count >= 3, allJapanese, fixedName else {
                    log("SELFTEST FAILED (strict): translated=\(translations.count)/4, all Japanese=\(allJapanese), fixed Roblocks=\(fixedName)")
                    return 1
                }
            }
            log("SELFTEST OK" + (strict ? " (strict)" : ""))
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
