import Foundation
import KikimimiCore
import KikimimiWhisper

/// whisper.cpp の推論を専用のスレッドで回す。読み込んだモデルは使い回す。
final class TranscriptionService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.kikimimi.transcribe", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "local.kikimimi.preview", qos: .utility)
    private let lock = NSLock()
    private var context: WhisperContext?
    /// whisper.cpp は直前に VAD を使った実行の「時刻の対応表」を持ち続け、VAD なしの実行の時刻にも当ててしまう。
    /// そのため VAD を使ったあとに VAD なしで認識するときは、モデルを読み込み直す。`lock` で保護する。
    private var contextHasVADMap = false

    /// 読み込みも読み直しも要らず、すぐ認識に入れるか (状態表示用)
    func isReady(modelPath: String, vad: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return context?.modelPath == modelPath && context?.isUsable == true && (vad || !contextHasVADMap)
    }

    /// `queue` の上でだけ呼ぶ (読み込みは同時に 1 本)。数秒かかる読み込みの間はロックを持たない。
    /// - Parameter vad: これから VAD あり (true) / なし (false) で認識する。nil は時刻を使わない先読み。
    private func loadedContext(_ modelPath: String, vad: Bool?) throws -> WhisperContext {
        lock.lock()
        // 使えなくなったコンテキスト (whisper.cpp が内部の状態を解放した) は読み込み直す
        if let context, context.modelPath == modelPath, context.isUsable, !(vad == false && contextHasVADMap) {
            if vad == true { contextHasVADMap = true }
            lock.unlock()
            return context
        }
        context = nil // 先に古いモデルを手放してメモリを空ける
        contextHasVADMap = false
        lock.unlock()

        let loaded = try WhisperContext(modelPath: modelPath)

        lock.lock()
        context = loaded
        contextHasVADMap = (vad == true)
        lock.unlock()
        return loaded
    }

    /// 読み込んだモデルを手放す (メモリの少ない Mac で、LLM を動かす前に空ける)
    func unload() {
        queue.async {
            self.lock.lock()
            self.context = nil
            self.contextHasVADMap = false
            self.lock.unlock()
        }
    }

    /// モデルを先に読み込んでおく (録音中のプレビュー用)
    func preload(modelPath: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    _ = try self.loadedContext(modelPath, vad: nil)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func transcribe(samples: [Float],
                    modelPath: String,
                    options: WhisperOptions,
                    onProgress: @escaping @Sendable (Double) -> Void,
                    onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
                    shouldCancel: @escaping @Sendable () -> Bool) async throws -> WhisperOutput {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WhisperOutput, Error>) in
            queue.async {
                do {
                    let output = try self.run(samples: samples, modelPath: modelPath, options: options,
                                              onProgress: onProgress, onSegment: onSegment,
                                              shouldCancel: shouldCancel)
                    cont.resume(returning: output)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func run(samples: [Float],
                     modelPath: String,
                     options: WhisperOptions,
                     onProgress: @escaping @Sendable (Double) -> Void,
                     onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
                     shouldCancel: @escaping @Sendable () -> Bool) throws -> WhisperOutput {
        // WhisperContext と同じ条件 (パスがあり、ファイルが存在する) で VAD を使う
        let usesVAD = options.vadModelPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let ctx = try loadedContext(modelPath, vad: usesVAD)
        do {
            return try ctx.transcribe(samples: samples, options: options,
                                      onProgress: onProgress, onSegment: onSegment,
                                      shouldCancel: shouldCancel)
        } catch WhisperError.failed(let code) where code == -7 && !shouldCancel() {
            // whisper.cpp が内部の状態を解放した (メモリ不足で KV キャッシュを作り直せなかった)。VAD とは関係ないので、
            // 読み込み直して同じ設定で 1 回だけやり直す (使えなくなったコンテキストは loadedContext が読み込み直す)
            let fresh = try loadedContext(modelPath, vad: usesVAD)
            return try fresh.transcribe(samples: samples, options: options,
                                        onProgress: onProgress, onSegment: onSegment,
                                        shouldCancel: shouldCancel)
        } catch WhisperError.failed where usesVAD && !shouldCancel() {
            // VAD モデルが読めない等。VAD なしでやり直す
            var plainOptions = options
            plainOptions.vadModelPath = nil
            let plain = try loadedContext(modelPath, vad: false)
            return try plain.transcribe(samples: samples, options: plainOptions,
                                        onProgress: onProgress, onSegment: onSegment,
                                        shouldCancel: shouldCancel)
        }
    }

    /// 録音中のプレビュー。モデルが読み込み済みで、ほかの推論が走っていないときだけ動く (本文だけを使う)。
    func preview(samples: [Float], modelPath: String, options: WhisperOptions) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            previewQueue.async {
                self.lock.lock()
                let ctx = self.context?.modelPath == modelPath ? self.context : nil
                self.lock.unlock()
                guard let ctx, let output = try? ctx.transcribeIfIdle(samples: samples, options: options) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: output.segments.map(\.text).joined(separator: " "))
            }
        }
    }
}
