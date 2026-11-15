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

/// 結果の右の、メモの欄と、その左の区切り (つかんで左右に動かすと、メモの欄の幅が変わる)。
/// メモの欄の幅 (動かしている最中の幅と設定の notesWidth) を見るのは、この部品だけにする
/// (結果の画面が見ると、区切りを動かすたびに、結果の画面の body が動き、数千行の一覧の行を作り直すことになる)。
/// 区切りを動かしているあいだは、この部品の中の幅だけが変わる。設定には、離したときだけ書く
struct NotesSidebar: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// メモの欄と一覧を並べている欄の幅 (一覧を 360 pt より狭めないため)
    let space: NotesSpace
    /// 区切りを動かしている最中の幅 (nil なら動かしていない)
    @State private var dragWidth: Double?
    /// 区切りをつかんだときの幅
    @State private var dragStart: Double?

    /// 一覧に残す幅の最小 (結果の画面の一覧の欄の minWidth と同じ)
    static let listMinWidth = 360.0

    var body: some View {
        let width = dragWidth ?? fitted(model.notesWidth)
        HStack(spacing: 0) {
            NotesResizeHandle(isDragging: dragWidth != nil)
                .gesture(
                    // 区切りは動かしているあいだに動くので、動かした量はウインドウの中の位置で測る
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? width
                            if dragStart == nil { dragStart = start }
                            // 左へ動かすと、メモの欄が広がる
                            let new = fitted(start - Double(value.translation.width))
                            if new != dragWidth { dragWidth = new }
                        }
                        .onEnded { value in
                            let start = dragStart ?? width
                            let new = fitted(start - Double(value.translation.width))
                            if new != model.notesWidth { model.notesWidth = new }
                            dragStart = nil
                            dragWidth = nil
                        }
                )
            NotesPane(job: job)
                .frame(width: CGFloat(width))
        }
        .frame(maxHeight: .infinity)
    }

    /// 幅を、設定の範囲 (220〜520) と、一覧に 360 pt を残す幅に収める (並べている欄の幅がわからないうちは、設定の範囲だけ)
    private func fitted(_ width: Double) -> Double {
        let range = AppModel.notesWidthRange
        var upper = range.upperBound
        if space.width > 0 {
            upper = min(upper, space.width - Self.listMinWidth - NotesResizeHandle.width)
        }
        return max(range.lowerBound, min(width, upper))
    }
}

/// メモの欄と一覧を並べている欄の幅 (結果の画面が測って入れる)。見るのは NotesSidebar だけ
@MainActor
@Observable
final class NotesSpace {
    var width = 0.0
}

/// メモの欄の左の区切り。押せる幅は 7 pt、線は 1 pt。上に載せているあいだと動かしているあいだは、左右の矢印のカーソルにする
private struct NotesResizeHandle: View {
    static let width = 7.0
    /// 区切りを動かしている (外へ出ても、離すまでカーソルを戻さない)
    let isDragging: Bool
    @State private var hovering = false
    /// カーソルを push した (pop するまで)
    @State private var pushed = false

    var body: some View {
        Color.clear
            .frame(width: CGFloat(Self.width))
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateCursor()
            }
            .onChange(of: isDragging) { _, _ in
                updateCursor()
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }

    private func updateCursor() {
        let wanted = hovering || isDragging
        if wanted && !pushed {
            NSCursor.resizeLeftRight.push()
            pushed = true
        } else if !wanted && pushed {
            NSCursor.pop()
            pushed = false
        }
    }
}
