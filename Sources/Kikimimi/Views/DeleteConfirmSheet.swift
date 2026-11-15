import AppKit
import KikimimiCore
import SwiftUI

/// 結果をゴミ箱に入れるかを確かめる画面。何がどこから消え、何が残るかを、パスで出す。
/// 計画は body の中で読む (画面を出している間にジョブが保存されても、いまの状態に合わせる)
struct DeleteConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        let plan = model.deletionPlan(for: job)
        VStack(alignment: .leading, spacing: 14) {
            Text("「" + job.name + "」をゴミ箱に入れますか？")
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            if plan.stopsWork {
                Text(workText + "の途中です。作業を止めてから、ゴミ箱に入れます。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.isEmpty {
                Text("この結果は、まだ保存されていません。一覧から外すだけで、ファイルは消えません。")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                section("ゴミ箱に入れるもの") {
                    if let folder = plan.libraryFolder {
                        item("保存した結果 (文字起こし・訳・メモ・履歴)", url: folder) { model.revealInLibrary(job) }
                    }
                    if let recording = plan.recording {
                        item("マイクの録音", url: recording) { reveal(recording) }
                    }
                }
            }
            if let kept = plan.keptAudio {
                section("残るもの") {
                    item(keptTitle(plan.keptAudioReason), url: kept, note: keptNote(plan.keptAudioReason)) { reveal(kept) }
                }
            }
            if !plan.isEmpty {
                Text("macOS のゴミ箱に入ります。ゴミ箱を空にするまでは、Finder で取り出せます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                // Return で押されるのは「キャンセル」(消すほうは、押した時だけ)
                Button("キャンセル") { close() }
                    .keyboardShortcut(.defaultAction)
                Button(plan.isEmpty ? "一覧から外す" : "ゴミ箱に入れる", role: .destructive) {
                    close()
                    model.delete(job)
                }
                .disabled(model.isRecording)
            }
        }
        .padding(20)
        // esc でも閉じる (見えないボタン。「キャンセル」には Return を当てているので、esc はこちらで受ける)
        .background {
            Button("閉じる") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: 500)
    }

    /// 止める作業の名前
    private var workText: String {
        if job.isActive { return "文字起こし" }
        let task: PostTask?
        if case .running(let running, _, _) = job.postState {
            task = running
        } else {
            task = job.postQueue.first
        }
        switch task {
        case .audit: return "監査"
        case .translate, .translateLines: return "翻訳"
        case nil: return "監査・翻訳"
        }
    }

    private func keptTitle(_ reason: DeletionPlan.KeptAudioReason?) -> String {
        switch reason {
        case .original, nil: return "元の音声ファイル (消しません)"
        case .sharedRecording, .recordingOutsideAppFolder, .notSaved: return "マイクの録音 (消しません)"
        }
    }

    private func keptNote(_ reason: DeletionPlan.KeptAudioReason?) -> String? {
        switch reason {
        case .original, nil: return nil
        case .sharedRecording: return "ほかの結果も、この録音を使っています。"
        case .recordingOutsideAppFolder: return "この録音は、アプリの録音フォルダの外に在ります。"
        case .notSaved: return "この結果は、まだ保存されていないので、録音も残します。"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
            content()
        }
    }

    /// 1 つの物: 名前、パス (選んで写せる。長い時は折り返す)、「Finder で表示」
    private func item(_ title: String, url: URL, note: String? = nil, reveal: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Finder で表示", action: reveal)
                    .controlSize(.small)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func close() {
        model.pendingDeleteJobID = nil
    }
}
