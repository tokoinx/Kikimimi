import AppKit
import Foundation

/// `Kikimimi --selftest-launch [秒] [--reopen | --reopen-external] [--report <ファイル>]`
///
/// ふつうに起動して (画面も出す)、数秒後にメインのウインドウが見えているかを確かめて終わる。
/// 「起動しない」ときの診断 (`make doctor`) と、CI での起動の確認に使う。
/// 文字起こしや LLM の確認 (`--selftest-whisper` / `--selftest-llm`) は画面を出さないので、起動そのものはここで確かめる。
///
/// `--reopen` を付けると、続けてウインドウを全部閉じ、Dock や `open` から呼ばれたときと同じ合図を自分に送って、
/// ウインドウが戻るかも確かめる (`--reopen-external` は合図を送らず、外からの `open` を待つ)。
///
/// 終了コード: 0 = 成功、1 = 見えているウインドウが無い、3 = 画面の準備が終わらない (メインスレッドが止まっている)、
/// 4 = 呼ばれてもウインドウが戻らない
enum LaunchSelfTest {
    /// 起動の前に呼ぶ。数秒後の確認を予約するだけで、すぐに戻る
    static func arm(arguments: [String]) {
        let seconds: Double = {
            guard let i = arguments.firstIndex(of: "--selftest-launch"), i + 1 < arguments.count,
                  let value = Double(arguments[i + 1]), value > 0 else { return 5 }
            return min(value, 60)
        }()
        let reportPath: String? = {
            guard let i = arguments.firstIndex(of: "--report"), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }()
        let external = arguments.contains("--reopen-external")
        let reopen = external || arguments.contains("--reopen")
        let header = [
            LaunchLog.versionLine + " launch self-test",
            LaunchLog.environmentLine,
            "other instances: \(LaunchLog.otherInstances())",
            "whisper.cpp: " + LaunchLog.whisperInfo,
            "llama.cpp:   " + LaunchLog.llamaInfo,
        ]
        let hangLimit = seconds + (reopen ? 45 : 20)
        // メインスレッドが止まったまま (画面の準備が終わらない) なら、別のスレッドから知らせて終わる
        DispatchQueue.global().asyncAfter(deadline: .now() + hangLimit) {
            finish(header + ["LAUNCH SELFTEST FAILED: the main thread did not respond for \(Int(hangLimit)) s"],
                   code: 3, reportPath: reportPath)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            var first = header
            let visible = MainActor.assumeIsolated { describeWindows(into: &first) }
            guard visible > 0 else {
                finish(first + ["LAUNCH SELFTEST FAILED: the app is running but shows no main window"],
                       code: 1, reportPath: reportPath)
            }
            guard reopen else {
                finish(first + ["LAUNCH SELFTEST OK"], code: 0, reportPath: reportPath)
            }
            // ウインドウを全部閉じても動き続ける状態 (作業中と同じ) にしてから、呼び戻せるかを確かめる
            MainActor.assumeIsolated {
                AppDelegate.shared?.keepRunningWithoutWindows = true
                for window in MainWindow.all() { window.close() }
            }
            let afterFirst = first
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let left = MainActor.assumeIsolated { MainWindow.all().filter { $0.isVisible }.count }
                let afterClose = afterFirst + ["after closing: \(left) visible main window(s)"]
                if !external { sendReopenToSelf() }
                DispatchQueue.main.asyncAfter(deadline: .now() + (external ? 15 : 4)) {
                    var last = afterClose
                    let back = MainActor.assumeIsolated { describeWindows(into: &last) }
                    let helped = MainActor.assumeIsolated { AppDelegate.shared?.windowsReopened ?? -1 }
                    last.append("reopen (\(external ? "external open" : "sent to self")): \(back) visible main window(s),"
                                + " opened by the app's own fallback \(helped) time(s)")
                    guard back > 0 else {
                        finish(last + ["LAUNCH SELFTEST FAILED: no window came back after the reopen request"],
                               code: 4, reportPath: reportPath)
                    }
                    finish(last + ["LAUNCH SELFTEST OK"], code: 0, reportPath: reportPath)
                }
            }
        }
    }

    /// ウインドウの一覧を書き足し、見えているメインのウインドウの数を返す
    @MainActor
    private static func describeWindows(into lines: inout [String]) -> Int {
        let windows = NSApplication.shared.windows
        lines.append("windows: \(windows.count), app active: \(NSApplication.shared.isActive)")
        for window in windows {
            let frame = window.frame
            lines.append("  \(window.identifier?.rawValue ?? "(no id)") \"\(window.title)\""
                         + " \(Int(frame.width))x\(Int(frame.height))"
                         + (window.isVisible ? " visible" : " hidden")
                         + (window.isMiniaturized ? " miniaturized" : ""))
        }
        return MainWindow.all().filter { $0.isVisible && !$0.isMiniaturized }.count
    }

    /// Dock のアイコンを押したとき・動いているアプリを `open` したときに届く合図 (reopen) を、自分に送る
    private static func sendReopenToSelf() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: [.noReply], timeout: 5)
    }

    private static func finish(_ lines: [String], code: Int32, reportPath: String?) -> Never {
        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        LaunchLog.note("launch self-test finished with code \(code)")
        if let reportPath {
            try? text.write(toFile: (reportPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        exit(code)
    }
}
