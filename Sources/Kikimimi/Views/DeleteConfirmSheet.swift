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
            // 保存していない結果は、ディスクから何も消えないので、「一覧から外す」と言う
            Text(plan.isEmpty ? L("Remove “%@” from the list?", job.name) : L("Move “%@” to the Trash?", job.name))
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            if plan.stopsWork {
                Text(workText(removesFromListOnly: plan.isEmpty))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.isEmpty {
                Text(L("This result is not saved yet. It is only removed from the list, and no files are deleted."))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                section(L("What goes to the Trash")) {
                    if let folder = plan.libraryFolder {
                        item(L("The saved result (transcription, translation, notes, history)"), url: folder) { model.revealInLibrary(job) }
                    }
                    if let recording = plan.recording {
                        item(L("The microphone recording"), url: recording) { reveal(recording) }
                    }
                }
            }
            if let kept = plan.keptAudio {
                section(L("What stays")) {
                    item(keptTitle(plan.keptAudioReason), url: kept, note: keptNote(plan.keptAudioReason)) { reveal(kept) }
                }
            }
            if !plan.isEmpty {
                Text(L("They go to the macOS Trash. Until you empty the Trash, you can take them back out in Finder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                // Return で押されるのは「キャンセル」(消すほうは、押した時だけ)
                Button(L("Cancel")) { close() }
                    .keyboardShortcut(.defaultAction)
                Button(plan.isEmpty ? L("Remove from list") : L("Move to Trash"), role: .destructive) {
                    close()
                    model.delete(job)
                }
                .disabled(model.isRecording)
            }
        }
        .padding(20)
        // esc でも閉じる (見えないボタン。「キャンセル」には Return を当てているので、esc はこちらで受ける)
        .background {
            Button(L("Close")) { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: 500)
    }

    /// 止める作業の知らせ (作業の名前ごと、一覧から外すかゴミ箱に入れるかごとに、文全体を 1 つの鍵にする)
    private func workText(removesFromListOnly: Bool) -> String {
        if job.isActive {
            return removesFromListOnly
                ? L("Transcription is in progress. It will be stopped, then the result is removed from the list.")
                : L("Transcription is in progress. It will be stopped, then the result is moved to the Trash.")
        }
        let task: PostTask?
        if case .running(let running, _, _) = job.postState {
            task = running
        } else {
            task = job.postQueue.first
        }
        switch task {
        case .audit:
            return removesFromListOnly
                ? L("An audit is in progress. It will be stopped, then the result is removed from the list.")
                : L("An audit is in progress. It will be stopped, then the result is moved to the Trash.")
        case .translate, .translateLines:
            return removesFromListOnly
                ? L("A translation is in progress. It will be stopped, then the result is removed from the list.")
                : L("A translation is in progress. It will be stopped, then the result is moved to the Trash.")
        case nil:
            return removesFromListOnly
                ? L("An audit or translation is in progress. It will be stopped, then the result is removed from the list.")
                : L("An audit or translation is in progress. It will be stopped, then the result is moved to the Trash.")
        }
    }

    private func keptTitle(_ reason: DeletionPlan.KeptAudioReason?) -> String {
        switch reason {
        case .original, nil: return L("The original audio file (not deleted)")
        case .sharedRecording, .recordingOutsideAppFolder, .notSaved: return L("The microphone recording (not deleted)")
        }
    }

    private func keptNote(_ reason: DeletionPlan.KeptAudioReason?) -> String? {
        switch reason {
        case .original, nil: return nil
        case .sharedRecording: return L("Other results also use this recording.")
        case .recordingOutsideAppFolder: return L("This recording is outside the app’s recordings folder.")
        case .notSaved: return L("This result is not saved yet, so the recording is kept too.")
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
                Button(L("Show in Finder"), action: reveal)
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
