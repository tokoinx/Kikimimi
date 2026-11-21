// 画面の重さの確認の、時間を測る道具: メインスレッドが空くまで待つ所、時刻と秒、
// 操作の記録 (ActionLog) と、メインスレッドの待ちの見張り (LatencyProbe)。

import CoreFoundation
import Foundation

extension UILoadSelfTest {
    /// 操作のあと、メインスレッドがまた空くまで待ち、started (操作の直前の uptime のナノ秒) からの秒を返す。
    ///
    /// 1. DispatchQueue.main.async で積んだ仕事が動くまで待つ (操作のあいだに積まれた、メインのキューの仕事が先に済む)。
    /// 2. そのあと、メインの run loop が眠る直前 (beforeWaiting) まで待つ。run loop は、メインのキューや入力に
    ///    すぐ行う仕事が残っていると眠らないので、ここまで来れば手が空いている。SwiftUI の描き直しと Core Animation の
    ///    反映も、眠る直前の観測者で行われるので、こちらの観測者は順番を最後 (CFIndex.max) にして、それらのあとで時刻を取る。
    /// 1 だけでは、描き直しの前に動いてしまうことがあり、2 だけでは、操作で積まれたメインのキューの仕事を待たないことがある。
    ///
    /// 1 と 2 を 1 回りとして、何回か繰り返す。描き直しの中で積まれた仕事 (一覧の scrollTo は、描き直しの中から
    /// Task で次の回に回している) は、こちらの観測者と同じ眠る直前に積まれ、時刻を取ったあとで動くので、1 回りでは測れない。
    /// 前の回りの眠る直前から、この回りの眠る直前までが短ければ (idleGap より短い)、そのあいだに新しい仕事は無かった:
    /// そこで終わる (少なくとも 2 回り、多くても maxRounds 回り)。終わりの時刻は、最後の回りの眠る直前。
    /// 測り始めから 2 秒たっても終わらなければ、そこで打ち切る (その時間を記録するので、遅いものとして出る)
    @MainActor
    static func untilIdle(since started: UInt64) async -> Double {
        let giveUp = now() + 2_000_000_000
        var previous: UInt64?
        var ended = now()
        for round in 1...maxRounds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            let left = seconds(from: now(), to: giveUp)
            guard left > 0, let at = await nextBeforeWaiting(timeout: left) else {
                // 打ち切り
                ended = now()
                break
            }
            ended = at
            if round >= 2, let previous, seconds(from: previous, to: at) < idleGap { break }
            previous = at
        }
        return seconds(from: started, to: ended)
    }

    /// untilIdle の回りの数の上限
    private static let maxRounds = 10
    /// untilIdle で、前の回りの眠る直前から、この回りの眠る直前までがこれより短ければ、新しい仕事は無かったとみなす (秒)。
    /// 仕事の無い回りは、メインのキューの小さな仕事 2 つ分 (数十マイクロ秒) で済む
    private static let idleGap = 0.003

    /// 次に、メインの run loop が眠る直前 (beforeWaiting) になった時刻 (uptime のナノ秒)。timeout 秒たっても来なければ nil。
    /// 観測者 (CF の型で Sendable ではない) は ResumeOnce の中だけに置き、ほかのクロージャには ResumeOnce だけを渡す
    @MainActor
    private static func nextBeforeWaiting(timeout: Double) async -> UInt64? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
            let once = ResumeOnce(continuation)
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                once.resume(DispatchTime.now().uptimeNanoseconds)
            }
            once.hold(observer)
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    private static var commonModes: CFRunLoopMode {
        #if os(macOS)
        return CFRunLoopMode.commonModes
        #else
        return kCFRunLoopCommonModes
        #endif
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }

    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    static func ms(_ seconds: Double) -> Double { seconds * 1000 }

    /// 小さい順に並べた値の p (0...1) の位置の値
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}

/// 起こした操作の記録 (どのスレッドからでも書ける)。長い待ちの前に、最後に何をしたかを出すのに使う
final class ActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(time: UInt64, name: String)] = []
    /// 操作の数などをまとめた 1 行 (メインスレッドだけで使う)
    var summaryLine: String?

    func note(_ name: String, at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        entries.append((time, name))
        lock.unlock()
    }

    /// time より前の、最後の操作
    func last(before time: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.time <= time }.max { $0.time < $1.time }?.name
    }
}

/// 続きを 1 回だけ再開する (眠る直前の知らせと、打ち切りの、先に来たほう)。
/// 眠る直前の観測者も持ち、再開するときに無効にする (CF の型は Sendable ではないので、ほかのクロージャには持たせない。
/// 観測者はメインの run loop の上でだけ動き、打ち切りもメインのキューから呼ぶ)
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt64?, Never>?
    private var observer: CFRunLoopObserver?

    init(_ continuation: CheckedContinuation<UInt64?, Never>) {
        self.continuation = continuation
    }

    /// 観測者を預かる。もう再開していれば、すぐに無効にする
    func hold(_ observer: CFRunLoopObserver?) {
        lock.lock()
        let done = continuation == nil
        if !done { self.observer = observer }
        lock.unlock()
        if done, let observer, CFRunLoopObserverIsValid(observer) { CFRunLoopObserverInvalidate(observer) }
    }

    func resume(_ value: UInt64?) {
        lock.lock()
        let c = continuation
        continuation = nil
        let o = observer
        observer = nil
        lock.unlock()
        if let o, CFRunLoopObserverIsValid(o) { CFRunLoopObserverInvalidate(o) }
        c?.resume(returning: value)
    }
}

/// メインスレッドの待ちを、別のスレッドから測る見張り: 50 ms ごとに (前の合図が戻るのを待たずに) メインのキューへ
/// 小さな仕事を積み、始まるまでの時間を、積んだときの段階の名前とともに記録する
final class LatencyProbe: @unchecked Sendable {
    struct Sample {
        var phase: String
        /// 積んだ時刻と、始まった時刻 (uptime のナノ秒)
        var posted: UInt64
        var ran: UInt64
        var wait: Double { UILoadSelfTest.seconds(from: posted, to: ran) }
    }

    /// 積む間隔 (秒)
    static let interval = 0.05

    private let lock = NSLock()
    private var recorded: [Sample] = []
    private var sentCount: [String: Int] = [:]
    private var phase = "between phases"
    private var running = false

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            let origin = DispatchTime.now().uptimeNanoseconds
            var n: UInt64 = 0
            while let phase = self.nextPhase() {
                let posted = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    self.record(Sample(phase: phase, posted: posted, ran: DispatchTime.now().uptimeNanoseconds))
                }
                // 決まった刻みで積む (遅れても、前の合図を待たない)
                n += 1
                let next = origin + n * UInt64(LatencyProbe.interval * 1_000_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                if next > now { Thread.sleep(forTimeInterval: Double(next - now) / 1_000_000_000) }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func setPhase(_ name: String) {
        lock.lock()
        phase = name
        lock.unlock()
    }

    func samples() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sent(in phase: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sentCount[phase] ?? 0
    }

    /// 待っていた区間 (積んでから始まるまで) を重ねた長さ: メインスレッドが合図に応えられなかった時間
    static func unavailable(_ samples: [Sample]) -> Double {
        var total: UInt64 = 0
        var end: UInt64 = 0
        for s in samples.sorted(by: { $0.posted < $1.posted }) {
            let from = max(s.posted, end)
            if s.ran > from { total += s.ran - from }
            end = max(end, s.ran)
        }
        return Double(total) / 1_000_000_000
    }

    /// 動いているなら、いまの段階の名前を返し、積んだ数を数える。止めたら nil
    private func nextPhase() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return nil }
        sentCount[phase, default: 0] += 1
        return phase
    }

    private func record(_ sample: Sample) {
        lock.lock()
        recorded.append(sample)
        lock.unlock()
    }
}
