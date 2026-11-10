import Foundation
import KikimimiCore
import KikimimiLLM

/// 監査・翻訳のローカル LLM (llama.cpp) を専用のスレッドで回す。読み込んだモデルは使い回す。
final class LLMService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.kikimimi.llm", qos: .userInitiated)
    private let lock = NSLock()
    /// `queue` の上でだけ書き換える。`lock` で保護する
    private var engine: LlamaEngine?

    /// 読み込み済みで、すぐに使えるか (状態表示用)
    func isLoaded(modelPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine?.modelPath == modelPath
    }

    /// 読み込んだモデルを手放してメモリを空ける
    func unload() {
        queue.async {
            self.lock.lock()
            self.engine = nil
            self.lock.unlock()
        }
    }

    /// 読み込めなかった差分 (あれば)。読み込めないときは、差分なしの元のモデルで動かす
    func failedAdapter() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rejectedAdapter
    }

    /// `lock` で保護する
    private var rejectedAdapter: String?

    /// モデルを (必要なら読み込んで) 使う。body は LLM のスレッドで動く。
    /// adapterPath は追加学習の差分 (LoRA)。読み込めなければ、差分なしで動かす (`failedAdapter()` でわかる)
    func run<T>(modelPath: String, adapterPath: String? = nil,
                shouldCancel: @escaping @Sendable () -> Bool,
                _ body: @escaping (LlamaEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    let engine = try self.loadedEngine(modelPath, adapterPath: adapterPath, shouldCancel: shouldCancel)
                    cont.resume(returning: try body(engine))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func loadedEngine(_ path: String, adapterPath: String?, shouldCancel: @escaping () -> Bool) throws -> LlamaEngine {
        lock.lock()
        // 前に読み込めなかった差分は、もう試さない (毎回、数秒の読み込みをやり直さない)
        let adapter = adapterPath == rejectedAdapter ? nil : adapterPath
        if let engine, engine.modelPath == path, engine.adapterPath == adapter {
            lock.unlock()
            return engine
        }
        engine = nil // 先に古いモデルを手放す
        lock.unlock()

        let loaded: LlamaEngine
        do {
            loaded = try LlamaEngine(modelPath: path, options: LlamaOptions(adapterPath: adapter), shouldCancel: shouldCancel)
        } catch LLMError.adapterLoadFailed(let failed) {
            lock.lock()
            rejectedAdapter = failed
            lock.unlock()
            loaded = try LlamaEngine(modelPath: path, options: LlamaOptions(), shouldCancel: shouldCancel)
        }
        lock.lock()
        engine = loaded
        lock.unlock()
        return loaded
    }

    /// 差分を入れ替えた・外したときに呼ぶ (読み込めなかった記録を消し、次の実行で読み込み直す)
    func adapterChanged() {
        queue.async {
            self.lock.lock()
            self.rejectedAdapter = nil
            self.engine = nil
            self.lock.unlock()
        }
    }
}

/// メモリの少ない Mac では、Whisper と LLM を同時に持たない
enum MemoryBudget {
    static var isTight: Bool {
        ProcessInfo.processInfo.physicalMemory < 12 * 1_073_741_824
    }

    static var physicalGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }
}
