import Foundation
import KikimimiCore
import whisper

/// 文字起こしの設定
public struct WhisperOptions: Sendable {
    /// "auto" か言語コード ("ja" など)
    public var language: String
    /// true: ビームサーチ (精度優先) / false: 貪欲法 (速度優先)
    public var useBeamSearch: Bool
    /// VAD (無音スキップ) モデルのパス。nil なら VAD を使わない
    public var vadModelPath: String?
    /// 固有名詞などのヒント (初期プロンプト)
    public var initialPrompt: String?
    public var threads: Int
    /// ライブプレビュー向け: 1 区間にまとめて高速化
    public var singleSegment: Bool
    public var noTimestamps: Bool
    /// 定番の誤認識 (ご視聴ありがとうございました 等) を除去する
    public var filterHallucinations: Bool

    public init(language: String = "auto",
                useBeamSearch: Bool = true,
                vadModelPath: String? = nil,
                initialPrompt: String? = nil,
                threads: Int = WhisperOptions.recommendedThreads,
                singleSegment: Bool = false,
                noTimestamps: Bool = false,
                filterHallucinations: Bool = true) {
        self.language = language
        self.useBeamSearch = useBeamSearch
        self.vadModelPath = vadModelPath
        self.initialPrompt = initialPrompt
        self.threads = threads
        self.singleSegment = singleSegment
        self.noTimestamps = noTimestamps
        self.filterHallucinations = filterHallucinations
    }

    public static var recommendedThreads: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
}

public struct WhisperOutput: Sendable {
    public var segments: [TranscriptSegment]
    public var language: String?
}

public enum WhisperError: LocalizedError, Equatable {
    case modelLoadFailed(String)
    case emptyAudio
    case cancelled
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "モデルを読み込めませんでした: \((path as NSString).lastPathComponent)。ファイルが壊れている可能性があります。設定から削除して取り直してください。"
        case .emptyAudio: return "音声が空です。"
        case .cancelled: return "中止しました。"
        case .failed(let code): return "文字起こしに失敗しました (whisper.cpp エラー \(code))。"
        }
    }
}

/// whisper.cpp のコンテキスト (読み込み済みモデル)。
///
/// 1 つのコンテキストで同時に走れる推論は 1 本なので、内部のロックで直列化する。
public final class WhisperContext: @unchecked Sendable {
    public let modelPath: String
    private let ctx: OpaquePointer
    private let lock = NSLock()

    public init(modelPath: String, useGPU: Bool = true) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
        self.modelPath = modelPath
    }

    deinit {
        whisper_free(ctx)
    }

    /// 文字起こし (ブロッキング)。呼び出し側でバックグラウンドのスレッドから呼ぶこと。
    public func transcribe(samples: [Float],
                           options: WhisperOptions,
                           onProgress: @escaping (Double) -> Void = { _ in },
                           onSegment: @escaping (TranscriptSegment) -> Void = { _ in },
                           shouldCancel: @escaping () -> Bool = { false }) throws -> WhisperOutput {
        lock.lock()
        defer { lock.unlock() }
        return try run(samples: samples, options: options, onProgress: onProgress,
                       onSegment: onSegment, shouldCancel: shouldCancel)
    }

    /// 他の推論が走っていれば待たずに nil を返す (ライブプレビュー用)。
    public func transcribeIfIdle(samples: [Float], options: WhisperOptions) throws -> WhisperOutput? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try run(samples: samples, options: options, onProgress: { _ in },
                       onSegment: { _ in }, shouldCancel: { false })
    }

    // MARK: - 実装

    private func run(samples: [Float],
                     options: WhisperOptions,
                     onProgress: @escaping (Double) -> Void,
                     onSegment: @escaping (TranscriptSegment) -> Void,
                     shouldCancel: @escaping () -> Bool) throws -> WhisperOutput {
        guard !samples.isEmpty else { throw WhisperError.emptyAudio }

        let box = CallbackBox(onProgress: onProgress, onSegment: onSegment,
                              shouldCancel: shouldCancel, filter: options.filterHallucinations)
        let userData = Unmanaged.passUnretained(box).toOpaque()

        var params = whisper_full_default_params(options.useBeamSearch ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, options.threads))
        params.translate = false
        params.no_context = true
        params.single_segment = options.singleSegment
        params.no_timestamps = options.noTimestamps
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true   // ♪ や (音楽) などの非音声トークンを抑える (OpenAI 版の既定と同じ)

        // C 文字列は whisper_full が終わるまで生かしておく
        let language = strdup(options.language.isEmpty ? "auto" : options.language)
        defer { free(language) }
        params.language = UnsafePointer(language)
        params.detect_language = false

        var prompt: UnsafeMutablePointer<CChar>? = nil
        if let p = options.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            prompt = strdup(p)
            params.initial_prompt = UnsafePointer(prompt)
        }
        defer { free(prompt) }

        var vadPath: UnsafeMutablePointer<CChar>? = nil
        if let p = options.vadModelPath, FileManager.default.fileExists(atPath: p) {
            vadPath = strdup(p)
            params.vad = true
            params.vad_model_path = UnsafePointer(vadPath)
            params.vad_params.speech_pad_ms = 100
        }
        defer { free(vadPath) }

        params.progress_callback = { _, _, progress, userData in
            guard let userData else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            box.onProgress(Double(progress) / 100.0)
        }
        params.progress_callback_user_data = userData

        params.new_segment_callback = { _, state, nNew, userData in
            guard let userData, let state else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            let total = whisper_full_n_segments_from_state(state)
            let first = max(0, total - nNew)
            guard first < total else { return }
            for i in first..<total {
                if let seg = WhisperContext.segmentFromState(state, i, filter: box.filter) {
                    box.onSegment(seg)
                }
            }
        }
        params.new_segment_callback_user_data = userData

        params.encoder_begin_callback = { _, _, userData in
            guard let userData else { return true }
            return !Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue().shouldCancel()
        }
        params.encoder_begin_callback_user_data = userData

        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue().shouldCancel()
        }
        params.abort_callback_user_data = userData

        let rc: Int32 = withExtendedLifetime(box) {
            samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        if shouldCancel() { throw WhisperError.cancelled }
        guard rc == 0 else { throw WhisperError.failed(rc) }

        var segments: [TranscriptSegment] = []
        let n = whisper_full_n_segments(ctx)
        if n > 0 {
            for i in 0..<n {
                if let seg = segmentFromContext(i, filter: options.filterHallucinations) {
                    segments.append(seg)
                }
            }
        }

        // whisper_full は「VAD で発話が見つからない」「100 ms 未満」のとき lang_id を更新せずに 0 を返す。
        // 前回の値を拾わないよう、指定された言語を優先し、自動判定は実際に認識できたときだけ読む。
        var detected: String? = nil
        if whisper_is_multilingual(ctx) == 0 {
            detected = "en"   // 英語専用モデルは言語指定を無視する
        } else if !options.language.isEmpty, options.language != "auto" {
            detected = options.language
        } else if n > 0 {
            let langID = whisper_full_lang_id(ctx)
            if langID >= 0, let cLang = whisper_lang_str(langID) {
                detected = String(cString: cLang)
            }
        }
        return WhisperOutput(segments: segments, language: detected)
    }

    /// whisper.cpp の時刻は 10 ミリ秒単位
    private static func seconds(_ t: Int64) -> TimeInterval { TimeInterval(t) / 100.0 }

    private func segmentFromContext(_ i: Int32, filter: Bool) -> TranscriptSegment? {
        guard let cText = whisper_full_get_segment_text(ctx, i) else { return nil }
        let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
        let noSpeech = whisper_full_get_segment_no_speech_prob(ctx, i)
        if text.isEmpty || (filter && HallucinationFilter.shouldDrop(text: text, noSpeechProbability: noSpeech)) {
            return nil
        }
        return TranscriptSegment(start: Self.seconds(whisper_full_get_segment_t0(ctx, i)),
                                 end: Self.seconds(whisper_full_get_segment_t1(ctx, i)),
                                 text: text)
    }

    fileprivate static func segmentFromState(_ state: OpaquePointer, _ i: Int32, filter: Bool) -> TranscriptSegment? {
        guard let cText = whisper_full_get_segment_text_from_state(state, i) else { return nil }
        let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
        let noSpeech = whisper_full_get_segment_no_speech_prob_from_state(state, i)
        if text.isEmpty || (filter && HallucinationFilter.shouldDrop(text: text, noSpeechProbability: noSpeech)) {
            return nil
        }
        return TranscriptSegment(start: seconds(whisper_full_get_segment_t0_from_state(state, i)),
                                 end: seconds(whisper_full_get_segment_t1_from_state(state, i)),
                                 text: text)
    }

    /// whisper.cpp のビルド情報 (Metal が有効か等)
    public static var systemInfo: String {
        guard let info = whisper_print_system_info() else { return "" }
        return String(cString: info)
    }
}

/// C のコールバックへ user_data として渡す入れ物
private final class CallbackBox {
    let onProgress: (Double) -> Void
    let onSegment: (TranscriptSegment) -> Void
    let shouldCancel: () -> Bool
    let filter: Bool

    init(onProgress: @escaping (Double) -> Void,
         onSegment: @escaping (TranscriptSegment) -> Void,
         shouldCancel: @escaping () -> Bool,
         filter: Bool) {
        self.onProgress = onProgress
        self.onSegment = onSegment
        self.shouldCancel = shouldCancel
        self.filter = filter
    }
}
