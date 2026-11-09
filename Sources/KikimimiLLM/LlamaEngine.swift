import Foundation
import KikimimiCore
// whisper.framework と llama.framework は、版の違う ggml.h をそれぞれ持っている。
// 両方の C モジュールが 1 つのコンパイルに入ると型の定義がぶつかるので、llama はこのモジュールの中だけで使う
// (internal import + library evolution。アプリ本体からは llama の型が見えない)。
internal import llama

/// llama.cpp で GGUF の LLM を動かすときの設定
public struct LlamaOptions: Sendable {
    /// 1 回に扱える長さ (プロンプト + 出力のトークン数)。モデルが学習した長さを超えない
    public var contextLength: Int
    /// プロンプトを一度に読む量 (トークン数)
    public var batchSize: Int
    /// GPU (Metal) に載せる層の数。-1 ですべて、0 で CPU だけ
    public var gpuLayers: Int
    public var threads: Int

    public init(contextLength: Int = 8192, batchSize: Int = 512, gpuLayers: Int = -1,
                threads: Int = LlamaOptions.recommendedThreads) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.gpuLayers = gpuLayers
        self.threads = threads
    }

    public static var recommendedThreads: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
}

/// 読み込んだ GGUF の LLM。読み込みに数秒かかるので、作ったら使い回す。
///
/// 生成はブロッキングで、同時に 1 本だけ (内部のロックで直列化する)。バックグラウンドのスレッドから呼ぶこと。
/// 出力は貪欲法 (毎回いちばん確からしいトークン) で決めるので、同じ入力には同じ答えを返す。
public final class LlamaEngine: TextGenerating, @unchecked Sendable {
    public let modelPath: String
    public let contextLength: Int
    /// 例: "qwen35 4B Q4_K - Medium"
    public let modelDescription: String

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let vocabSize: Int
    private let batchSize: Int
    private var batch: llama_batch
    private let format: ChatFormat
    /// 利用者の文に紛れ込んだ制御用の文字列 (<|im_end|> など) を取り除くための一覧
    private let controlTexts: [String]
    /// 全語彙で文法を確かめるときの入れ物 (使い回す)
    private var allCandidates: [llama_token_data] = []
    private let lock = NSLock()

    /// 候補として見る上位のトークン数
    private static let topK = 40
    /// 同じトークンの繰り返しを抑える強さと、見る範囲
    private static let repeatPenalty: Float = 1.05
    private static let repeatWindow = 64

    private enum ChatFormat {
        /// Qwen などの ChatML。思考 (<think>) を持つモデルは、空の思考を先に置いて答えだけを出させる
        case chatML(skipThinking: Bool)
        /// llama.cpp が知っている、その他のテンプレート (Gemma など)
        case builtin(String)
    }

    /// - Parameter shouldCancel: 読み込みの途中でも true を返せば止める (`LLMError.cancelled`)
    public init(modelPath: String, options: LlamaOptions = LlamaOptions(),
                shouldCancel: @escaping () -> Bool = { false }) throws {
        LlamaEngine.setUp()
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(options.gpuLayers)
        let box = LoadBox(shouldCancel: shouldCancel)
        mparams.progress_callback = { _, userData in
            guard let userData else { return true }
            return !Unmanaged<LoadBox>.fromOpaque(userData).takeUnretainedValue().shouldCancel()
        }
        mparams.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        let loaded: OpaquePointer? = withExtendedLifetime(box) {
            llama_model_load_from_file(modelPath, mparams)
        }
        if shouldCancel() {
            if let loaded { llama_model_free(loaded) }
            throw LLMError.cancelled
        }
        guard let model = loaded else { throw LLMError.modelLoadFailed(modelPath) }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw LLMError.modelLoadFailed(modelPath)
        }

        var cparams = llama_context_default_params()
        let trained = Int(llama_model_n_ctx_train(model))
        let wanted = max(512, options.contextLength)
        cparams.n_ctx = UInt32(trained > 0 ? min(wanted, trained) : wanted)
        cparams.n_batch = UInt32(max(32, options.batchSize))
        cparams.n_ubatch = UInt32(max(32, min(options.batchSize, 512)))
        cparams.n_seq_max = 1
        cparams.n_threads = Int32(max(1, options.threads))
        cparams.n_threads_batch = Int32(max(1, options.threads))
        cparams.no_perf = true
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LLMError.contextFailed
        }

        self.modelPath = modelPath
        self.model = model
        self.vocab = vocab
        self.context = context
        self.contextLength = Int(llama_n_ctx(context))
        self.batchSize = Int(cparams.n_batch)
        self.vocabSize = Int(llama_vocab_n_tokens(vocab))
        self.batch = llama_batch_init(Int32(cparams.n_batch), 0, 1)

        var desc = [CChar](repeating: 0, count: 256)
        let n = llama_model_desc(model, &desc, desc.count)
        self.modelDescription = n > 0 ? String(cString: desc) : (modelPath as NSString).lastPathComponent

        var controls: [String] = []
        for t in 0..<Int32(vocabSize) {
            let attr = llama_vocab_get_attr(vocab, t).rawValue
            guard attr & LLAMA_TOKEN_ATTR_CONTROL.rawValue != 0, let cText = llama_vocab_get_text(vocab, t) else { continue }
            let text = String(cString: cText)
            if text.count >= 3 { controls.append(text) }
        }
        self.controlTexts = controls.sorted { $0.count > $1.count }

        let template = llama_model_chat_template(model, nil).map { String(cString: $0) }
        if let template, !template.contains("<|im_start|>"),
           LlamaEngine.applyTemplate(template, [("system", "s"), ("user", "u")]) != nil {
            self.format = .builtin(template)
        } else {
            let thinking = template.map { $0.contains("<think>") || $0.contains("enable_thinking") } ?? false
            self.format = .chatML(skipThinking: thinking)
        }
    }

    /// 会話の組み立て方 (診断用)
    public var chatFormatDescription: String {
        switch format {
        case .chatML(let skipThinking): return skipThinking ? "ChatML (思考を省く)" : "ChatML"
        case .builtin: return "モデル付属のテンプレート"
        }
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    /// llama.cpp のビルド情報 (Metal が有効か等)
    public static var systemInfo: String {
        setUp()
        guard let info = llama_print_system_info() else { return "" }
        return String(cString: info)
    }

    // MARK: TextGenerating

    public func tokenCount(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tokenize(text, addSpecial: false, parseSpecial: false).count
    }

    public func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if shouldCancel() { throw LLMError.cancelled }

        let text = formatted(prompt)
        let tokens = tokenize(text, addSpecial: shouldAddSpecial(text), parseSpecial: true)
        guard !tokens.isEmpty else { return "" }
        let limit = contextLength - 8
        guard tokens.count < limit else { throw LLMError.promptTooLong(tokens: tokens.count, limit: limit) }
        let maxNew = max(0, min(prompt.maxTokens, contextLength - tokens.count - 1))

        var grammar: UnsafeMutablePointer<llama_sampler>? = nil
        if let g = prompt.grammar {
            guard let sampler = llama_sampler_init_grammar(vocab, g, "root") else { throw LLMError.invalidGrammar }
            grammar = sampler
        }
        defer { if let grammar { llama_sampler_free(grammar) } }

        // 毎回まっさらな状態から読む (前の依頼の内容を引きずらない)
        llama_memory_clear(llama_get_memory(context), true)

        var position = 0
        while position < tokens.count {
            if shouldCancel() { throw LLMError.cancelled }
            let n = min(batchSize, tokens.count - position)
            let isLast = position + n == tokens.count
            fillBatch(tokens[position..<(position + n)], startingAt: position, wantLastLogits: isLast)
            let rc = llama_decode(context, batch)
            guard rc == 0 else { throw LLMError.decodeFailed(rc) }
            position += n
        }

        var output: [UInt8] = []
        var lineStart = 0
        var recent: [llama_token] = []
        for step in 0..<maxNew {
            if shouldCancel() { throw LLMError.cancelled }
            guard let token = pick(grammar: grammar, recent: recent) else { break }
            if llama_vocab_is_eog(vocab, token) { break }
            if let grammar { llama_sampler_accept(grammar, token) }
            output += piece(token)
            if let newline = output.lastIndex(of: 0x0A), newline >= lineStart { lineStart = newline + 1 }
            // 1 行が長すぎる: 同じ語の繰り返しなどの暴走。ここで打ち切る
            if let limit = prompt.maxLineBytes, output.count - lineStart > limit { break }
            recent.append(token)
            if recent.count > Self.repeatWindow { recent.removeFirst() }
            guard step + 1 < maxNew else { break }
            fillBatch([token][...], startingAt: position, wantLastLogits: true)
            let rc = llama_decode(context, batch)
            guard rc == 0 else { throw LLMError.decodeFailed(rc) }
            position += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - 実装

    private func fillBatch(_ tokens: ArraySlice<llama_token>, startingAt start: Int, wantLastLogits: Bool) {
        batch.n_tokens = Int32(tokens.count)
        for (k, token) in tokens.enumerated() {
            batch.token[k] = token
            batch.pos[k] = llama_pos(start + k)
            batch.n_seq_id[k] = 1
            batch.seq_id[k]![0] = 0
            batch.logits[k] = (wantLastLogits && k == tokens.count - 1) ? 1 : 0
        }
    }

    /// 次のトークンを選ぶ。文法があれば、文法に合うものの中でいちばん確からしいもの。
    /// 上位の候補だけで文法を確かめ、どれも合わないときだけ全語彙を確かめる (毎回全語彙を確かめると遅い)。
    private func pick(grammar: UnsafeMutablePointer<llama_sampler>?, recent: [llama_token]) -> llama_token? {
        guard let logits = llama_get_logits_ith(context, -1) else { return nil }
        let recentSet = Set(recent)
        func adjusted(_ id: llama_token, _ value: Float) -> Float {
            guard recentSet.contains(id) else { return value }
            return value > 0 ? value / Self.repeatPenalty : value * Self.repeatPenalty
        }

        var top: [(id: llama_token, logit: Float)] = []
        top.reserveCapacity(Self.topK)
        var minIndex = 0
        for i in 0..<vocabSize {
            let v = logits[i]
            guard v.isFinite else { continue }
            if top.count < Self.topK {
                top.append((llama_token(i), v))
                if top.count == Self.topK { minIndex = top.indices.min { top[$0].logit < top[$1].logit }! }
            } else if v > top[minIndex].logit {
                top[minIndex] = (llama_token(i), v)
                minIndex = top.indices.min { top[$0].logit < top[$1].logit }!
            }
        }
        for k in top.indices { top[k].logit = adjusted(top[k].id, top[k].logit) }
        top.sort { $0.logit > $1.logit }

        guard let grammar else { return top.first?.id }
        for candidate in top where accepts(grammar, candidate.id) {
            return candidate.id
        }

        if allCandidates.count != vocabSize {
            allCandidates = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: vocabSize)
        }
        for i in 0..<vocabSize {
            allCandidates[i] = llama_token_data(id: llama_token(i), logit: adjusted(llama_token(i), logits[i]), p: 0)
        }
        return allCandidates.withUnsafeMutableBufferPointer { buffer -> llama_token? in
            var array = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &array)
            guard let data = array.data else { return nil }
            var best: llama_token? = nil
            var bestValue = -Float.infinity
            for k in 0..<array.size where data[k].logit.isFinite && data[k].logit > bestValue {
                best = data[k].id
                bestValue = data[k].logit
            }
            return best
        }
    }

    /// 文法がこのトークンを受け付けるか
    private func accepts(_ grammar: UnsafeMutablePointer<llama_sampler>, _ token: llama_token) -> Bool {
        var data = llama_token_data(id: token, logit: 0, p: 0)
        return withUnsafeMutablePointer(to: &data) { pointer in
            var array = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &array)
            return pointer.pointee.logit.isFinite
        }
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    private func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token] {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return [] }
        var tokens = [llama_token](repeating: 0, count: byteCount + 8)
        var n = llama_tokenize(vocab, text, Int32(byteCount), &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        if n < 0 {
            guard n != Int32.min else { return [] }
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(byteCount), &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        }
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }

    /// テンプレートが先頭の BOS を自分で書いていれば、二重に付けない
    private func shouldAddSpecial(_ text: String) -> Bool {
        guard llama_vocab_get_add_bos(vocab) else { return true }
        let bos = llama_vocab_bos(vocab)
        guard bos >= 0, let cText = llama_vocab_get_text(vocab, bos) else { return true }
        return !text.hasPrefix(String(cString: cText))
    }

    private func sanitize(_ text: String) -> String {
        var s = text
        for control in controlTexts where s.contains(control) {
            s = s.replacingOccurrences(of: control, with: "")
        }
        return s
    }

    private func formatted(_ prompt: LLMPrompt) -> String {
        let system = sanitize(prompt.system)
        let user = sanitize(prompt.user)
        switch format {
        case .chatML(let skipThinking):
            var s = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
            if skipThinking { s += "<think>\n\n</think>\n\n" }
            return s
        case .builtin(let template):
            return LlamaEngine.applyTemplate(template, [("system", system), ("user", user)])
                ?? "\(system)\n\n\(user)\n\n"
        }
    }

    private static func applyTemplate(_ template: String, _ messages: [(role: String, content: String)]) -> String? {
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        var chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }
        let total = messages.reduce(0) { $0 + $1.content.utf8.count + $1.role.utf8.count }
        var buffer = [CChar](repeating: 0, count: max(1024, total * 2 + 256))
        var n = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(buffer.count))
        if n > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard n >= 0, n <= Int32(buffer.count) else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static let setUpOnce: Void = {
        // llama.cpp は読み込みの様子などを大量に出すので、エラーだけを残す (初期化の出力も抑えるため先に設定する)
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            fputs(String(cString: text), stderr)
        }, nil)
        #if os(Linux)
        // 検証用の Linux 版 llama.cpp は CPU の処理部を別ファイルにしている (macOS 版は中に組み込み済み)
        if let dir = ProcessInfo.processInfo.environment["GGML_BACKEND_DIR"], !dir.isEmpty {
            ggml_backend_load_all_from_path(dir)
        } else {
            ggml_backend_load_all()
        }
        #endif
        llama_backend_init()
    }()

    private static func setUp() {
        _ = setUpOnce
    }
}

/// 読み込み中の progress_callback へ渡す入れ物
private final class LoadBox {
    let shouldCancel: () -> Bool
    init(shouldCancel: @escaping () -> Bool) {
        self.shouldCancel = shouldCancel
    }
}
