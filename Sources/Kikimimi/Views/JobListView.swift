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
            ForEach(model.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .contextMenu {
                        if job.isActive || job.isPostActive {
                            Button(L("Cancel task")) { model.cancel(job) }
                        }
                        if let url = job.url {
                            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        // どの結果も (保存していない・作業中の結果も)、確かめの画面を通す
                        Button(L("Move to Trash…"), role: .destructive) {
                            model.requestDelete(job)
                        }
                        .disabled(model.isRecording)
                    }
            }
        }
        // 一覧での delete キーは、PlaybackKeys (KikimimiApp.swift) が受ける
        .listStyle(.sidebar)
        // 空の時の文は、一覧の行にしない。行にすると、最後の 1 つを消した後、
        // 一覧がその行を「選んだ行」として青く塗る (2026-11-26 に画面で見た)
        .overlay(alignment: .topLeading) {
            if model.jobs.isEmpty {
                Text(L("Nothing here yet"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        // 結果が在る時も、落として読み込める事が分かるように、一覧の下に案内を出す
        .safeAreaInset(edge: .bottom) {
            Label(L("You can also drop audio or video files here"), systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .navigationTitle(L("Kikimimi"))
        // ゴミ箱に入れるかを確かめる画面 (右クリック・ツールバー・メニュー・Delete キー)
        .sheet(isPresented: Binding(
            get: { model.pendingDeleteJobID != nil },
            set: { if !$0 { model.pendingDeleteJobID = nil } }
        )) {
            if let job = model.jobs.first(where: { $0.id == model.pendingDeleteJobID }) {
                DeleteConfirmSheet(job: job)
                    .environment(model)
                    // 画面の言語を変えたら作り直す
                    .id(model.uiLanguage)
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
        case .queued: return L("Waiting")
        case .running: return job.message
        case .done:
            if case .running(_, let message, _) = job.postState { return message }
            if let t = job.transcript {
                var parts = ["\(TimeFormat.short(t.duration))", LPlural(t.segments.count, one: "%d segment", other: "%d segments")]
                if t.hasTranslation { parts.append(L("Bilingual")) }
                if t.audit != nil { parts.append(L("Audited")) }
                if job.hasNotes { parts.append(L("Notes")) }
                return parts.joined(separator: " · ")
            }
            return L("Done")
        case .failed: return L("Error")
        case .cancelled: return L("Stopped")
        }
    }
}
