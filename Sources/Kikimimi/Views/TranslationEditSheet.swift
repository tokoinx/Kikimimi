import KikimimiCore
import SwiftUI

/// 訳を直す画面 (対訳の行の右クリックの「訳を直す…」・「直した」の印)。
/// 一覧の外のシートに置く: 翻訳の途中は一覧の行が作り直されるので、行の中の入力欄では下書きが消える。
/// 下書きはこの画面の @State に持ち、結果が変わっても (翻訳が進んでも) そのまま残す。
/// 原文・直す前の機械の訳は、body の中で今の結果から読む
struct TranslationEditSheet: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// 開いた行の区間 (行のどの区間でもよい。保存する時に、その区間を含む訳のまとまりに置く)
    let segmentID: UUID
    @State private var draft = ""
    @State private var started = false

    /// 今の結果から読んだ、その行の訳のまとまり
    private struct Current {
        var source: String
        var translation: String?
        var note: TranslationNote?

        var isEdited: Bool { note?.isEdited == true }
        /// 直す前の機械の訳 (直した訳なら覚えの物、直していなければ今の訳)。
        /// 訳の記憶から置いた訳は、機械の訳ではないので出さない (nil)
        var machine: String? {
            if note?.isRemembered == true { return nil }
            return isEdited ? note?.machine : translation
        }
    }

    private var current: Current? {
        guard let transcript = job.transcript,
              let head = Translator.translationGroupIDs(of: segmentID, in: transcript.segments).first,
              let segment = transcript.segments.first(where: { $0.id == head }) else { return nil }
        return Current(source: transcript.translationSource(ofHead: head) ?? segment.text,
                       translation: segment.translation, note: transcript.translationNote(for: head))
    }

    var body: some View {
        let current = self.current
        let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edit translation"))
                .font(.headline)
            section(L("Original")) {
                Text(current?.source ?? "")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let machine = current?.machine {
                section(L("Machine translation")) {
                    Text(machine)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            section(L("Your translation")) {
                // 枠つきの決まりの見た目 (.roundedBorder) は、macOS では 1 行のままで折り返さない。
                // 長い訳を全部見て直せるよう、枠を自分で描き、3〜8 行に広がる入力欄にする
                TextField("", text: $draft, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    .accessibilityLabel(Text(L("Your translation")))
            }
            HStack {
                if let current, current.isEdited {
                    Button(current.machine == nil ? L("Remove your translation") : L("Restore machine translation")) {
                        model.revertTranslation(head: segmentID, in: job)
                        close()
                    }
                }
                Spacer()
                Button(L("Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    model.setTranslation(draft, head: segmentID, in: job)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil || cleaned.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // 下書きは、開いた時の訳から始める (結果が変わっても、書きかけは変えない)
            guard !started else { return }
            started = true
            draft = current?.translation ?? ""
        }
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
        model.translationEdit = nil
    }
}
