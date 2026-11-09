import AppKit
import Foundation
import KikimimiCore
import SwiftUI

/// 起動の入り口。`--selftest-llm <GGUF>` / `--selftest-whisper <音声>` のときは画面を出さずに、
/// LLM / 文字起こしの動作確認だけをして終わる (診断・CI 用)。
/// `--selftest-launch` は、ふつうに起動して、数秒後にウインドウができたかを確かめて終わる (起動しないときの診断用)
@main
enum KikimimiMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-llm") {
            let path = i + 1 < args.count ? args[i + 1] : ""
            exit(LLMSelfTest.run(modelPath: path, useGPU: !args.contains("--cpu"), strict: args.contains("--strict")))
        }
        if args.contains("--selftest-whisper") {
            exit(WhisperSelfTest.run(arguments: args))
        }
        // 版と、同梱した whisper.cpp / llama.cpp を読み込めるかだけを表示して終わる (組み立ての最後に、この Mac で動くかを確かめる)
        if args.contains("--version") {
            print(LaunchLog.versionLine)
            print("whisper.cpp: " + LaunchLog.whisperInfo)
            print("llama.cpp:   " + LaunchLog.llamaInfo)
            exit(0)
        }
        if args.contains("--selftest-launch") {
            LaunchSelfTest.arm(arguments: args)
        }
        LaunchLog.note("launch: \(LaunchLog.versionLine); \(LaunchLog.environmentLine); other instances: \(LaunchLog.otherInstances())")
        // 前回のウインドウの状態を復元しない。強制終了の後 (make run は前のアプリを終了させてから起動する) の起動では、
        // macOS が復元しようとして、ウインドウが 1 つも無いまま動いていることがあった (CI で、3 回目の起動で再現)。
        // 復元するものは無い (文字起こしの結果は保存していない) ので、いつも新しいウインドウで始める
        if !args.contains("--restore-windows") {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        }
        KikimimiApp.main()
    }
}

/// アプリ全体の出来事: ウインドウを全部閉じたとき、Dock や `open` から呼ばれたとき。
/// ウインドウの無いまま動き続けると、`open` しても何も起きないように見える (メニューから開き直す手段も要る)。
/// そこで、作業中でなければ最後のウインドウを閉じたときに終了し、呼ばれたときは必ずウインドウを出す
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static weak var shared: AppDelegate?
    /// 作業中か (文字起こし・録音・監査・翻訳・モデルの取得)。作業中は、ウインドウを閉じても終了しない
    var isBusy: @MainActor () -> Bool = { false }
    /// メインのウインドウを新しく開く (SwiftUI の openWindow)
    var openMainWindow: (@MainActor () -> Void)?
    /// 起動の確認 (`--selftest-launch --reopen`) のあいだは、ウインドウを閉じても終了しない
    var keepRunningWithoutWindows = false
    /// 呼ばれたときに、こちらでウインドウを開き直した回数 (確認用)
    private(set) var windowsReopened = 0

    /// メニューの「メインウインドウを表示」の名前 (ウインドウが 1 つも無いときは、このメニューの動作で開く)
    static let showMainWindowTitle = "メインウインドウを表示"

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 起動したのにウインドウが出ていなければ、開く (復元の失敗など、理由を問わない)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.keepRunningWithoutWindows else { return }
            if MainWindow.all().isEmpty {
                LaunchLog.note("no main window 1.5 s after launch")
                self.showMainWindow(openIfMissing: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepRunningWithoutWindows && !isBusy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // SwiftUI が自分で開き直すのを少し待ち、それでも無ければこちらで開く
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.showMainWindow(openIfMissing: true)
            }
        }
        return true
    }

    /// メインのウインドウを前に出す。しまってあれば戻し、無ければ開く
    func showMainWindow(openIfMissing: Bool) {
        let windows = MainWindow.all()
        if let window = windows.first(where: { $0.isVisible }) ?? windows.first(where: { $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if openIfMissing {
            windowsReopened += 1
            if let openMainWindow {
                LaunchLog.note("no main window: opening one")
                openMainWindow()
            } else if performShowMainWindowMenuItem() {
                // まだ 1 度もウインドウが出ていない (開き方を受け取っていない) ときは、メニューの動作を使う
                LaunchLog.note("no main window: opened one through the menu command")
            } else {
                LaunchLog.note("no main window, and no way to open one was found")
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// メニューの「メインウインドウを表示」を実行する (SwiftUI の openWindow は画面の部品の中でしか使えないため)
    private func performShowMainWindowMenuItem() -> Bool {
        guard let main = NSApplication.shared.mainMenu else { return false }
        for top in main.items {
            guard let menu = top.submenu else { continue }
            menu.update()
            let index = menu.indexOfItem(withTitle: Self.showMainWindowTitle)
            if index >= 0 {
                menuOpening = true
                defer { menuOpening = false }
                menu.performActionForItem(at: index)
                return true
            }
        }
        return false
    }

    /// メニューの動作をこちらから実行しているあいだ (メニューの側で、もう一度ここへ戻ってこないように)
    private(set) var menuOpening = false
}

/// メインのウインドウ (設定のウインドウなどを除く)
enum MainWindow {
    static let id = "main"

    /// SwiftUI は、WindowGroup(id:) のウインドウに「<id>-AppWindow-<番号>」という名前を付ける
    @MainActor
    static func all() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.identifier?.rawValue.hasPrefix(id + "-") == true }
    }
}

/// ウインドウの中から、アプリ全体の出来事の受け口 (AppDelegate) に、作業中かどうかとウインドウの開き方を教える
private struct AppLifecycleHook: View {
    let delegate: AppDelegate
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let model = model
                let openWindow = openWindow
                delegate.isBusy = { model.isBusy }
                delegate.openMainWindow = { openWindow(id: MainWindow.id) }
                LaunchLog.note("window appeared")
            }
    }
}

/// メニューの「メインウインドウを表示」(ウインドウを閉じたまま作業が続いているときに、開き直す)
private struct ShowMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AppDelegate.showMainWindowTitle) {
            guard let delegate = AppDelegate.shared, !delegate.menuOpening else {
                openWindow(id: MainWindow.id)
                return
            }
            if delegate.openMainWindow == nil {
                let openWindow = openWindow
                delegate.openMainWindow = { openWindow(id: MainWindow.id) }
            }
            delegate.showMainWindow(openIfMissing: true)
        }
        .keyboardShortcut("0")
    }
}

struct KikimimiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("ききみみ", id: MainWindow.id) {
            ContentView()
                .background(AppLifecycleHook(delegate: appDelegate))
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                // Finder の「このアプリケーションで開く」/ Dock アイコンへのドロップ
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    model.enqueue([url])
                }
                // 開くたびに新しいウインドウを作らず、今のウインドウで受け取る
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // アプリに戻ったら LLM のフォルダを見直す (Finder で GGUF を置いた・消したときに、
                // 置いた LLM に「ダウンロード」を出して数 GB を取り直させたり、消えた LLM を取得済みと出したりしない)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshLLMInstalled()
                }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開く…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button(model.isRecording ? "録音を停止して文字起こし" : "マイクで録音") {
                    Task { await model.toggleRecording() }
                }
                .keyboardShortcut("r")
                Button("選択中の処理を中止") {
                    if let job = model.selectedJob { model.cancel(job) }
                }
                .keyboardShortcut(".")
                .disabled(!(model.selectedJob.map { $0.isActive || $0.isPostActive } ?? false))
                Divider()
                ShowMainWindowButton()
            }
            CommandGroup(after: .saveItem) {
                Menu("書き出す") {
                    ExportMenuItems(hasTranslation: model.selectedJob?.transcript?.hasTranslation ?? false)
                        .environment(model)
                }
                .disabled(model.selectedJob?.status != .done)
                Button("本文をコピー") { model.copySelectedText() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selectedJob?.transcript == nil)
                Divider()
                Button("監査する (繰り返し・聞き取りミス)") {
                    if let job = model.selectedJob { model.audit(job) }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedJob?.status != .done || model.selectedJob?.isPostActive == true)
                Button("日本語に翻訳") {
                    if let job = model.selectedJob { model.translate(job) }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.selectedJob?.status != .done || model.selectedJob?.isPostActive == true
                          || (model.selectedJob?.transcript?.untranslatedCount ?? 0) == 0)
            }
        }
        Settings {
            SettingsView()
                .environment(model)
                // メインのウインドウを閉じて設定だけを開いているときも、アプリに戻ったら見直す
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshLLMInstalled()
                }
        }
    }
}
