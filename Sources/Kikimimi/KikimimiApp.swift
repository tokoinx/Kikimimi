import KikimimiCore
import SwiftUI

@main
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
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.displayName) { model.export(as: format) }
                    }
                }
                .disabled(model.selectedJob?.status != .done)
                Button("本文をコピー") { model.copySelectedText() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selectedJob?.transcript == nil)
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
