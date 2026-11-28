// 知らせ (AppModel.errorMessage) の変わり方の、小さい履歴。確認用の起動 (--selftest-…) の時だけ記録する。
// アプリの確認で、知らせが黙って消えた時 (2026-11-28 に 16 回に 1 回起きた「message none」) に、誰が消したかを、
// その回の出力に残すため。ふつうの起動では、何も記録しない (呼び出しの並びも取らない)。

import AppKit
import Foundation
import KikimimiCore

@MainActor
final class NoticeHistory {
    static let shared = NoticeHistory()

    /// 残す件数 (新しい物から)
    static let limit = 20
    /// 呼び出しの並びの、残す行の数 (この型の中の行を除いた頭から)
    static let stackLines = 6

    private var entries: [String] = []
    private var started = false
    private let start = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []

    /// 確認用の起動の時だけ、アプリが前に出た・後ろに回った時も記録し始める (AppModel の init から呼ぶ)
    func startIfSelfTest() {
        guard LaunchMode.current.isSelfTest, !started else { return }
        started = true
        let center = NotificationCenter.default
        for (name, text) in [(NSApplication.didBecomeActiveNotification, "app became active"),
                             (NSApplication.didResignActiveNotification, "app resigned active")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NoticeHistory.shared.add(text) }
            })
        }
    }

    /// 知らせが変わった (AppModel.errorMessage の didSet から)。確認用の起動の時だけ、値と呼び出しの並びを残す
    func noteMessage(_ message: String?) {
        guard started else { return }
        // 頭の 2 行は、ここと didSet の中なので除く
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(Self.stackLines).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined()
        }
        let value = message.map { "\"\($0.prefix(40))\"" } ?? "nil"
        add("message = \(value) from [\(stack.joined(separator: " < "))]")
    }

    private func add(_ text: String) {
        let seconds = ProcessInfo.processInfo.systemUptime - start
        entries.append(String(format: "%.3f s ", seconds) + text)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// 履歴の全部を 1 行に (古い順)
    var line: String {
        entries.isEmpty ? "(empty)" : entries.joined(separator: " | ")
    }
}
