import AppKit
import KikimimiCore
import SwiftUI

/// 操作列の「履歴」: 履歴の画面を開く (保存した、終わった結果のときだけ)
struct HistoryButton: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        let available = job.inLibrary && job.status == .done
        Button {
            model.historyJobID = job.id
        } label: {
            Label(L("History"), systemImage: "clock.arrow.circlepath")
        }
        .help(available ? L("Keep the current state as a version, or go back to an earlier version (⌘S)") : L("Only finished, saved transcription results can have versions"))
        .disabled(!available)
    }
}

/// 履歴の画面: いまの状態を版として残す (新しい版・いちばん新しい版に上書き)、版の一覧、版に戻す・消す。
/// 監査・翻訳の最中は、ボタンを押せない (説明を出す)
struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var label = ""
    @State private var mode: VersionSaveMode = .new
    /// 戻すか確かめている版
    @State private var restoreTarget: VersionInfo?
    /// 消すか確かめている版
    @State private var deleteTarget: VersionInfo?

    var body: some View {
        let blocked = model.versionBlockedReason(job)
        let latest = job.versions.first { $0.origin == .manual }
        // 自分で残した版が無いときは、上書きを選べない (新しい版になる)
        let effective: VersionSaveMode = mode == .overwriteLatest && latest != nil ? .overwriteLatest : .new
        VStack(alignment: .leading, spacing: 14) {
            Text(L("History: %@", job.name))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("Name (optional)"), text: $label)
                        .textFieldStyle(.roundedBorder)
                    choice(.new, title: L("Save as a new version"), selected: effective == .new, enabled: true)
                    choice(.overwriteLatest,
                           title: latest.map { L("Overwrite the newest version (“%@”)", HistorySheet.title(of: $0)) }
                               ?? L("Overwrite the newest version (there is no version to overwrite)"),
                           selected: effective == .overwriteLatest, enabled: latest != nil)
                    HStack {
                        if let blocked {
                            Text(blocked)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Save")) { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(blocked != nil)
                    }
                }
                .padding(6)
            } label: {
                Text(L("Keep the current state as a version"))
                    .font(.callout.weight(.semibold))
            }
            versionList(blocked: blocked)
            Text(L("The transcription, translation, and notes are saved automatically every time they change. A version is a copy of one moment."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L("Show in Finder")) { model.revealInLibrary(job) }
                Spacer()
                Button(L("Close")) { model.historyJobID = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .sheet(item: $restoreTarget) { version in
            RestoreVersionConfirm(job: job, version: version) { restoreTarget = nil }
                .environment(model)
        }
        .alert(L("Delete this version?"), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { version in
            Button(L("Delete version"), role: .destructive) {
                deleteTarget = nil
                Task { await model.deleteVersion(job, versionID: version.id) }
            }
            Button(L("Cancel"), role: .cancel) {
                deleteTarget = nil
            }
        } message: { version in
            Text(L("“%@” will be deleted. This cannot be undone.", HistorySheet.title(of: version)))
        }
    }

    /// 版の残し方の 1 つ (丸の印を付けた、押せる行)
    private func choice(_ value: VersionSaveMode, title: String, selected: Bool, enabled: Bool) -> some View {
        Button {
            mode = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func versionList(blocked: String?) -> some View {
        if job.versions.isEmpty {
            VStack {
                Spacer()
                Text(L("No versions yet."))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(job.versions) { version in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(version.label.isEmpty ? L("No name") : version.label)
                                .fontWeight(.semibold)
                                .foregroundStyle(version.label.isEmpty ? Color.secondary : Color.primary)
                                .lineLimit(1)
                            if version.origin == .beforeRestore {
                                Text(L("Automatic (before going back)"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L("%1$@  %2$@, notes %3$@", HistorySheet.dateText(version.savedAt),
                               LPlural(version.segmentCount, one: "%d segment", other: "%d segments"),
                               LPlural(version.noteLength, one: "%d character", other: "%d characters")))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Go back to this version…")) { restoreTarget = version }
                        .disabled(blocked != nil)
                        .help(blocked ?? L("Go back to the contents of this version (the current state is kept as a version automatically)"))
                    Button {
                        deleteTarget = version
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(blocked != nil)
                    .help(blocked ?? L("Delete this version"))
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }

    private func save() {
        // 自分で残した版が無ければ、上書きではなく新しい版にする
        let hasManual = job.versions.contains { $0.origin == .manual }
        let effective: VersionSaveMode = mode == .overwriteLatest && hasManual ? .overwriteLatest : .new
        let name = label
        Task {
            if await model.saveVersion(job, label: name, mode: effective) { label = "" }
        }
    }

    /// 版の呼び名 (名前が無ければ、残した日時)
    static func title(of version: VersionInfo) -> String {
        version.label.isEmpty ? dateText(version.savedAt) : version.label
    }

    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        // 数だけの書式なので、言語に左右されない形にする (見た目は ja_JP の時と同じ)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()
}

/// 「この版に戻す…」の確認: 戻すもの (文字起こしと訳・メモ。どちらか 1 つは残す) を選ぶ
private struct RestoreVersionConfirm: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let version: VersionInfo
    let close: () -> Void
    @State private var transcript = true
    @State private var notes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Go back to “%@”?", HistorySheet.title(of: version)))
                .font(.headline)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 6) {
                // 両方を外すことはできない (最後の 1 つは外せない)
                Toggle(L("Transcription and translation"), isOn: $transcript)
                    .toggleStyle(.checkbox)
                    .disabled(transcript && !notes)
                Toggle(L("Notes"), isOn: $notes)
                    .toggleStyle(.checkbox)
                    .disabled(notes && !transcript)
            }
            Text(L("The current state is kept as a version automatically."))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Go back")) {
                    let restoreTranscript = transcript
                    let restoreNotes = notes
                    close()
                    Task {
                        await model.restoreVersion(job, versionID: version.id,
                                                   transcript: restoreTranscript, notes: restoreNotes)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(transcript || notes) || model.versionBlockedReason(job) != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
