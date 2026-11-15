import Foundation

/// 文字起こしの途中で届く区間を貯めておき、画面 (ジョブの文字起こし) へはまとめて渡すための入れ物。
///
/// 区間は認識のスレッドから 1 つずつ届き、「日本語＋英語」では長い範囲を文字にし終えたときに数百がいっぺんに届く。
/// 1 つずつ画面の文字起こしに足すと、そのたびに一覧 (数千行) を作り直すので、メインスレッドが何秒も埋まる。
/// ここでは届いた区間を順に貯め、最初の 1 つが届いたときに `wake` で知らせる。受け取る側は少し待って
/// (`interval(forRows:)`: 0.25〜1 秒。ジョブの行が多いほど長い) `take()` で貯まった分をまとめて受け取り、
/// 1 回の代入で反映する (行が少ないうちは 1 秒に 4 回まで、数千行では 1 秒に 1 回まで。届いた数によらない)。
///
/// - 順番は届いた順のまま。
/// - `restart()` (認識を始めからやり直す) は、貯まっている分を捨て、次に渡す分に「先にここまでの区間を消す」印を付ける。
/// - `close()` で閉じると、貯まっている分を返し (中止・失敗のときは反映し、終わったときは結果で置き換えるので捨てる)、
///   そのあとに届く区間は受け取らない。
///
/// どのメソッドも、どのスレッドから呼んでもよい (中は 1 つのロックで守る)。
public final class LiveSegmentBuffer: @unchecked Sendable {
    /// まとめて渡す分
    public struct Batch: Equatable, Sendable {
        /// 先に、ここまでに画面へ出した区間をすべて消す (認識を始めからやり直した)
        public var reset: Bool
        /// 足す区間 (届いた順)
        public var segments: [TranscriptSegment]

        public init(reset: Bool = false, segments: [TranscriptSegment]) {
            self.reset = reset
            self.segments = segments
        }

        /// 画面の区間に反映する
        public func apply(to target: inout [TranscriptSegment]) {
            if reset {
                target = segments
            } else {
                target.append(contentsOf: segments)
            }
        }
    }

    /// 受け取る側が `wake` から `take()` までに待つ時間 (秒)。rows は、そのジョブの画面にすでに出ている区間の数。
    ///
    /// 一覧に行を足すたびに、一覧の行の比べ直しと表の更新が要り、行が多いほど重い。数は測ったもの: GitHub の macOS の
    /// 実行機 (3 コア、仮想の GPU) で 3000 行のとき、まとめて足す 1 回が 0.1〜0.26 秒ほど (中央値) かかり、0.25 秒ごとに
    /// 足すと、文字起こしのあいだメインスレッドが 26〜49% 埋まった。そこで、行が多いほど長く待ち、足す回数を減らす:
    /// 500 行未満は 0.25 秒 (新しいジョブの始めの行は、すぐ出る)、2000 行までは 0.5 秒、それより多ければ 1 秒
    public static func interval(forRows rows: Int) -> TimeInterval {
        if rows < 500 { return 0.25 }
        if rows <= 2000 { return 0.5 }
        return maxInterval
    }

    /// interval(forRows:) のいちばん長い値 (秒)
    public static let maxInterval: TimeInterval = 1.0

    private let lock = NSLock()
    private var pending: [TranscriptSegment] = []
    private var resetPending = false
    /// `wake` で知らせたが、まだ `take()` されていない
    private var woken = false
    private var closed = false
    private let wake: @Sendable (LiveSegmentBuffer) -> Void

    /// - Parameter wake: 貯まっていなかったところに区間 (またはやり直し) が届いたときに 1 回だけ呼ばれる
    ///   (届けたスレッドで、ロックの外で)。受け取る側は、少し待ってから `take()` を呼ぶ
    public init(wake: @escaping @Sendable (LiveSegmentBuffer) -> Void) {
        self.wake = wake
    }

    /// 区間が 1 つ届いた
    public func append(_ segment: TranscriptSegment) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pending.append(segment)
        let first = !woken
        woken = true
        lock.unlock()
        if first { wake(self) }
    }

    /// 認識を始めからやり直す: ここまでに貯めた分を捨て、画面に出した区間も次に渡すときに消す
    public func restart() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pending.removeAll()
        resetPending = true
        let first = !woken
        woken = true
        lock.unlock()
        if first { wake(self) }
    }

    /// 貯まっている分を受け取る (何も無ければ nil)。このあと届く区間では、また `wake` が呼ばれる
    public func take() -> Batch? {
        lock.lock()
        defer { lock.unlock() }
        woken = false
        return drain()
    }

    /// 閉じる: 貯まっている分を返し (無ければ nil)、このあと届く区間とやり直しは受け取らない
    @discardableResult
    public func close() -> Batch? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        woken = false
        return drain()
    }

    /// 貯まっている区間の数 (確かめる用)
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// ロックを持って呼ぶ
    private func drain() -> Batch? {
        guard resetPending || !pending.isEmpty else { return nil }
        let batch = Batch(reset: resetPending, segments: pending)
        pending = []
        resetPending = false
        return batch
    }
}
