import Foundation
import KikimimiCore
import KikimimiLLM

/// `Kikimimi --selftest-llm-queue <model.gguf> [--cpu] [--adapter <lora.gguf>]`
///
/// 画面を出さずに、本物の `LLMService` を通して、監査・翻訳の最中にチャットが割り込めるかを確かめる (診断・CI 用)。
/// 1. 決まった原稿を、`LLMService.run` を通して翻訳・監査する → 結果 A。
/// 2. 同じ事を、最中に割り込みの口 (`runInteractive`) からチャットの `generate` を入れながら行う → 結果 B。
///    割り込みは、時間の運に頼らずに入れる: 決めた回の `generate` の手前で body を止め、割り込みを積み終えるまで待たせる。
/// 3. 見る事: A と B が一字も同じ / 最中に答えた割り込みが 1 つ以上 / 中止の割り込みが監査・翻訳を止めない /
///    合わない依頼 (別のモデルのファイル) は最中には通らず、監査・翻訳の後に通る。
///    `--adapter` を渡した時は、差分つきの監査の最中に積んだチャットも、最中には通らず、監査の後に答える事を見る。
/// 乱数の重みのモデル (CI) でも成り立つ事だけを見る (答えの中身は見ない)。
/// 終了コード: 0 = LLM QUEUE OK、1 = LLM QUEUE FAILED、2 = 使い方の間違い
enum LLMQueueSelfTest {
    static func run(arguments: [String]) -> Int32 {
        let usage = "usage: Kikimimi --selftest-llm-queue <model.gguf> [--cpu] [--adapter <lora.gguf>]"
        guard let i = arguments.firstIndex(of: "--selftest-llm-queue"), i + 1 < arguments.count,
              FileManager.default.fileExists(atPath: arguments[i + 1]) else {
            log(usage)
            return 2
        }
        let modelPath = arguments[i + 1]
        let useGPU = !arguments.contains("--cpu")
        // 差分 (LoRA) を渡した時は、差分つきの監査の最中のチャットが、最中には通らない事も見る
        var adapterPath: String?
        if let a = arguments.firstIndex(of: "--adapter") {
            guard a + 1 < arguments.count, FileManager.default.fileExists(atPath: arguments[a + 1]) else {
                log(usage)
                return 2
            }
            adapterPath = arguments[a + 1]
        }
        let adapter = adapterPath
        let code = LockedBox<Int32>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            code.value = await check(modelPath: modelPath, adapterPath: adapter, useGPU: useGPU)
            done.signal()
        }
        // 返ってこない時 (CI で何十分も待たないように)
        guard done.wait(timeout: .now() + 1800) == .success else {
            log("LLM QUEUE FAILED: timed out")
            return 1
        }
        return code.value ?? 1
    }

    /// 決まった原稿 (`--selftest-llm` の例文に足した物)。3 行ずつのかたまりで、翻訳・監査とも 2 つ以上になる
    private static let segments: [TranscriptSegment] = [
        "Welcome to today's session about building games in Roblocks Studio.",
        "First, we will open a new place and add a part.",
        "First, we will open a new place and add a part.",
        "Then we press the play button to test it.",
        "Next, we change the color of the part to red.",
        "After that, we add a script to make it spin.",
        "Roblocks Studio saves the place automatically.",
        "That is all for the first lesson.",
    ].enumerated().map { i, text in
        TranscriptSegment(start: Double(i) * 3, end: Double(i) * 3 + 3, text: text)
    }

    private static let auditOptions = AuditOptions(glossary: "Roblox Studio", maxLinesPerChunk: 3)
    private static let translateOptions = TranslationOptions(maxLinesPerChunk: 3)

    /// 1 回分の結果と、途中の値
    private struct Pass {
        var translations: [String] = []
        var audit: [String] = []
        var translateChunks = 0
        var auditChunks = 0
        var translateCalls = 0
        var auditCalls = 0
        var seconds = 0.0
    }

    /// 割り込み 1 つの記録
    private final class Interrupt: @unchecked Sendable {
        let name: String
        let queuedAt = Date()
        var ranDuring = false
        var finishedDuring = false
        var waited: Double?
        var outcome = "pending"
        var finishedAt: Date?

        init(name: String) {
            self.name = name
        }
    }

    /// 監査・翻訳の body が動いている間だけ true (LLM のスレッドの上で書く)
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
        /// 監査の body が終わった時刻 (合わない依頼が、その後に通ったかを見る)
        var auditBodyEnded: Date?
    }

    /// `generate` を数え、決めた回の手前で `before` を呼ぶ包み (この確認だけで使う)
    private final class Hooked: TextGenerating {
        let inner: any TextGenerating
        let before: (Int) -> Void
        private(set) var calls = 0

        init(_ inner: any TextGenerating, before: @escaping (Int) -> Void) {
            self.inner = inner
            self.before = before
        }

        var contextLength: Int { inner.contextLength }
        func tokenCount(_ text: String) -> Int { inner.tokenCount(text) }

        func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
            calls += 1
            before(calls)
            return try inner.generate(prompt, shouldCancel: shouldCancel)
        }

        func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool, onText: ((String) -> Void)?) throws -> String {
            calls += 1
            before(calls)
            return try inner.generate(prompt, shouldCancel: shouldCancel, onText: onText)
        }
    }

    private enum Phase {
        case translate
        case audit
    }

    /// 翻訳 → 監査を、本物の `LLMService.run` を通して 1 回ずつ走らせる。inject は、決めた回の `generate` の手前で呼ぶ
    private static func pass(_ service: LLMService, modelPath: String, running: Running,
                             inject: @escaping (Phase, Int) -> Void) async throws -> Pass {
        var result = Pass()
        let clock = Date()
        let translated = try await service.run(modelPath: modelPath, shouldCancel: { false }) { generator in
            running.value = true
            defer { running.value = false }
            let hooked = Hooked(generator) { inject(.translate, $0) }
            var texts: [UUID: String] = [:]
            var chunks = 0
            var lastDone = 0
            _ = try Translator.translate(segments, language: "en", options: translateOptions, generator: hooked,
                                         shouldCancel: { false }) { batch, done, _ in
                // 初めの 1 回 (0 件) のほかは、かたまり 1 つにつき 1 回届く (訳せなかったかたまりも、進んだ数は増える)
                if done > lastDone { chunks += 1 }
                lastDone = done
                for r in batch { texts[r.head] = r.text }
            }
            return (texts, chunks, hooked.calls)
        }
        result.translations = segments.map { "\($0.id.uuidString.prefix(8)) " + (translated.0[$0.id] ?? "(not translated)") }
        result.translateChunks = translated.1
        result.translateCalls = translated.2
        let audited = try await service.run(modelPath: modelPath, shouldCancel: { false }) { generator in
            running.value = true
            defer {
                running.value = false
                running.auditBodyEnded = Date()
            }
            let hooked = Hooked(generator) { inject(.audit, $0) }
            var chunks = 0
            let report = try Auditor.audit(segments, language: "en", options: auditOptions, generator: hooked,
                                           modelName: "queue check", shouldCancel: { false },
                                           onProgress: { _, total in chunks = total })
            return (report, chunks, hooked.calls)
        }
        result.audit = audited.0.changes.map { c in
            "\(c.kind.rawValue) \(c.original.id.uuidString.prefix(8)) \(c.isConfident ? "auto" : "suggest") "
                + "\(c.replacement ?? "-") (\(c.reason))"
        }
        result.auditChunks = audited.1
        result.auditCalls = audited.2
        result.seconds = Date().timeIntervalSince(clock)
        return result
    }

    private static func check(modelPath: String, adapterPath: String?, useGPU: Bool) async -> Int32 {
        log("llama.cpp: " + LlamaEngine.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        let service = LLMService(baseOptions: LlamaOptions(gpuLayers: useGPU ? -1 : 0))
        let running = Running()
        do {
            // 1. 割り込みなし (読み込みの秒も入る)
            let a = try await pass(service, modelPath: modelPath, running: running) { _, _ in }
            log("A: translate \(a.translateChunks) chunks / \(a.translateCalls) generate calls, "
                + "audit \(a.auditChunks) chunks / \(a.auditCalls) generate calls, " + String(format: "%.2f s", a.seconds))

            // 2. 割り込みを入れながら
            let interrupts = LockedBox<[Interrupt]>()
            interrupts.value = []
            let tasksBox = LockedBox<[Task<Void, Never>]>()
            tasksBox.value = []
            let missingModel = modelPath + ".no-such-model"
            /// 割り込みを 1 つ積み、待ち行列に入るまで body を待たせる
            func enqueue(_ name: String, path: String, cancel: Bool) {
                let record = Interrupt(name: name)
                interrupts.value = (interrupts.value ?? []) + [record]
                let before = service.waitingInterrupts
                let task = Task.detached {
                    do {
                        let reply = try await service.runInteractive(modelPath: path, shouldCancel: { cancel }) { engine in
                            record.ranDuring = running.value
                            record.waited = Date().timeIntervalSince(record.queuedAt)
                            let text = try engine.generate(LLMPrompt(system: "You are a helpful assistant.",
                                                                     user: "In one sentence, what is a transcript?",
                                                                     maxTokens: 32),
                                                           shouldCancel: { cancel }, onText: { _ in })
                            record.finishedDuring = running.value
                            return text
                        }
                        record.outcome = "answered (\(reply.utf8.count) bytes)"
                    } catch LLMError.cancelled {
                        record.outcome = "cancelled"
                    } catch {
                        record.outcome = "failed: \(error.localizedDescription)"
                    }
                    record.finishedAt = Date()
                }
                tasksBox.value = (tasksBox.value ?? []) + [task]
                // 待ち行列に入るまで待つ (運に頼らない。入らなければ 10 秒で諦める)
                let limit = Date().addingTimeInterval(10)
                while service.waitingInterrupts <= before && Date() < limit { usleep(1000) }
            }
            let yieldedBefore = service.yieldedInterrupts
            let b = try await pass(service, modelPath: modelPath, running: running) { phase, call in
                switch (phase, call) {
                case (.translate, 1):
                    enqueue("chat during translate (body start)", path: modelPath, cancel: false)
                case (.translate, 2):
                    enqueue("chat during translate (between chunks)", path: modelPath, cancel: false)
                case (.audit, 1):
                    enqueue("cancelled chat during audit", path: modelPath, cancel: true)
                    enqueue("chat for another model during audit", path: missingModel, cancel: false)
                case (.audit, 2):
                    enqueue("chat during audit (between chunks)", path: modelPath, cancel: false)
                default:
                    break
                }
            }
            let tasks = tasksBox.value ?? []
            for task in tasks { await task.value }
            let yielded = service.yieldedInterrupts - yieldedBefore
            log("B: translate \(b.translateChunks) chunks / \(b.translateCalls) generate calls, "
                + "audit \(b.auditChunks) chunks / \(b.auditCalls) generate calls, " + String(format: "%.2f s", b.seconds))

            let all = interrupts.value ?? []
            for r in all {
                let waited = r.waited.map { String(format: "%.2f s", $0) } ?? "-"
                let total = r.finishedAt.map { String(format: "%.2f s", $0.timeIntervalSince(r.queuedAt)) } ?? "-"
                log("interrupt: \(r.name): \(r.outcome), ran during=\(r.ranDuring), answered during=\(r.finishedDuring), "
                    + "waited \(waited) before it ran, done \(total) after it was queued")
            }
            let matching = all.filter { !$0.name.contains("another model") }
            let answeredDuring = matching.filter { $0.finishedDuring && $0.outcome.hasPrefix("answered") }.count
            let cancelledOK = all.filter { $0.name.hasPrefix("cancelled") }.allSatisfy { $0.outcome == "cancelled" && $0.ranDuring }
            let other = all.first { $0.name.contains("another model") }
            let otherLater = other.map { r in
                !r.ranDuring && r.outcome.hasPrefix("failed")
                    && (r.finishedAt.flatMap { end in running.auditBodyEnded.map { end > $0 } } ?? false)
            } ?? false
            log("interrupts: \(all.count) queued, \(yielded) passed during audit/translation, \(answeredDuring) answered during")
            log("translation:")
            for line in a.translations { log("  " + line) }
            log("audit: \(a.audit.count) changes")
            for line in a.audit { log("  " + line) }

            let sameTranslation = a.translations == b.translations
            let sameAudit = a.audit == b.audit
            let sameCalls = a.translateCalls == b.translateCalls && a.auditCalls == b.auditCalls
            var problems: [String] = []
            if a.translateChunks < 2 || a.auditChunks < 2 { problems.append("fewer than 2 chunks") }
            if !sameTranslation { problems.append("translation differs with interrupts") }
            if !sameAudit { problems.append("audit differs with interrupts") }
            if !sameCalls { problems.append("generate calls differ with interrupts") }
            if answeredDuring < 1 { problems.append("no interrupt answered during audit/translation") }
            if yielded != matching.count { problems.append("\(yielded) of \(matching.count) matching interrupts passed during the run") }
            if !cancelledOK { problems.append("the cancelled interrupt did not end as cancelled") }
            if !otherLater { problems.append("the interrupt for another model did not wait for the run") }
            // 3. (差分を渡した時だけ) 差分つきの監査の最中に積んだチャットは、最中には通らず、監査の後に通る
            if let adapterPath {
                let before = interrupts.value?.count ?? 0
                let yieldedBeforeAdapter = service.yieldedInterrupts
                let clock = Date()
                let loaded = try await service.run(modelPath: modelPath, adapterPath: adapterPath, shouldCancel: { false }) { generator in
                    running.value = true
                    defer {
                        running.value = false
                        running.auditBodyEnded = Date()
                    }
                    let hooked = Hooked(generator) { call in
                        if call == 1 { enqueue("chat during an audit with an adapter", path: modelPath, cancel: false) }
                    }
                    _ = try Auditor.audit(segments, language: "en", options: auditOptions, generator: hooked,
                                          modelName: "queue check", shouldCancel: { false })
                    return generator.adapterPath != nil
                }
                let auditEnded = running.auditBodyEnded
                for task in (tasksBox.value ?? []).dropFirst(tasks.count) { await task.value }
                let added = (interrupts.value ?? []).dropFirst(before)
                log("C: audit with the adapter " + (loaded ? "loaded" : "NOT loaded") + ", " + String(format: "%.2f s", Date().timeIntervalSince(clock)))
                for r in added {
                    let waited = r.waited.map { String(format: "%.2f s", $0) } ?? "-"
                    let total = r.finishedAt.map { String(format: "%.2f s", $0.timeIntervalSince(r.queuedAt)) } ?? "-"
                    log("interrupt: \(r.name): \(r.outcome), ran during=\(r.ranDuring), answered during=\(r.finishedDuring), "
                        + "waited \(waited) before it ran, done \(total) after it was queued")
                }
                if loaded {
                    let waitedForRun = added.allSatisfy { r in
                        !r.ranDuring && r.outcome.hasPrefix("answered")
                            && (r.finishedAt.flatMap { end in auditEnded.map { end > $0 } } ?? false)
                    }
                    if added.isEmpty || !waitedForRun || service.yieldedInterrupts != yieldedBeforeAdapter {
                        problems.append("the chat during an audit with an adapter did not wait for the audit")
                    }
                } else {
                    log("C: skipped (the adapter could not be loaded)")
                }
            }
            for line in b.translations where !a.translations.contains(line) { log("  B differs: " + line) }
            for line in b.audit where !a.audit.contains(line) { log("  B differs: " + line) }
            log("same translation: \(sameTranslation), same audit: \(sameAudit), same generate calls: \(sameCalls)")
            if problems.isEmpty {
                log("LLM QUEUE OK")
                return 0
            }
            log("LLM QUEUE FAILED: " + problems.joined(separator: "; "))
            return 1
        } catch {
            log("LLM QUEUE FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
