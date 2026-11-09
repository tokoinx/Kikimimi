import Foundation
import KikimimiCore
import SwiftUI

/// 起動の入り口。`--selftest-llm <GGUF>` のときは画面を出さずに LLM の動作確認だけをして終わる (診断・CI 用)
@main
enum KikimimiMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-llm") {
            let path = i + 1 < args.count ? args[i + 1] : ""
            exit(LLMSelfTest.run(modelPath: path, useGPU: !args.contains("--cpu")))
        }
        KikimimiApp.main()
    }
}

struct KikimimiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("ききみみ") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                // Finder の「このアプリケーションで開く」/ Dock アイコンへのドロップ
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    model.enqueue([url])
                }
                // 開くたびに新しいウインドウを作らず、今のウインドウで受け取る
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
                .disabled(model.selectedJob?.isActive != true)
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
        }
    }
}
