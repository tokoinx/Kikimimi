import AppKit
import KikimimiCore
import SwiftUI

struct JobListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(
            get: { model.selectedJobID },
            set: { id in model.select(model.jobs.first { $0.id == id }) }
        )) {
            if model.jobs.isEmpty {
                Text("まだ何もありません")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(model.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .contextMenu {
                        if job.isActive || job.isPostActive {
                            Button("中止") { model.cancel(job) }
                        }
                        if let url = job.url {
                            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        // どの結果も (保存していない・作業中の結果も)、確かめの画面を通す
                        Button("ゴミ箱に入れる…", role: .destructive) {
                            model.requestDelete(job)
                        }
                        .disabled(model.isRecording)
                    }
            }
        }
        // 一覧での delete キーは、PlaybackKeys (KikimimiApp.swift) が受ける
        .listStyle(.sidebar)
        // 結果が在る時も、落として読み込める事が分かるように、一覧の下に案内を出す
        .safeAreaInset(edge: .bottom) {
            Label("音声・動画のファイルを、ここに落としても読み込めます", systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .navigationTitle("ききみみ")
        // ゴミ箱に入れるかを確かめる画面 (右クリック・ツールバー・メニュー・Delete キー)
        .sheet(isPresented: Binding(
            get: { model.pendingDeleteJobID != nil },
            set: { if !$0 { model.pendingDeleteJobID = nil } }
        )) {
            if let job = model.jobs.first(where: { $0.id == model.pendingDeleteJobID }) {
                DeleteConfirmSheet(job: job)
                    .environment(model)
            }
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if job.status == .running {
                        ProgressView(value: job.progress)
                            .controlSize(.mini)
                    } else if case .running(_, _, let progress?) = job.postState {
                        ProgressView(value: progress)
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch job.status {
        case .queued: return "clock"
        case .running: return "waveform"
        case .done:
            if let task = job.postState.task { return task == .audit ? "checkmark.seal" : "character.bubble" }
            return job.isRecording ? "mic.fill" : "doc.text"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .queued, .cancelled: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .orange
        }
    }

    private var statusText: String {
        switch job.status {
        case .queued: return "順番待ち"
        case .running: return job.message
        case .done:
            if case .running(_, let message, _) = job.postState { return message }
            if let t = job.transcript {
                var parts = ["\(TimeFormat.short(t.duration))", "\(t.segments.count) 区間"]
                if t.hasTranslation { parts.append("対訳") }
                if t.audit != nil { parts.append("監査済み") }
                if job.hasNotes { parts.append("メモ") }
                return parts.joined(separator: " · ")
            }
            return "完了"
        case .failed: return "エラー"
        case .cancelled: return "中止"
        }
    }
}
