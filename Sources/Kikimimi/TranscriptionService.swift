import Foundation
import KikimimiCore
import KikimimiWhisper

/// 自動で、無音を飛ばさずに (VAD なしで) やり直した様子
struct VADRetryReport: Sendable {
    /// やり直すと決めた時の、初めの結果の様子
    var assessment: VADDropCheck.Assessment
    /// 初めの結果の文字の数 (空白を除く)
    var firstLetters: Int
    /// やり直した結果の文字の数 (やり直しが失敗した時は nil)
    var retryLetters: Int?
    /// やり直した結果を採った
    var usedRetry: Bool
    /// やり直しが失敗した時の知らせ
    var retryError: String?
}

/// 文字起こしの結果と、自動のやり直しの様子
struct TranscriptionResult: Sendable {
    var output: WhisperOutput
    /// 自動で VAD なしでやり直した時だけ入る
    var vadRetry: VADRetryReport?
}

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

    /// 文字起こしする。autoVADOff が true なら、VAD を使った結果が音を落としたらしい時に、VAD なしでやり直す
    /// (transcribeCheckingVAD)。やり直しを始める時に onVADRetry を呼ぶ (そこまでに出した区間は、使う側で消す)
    func transcribe(samples: [Float],
                    modelPath: String,
                    options: WhisperOptions,
                    autoVADOff: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void,
                    onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
                    onRestart: @escaping @Sendable () -> Void = {},
                    onVADRetry: @escaping @Sendable (VADDropCheck.Assessment) -> Void = { _ in },
                    onStage: @escaping @Sendable (TranscriptionStage) -> Void = { _ in },
                    shouldCancel: @escaping @Sendable () -> Bool) async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TranscriptionResult, Error>) in
            queue.async {
                do {
                    let result = try Self.transcribeCheckingVAD(
                        samples: samples, options: options, autoVADOff: autoVADOff,
                        transcribe: { runOptions in
                            try self.run(samples: samples, modelPath: modelPath, options: runOptions,
                                         onProgress: onProgress, onSegment: onSegment, onRestart: onRestart,
                                         onStage: onStage, shouldCancel: shouldCancel)
                        },
                        onRetry: onVADRetry,
                        shouldCancel: shouldCancel
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// VAD を使って文字起こしし、音が続いているのに結果の区間が少ない (VADDropCheck) 時は、同じ指定のまま VAD だけを外して、
    /// もう一度文字起こしする。文字の数が多いほうを採る (同じなら初めの結果)。
    /// やり直しが中止されたら中止を投げ、失敗したら初めの結果を返す。
    /// アプリ (TranscriptionService.transcribe) と診断 (WhisperSelfTest) の両方が、これを通る。
    /// - Parameters:
    ///   - autoVADOff: false なら、やり直さない (1 回だけ文字起こしする)
    ///   - transcribe: 1 回の文字起こし。結果と、VAD を本当に使ったか (VAD が動かず VAD なしになった時は false) を返す
    ///   - onRetry: やり直しを始める直前に呼ぶ
    static func transcribeCheckingVAD(samples: [Float],
                                      options: WhisperOptions,
                                      autoVADOff: Bool,
                                      transcribe: (WhisperOptions) throws -> (output: WhisperOutput, usedVAD: Bool),
                                      onRetry: (VADDropCheck.Assessment) -> Void,
                                      shouldCancel: () -> Bool) throws -> TranscriptionResult {
        let first = try transcribe(options)
        guard autoVADOff, first.usedVAD else { return TranscriptionResult(output: first.output, vadRetry: nil) }
        if shouldCancel() { throw WhisperError.cancelled }
        let ranges = first.output.segments.map { min($0.start, $0.end)...max($0.start, $0.end) }
        let assessment = VADDropCheck.assess(samples: samples, sampleRate: MixedLanguageRules.sampleRate, segments: ranges)
        guard assessment.looksDropped else { return TranscriptionResult(output: first.output, vadRetry: nil) }

        // 同じ指定のまま、VAD だけを外す。日本語と英語が混ざっていると確かめて「日本語＋英語」で文字にしていたら、
        // やり直しも「日本語＋英語」にする (混ざっているかを確かめるのは VAD を使う時だけなので、外すと確かめられない)
        var plain = options
        plain.vadModelPath = nil
        if let probe = first.output.probe, probe.isMixed, !probe.candidates.isEmpty {
            plain.languageCandidates = probe.candidates
            plain.language = probe.candidates[0]
        }
        let firstLetters = VADDropCheck.letterCount(of: first.output.segments)
        onRetry(assessment)
        do {
            var retry = try transcribe(plain).output
            if shouldCancel() { throw WhisperError.cancelled }
            let retryLetters = VADDropCheck.letterCount(of: retry.segments)
            let usesRetry = VADDropCheck.prefersRetry(first: first.output.segments, retry: retry.segments)
            let report = VADRetryReport(assessment: assessment, firstLetters: firstLetters, retryLetters: retryLetters,
                                        usedRetry: usesRetry, retryError: nil)
            guard usesRetry else { return TranscriptionResult(output: first.output, vadRetry: report) }
            // 混ざっているかを確かめた結果は、初めの実行の物を残す (アプリが「日本語＋英語」の印を付けるため)
            if retry.probe == nil { retry.probe = first.output.probe }
            return TranscriptionResult(output: retry, vadRetry: report)
        } catch {
            if shouldCancel() || (error as? WhisperError) == .cancelled { throw WhisperError.cancelled }
            let report = VADRetryReport(assessment: assessment, firstLetters: firstLetters, retryLetters: nil,
                                        usedRetry: false, retryError: error.localizedDescription)
            return TranscriptionResult(output: first.output, vadRetry: report)
        }
    }

    /// 1 回の文字起こし。結果と、VAD を本当に使ったかを返す
    private func run(samples: [Float],
                     modelPath: String,
                     options: WhisperOptions,
                     onProgress: @escaping @Sendable (Double) -> Void,
                     onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
                     onRestart: @escaping @Sendable () -> Void,
                     onStage: @escaping @Sendable (TranscriptionStage) -> Void,
                     shouldCancel: @escaping @Sendable () -> Bool) throws -> (output: WhisperOutput, usedVAD: Bool) {
        // WhisperContext と同じ条件 (パスがあり、ファイルが存在する) で VAD を使う
        let usesVAD = options.vadModelPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let ctx = try loadedContext(modelPath, vad: usesVAD)
        do {
            let output = try ctx.transcribe(samples: samples, options: options,
                                            onProgress: onProgress, onSegment: onSegment, onStage: onStage,
                                            shouldCancel: shouldCancel)
            return (output, usesVAD)
        } catch WhisperError.failed(let code) where code == -7 && !shouldCancel() {
            // whisper.cpp が内部の状態を解放した (メモリ不足で KV キャッシュを作り直せなかった)。VAD とは関係ないので、
            // 読み込み直して同じ設定で 1 回だけやり直す (使えなくなったコンテキストは loadedContext が読み込み直す)
            let fresh = try loadedContext(modelPath, vad: usesVAD)
            onRestart() // そこまでに出した区間は、やり直しでもう一度出る
            let output = try fresh.transcribe(samples: samples, options: options,
                                              onProgress: onProgress, onSegment: onSegment, onStage: onStage,
                                              shouldCancel: shouldCancel)
            return (output, usesVAD)
        } catch WhisperError.failed where usesVAD && !shouldCancel() {
            // VAD モデルが読めない等。VAD なしでやり直す
            var plainOptions = options
            plainOptions.vadModelPath = nil
            let plain = try loadedContext(modelPath, vad: false)
            onRestart()
            let output = try plain.transcribe(samples: samples, options: plainOptions,
                                              onProgress: onProgress, onSegment: onSegment, onStage: onStage,
                                              shouldCancel: shouldCancel)
            return (output, false)
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
