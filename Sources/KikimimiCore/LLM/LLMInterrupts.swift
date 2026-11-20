import Foundation

/// 監査・翻訳の最中に、先に通したい短い依頼 (チャット) の待ち行列。
///
/// 依頼は、ここに入れるのと同時に、LLM の列 (キュー) にも「まだここに在れば走らせる」仕事として積む。
/// 監査・翻訳が動いている時は、その `generate` の手前の継ぎ目 (`YieldingGenerator`) が
/// `runWaiting` で先に取り出して、同じエンジンで走らせる。何も動いていない時は、キューの順番が来た所で `take` で取り出す。
/// どちらが取っても、取り出せるのは 1 度だけ (取り出した側だけが走らせる)。
///
/// Engine は、依頼に渡すエンジンの型 (アプリでは `LlamaEngine`、試験では偽物)。
public final class LLMInterruptQueue<Engine>: @unchecked Sendable {
    /// 待っている依頼 1 つ
    public final class Request: @unchecked Sendable {
        public let id: Int
        /// この依頼が使うモデルのファイル (差分はいつも「なし」)
        public let modelPath: String
        /// 入れた時刻 (待った秒を測る)
        public let queuedAt: Date
        private let work: (Engine) -> Void
        private let failure: (Error) -> Void

        fileprivate init(id: Int, modelPath: String, work: @escaping (Engine) -> Void, failure: @escaping (Error) -> Void) {
            self.id = id
            self.modelPath = modelPath
            self.queuedAt = Date()
            self.work = work
            self.failure = failure
        }

        /// 依頼の body を、このエンジンで走らせる。body が投げたエラーは、依頼の側 (completion) にだけ返り、ここからは投げない
        public func run(_ engine: Engine) {
            work(engine)
        }

        /// 走らせる前に失敗した (エンジンを読み込めなかった時など)。エラーを依頼の側に返す
        public func fail(_ error: Error) {
            failure(error)
        }
    }

    private let lock = NSLock()
    /// 入れた順 (先着順)。`lock` で保護する
    private var waiting: [Request] = []
    /// `lock` で保護する
    private var nextID = 0
    /// 継ぎ目 (`runWaiting`) が取り出して走らせた数。`lock` で保護する
    private var yieldedCount = 0

    public init() {}

    /// 依頼を入れる。返す番号は、キューの順番が来た時に `take` で取り出すのに使う。
    /// completion は、body の結果 (またはエラー) で 1 度だけ呼ばれる
    @discardableResult
    public func add<T>(modelPath: String, body: @escaping (Engine) throws -> T,
                       completion: @escaping (Result<T, Error>) -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        let request = Request(id: nextID, modelPath: modelPath,
                              work: { engine in completion(Result { try body(engine) }) },
                              failure: { error in completion(.failure(error)) })
        waiting.append(request)
        return request.id
    }

    /// キューの順番が来た時: まだ待っていれば取り出す (継ぎ目が先に取って走らせていれば nil)
    public func take(id: Int) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return waiting.remove(at: i)
    }

    /// 今のエンジンに合う依頼のうち、いちばん先に入れた物を取り出す。
    /// 合う = モデルのファイルが同じで、今のエンジンに差分 (LoRA) を重ねていない。合わない依頼は残す
    public func takeFirst(matching modelPath: String, adapterLoaded: Bool) -> Request? {
        guard !adapterLoaded else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let i = waiting.firstIndex(where: { $0.modelPath == modelPath }) else { return nil }
        return waiting.remove(at: i)
    }

    /// 継ぎ目: 今のエンジンに合う依頼を、入れた順に全部、その場で走らせる (走らせている間に入った物も)。
    /// 監査・翻訳の body の中から、LLM のスレッドの上で呼ぶ。走らせた数を返す
    @discardableResult
    public func runWaiting(modelPath: String, adapterLoaded: Bool, engine: Engine) -> Int {
        var count = 0
        while let request = takeFirst(matching: modelPath, adapterLoaded: adapterLoaded) {
            request.run(engine)
            count += 1
        }
        if count > 0 {
            lock.lock()
            yieldedCount += count
            lock.unlock()
        }
        return count
    }

    /// 待っている依頼の数
    public var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }

    /// 継ぎ目が走らせた依頼の数 (これまでの合計)
    public var yielded: Int {
        lock.lock()
        defer { lock.unlock() }
        return yieldedCount
    }
}

/// `generate` の手前で、待っている割り込み (チャット) を先に通す包み。
/// 答えそのものは、包んだエンジンにそのまま任せる (指示文・回数・順は変えない)。
/// 監査・翻訳の body には、これを渡す。割り込みの body には、包んでいない物を渡す (割り込みの中から、また割り込みを通さない)
public final class YieldingGenerator: TextGenerating {
    /// 包んでいるエンジン
    public let base: any TextGenerating
    /// 包んでいるエンジンに重ねた差分 (LoRA) のファイル (無ければ nil)。名前の表示に使う
    public let adapterPath: String?
    private let yield: () -> Void

    /// yield は、`generate` を呼ぶたびに、その手前で 1 度呼ぶ
    public init(_ base: any TextGenerating, adapterPath: String? = nil, yield: @escaping () -> Void) {
        self.base = base
        self.adapterPath = adapterPath
        self.yield = yield
    }

    public var contextLength: Int { base.contextLength }

    public func tokenCount(_ text: String) -> Int {
        base.tokenCount(text)
    }

    public func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        yield()
        return try base.generate(prompt, shouldCancel: shouldCancel)
    }

    public func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool, onText: ((String) -> Void)?) throws -> String {
        yield()
        return try base.generate(prompt, shouldCancel: shouldCancel, onText: onText)
    }
}
