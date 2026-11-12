import AppKit
import SwiftUI

/// 結果の右のメモの欄。メモ (job.notes) を見るのは、この部品だけにする
/// (結果の画面や一覧が見ると、1 文字打つたびに、数千行の一覧まで作り直すことになる)。
/// 書いたものは、少し待ってから自動で保存する (AppModel が notes.md に書く)
struct NotesPane: View {
    @Bindable var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("メモ")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if job.notesSaved {
                    Text("保存しました")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            TextEditor(text: $job.notes)
                .font(.body)
                .padding(6)
                .overlay(alignment: .topLeading) {
                    if job.notes.isEmpty {
                        // 押せない飾り (押すと、下の入力欄に届く)
                        Text("理解したこと、覚えたい表現などを書けます。行を右クリックして「メモに引用」を選ぶと、その文を貼れます。")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
