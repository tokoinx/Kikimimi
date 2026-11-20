import Foundation
import KikimimiCore
import KikimimiLLM

/// 監査・翻訳・チャットのローカル LLM (llama.cpp) を専用のスレッドで回す。読み込んだモデルは使い回す。
/// チャット (`runInteractive`) は、監査・翻訳の最中でも、その `generate` の合間に先に通る (条件は `run` の説明)。
final class LLMService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.kikimimi.llm", qos: .userInitiated)
    private let lock = NSLock()
    /// `queue` の上でだけ書き換える。`lock` で保護する
    private var engine: LlamaEngine?
    /// 読み込みの設定 (差分のほか)。アプリはいつも既定の値。確認用の起動 (`--selftest-llm-queue --cpu`) だけが変える
    private let baseOptions: LlamaOptions

    init(baseOptions: LlamaOptions = LlamaOptions()) {
        var options = baseOptions
        options.adapterPath = nil
        self.baseOptions = options
    }

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
            self.loadedAdapter = nil
            self.lock.unlock()
        }
    }

    /// 読み込めなかった差分 (あれば)。読み込めないときは、差分なしの元のモデルで動かす
    func failedAdapter() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rejectedAdapter?.path
    }

    /// 差分のファイル。場所が同じでも、作り直されていれば (更新日時が違えば) 別のものとして読み込み直す
    /// (アプリを開いたまま `finetune.py --install` で入れ替えたとき)
    private struct AdapterID: Equatable {
        let path: String
        let modified: Date?

        init?(_ path: String?) {
            guard let path else { return nil }
            self.path = path
            modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
    }

    /// `lock` で保護する
    private var rejectedAdapter: AdapterID?
    /// いまのモデルに重ねてある差分。`lock` で保護する
    private var loadedAdapter: AdapterID?

    /// 割り込み (チャット) の待ち行列。監査・翻訳の `generate` の手前で、合う物を先に通す
    private let interrupts = LLMInterruptQueue<LlamaEngine>()

    /// 待っている割り込みの数 (確認用の起動 `--selftest-llm-queue` が、積み終えたかを見るのに使う)
    var waitingInterrupts: Int { interrupts.waitingCount }

    /// 監査・翻訳の `generate` の手前で通した割り込みの数 (これまでの合計。確認用)
    var yieldedInterrupts: Int { interrupts.yielded }

    /// モデルを (必要なら読み込んで) 使う。body は LLM のスレッドで動く。
    /// adapterPath は追加学習の差分 (LoRA)。読み込めなければ、差分なしで動かす (`failedAdapter()` でわかる)。
    /// body に渡すエンジンは包み (`YieldingGenerator`) で、`generate` の手前で、待っている割り込み (チャット) のうち
    /// 今のエンジンに合う物 (モデルが同じで、差分を重ねていない) を先に通す。割り込みの答えやエラーは、body には入らない
    func run<T>(modelPath: String, adapterPath: String? = nil,
                shouldCancel: @escaping @Sendable () -> Bool,
                _ body: @escaping (YieldingGenerator) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    let engine = try self.loadedEngine(modelPath, adapterPath: adapterPath, shouldCancel: shouldCancel)
                    let interrupts = self.interrupts
                    let generator = YieldingGenerator(engine, adapterPath: engine.adapterPath) {
                        interrupts.runWaiting(modelPath: engine.modelPath, adapterLoaded: engine.adapterPath != nil, engine: engine)
                    }
                    cont.resume(returning: try body(generator))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// チャットのための口。差分はいつも「なし」。body は LLM のスレッドで動き、包んでいないエンジンを受け取る。
    /// 依頼を割り込みの待ち行列に入れ、同時に LLM の列にも積む。先に取った側が 1 度だけ走らせる:
    /// 監査・翻訳が同じモデルを差分なしで使っている最中なら、その `generate` の手前で通る。
    /// そうでなければ (何も動いていない・差分やモデルが違う)、今までどおり列の順番で走る
    func runInteractive<T>(modelPath: String,
                           shouldCancel: @escaping @Sendable () -> Bool,
                           _ body: @escaping (LlamaEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let id = interrupts.add(modelPath: modelPath, body: body) { result in cont.resume(with: result) }
            queue.async {
                // 監査・翻訳の継ぎ目が先に取って走らせていれば、ここでは何もしない
                guard let request = self.interrupts.take(id: id) else { return }
                do {
                    let engine = try self.loadedEngine(modelPath, adapterPath: nil, shouldCancel: shouldCancel)
                    request.run(engine)
                } catch {
                    request.fail(error)
                }
            }
        }
    }

    private func loadedEngine(_ path: String, adapterPath: String?, shouldCancel: @escaping () -> Bool) throws -> LlamaEngine {
        let wanted = AdapterID(adapterPath)
        lock.lock()
        // 前に読み込めなかった差分は、もう試さない (毎回、数秒の読み込みをやり直さない)
        let adapter = wanted == rejectedAdapter ? nil : wanted
        if let engine, engine.modelPath == path, loadedAdapter == adapter {
            lock.unlock()
            return engine
        }
        // 同じモデルを、差分だけが違うので読み直す (監査 → 翻訳と続き、監査用と翻訳用の差分が違う時など)。掛かった秒をログに出す
        let previousAdapter = engine?.modelPath == path ? loadedAdapter : nil
        let reloadingForAdapter = engine?.modelPath == path
        engine = nil // 先に古いモデルを手放す
        loadedAdapter = nil
        lock.unlock()

        let started = Date()
        let loaded: LlamaEngine
        var applied = adapter
        do {
            var options = baseOptions
            options.adapterPath = adapter?.path
            loaded = try LlamaEngine(modelPath: path, options: options, shouldCancel: shouldCancel)
        } catch LLMError.adapterLoadFailed {
            lock.lock()
            rejectedAdapter = adapter
            lock.unlock()
            applied = nil
            loaded = try LlamaEngine(modelPath: path, options: baseOptions, shouldCancel: shouldCancel)
        }
        lock.lock()
        engine = loaded
        loadedAdapter = applied
        // 前に読み込めなかった差分が、作り直されて読み込めた: 「読み込めなかった」の記録を消す
        if let applied, rejectedAdapter?.path == applied.path { rejectedAdapter = nil }
        lock.unlock()
        if reloadingForAdapter {
            func name(_ id: AdapterID?) -> String { id.map { ($0.path as NSString).lastPathComponent } ?? "none" }
            LaunchLog.note("llm: reloaded \((path as NSString).lastPathComponent) for a different adapter ("
                + "\(name(previousAdapter)) -> \(name(applied))) in " + String(format: "%.2f s", Date().timeIntervalSince(started)))
        }
        return loaded
    }

    /// 差分を入れ替えた・外したときに呼ぶ (読み込めなかった記録を消し、次の実行で読み込み直す)
    func adapterChanged() {
        queue.async {
            self.lock.lock()
            self.rejectedAdapter = nil
            self.loadedAdapter = nil
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
