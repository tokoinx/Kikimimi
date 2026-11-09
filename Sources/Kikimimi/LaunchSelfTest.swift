import AppKit
import Foundation
import KikimimiCore
import KikimimiLLM
import KikimimiWhisper

/// `Kikimimi --selftest-launch [秒] [--report <ファイル>]`
///
/// ふつうに起動して (画面も出す)、数秒後にウインドウができているかを確かめて終わる。
/// 「起動しない」ときの診断 (`make doctor`) と、CI での起動の確認に使う。
/// 文字起こしや LLM の確認 (`--selftest-whisper` / `--selftest-llm`) は画面を出さないので、起動そのものはここで確かめる。
///
/// 終了コード: 0 = ウインドウができた、1 = ウインドウが無い、3 = 画面の準備が終わらない (メインスレッドが止まっている)
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
        let header = environmentLines()
        let hangLimit = seconds + 20
        // メインスレッドが止まったまま (画面の準備が終わらない) なら、別のスレッドから知らせて終わる
        DispatchQueue.global().asyncAfter(deadline: .now() + hangLimit) {
            finish(header + ["LAUNCH SELFTEST FAILED: the main thread did not respond for \(Int(hangLimit)) s"],
                   code: 3, reportPath: reportPath)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let windows = MainActor.assumeIsolated { windowLines() }
            var lines = header
            lines.append("windows: \(windows.count)")
            lines += windows.map { "  " + $0 }
            if windows.isEmpty {
                lines.append("LAUNCH SELFTEST FAILED: the app is running but made no window")
                finish(lines, code: 1, reportPath: reportPath)
            }
            lines.append("LAUNCH SELFTEST OK")
            finish(lines, code: 0, reportPath: reportPath)
        }
    }

    /// 起動した環境 (原因を切り分けるための手がかり)
    private static func environmentLines() -> [String] {
        let info = ProcessInfo.processInfo
        let defaults = UserDefaults.standard
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return [
            "Kikimimi \(version) (\(build)) launch self-test",
            "macOS: \(info.operatingSystemVersionString), memory \(info.physicalMemory / 1_073_741_824) GB, cores \(info.activeProcessorCount)",
            "bundle: \(bundle.bundlePath)",
            "settings: language=\(defaults.string(forKey: "languageCode") ?? "(default)")"
                + " model=\(defaults.string(forKey: "modelID") ?? "(default)")"
                + " llm=\(defaults.string(forKey: "llmModelID") ?? "(default)")",
            "whisper.cpp: " + WhisperContext.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines),
            "llama.cpp:   " + LlamaEngine.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
    }

    @MainActor
    private static func windowLines() -> [String] {
        NSApplication.shared.windows.map { window in
            let frame = window.frame
            return "\(window.title.isEmpty ? "(no title)" : window.title)"
                + " \(Int(frame.width))x\(Int(frame.height))"
                + (window.isVisible ? " visible" : " hidden")
        }
    }

    private static func finish(_ lines: [String], code: Int32, reportPath: String?) -> Never {
        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        if let reportPath {
            try? text.write(toFile: (reportPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        exit(code)
    }
}
