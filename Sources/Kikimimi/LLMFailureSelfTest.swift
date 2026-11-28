import Darwin
import Foundation
import KikimimiCore
import KikimimiLLM

/// `--selftest-llm` の中で、本物のエンジン (llama.cpp) をわざと失敗させて、失敗の扱いを確かめる。
/// 偽の生成器での確かめ (`LLMFailureTests`) では見えない、llama.cpp そのものの返し方を見る。
/// どの確かめも 1 行 `LLM FAILURE: <名前>: ok|NG (<事実>)` を出し、true (ok) か false (NG) を返す。
/// 作るファイルは、一時フォルダの中の自分だけのフォルダに置き、終わりに消す (設定やライブラリには触れない)。
enum LLMFailureSelfTest {
    /// 読み込みの失敗の確かめ (1〜3)。ふだんの読み込みの前に呼ぶ (llama.cpp が落ちた時に、どこで落ちたかがすぐわかる)
    static func loadFailures(modelPath: String, useGPU: Bool) -> Bool {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimimi-llm-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let options = LlamaOptions(gpuLayers: useGPU ? -1 : 0)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // 1. 途中で切れたモデル: 元のファイルの頭 (4 MB か、半分の小さい方) だけを写す
            let truncated = folder.appendingPathComponent("truncated.gguf")
            let size = ((try FileManager.default.attributesOfItem(atPath: modelPath))[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: modelPath))
            let head = try handle.read(upToCount: min(4 << 20, size / 2)) ?? Data()
            try handle.close()
            try head.write(to: truncated)
            // 2・3. モデルでも差分でもない、ふつうの文字だけのファイル (1 MB)
            let text = folder.appendingPathComponent("not-a-model.gguf")
            try plainText(bytes: 1 << 20).write(to: text)

            var ok = true
            ok = rejected(name: "a truncated model file is rejected", path: truncated.path,
                          facts: "\(head.count) of \(size) bytes", options: options) && ok
            ok = rejected(name: "a file that is not a model is rejected", path: text.path,
                          facts: "1 MB of text", options: options) && ok
            ok = brokenAdapter(modelPath: modelPath, adapterPath: text.path, options: options) && ok
            ok = serviceFallback(modelPath: modelPath, adapterPath: text.path, options: options) && ok
            return ok
        } catch {
            log("LLM FAILURE: preparing the broken files: NG (\(error.localizedDescription))")
            return false
        }
    }

    /// 読み込んだエンジンでの失敗の確かめ (4・5)。翻訳・監査の前に呼ぶ (その後の翻訳・監査が、失敗の後でもふつうに動く事も見られる)
    static func generateFailures(engine: LlamaEngine) -> Bool {
        var ok = true
        ok = promptTooLong(engine: engine) && ok
        ok = stopPartway(engine: engine) && ok
        return ok
    }

    // MARK: - 1・2 読み込めないファイル

    private static func rejected(name: String, path: String, facts: String, options: LlamaOptions) -> Bool {
        let clock = Date()
        let result = within(seconds: 120) { () -> Result<LlamaEngine, Error> in
            Result { try LlamaEngine(modelPath: path, options: options) }
        }
        let took = seconds(since: clock)
        switch result {
        case nil:
            log("LLM FAILURE: \(name): NG (no answer after \(took), \(facts))")
            return false
        case .success?:
            log("LLM FAILURE: \(name): NG (it loaded, \(facts), \(took))")
            return false
        case .failure(let error)?:
            guard case LLMError.modelLoadFailed = error else {
                log("LLM FAILURE: \(name): NG (wrong error: \(short(error)), \(took))")
                return false
            }
            log("LLM FAILURE: \(name): ok (\(facts), \(took), \"\(short(error))\")")
            return true
        }
    }

    // MARK: - 3 壊れた差分 (LoRA)

    /// 本物のモデルに、差分の代わりに文字だけのファイルを重ねる: adapterLoadFailed で止まり、モデルのメモリは手放される
    private static func brokenAdapter(modelPath: String, adapterPath: String, options: LlamaOptions) -> Bool {
        let name = "a broken adapter is reported"
        let withAdapter = LlamaOptions(gpuLayers: options.gpuLayers, adapterPath: adapterPath)
        let before = footprintMB()
        let clock = Date()
        let result = within(seconds: 300) { () -> Result<LlamaEngine, Error> in
            Result { try LlamaEngine(modelPath: modelPath, options: withAdapter) }
        }
        let took = seconds(since: clock)
        // 手放した後の使用量。読み込みの途中は 1 GB 以上増えるので、戻っていれば手放せている
        let after = footprintMB()
        let memory = "memory \(before) -> \(after) MB"
        switch result {
        case nil:
            log("LLM FAILURE: \(name): NG (no answer after \(took))")
            return false
        case .success?:
            log("LLM FAILURE: \(name): NG (it loaded with a text file as the adapter, \(took))")
            return false
        case .failure(let error)?:
            guard case LLMError.adapterLoadFailed = error else {
                log("LLM FAILURE: \(name): NG (wrong error: \(short(error)), \(took))")
                return false
            }
            guard after - before < 512 else {
                log("LLM FAILURE: \(name): NG (the model memory was not released: \(memory), \(took))")
                return false
            }
            log("LLM FAILURE: \(name): ok (\(took), \(memory), \"\(short(error))\")")
            return true
        }
    }

    /// アプリと同じ口 (`LLMService.run`) で、壊れた差分を頼む: 差分なしのモデルで答え、読み込めなかった差分を覚える。
    /// 確認のためだけの `LLMService` を作るので、アプリの設定やライブラリには触れない
    private static func serviceFallback(modelPath: String, adapterPath: String, options: LlamaOptions) -> Bool {
        let name = "the service falls back to the model without the adapter"
        let clock = Date()
        let box = LockedBox<Result<(String?, String), Error>>()
        let rejected = LockedBox<String>()
        let done = DispatchSemaphore(value: 0)
        // 確かめが終わったら、サービスごとモデルを手放す (次のふだんの読み込みと、メモリを重ねない)
        do {
            let service = LLMService(baseOptions: options)
            Task.detached {
                do {
                    let answer = try await service.run(modelPath: modelPath, adapterPath: adapterPath,
                                                       shouldCancel: { false }) { generator in
                        let text = try generator.generate(shortPrompt, shouldCancel: { false })
                        return (generator.adapterPath, text)
                    }
                    box.value = .success(answer)
                } catch {
                    box.value = .failure(error)
                }
                rejected.value = service.failedAdapter()
                service.unload()
                done.signal()
            }
            guard done.wait(timeout: .now() + 300) == .success else {
                log("LLM FAILURE: \(name): NG (no answer after \(seconds(since: clock)))")
                return false
            }
        }
        let took = seconds(since: clock)
        switch box.value {
        case .success(let (applied, text))?:
            guard applied == nil, rejected.value == adapterPath, !text.isEmpty else {
                log("LLM FAILURE: \(name): NG (adapter in use=\(applied ?? "none"), remembered as rejected="
                    + "\(rejected.value.map { ($0 as NSString).lastPathComponent } ?? "none"), answer \(text.debugDescription), \(took))")
                return false
            }
            log("LLM FAILURE: \(name): ok (answered \(text.debugDescription) without the adapter, "
                + "remembered \((adapterPath as NSString).lastPathComponent) as rejected, \(took))")
            return true
        case .failure(let error)?:
            log("LLM FAILURE: \(name): NG (\(short(error)), \(took))")
            return false
        case nil:
            log("LLM FAILURE: \(name): NG (no result, \(took))")
            return false
        }
    }

    // MARK: - 4 文脈より長い文

    private static func promptTooLong(engine: LlamaEngine) -> Bool {
        let name = "a prompt longer than the context is refused"
        let clock = Date()
        // 文脈の長さを超えるまで、同じ文を倍々に重ねる
        var user = "We open a new place and add a part. "
        while engine.tokenCount(user) <= engine.contextLength { user += user }
        let counted = engine.tokenCount(user)
        do {
            let text = try engine.generate(LLMPrompt(system: "Answer briefly.", user: user, maxTokens: 8),
                                           shouldCancel: { false })
            log("LLM FAILURE: \(name): NG (it answered \(text.prefix(40).debugDescription) for \(counted) tokens "
                + "with a context of \(engine.contextLength))")
            return false
        } catch LLMError.promptTooLong(let tokens, let limit) {
            let refused = seconds(since: clock)
            guard tokens >= limit else {
                log("LLM FAILURE: \(name): NG (refused with tokens \(tokens) < limit \(limit))")
                return false
            }
            // 断った後も、短いふつうの依頼には答える
            let after = (try? engine.generate(shortPrompt, shouldCancel: { false })) ?? ""
            guard !after.isEmpty else {
                log("LLM FAILURE: \(name): NG (refused \(tokens)/\(limit), but the next short request answered nothing)")
                return false
            }
            log("LLM FAILURE: \(name): ok (refused \(tokens)/\(limit) tokens in \(refused), "
                + "then answered \(after.debugDescription))")
            return true
        } catch {
            log("LLM FAILURE: \(name): NG (wrong error: \(short(error)))")
            return false
        }
    }

    // MARK: - 5 途中で止める

    private static func stopPartway(engine: LlamaEngine) -> Bool {
        let name = "stopping partway works and the next request still answers"
        // 文法で 40 字の小文字を書かせる (乱数の重みのモデルでも、途中で終わらずに何度も文を渡してくる)
        let long = LLMPrompt(system: "Write letters.", user: "Write forty letters.",
                             grammar: "root ::= " + String(repeating: "[a-z] ", count: 40), maxTokens: 64)
        var calls = 0
        let clock = Date()
        do {
            let text = try engine.generate(long, shouldCancel: { calls >= 3 }, onText: { _ in calls += 1 })
            log("LLM FAILURE: \(name): NG (it was not stopped: \(calls) updates, \(text.debugDescription))")
            return false
        } catch LLMError.cancelled {
            let stopped = seconds(since: clock)
            guard calls <= 4 else {
                log("LLM FAILURE: \(name): NG (stopped only after \(calls) updates, \(stopped))")
                return false
            }
            do {
                let next = try engine.generate(shortPrompt, shouldCancel: { false })
                let finish = engine.lastFinish
                // 文法の終わりまで書けば、終わりのトークンしか選べないので「書き終えた」(.complete) になる
                guard !next.isEmpty, finish == .complete else {
                    log("LLM FAILURE: \(name): NG (stopped after \(calls) updates, then \(next.debugDescription), finish \(finish))")
                    return false
                }
                log("LLM FAILURE: \(name): ok (stopped after \(calls) updates in \(stopped), "
                    + "then answered \(next.debugDescription), finish complete)")
                return true
            } catch {
                log("LLM FAILURE: \(name): NG (stopped, but the next request failed: \(short(error)))")
                return false
            }
        } catch {
            log("LLM FAILURE: \(name): NG (wrong error: \(short(error)))")
            return false
        }
    }

    // MARK: - 道具

    /// 短いふつうの依頼。文法で形を決めるので、乱数の重みのモデル (CI) でも、空でない答えを書き終える
    private static var shortPrompt: LLMPrompt {
        LLMPrompt(system: "Answer with one short line.", user: "[1] hello",
                  grammar: "root ::= \"[1] \" [a-z] [a-z]? \"\\n\"", maxTokens: 16)
    }

    /// 決めた秒のうちに返らなければ nil (llama.cpp が止まってしまっても、確かめ全体は止めない)
    private static func within<T>(seconds limit: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let box = LockedBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = body()
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success else { return nil }
        return box.value
    }

    /// 1 MB ほどの、ふつうの文字だけの中身
    private static func plainText(bytes: Int) -> Data {
        let line = "This is plain text. It is not a model and not an adapter.\n"
        var data = Data(capacity: bytes)
        while data.count < bytes { data.append(Data(line.utf8)) }
        return data.prefix(bytes)
    }

    /// このプロセスが使っているメモリ (MB。アクティビティモニタの「メモリ」と同じ数え方)
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// エラーの文の頭 (およそ 100 字)
    private static func short(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count > 100 ? String(text.prefix(100)) + "…" : text
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(date))
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
