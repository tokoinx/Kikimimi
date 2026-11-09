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
                        Button("リストから削除", role: .destructive) { model.remove(job) }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ききみみ")
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
                return parts.joined(separator: " · ")
            }
            return "完了"
        case .failed: return "エラー"
        case .cancelled: return "中止"
        }
    }
}
