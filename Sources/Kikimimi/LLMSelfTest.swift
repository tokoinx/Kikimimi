import Foundation
import KikimimiCore
import KikimimiLLM
import KikimimiWhisper

/// `Kikimimi --selftest-llm <GGUF> [--cpu] [--strict] [--translate-to <code>]`
///
/// 画面を出さずに、LLM の読み込み・翻訳・監査をひと通り試して結果を表示する (動作確認・CI 用)。
/// whisper.framework と llama.framework を同じプロセスで使えることの確認も兼ねる。
/// 乱数の重みのモデル (CI) でも成り立つことだけを必ず確かめ、`--strict` では本物のモデルの答えの中身まで確かめる。
/// `--translate-to <code>` (13 言語のどれか) を付けると、翻訳の例をその言語へ訳す
/// (en なら日本語の数行、ほかは英語の数行を原文にする)。付けなければ、これまでどおり日本語へ訳す
enum LLMSelfTest {
    static func run(modelPath: String, useGPU: Bool, strict: Bool, translateTo: String? = nil) -> Int32 {
        let usage = "usage: Kikimimi --selftest-llm <model.gguf> [--cpu] [--strict] [--translate-to <code>]"
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            log(usage)
            return 2
        }
        let target = translateTo?.lowercased()
        if let target, !TranslationTarget.all.contains(target) {
            log("unknown language for --translate-to: \"\(target)\" (one of:\(TranslationTarget.all.joined(separator: " ")))")
            log(usage)
            return 2
        }
        log("whisper.cpp: " + WhisperContext.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        log("llama.cpp:   " + LlamaEngine.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        // 本物のエンジンの読み込みの失敗 (壊れたモデル・モデルでないファイル・壊れた差分)。ふだんの読み込みより前に行う:
        // llama.cpp がここで落ちた時に、どの確かめで落ちたかがすぐわかり、メモリもふだんのモデルと重ならない
        guard LLMFailureSelfTest.loadFailures(modelPath: modelPath, useGPU: useGPU) else {
            log("SELFTEST FAILED: a load-failure check of the real engine went wrong")
            return 1
        }
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
            // 長すぎる文を断る・途中で止める。この後の翻訳・監査が、失敗の後でもふつうに動く事も見る
            guard LLMFailureSelfTest.generateFailures(engine: engine) else {
                log("SELFTEST FAILED: a generate-failure check of the real engine went wrong")
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
            // 訳す先を選んだ時は、その言語へ訳す例 (原文は、英語へ訳す時は日本語、ほかは英語)
            let sources = target.map { $0 == "en" ? japaneseSamples : englishSamples } ?? segments
            let failed: Int
            if let target {
                failed = try Translator.translate(sources, language: target == "en" ? "ja" : "en", target: target,
                                                  generator: engine, shouldCancel: { false }) { batch, _, _ in
                    for result in batch { translations[result.head] = result.text }
                }
                log("translate to \(target): \(translations.count) translated, \(failed) failed, \(seconds(since: clock))")
            } else {
                failed = try Translator.translate(segments, language: "en", generator: engine, shouldCancel: { false }) { batch, _, _ in
                    for result in batch { translations[result.head] = result.text }
                }
                log("translate: \(translations.count) translated, \(failed) failed, \(seconds(since: clock))")
            }
            for s in sources {
                log("  \(s.text)\n    => \(translations[s.id] ?? "(not translated)")")
            }

            clock = Date()
            // LLM の答えを読めなかった所の数 (書き切っていない答えなど)。ふだんの監査なら 0
            var unread = 0
            let report = try Auditor.audit(segments, language: "en", options: AuditOptions(glossary: "Roblox Studio"),
                                           generator: engine, modelName: engine.modelDescription, shouldCancel: { false },
                                           onUnread: { unread = $0 })
            log("audit: \(report.changes.count) findings, \(seconds(since: clock)), unread \(unread)")
            for c in report.changes {
                let state = c.isConfident ? "auto" : "suggest"
                log("  [\(state)] \(c.kind.rawValue) \(TimeFormat.short(c.original.start)) \(c.original.text)"
                    + (c.replacement.map { " -> \($0)" } ?? "") + " (\(c.reason))")
            }

            let duplicateRemoved = report.changes.contains { $0.original.id == segments[3].id && $0.kind == .delete && $0.isConfident }
            if let target {
                return check(target: target, sources: sources, translations: translations, failed: failed,
                             duplicateRemoved: duplicateRemoved, report: report, auditedFirst: segments[0].id, strict: strict)
            }
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

    /// 英語へ訳す時の原文 (日本語の 4 行)
    private static let japaneseSamples = [
        TranscriptSegment(start: 0, end: 3, text: "今日は、ゲームの作り方についてお話しします。", language: nil),
        TranscriptSegment(start: 3, end: 6, text: "まず、新しい場所を開いて、部品を 1 つ置きます。", language: nil),
        TranscriptSegment(start: 6, end: 9, text: "次に、再生のボタンを押して試してみましょう。", language: nil),
        TranscriptSegment(start: 9, end: 12, text: "全部で 10 分ほどかかります。", language: nil),
    ]

    /// 日本語のほかの言語へ訳す時の原文 (英語の 4 行)
    private static let englishSamples = [
        TranscriptSegment(start: 0, end: 3, text: "Welcome to today's session about building games.", language: nil),
        TranscriptSegment(start: 3, end: 6, text: "First, we will open a new place and add a part.", language: nil),
        TranscriptSegment(start: 6, end: 9, text: "Then we press the play button to test it.", language: nil),
        TranscriptSegment(start: 9, end: 12, text: "It takes about ten minutes in total.", language: nil),
    ]

    /// 訳す先を選んだ時の確かめ。乱数の重みのモデルでも成り立つこと (重なりが消えた・どの行も訳せたか訳せなかったか) を必ず見て、
    /// --strict では、3 行以上が訳す先の言語らしい訳か (ko・ru・th・zh・ja はその言語の文字を含むか、
    /// ほかは空でなく原文と違うか) と、聞き間違い (Roblocks → Roblox) を直せたかを見る
    private static func check(target: String, sources: [TranscriptSegment], translations: [UUID: String], failed: Int,
                              duplicateRemoved: Bool, report: AuditReport, auditedFirst: UUID, strict: Bool) -> Int32 {
        guard duplicateRemoved, translations.count + failed == sources.count else {
            log("SELFTEST FAILED: duplicate removed=\(duplicateRemoved), translated=\(translations.count) + failed=\(failed) of \(sources.count)")
            return 1
        }
        if strict {
            let good = sources.filter { s in
                translations[s.id].map { looksTranslated($0, source: s.text, into: target) } ?? false
            }.count
            let fixedName = report.changes.contains {
                $0.original.id == auditedFirst && $0.kind == .fix && ($0.replacement ?? "").contains("Roblox")
            }
            guard good >= 3, fixedName else {
                log("SELFTEST FAILED (strict): translated into \(target)=\(good)/\(sources.count), fixed Roblocks=\(fixedName)")
                return 1
            }
        }
        log("SELFTEST OK" + (strict ? " (strict)" : "") + " (translated into \(target))")
        return 0
    }

    /// 訳す先の言語らしい訳か。文字で見分けられる言語 (ko・ru・th・zh・ja) は、その言語の文字を含むか。
    /// ほかの言語 (ラテン文字) は、空でなく、原文と違うか
    static func looksTranslated(_ translation: String, source: String, into target: String) -> Bool {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let ranges: [ClosedRange<UInt32>]
        switch target {
        case "ko": ranges = [0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F]
        case "ru": ranges = [0x0400...0x04FF]
        case "th": ranges = [0x0E00...0x0E7F]
        case "zh": ranges = [0x4E00...0x9FFF]
        case "ja": ranges = [0x3040...0x30FF]
        default: return t != source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t.unicodeScalars.contains { s in ranges.contains { $0.contains(s.value) } }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(date))
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
