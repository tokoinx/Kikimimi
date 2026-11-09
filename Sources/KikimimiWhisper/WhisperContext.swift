import Foundation
import KikimimiCore
// llama.framework と同じ名前の ggml の型がぶつからないよう、whisper はこのモジュールの中だけで使う
internal import whisper

/// 文字起こしの設定
public struct WhisperOptions: Sendable {
    /// "auto" か言語コード ("ja" など)
    public var language: String
    /// 区切りごとに言語を判定するときの候補 (2 つ以上のとき。「日本語＋英語」なら ["ja", "en"])。
    /// 空なら、language の 1 つの言語で文字にする
    public var languageCandidates: [String]
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
                languageCandidates: [String] = [],
                useBeamSearch: Bool = true,
                vadModelPath: String? = nil,
                initialPrompt: String? = nil,
                threads: Int = WhisperOptions.recommendedThreads,
                singleSegment: Bool = false,
                noTimestamps: Bool = false,
                filterHallucinations: Bool = true) {
        self.language = language
        self.languageCandidates = languageCandidates
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

    /// 区切りごとに言語を判定して文字にするか
    var isMixed: Bool { languageCandidates.count >= 2 }
}

public struct WhisperOutput: Sendable {
    public var segments: [TranscriptSegment]
    public var language: String?
    /// 区切りごとに言語を判定したときの記録 (診断用)
    public var report: MixedReport?

    public init(segments: [TranscriptSegment], language: String?, report: MixedReport? = nil) {
        self.segments = segments
        self.language = language
        self.report = report
    }
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
    let ctx: OpaquePointer
    private let lock = NSLock()
    /// whisper_full が -7 (KV キャッシュを作れない) を返したとき、whisper.cpp は内部の状態をもう解放している。
    /// whisper_free でもう一度解放すると落ちるので、このコンテキストは解放せずに手放す (使う側が読み込み直す)
    private let brokenLock = NSLock()
    private var broken = false
    /// ライブプレビュー (「日本語＋英語」) の言語。`lock` を持っているあいだだけ触る
    private var preview = PreviewLanguage()

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
        if !isBroken { whisper_free(ctx) }
    }

    /// まだ使えるか (false なら読み込み直す)
    public var isUsable: Bool { !isBroken }

    private var isBroken: Bool {
        brokenLock.lock()
        defer { brokenLock.unlock() }
        return broken
    }

    /// 文字起こし (ブロッキング)。呼び出し側でバックグラウンドのスレッドから呼ぶこと。
    public func transcribe(samples: [Float],
                           options: WhisperOptions,
                           onProgress: @escaping (Double) -> Void = { _ in },
                           onSegment: @escaping (TranscriptSegment) -> Void = { _ in },
                           shouldCancel: @escaping () -> Bool = { false }) throws -> WhisperOutput {
        lock.lock()
        defer { lock.unlock() }
        guard !isBroken else { throw WhisperError.failed(-7) }
        if options.isMixed, whisper_is_multilingual(ctx) != 0 {
            return try runMixed(samples: samples, options: options, onProgress: onProgress,
                                onSegment: onSegment, shouldCancel: shouldCancel)
        }
        return try run(samples: samples, options: options, onProgress: onProgress,
                       onSegment: onSegment, shouldCancel: shouldCancel)
    }

    /// 他の推論が走っていれば待たずに nil を返す (ライブプレビュー用)。
    /// 「日本語＋英語」では、窓の言語を判定してから、その言語で文字にする (判定は 3 回に 1 回と、文字が言語と合わないとき)
    public func transcribeIfIdle(samples: [Float], options: WhisperOptions) throws -> WhisperOutput? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard !isBroken else { return nil }
        var options = options
        let candidates = options.languageCandidates
        let mixed = options.isMixed && whisper_is_multilingual(ctx) != 0 && !samples.isEmpty
        if mixed {
            options.language = previewLanguage(samples, candidates: candidates, threads: options.threads)
        }
        options.languageCandidates = []
        let output = try run(samples: samples, options: options, onProgress: { _ in },
                             onSegment: { _ in }, shouldCancel: { false })
        if mixed {
            let text = output.segments.map(\.text).joined(separator: " ")
            if Script.hasLetters(text),
               Script.spokenLanguage(of: text, among: candidates, fallback: options.language) != options.language {
                preview.recheck = true
            }
        }
        return output
    }

    // MARK: - 1 つの言語で文字にする

    private func run(samples: [Float],
                     options: WhisperOptions,
                     onProgress: @escaping (Double) -> Void,
                     onSegment: @escaping (TranscriptSegment) -> Void,
                     shouldCancel: @escaping () -> Bool) throws -> WhisperOutput {
        guard !samples.isEmpty else { throw WhisperError.emptyAudio }

        // 画面への途中表示: 1 区間の中の繰り返しをまとめ、定番の誤認識を除き、間を空けずに続く同じ区間を出さない
        let filter = options.filterHallucinations
        var stream = RepetitionFilter.Streaming()
        let box = CallbackBox(onProgress: onProgress, onSegment: { raw in
            guard let seg = WhisperContext.filtered(raw, filter: filter) else { return }
            if filter, !stream.accept(seg) { return }
            onSegment(seg)
        }, shouldCancel: shouldCancel)
        let language = Self.effectiveLanguage(options.language)
        let params = makeParams(options, language: language, hint: options.initialPrompt, box: box)

        let rc: Int32 = withExtendedLifetime(params) {
            samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params.raw, buffer.baseAddress, Int32(buffer.count))
            }
        }
        markBrokenIfStateFreed(rc)
        if shouldCancel() { throw WhisperError.cancelled }
        try check(rc)

        var segments: [TranscriptSegment] = []
        let n = whisper_full_n_segments(ctx)
        if n > 0 {
            for i in 0..<n {
                if let seg = segmentFromContext(i, filter: options.filterHallucinations) {
                    segments.append(seg)
                }
            }
        }
        if options.filterHallucinations {
            segments = RepetitionFilter.clean(segments)
        }

        // whisper_full は「VAD で発話が見つからない」「100 ms 未満」のとき lang_id を更新せずに 0 を返す。
        // 前回の値を拾わないよう、指定された言語を優先し、自動判定は実際に認識できたときだけ読む。
        var detected: String? = nil
        if whisper_is_multilingual(ctx) == 0 {
            detected = "en"   // 英語専用モデルは言語指定を無視する
        } else if language != "auto" {
            detected = language
        } else if n > 0 {
            let langID = whisper_full_lang_id(ctx)
            if langID >= 0, let cLang = whisper_lang_str(langID) {
                detected = String(cString: cLang)
            }
        }
        return WhisperOutput(segments: segments, language: detected)
    }

    /// whisper に渡す言語。whisper の知らないコード (「日本語＋英語」の "ja+en" など) は自動判定にする
    /// (知らないコードをそのまま渡すと、whisper は言語のトークンの代わりに開始のトークンを使ってしまう)
    static func effectiveLanguage(_ code: String) -> String {
        guard !code.isEmpty, code != "auto", whisper_lang_id(code) >= 0 else { return "auto" }
        return code
    }

    /// whisper_full の戻り値を確かめる
    private func check(_ rc: Int32) throws {
        guard rc != 0 else { return }
        markBrokenIfStateFreed(rc)
        throw WhisperError.failed(rc)
    }

    /// -7 なら、whisper.cpp が状態を解放済み (whisper_full_with_state の KV キャッシュの作り直しに失敗)。
    /// 中止と重なっても必ず印を付ける (印が無いと、次の文字起こしが解放済みの状態を使ってしまう)
    private func markBrokenIfStateFreed(_ rc: Int32) {
        guard rc == -7 else { return }
        brokenLock.lock()
        broken = true
        brokenLock.unlock()
    }

    // MARK: - whisper_full の設定

    /// 文字起こしの設定を whisper_full_params にする (language は whisper の言語コードか "auto")
    private func makeParams(_ options: WhisperOptions, language: String, hint: String?, box: CallbackBox) -> FullParams {
        var params = whisper_full_default_params(options.useBeamSearch ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, options.threads))
        params.translate = false
        // 前の 30 秒区間で認識した文章を、次の区間の手がかりとして渡さない
        // (OpenAI 版の condition_on_previous_text=False に相当)。
        // whisper.cpp の no_context は「前回の whisper_full 呼び出し」の文脈を捨てるだけで、
        // 1 回の呼び出しの中での区間どうしの引き継ぎは n_max_text_ctx で決まる (既定 16384 = 引き継ぐ)。
        // 引き継ぐと、1 度の誤認識が後ろの区間すべてに連鎖する (講演の録音で 1,000 行を超える繰り返しが出た)。
        params.no_context = true
        params.n_max_text_ctx = 0
        // 言い直し (温度を上げた再デコード) は、ビームサーチでも 5 候補から選ぶ (whisper-cli と同じ)。
        // whisper_full_default_params(BEAM_SEARCH) は greedy.best_of を -1 のままにするため、
        // そのままだと言い直しが 1 候補だけの抽選になり、音楽や雑音の部分ででたらめな文が出やすい。
        // 繰り返しとみなす基準 (entropy_thold) は既定の 2.4 のまま。上げると普通の発話でも言い直しが増え、
        // 遅くなるうえに、まとめやすい「同じ文の繰り返し」が、まとめにくい「毎回違うでたらめな文」に変わる。
        if options.useBeamSearch {
            params.greedy.best_of = 5
        }
        params.single_segment = options.singleSegment
        params.no_timestamps = options.noTimestamps
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true   // ♪ や (音楽) などの非音声トークンを抑える (OpenAI 版の既定と同じ)
        params.detect_language = false

        let holder = FullParams(params, box: box)
        // C 文字列は whisper_full が終わるまで生かしておく (holder が持つ)
        holder.raw.language = holder.string(language.isEmpty ? "auto" : language)

        // 語彙のヒントは、前の区間の文章を混ぜずに毎区間へ付ける:
        // carry_initial_prompt でヒントを固定の前置きにし、n_max_text_ctx を「ヒント + 1」に絞って
        // 前の区間の文章が入る余地をなくす (whisper.cpp v1.9.2 の whisper_full_with_state の組み立て方による)。
        if let p = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            let hintTokens = tokenCount(p)
            if hintTokens > 0 {
                holder.raw.initial_prompt = holder.string(p)
                holder.raw.carry_initial_prompt = true
                holder.raw.n_max_text_ctx = Int32(hintTokens + 1)
            }
        }

        if let p = options.vadModelPath, FileManager.default.fileExists(atPath: p) {
            holder.raw.vad = true
            holder.raw.vad_model_path = holder.string(p)
            holder.raw.vad_params.speech_pad_ms = 100
        }

        let userData = Unmanaged.passUnretained(box).toOpaque()
        holder.raw.progress_callback = { _, _, progress, userData in
            guard let userData else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            box.onProgress(Double(progress) / 100.0)
        }
        holder.raw.progress_callback_user_data = userData

        holder.raw.new_segment_callback = { _, state, nNew, userData in
            guard let userData, let state else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            let total = whisper_full_n_segments_from_state(state)
            let first = max(0, total - nNew)
            guard first < total else { return }
            for i in first..<total {
                box.onSegment(WhisperContext.rawSegment(state, i, offset: box.offset, language: box.language))
            }
        }
        holder.raw.new_segment_callback_user_data = userData

        holder.raw.encoder_begin_callback = { _, _, userData in
            guard let userData else { return true }
            return !Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue().shouldCancel()
        }
        holder.raw.encoder_begin_callback_user_data = userData

        holder.raw.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue().shouldCancel()
        }
        holder.raw.abort_callback_user_data = userData
        return holder
    }

    /// whisper.cpp の時刻は 10 ミリ秒単位
    private static func seconds(_ t: Int64) -> TimeInterval { TimeInterval(t) / 100.0 }

    /// テキストのトークン数 (語彙のヒント用)。whisper_tokenize は入れ物が足りないと必要数を負の値で返す。
    private func tokenCount(_ text: String) -> Int {
        var tokens = [whisper_token](repeating: 0, count: 512)
        var n = whisper_tokenize(ctx, text, &tokens, Int32(tokens.count))
        if n < 0 {
            tokens = [whisper_token](repeating: 0, count: Int(-n))
            n = whisper_tokenize(ctx, text, &tokens, Int32(tokens.count))
        }
        return max(0, Int(n))
    }

    private func segmentFromContext(_ i: Int32, filter: Bool) -> TranscriptSegment? {
        guard let cText = whisper_full_get_segment_text(ctx, i) else { return nil }
        var text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
        if filter {
            text = RepetitionFilter.collapseInlineRepeats(text)
        }
        let noSpeech = whisper_full_get_segment_no_speech_prob(ctx, i)
        if text.isEmpty || (filter && HallucinationFilter.shouldDrop(text: text, noSpeechProbability: noSpeech)) {
            return nil
        }
        return TranscriptSegment(start: Self.seconds(whisper_full_get_segment_t0(ctx, i)),
                                 end: Self.seconds(whisper_full_get_segment_t1(ctx, i)),
                                 text: text)
    }

    /// 認識中に届いた区間 (フィルタをかける前)
    fileprivate static func rawSegment(_ state: OpaquePointer, _ i: Int32, offset: TimeInterval, language: String) -> DecodedSegment {
        let text = whisper_full_get_segment_text_from_state(state, i).map { String(cString: $0) } ?? ""
        return DecodedSegment(start: offset + seconds(whisper_full_get_segment_t0_from_state(state, i)),
                              end: offset + seconds(whisper_full_get_segment_t1_from_state(state, i)),
                              text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              noSpeechProbability: whisper_full_get_segment_no_speech_prob_from_state(state, i),
                              language: language)
    }

    /// 途中表示の区間にする (1 区間の中の繰り返しをまとめ、空の区間と定番の誤認識を除く)
    fileprivate static func filtered(_ raw: DecodedSegment, filter: Bool) -> TranscriptSegment? {
        var text = raw.text
        if filter {
            text = RepetitionFilter.collapseInlineRepeats(text)
        }
        if text.isEmpty || (filter && HallucinationFilter.shouldDrop(text: text, noSpeechProbability: raw.noSpeechProbability)) {
            return nil
        }
        return TranscriptSegment(start: raw.start, end: raw.end, text: text)
    }

    /// whisper.cpp のビルド情報 (Metal が有効か等)
    public static var systemInfo: String {
        guard let info = whisper_print_system_info() else { return "" }
        return String(cString: info)
    }

    // MARK: - 区切りごとに言語を判定して文字にする (「日本語＋英語」)

    private func runMixed(samples: [Float],
                          options: WhisperOptions,
                          onProgress: @escaping (Double) -> Void,
                          onSegment: @escaping (TranscriptSegment) -> Void,
                          shouldCancel: @escaping () -> Bool) throws -> WhisperOutput {
        guard !samples.isEmpty else { throw WhisperError.emptyAudio }
        let engine = WhisperEngine(context: self, options: options, shouldCancel: shouldCancel)
        do {
            let out = try MixedPipeline.run(samples: samples, engine: engine,
                                            options: MixedPipeline.Options(candidates: options.languageCandidates,
                                                                           glossary: options.initialPrompt,
                                                                           filterHallucinations: options.filterHallucinations),
                                            onProgress: onProgress, onSegment: onSegment, shouldCancel: shouldCancel)
            if shouldCancel() { throw WhisperError.cancelled }
            return WhisperOutput(segments: out.segments, language: out.language, report: out.report)
        } catch MixedPipelineError.cancelled {
            throw WhisperError.cancelled
        }
    }

    /// 音声全体の発話の区間 (今のアプリの VAD の設定と同じ: 既定 + 前後 100 ms)。VAD を使わない設定なら nil。
    /// VAD を使う設定で動かないときは、エラー (TranscriptionService が VAD なしでやり直す)
    func speechMap(_ samples: [Float], options: WhisperOptions) throws -> SpeechMap? {
        guard let path = options.vadModelPath, FileManager.default.fileExists(atPath: path) else { return nil }
        var cparams = whisper_vad_default_context_params()
        cparams.n_threads = Int32(max(1, options.threads))
        cparams.use_gpu = false
        guard let vad = whisper_vad_init_from_file_with_params(path, cparams) else { throw WhisperError.failed(-1) }
        defer { whisper_vad_free(vad) }
        var params = whisper_vad_default_params()
        params.speech_pad_ms = 100
        let found = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_segments_from_samples(vad, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard let found else { throw WhisperError.failed(-1) }
        defer { whisper_vad_free_segments(found) }
        var spans: [Range<Int>] = []
        let n = whisper_vad_segments_n_segments(found)
        if n > 0 {
            for i in 0..<n {
                // 時刻は 10 ミリ秒単位 (1 単位 = 160 サンプル)
                let a = max(0, Int((whisper_vad_segments_get_segment_t0(found, i) * 160).rounded()))
                let b = min(samples.count, Int((whisper_vad_segments_get_segment_t1(found, i) * 160).rounded()))
                if a < b { spans.append(a..<b) }
            }
        }
        var levels: [Float] = []
        let count = Int(whisper_vad_n_probs(vad))
        if count > 0, let probs = whisper_vad_probs(vad) {
            levels = Array(UnsafeBufferPointer(start: probs, count: count))
        }
        return SpeechMap(spans: spans, levels: levels, hop: 512, totalSamples: samples.count)
    }

    /// range の言語の確率 (candidates の順)。whisper の言語判定 (エンコーダーを 1 回通す)
    func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String], threads: Int) -> [Float]? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return nil }
        let n = Int32(max(1, threads))
        let rc = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return whisper_pcm_to_mel(ctx, base + range.lowerBound, Int32(range.count), n)
        }
        guard rc == 0 else { return nil }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(ctx, 0, n, &probs) >= 0 else { return nil }
        // 言語判定は [SOT] だけを読ませた次のトークンの確率を、状態の logits の 1 行目に残す。whisper.cpp v1.9.2 は、
        // 次の whisper_full の最初の 30 秒の「無音らしさ」(no_speech_prob) をその 1 行目から読むので、別の音声の値が混ざり、
        // 言い直しをせずに 30 秒ぶんの文を捨てることがある。読み込んだばかりの状態と同じく 0 に戻す
        // (判定に成功した直後の logits は、ちょうど語彙の数の 1 行)
        if let logits = whisper_get_logits(ctx) {
            logits.update(repeating: 0, count: Int(whisper_n_vocab(ctx)))
        }
        return candidates.map { code in
            let id = Int(whisper_lang_id(code))
            return id >= 0 && id < probs.count ? probs[id] : 0
        }
    }

    /// range を language で文字にする (今の「日本語」と同じ設定。VAD は range の中で whisper が行う)。時刻は音声全体の秒
    func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                options: WhisperOptions, onProgress: @escaping (Double) -> Void,
                onSegment: @escaping (DecodedSegment) -> Void,
                shouldCancel: @escaping () -> Bool) throws -> [DecodedSegment] {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return [] }
        let offset = TimeInterval(range.lowerBound) / 16_000
        let box = CallbackBox(onProgress: onProgress, onSegment: onSegment, shouldCancel: shouldCancel,
                              offset: offset, language: language)
        var runOptions = options
        if !useVAD { runOptions.vadModelPath = nil }
        let params = makeParams(runOptions, language: Self.effectiveLanguage(language), hint: hint, box: box)
        let rc: Int32 = withExtendedLifetime(params) {
            samples.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return whisper_full(ctx, params.raw, base + range.lowerBound, Int32(range.count))
            }
        }
        markBrokenIfStateFreed(rc)
        if shouldCancel() { throw WhisperError.cancelled }
        try check(rc)

        let eot = whisper_token_eot(ctx)
        var out: [DecodedSegment] = []
        let n = whisper_full_n_segments(ctx)
        if n > 0 {
            for i in 0..<n {
                let text = whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? ""
                var sum = 0.0
                var tokens = 0
                let count = whisper_full_n_tokens(ctx, i)
                if count > 0 {
                    for j in 0..<count {
                        let token = whisper_full_get_token_data(ctx, i, j)
                        guard token.id < eot else { continue }  // 特殊なトークン・時刻のトークン
                        sum += Double(token.plog)
                        tokens += 1
                    }
                }
                out.append(DecodedSegment(start: offset + Self.seconds(whisper_full_get_segment_t0(ctx, i)),
                                          end: offset + Self.seconds(whisper_full_get_segment_t1(ctx, i)),
                                          text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          noSpeechProbability: whisper_full_get_segment_no_speech_prob(ctx, i),
                                          tokenCount: tokens, meanLogProb: tokens > 0 ? sum / Double(tokens) : nil,
                                          language: language))
            }
        }
        return out
    }

    /// ライブプレビューの言語を決める (`lock` を持って呼ぶ)
    private func previewLanguage(_ samples: [Float], candidates: [String], threads: Int) -> String {
        defer { preview.calls += 1 }
        if preview.language.isEmpty || preview.recheck || preview.calls % 3 == 0 || !candidates.contains(preview.language) {
            if let probs = detectLanguage(samples, range: 0..<samples.count, candidates: candidates, threads: threads),
               let guess = LanguageGuess(probabilities: probs, candidates: candidates) {
                preview.language = guess.language
            } else if !candidates.contains(preview.language) {
                preview.language = candidates[0]
            }
            preview.recheck = false
        }
        return preview.language
    }
}

/// ライブプレビューで使っている言語
private struct PreviewLanguage {
    var language = ""
    var calls = 0
    /// 文字が言語と合わなかった: 次は判定し直す
    var recheck = true
}

/// whisper_full_params と、それが指す C 文字列・コールバックの入れ物 (whisper_full が終わるまで生かしておく)
private final class FullParams {
    var raw: whisper_full_params
    let box: CallbackBox
    private var strings: [UnsafeMutablePointer<CChar>] = []

    init(_ raw: whisper_full_params, box: CallbackBox) {
        self.raw = raw
        self.box = box
    }

    func string(_ s: String) -> UnsafePointer<CChar>? {
        guard let p = strdup(s) else { return nil }
        strings.append(p)
        return UnsafePointer(p)
    }

    deinit {
        for p in strings { free(p) }
    }
}

/// C のコールバックへ user_data として渡す入れ物
private final class CallbackBox {
    /// この whisper_full の中の進み具合 (0...1)
    let onProgress: (Double) -> Void
    /// 認識中に届いた区間 (時刻は offset を足したもの)
    let onSegment: (DecodedSegment) -> Void
    let shouldCancel: () -> Bool
    let offset: TimeInterval
    let language: String

    init(onProgress: @escaping (Double) -> Void,
         onSegment: @escaping (DecodedSegment) -> Void,
         shouldCancel: @escaping () -> Bool,
         offset: TimeInterval = 0,
         language: String = "") {
        self.onProgress = onProgress
        self.onSegment = onSegment
        self.shouldCancel = shouldCancel
        self.offset = offset
        self.language = language
    }
}
