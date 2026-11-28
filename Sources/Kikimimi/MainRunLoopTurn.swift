// メインの run loop の 1 回りを待つ道具: 次に眠る直前 (beforeWaiting) になるまで待つ。
// SwiftUI の描き直しと Core Animation の反映は、眠る直前の観測者で行われるので、順番を最後 (CFIndex.max) にした
// 観測者が呼ばれた時には、その回の描き直しは済んでいる。一覧の終わりへ小刻みに追いつく所 (ListFollow) と、
// 画面の重さの確認 (UILoadTiming.swift の untilIdle) が使う。タイマーで間をあけない
// (CI の Mac では、短い Task.sleep が 0.1 秒ほどかかり、30 回で数秒になった)。

import CoreFoundation
import Foundation

@MainActor
enum MainRunLoopTurn {
    /// 次にメインの run loop が眠る直前になるまで (その回の描き直しが済むまで) 待つ。timeout 秒たっても来なければ、そこで戻る
    static func afterRedraw(timeout: Double = 0.5) async {
        _ = await nextBeforeWaiting(timeout: timeout)
    }

    /// 次に、メインの run loop が眠る直前 (beforeWaiting) になった時刻 (uptime のナノ秒)。timeout 秒たっても来なければ nil。
    /// 観測者 (CF の型で Sendable ではない) は ResumeOnce の中だけに置き、ほかのクロージャには ResumeOnce だけを渡す
    static func nextBeforeWaiting(timeout: Double) async -> UInt64? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
            let once = ResumeOnce(continuation)
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                once.resume(DispatchTime.now().uptimeNanoseconds)
            }
            once.hold(observer)
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout)) {
                once.resume(nil)
            }
        }
    }
}

/// 続きを 1 回だけ再開する (眠る直前の知らせと、打ち切りの、先に来たほう)。
/// 眠る直前の観測者も持ち、再開するときに無効にする (CF の型は Sendable ではないので、ほかのクロージャには持たせない。
/// 観測者はメインの run loop の上でだけ動き、打ち切りもメインのキューから呼ぶ)
final class ResumeOnce: @unchecked Sendable {
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
