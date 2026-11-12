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
            Label("履歴", systemImage: "clock.arrow.circlepath")
        }
        .help(available ? "いまの状態を版として残す・前の版に戻す (⌘S)" : "文字起こしが終わって保存した結果だけ、版を残せます")
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
            Text("履歴: " + job.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名前 (なくてもよい)", text: $label)
                        .textFieldStyle(.roundedBorder)
                    choice(.new, title: "新しい版として保存", selected: effective == .new, enabled: true)
                    choice(.overwriteLatest,
                           title: latest.map { "いちばん新しい版に上書き (「" + HistorySheet.title(of: $0) + "」)" }
                               ?? "いちばん新しい版に上書き (上書きできる版がありません)",
                           selected: effective == .overwriteLatest, enabled: latest != nil)
                    HStack {
                        if let blocked {
                            Text(blocked)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("保存") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(blocked != nil)
                    }
                }
                .padding(6)
            } label: {
                Text("いまの状態を版として残す")
                    .font(.callout.weight(.semibold))
            }
            versionList(blocked: blocked)
            Text("文字起こし・訳・メモは、変えるたびに自動で保存されます。版は、その時点の写しです。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Finder で表示") { model.revealInLibrary(job) }
                Spacer()
                Button("閉じる") { model.historyJobID = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .sheet(item: $restoreTarget) { version in
            RestoreVersionConfirm(job: job, version: version) { restoreTarget = nil }
                .environment(model)
        }
        .alert("この版を消しますか？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { version in
            Button("消す", role: .destructive) {
                deleteTarget = nil
                Task { await model.deleteVersion(job, versionID: version.id) }
            }
            Button("キャンセル", role: .cancel) {
                deleteTarget = nil
            }
        } message: { version in
            Text("「" + HistorySheet.title(of: version) + "」を消します。元には戻せません。")
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
                Text("まだ版はありません。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(job.versions) { version in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(version.label.isEmpty ? "名前なし" : version.label)
                                .fontWeight(.semibold)
                                .foregroundStyle(version.label.isEmpty ? Color.secondary : Color.primary)
                                .lineLimit(1)
                            if version.origin == .beforeRestore {
                                Text("自動 (戻す前)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(HistorySheet.dateText(version.savedAt)
                             + "　\(version.segmentCount) 区間・メモ \(version.noteLength) 文字")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("この版に戻す…") { restoreTarget = version }
                        .disabled(blocked != nil)
                        .help(blocked ?? "この版の中身に戻す (いまの状態は、版として自動で残す)")
                    Button {
                        deleteTarget = version
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(blocked != nil)
                    .help(blocked ?? "この版を消す")
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
        f.locale = Locale(identifier: "ja_JP")
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
            Text("「" + HistorySheet.title(of: version) + "」に戻しますか？")
                .font(.headline)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 6) {
                // 両方を外すことはできない (最後の 1 つは外せない)
                Toggle("文字起こしと訳", isOn: $transcript)
                    .toggleStyle(.checkbox)
                    .disabled(transcript && !notes)
                Toggle("メモ", isOn: $notes)
                    .toggleStyle(.checkbox)
                    .disabled(notes && !transcript)
            }
            Text("いまの状態は、版として自動で残します。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("戻す") {
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
