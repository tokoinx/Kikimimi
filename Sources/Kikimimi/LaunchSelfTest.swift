import AppKit
import Foundation

/// `Kikimimi --selftest-launch [秒] [--reopen | --reopen-menu | --reopen-external] [--restore-windows] [--report <ファイル>]`
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
///
/// whisper.cpp / llama.cpp の情報は、別のスレッドで取る。取るのに Metal の準備で 15〜46 秒かかる事があり、
/// メインスレッドで待つと、止まった時の見張りも仕掛けられず、結果も書かれないため。
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
        let viaMenu = arguments.contains("--reopen-menu")
        let reopen = external || viaMenu || arguments.contains("--reopen")
        let header = [
            LaunchLog.versionLine + " launch self-test",
            LaunchLog.environmentLine,
            "other instances: \(LaunchLog.otherInstances())",
        ]
        // whisper.cpp / llama.cpp の情報は別のスレッドで取る。結果を書く時に、取れている分だけを入れる
        let engines = EngineInfo()
        DispatchQueue.global(qos: .userInitiated).async {
            engines.setWhisper(LaunchLog.whisperInfo)
            engines.setLlama(LaunchLog.llamaInfo)
        }
        // 結果を書く。見出しの次に、その時点で取れている whisper.cpp / llama.cpp の情報を入れる
        let report: ([String], Int32) -> Never = { lines, code in
            finish(header + engines.lines() + lines, code: code, reportPath: reportPath)
        }
        let hangLimit = seconds + (reopen ? 45 : 20)
        // メインスレッドが止まったまま (画面の準備が終わらない) なら、別のスレッドから知らせて終わる
        DispatchQueue.global().asyncAfter(deadline: .now() + hangLimit) {
            report(["LAUNCH SELFTEST FAILED: the main thread did not respond for \(Int(hangLimit)) s"], 3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            var first: [String] = []
            let visible = MainActor.assumeIsolated { describeWindows(into: &first) }
            guard visible > 0 else {
                report(first + ["LAUNCH SELFTEST FAILED: the app is running but shows no main window"], 1)
            }
            guard reopen else {
                report(first + ["LAUNCH SELFTEST OK"], 0)
            }
            // ウインドウを全部閉じても動き続ける状態 (作業中と同じ) にしてから、呼び戻せるかを確かめる
            MainActor.assumeIsolated {
                AppDelegate.shared?.keepRunningWithoutWindows = true
                // --reopen-menu: ウインドウの開き方を忘れさせて、メニューの動作で開く道を確かめる
                if viaMenu { AppDelegate.shared?.openMainWindow = nil }
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
                        report(last + ["LAUNCH SELFTEST FAILED: no window came back after the reopen request"], 4)
                    }
                    report(last + ["LAUNCH SELFTEST OK"], 0)
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

/// whisper.cpp / llama.cpp の情報の入れ物。別のスレッドが書き、結果を書く時に読む (ロックで守る)
private final class EngineInfo: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var whisper: String?
    private var llama: String?

    func setWhisper(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        whisper = value
    }

    func setLlama(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        llama = value
    }

    /// 取れている物は値を、まだの物は取り始めてからの秒数を書いた 2 行
    func lines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let waiting = "(not ready after \(Int(Date().timeIntervalSince(started))) s)"
        return ["whisper.cpp: " + (whisper ?? waiting),
                "llama.cpp:   " + (llama ?? waiting)]
    }
}
