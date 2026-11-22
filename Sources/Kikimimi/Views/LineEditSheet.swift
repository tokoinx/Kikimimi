import KikimimiCore
import SwiftUI

/// 行を直す画面 (行の右クリックの「この行を直す…」・原文の「直した」の印)。聞き取った文を、利用者が手で直す。
/// 訳を直す画面と同じく、一覧の外のシートに置き、下書きはこの画面の @State に区間ごとに持つ
/// (行の中の入力欄では、一覧の行が作り直されると下書きが消える)。
/// 行が持つ区間の全部を出す: 単言語の行は 1 つ、対訳の行は訳のまとまりの区間の全部 (区間ごとに入力欄を 1 つ)。
/// 聞き取った文・今の文・訳が在るかは、body の中で今の結果から読む
struct LineEditSheet: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// 直す区間 (開いた時の並びの順)
    let segmentIDs: [UUID]
    /// 下書き (区間の id ごと)
    @State private var drafts: [UUID: String] = [:]
    @State private var started = false

    /// 今の結果から読んだ、1 つの区間
    private struct Line: Identifiable {
        var id: UUID
        var start: TimeInterval
        var text: String
        /// 直した区間の、聞き取った文 (直していなければ nil)
        var heard: String?
    }

    /// 今の結果から読んだ、行の区間 (今も在る区間だけ) と、訳が在るか
    private struct Current {
        var lines: [Line]
        /// 行の区間を含む訳のまとまりに、訳が在る
        var hasTranslation: Bool
    }

    private var current: Current {
        guard let transcript = job.transcript else { return Current(lines: [], hasTranslation: false) }
        var lines: [Line] = []
        var translated = false
        for id in segmentIDs {
            guard let segment = transcript.segments.first(where: { $0.id == id }) else { continue }
            lines.append(Line(id: id, start: segment.start, text: segment.text,
                              heard: transcript.lineEdit(forSegment: id)?.heard))
            let head = Translator.translationGroupIDs(of: id, in: transcript.segments).first ?? id
            if transcript.segments.first(where: { $0.id == head })?.translation != nil { translated = true }
        }
        return Current(lines: lines, hasTranslation: translated)
    }

    /// 区間の下書き (まだ無ければ、今の文)
    private func draft(of line: Line) -> String {
        drafts[line.id] ?? line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func binding(_ line: Line) -> Binding<String> {
        Binding(get: { draft(of: line) }, set: { drafts[line.id] = $0 })
    }

    var body: some View {
        let current = self.current
        let lines = current.lines
        // 変わった区間 (整えた後で、今の文と違う)。空の入力欄が 1 つでも在れば、保存できない
        let changed = lines.filter { LineEdit.normalized(draft(of: $0)) != LineEdit.normalized($0.text) }
        let hasEmpty = lines.contains { LineEdit.normalized(draft(of: $0)).isEmpty }
        let canSave = !changed.isEmpty && !hasEmpty
        let edited = lines.filter { $0.heard != nil }.map(\.id)
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edit this line"))
                .font(.headline)
            if lines.count == 1, let line = lines.first {
                section(L("Heard text")) {
                    Text(line.heard ?? line.text)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                field(line, lines: 2...8)
            } else if lines.count > 1 {
                // 区間が多い行で画面が高くなりすぎないよう、4 つ以上は高さに上限を付けて中を巻ける形にする
                if lines.count > 3 {
                    ScrollView {
                        multiLines(lines)
                            .padding(.trailing, 12)
                    }
                    .frame(height: 380)
                } else {
                    multiLines(lines)
                }
            }
            if current.hasTranslation {
                Label(L("Saving removes this line’s translation. You can translate the line again."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !edited.isEmpty {
                    Button(L("Restore the heard text")) {
                        model.revertLineEdits(edited, in: job)
                        close()
                    }
                }
                Spacer()
                Button(L("Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    // 変わった区間だけを直す (結果への代入は 1 回)。区間がもう無い (間に監査が消した、など) 時は、
                    // その区間は lines に無いので、何も変えない
                    var texts: [UUID: String] = [:]
                    for line in changed { texts[line.id] = draft(of: line) }
                    model.setLineTexts(texts, in: job)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // 下書きは、開いた時の文から始める (結果が変わっても、書きかけは変えない)
            guard !started else { return }
            started = true
            for line in current.lines {
                drafts[line.id] = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// 区間が 2 つ以上の行: 区間ごとに、時刻 (区間の始まり)・直した区間なら聞き取った文・入力欄
    private func multiLines(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(TimeFormat.short(line.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                    if let heard = line.heard {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(L("Heard text"))
                                .font(.caption.weight(.semibold))
                            Text(heard)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.secondary)
                    }
                    field(line, lines: 1...5)
                }
            }
        }
    }

    /// 入力欄。枠つきの決まりの見た目 (.roundedBorder) は、macOS では 1 行のままで折り返さない。
    /// 長い文を全部見て直せるよう、枠を自分で描き、何行かに広がる入力欄にする (訳を直す画面と同じ)
    private func field(_ line: Line, lines: ClosedRange<Int>) -> some View {
        TextField("", text: binding(line), axis: .vertical)
            .lineLimit(lines)
            .textFieldStyle(.plain)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityLabel(Text(L("Edit this line")))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func close() {
        model.lineEdit = nil
    }
}
