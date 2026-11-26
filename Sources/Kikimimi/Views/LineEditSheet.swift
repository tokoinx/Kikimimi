import KikimimiCore
import SwiftUI

/// 行を直す画面 (行の右クリックの「この行を直す…」・原文の「直した」の印)。聞き取った文を、利用者が手で直す。
/// 訳を直す画面と同じく、一覧の外のシートに置き、下書きはこの画面の @State に区間ごとに持つ
/// (行の中の入力欄では、一覧の行が作り直されると下書きが消える)。
/// 行が持つ区間の全部を出す: 単言語の行は 1 つ、対訳の行は訳のまとまりの区間の全部 (区間ごとに入力欄を 1 つ)。
/// 聞き取った文・今の文・訳が在るかは、body の中で今の結果から読む。
/// 学習した直しを使う設定の時は、入力欄の下に「この直しを覚える」の所を出す (聞き間違えた語 → 正しい語を、
/// 学習した直しの台帳に 1 回分覚えさせる。組は、保存が記録に残す聞き取った文と下書きから切り出す:
/// `Transcript.suggestedLearnedPair`。保存は、ここで見せた組をそのまま覚えさせる)
struct LineEditSheet: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// 直す区間 (開いた時の並びの順)
    let segmentIDs: [UUID]
    /// 下書き (区間の id ごと)
    @State private var drafts: [UUID: String] = [:]
    @State private var started = false
    /// 「この直しを覚える」を利用者が触った値 (区間ごと。無ければ、切り出した組で決める)
    @State private var learnOn: [UUID: Bool] = [:]
    /// 利用者が自分で書き換えた (または、前に覚えた組から始めた) 2 つの欄 (区間ごと。在れば、切り出し直さない)
    @State private var fixedWrong: [UUID: String] = [:]
    @State private var fixedRight: [UUID: String] = [:]

    /// 今の結果から読んだ、1 つの区間
    private struct Line: Identifiable {
        var id: UUID
        var start: TimeInterval
        var text: String
        /// 直した区間の、聞き取った文 (直していなければ nil)
        var heard: String?
        /// この直しで、台帳に覚えさせた組
        var learned: AuditChange.Pair?
    }

    /// 今の結果から読んだ、行の区間 (今も在る区間だけ) と、訳が在るか
    private struct Current {
        var lines: [Line]
        /// 行の区間を含む訳のまとまりに、訳が在る
        var hasTranslation: Bool
    }

    /// 1 つの区間の「この直しを覚える」の所の状態
    private struct Learning {
        /// 出すか (学習した直しを使う設定で、組を切り出せる・前に覚えた・欄を書き換えた区間だけ)
        var shown: Bool
        var on: Bool
        var wrong: String
        var right: String
        /// 入の時に、保存できない理由 (無ければ nil)
        var problem: String?
        /// 保存の時に覚えさせる組 (出していて、入で、理由が無い時だけ)
        var pair: AuditChange.Pair? {
            guard shown, on, problem == nil else { return nil }
            return AuditChange.Pair(wrong: wrong.trimmingCharacters(in: .whitespacesAndNewlines),
                                    right: right.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var current: Current {
        guard let transcript = job.transcript else { return Current(lines: [], hasTranslation: false) }
        var lines: [Line] = []
        var translated = false
        for id in segmentIDs {
            guard let segment = transcript.segments.first(where: { $0.id == id }) else { continue }
            let edit = transcript.lineEdit(forSegment: id)
            lines.append(Line(id: id, start: segment.start, text: segment.text, heard: edit?.heard, learned: edit?.learned))
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

    /// 区間の「聞き取った文」: 保存が記録に残す文 (`Transcript.heardText(forSegment:)`)。
    /// 手で直した行では直す前の文、監査の直しを反映していた行では監査の前の文、どちらでもなければ今の文。
    /// 札に出す文と、「覚える組」を切り出す元の文を、同じにする (別々に決めると、札は監査の後・組は監査の前、と食い違う)
    private func heardText(of line: Line) -> String {
        job.transcript?.heardText(forSegment: line.id) ?? line.heard ?? line.text
    }

    /// 区間の「この直しを覚える」の所。組は、保存が記録に残す聞き取った文 (`Transcript.heardText(forSegment:)`。
    /// 監査の直しを反映していた行では監査の前の文) と下書きから、保存と同じ関数 (`Transcript.suggestedLearnedPair`) で、そのつど切り出す
    private func learning(of line: Line) -> Learning {
        let heard = heardText(of: line)
        let text = draft(of: line)
        let suggested = job.transcript?.suggestedLearnedPair(forSegment: line.id, edited: text)
        let fixed = fixedWrong[line.id] != nil || fixedRight[line.id] != nil
        // 聞き取った文と同じに戻した下書き (保存すると直しを戻す) では、出さない。
        // まだ直していない行を、文を変えずに開いた時も、出さない (監査の直しを反映していた行で、監査の直しを組として見せない)
        let backToHeard = LineEdit.normalized(text) == LineEdit.normalized(heard)
        let untouched = LineEdit.normalized(text) == LineEdit.normalized(line.text)
        let shown = model.useLedger && !backToHeard && (suggested != nil || fixed) && !(untouched && line.heard == nil)
        let wrong = fixedWrong[line.id] ?? suggested?.wrong ?? ""
        let right = fixedRight[line.id] ?? suggested?.right ?? ""
        // 初めの値: `LineEdit.remembersByDefault` (聞き間違えた語が 2 字以上なら入。ひらがなだけの組は切)。
        // ただし、前に覚えさせずに直した行を、文を変えずに開いた時は切 (開いただけで「保存」が押せる形にしない)
        let untouchedEdit = line.heard != nil && line.learned == nil && untouched
        let on = learnOn[line.id] ?? (!untouchedEdit && LineEdit.remembersByDefault(suggested))
        var problem: String?
        if shown && on {
            let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
            if w.isEmpty || r.isEmpty {
                problem = L("Fill in both terms.")
            } else if w == r {
                problem = L("The two terms are the same.")
            } else if !LineEdit.normalized(heard).contains(w) {
                problem = L("The heard text does not contain the misheard term.")
            } else if !LineEdit.normalized(text).contains(r) {
                problem = L("Your text does not contain the right term.")
            }
        }
        return Learning(shown: shown, on: on, wrong: wrong, right: right, problem: problem)
    }

    /// 区間が変わったか: 文が変わった (整えた後で、今の文と違う)、または、覚えさせる組が変わった (学習した直しを使う設定の時)
    private func isChanged(_ line: Line, learning: Learning?) -> Bool {
        LineEdit.normalized(draft(of: line)) != LineEdit.normalized(line.text)
            || (model.useLedger && line.heard != nil && learning?.pair != line.learned)
    }

    /// 「保存」。変わった区間だけを直す (結果への代入は 1 回)。区間がもう無い (間に監査が消した、など) 時は、
    /// その区間は lines に無いので、何も変えない。
    /// 変わった区間と覚える組は、押した時の下書きから決め直す (画面を作った時の値を使わない)。
    /// Return キーで保存すると、画面が見せた組が記録に残らない事が在った (2026-11-26 に画面で見た。ボタンを押した時は残った)
    private func save() {
        let lines = current.lines
        let learnings = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, learning(of: $0)) })
        // 空の入力欄・覚える組の理由が在る時は、保存しない (ボタンが押せない時と同じ決まり)
        guard !lines.contains(where: { LineEdit.normalized(draft(of: $0)).isEmpty }),
              !learnings.values.contains(where: { $0.shown && $0.on && $0.problem != nil }) else { return }
        var texts: [UUID: String] = [:]
        var pairs: [UUID: AuditChange.Pair] = [:]
        for line in lines where isChanged(line, learning: learnings[line.id]) {
            texts[line.id] = draft(of: line)
            if let pair = learnings[line.id]?.pair { pairs[line.id] = pair }
        }
        guard !texts.isEmpty else { return }
        model.setLineTexts(texts, learning: pairs, in: job)
        close()
    }

    var body: some View {
        let current = self.current
        let lines = current.lines
        let learnings = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, learning(of: $0)) })
        // 文が変わった区間 (整えた後で、今の文と違う) と、覚えさせる組が変わった区間 (学習した直しを使う設定の時)
        let changed = lines.filter { isChanged($0, learning: learnings[$0.id]) }
        // 空の入力欄・覚える組の理由が 1 つでも在れば、保存できない
        let hasEmpty = lines.contains { LineEdit.normalized(draft(of: $0)).isEmpty }
        let hasProblem = learnings.values.contains { $0.shown && $0.on && $0.problem != nil }
        let canSave = !changed.isEmpty && !hasEmpty && !hasProblem
        let edited = lines.filter { $0.heard != nil }.map(\.id)
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edit this line"))
                .font(.headline)
            if lines.count == 1, let line = lines.first {
                section(L("Heard text")) {
                    Text(heardText(of: line))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                field(line, lines: 2...8)
                if let learning = learnings[line.id], learning.shown {
                    learningArea(line, learning)
                }
            } else if lines.count > 1 {
                // 区間が多い行で画面が高くなりすぎないよう、4 つ以上は高さに上限を付けて中を巻ける形にする
                if lines.count > 3 {
                    ScrollView {
                        multiLines(lines, learnings)
                            .padding(.trailing, 12)
                    }
                    .frame(height: 380)
                } else {
                    multiLines(lines, learnings)
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
                        // 覚えさせた組は、中で取り消す
                        model.revertLineEdits(edited, in: job)
                        close()
                    }
                }
                Spacer()
                Button(L("Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // 下書きは、開いた時の文から始める (結果が変わっても、書きかけは変えない)。
            // 前に覚えさせた組が在る区間は、入で、その組から始める
            guard !started else { return }
            started = true
            for line in current.lines {
                drafts[line.id] = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let learned = line.learned {
                    learnOn[line.id] = true
                    fixedWrong[line.id] = learned.wrong
                    fixedRight[line.id] = learned.right
                }
            }
        }
    }

    /// 区間が 2 つ以上の行: 区間ごとに、時刻 (区間の始まり)・直した区間なら聞き取った文・入力欄・覚える所
    private func multiLines(_ lines: [Line], _ learnings: [UUID: Learning]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(TimeFormat.short(line.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                    // 聞き取った文が今の文と違う区間 (手で直した・監査の直しを反映していた) にだけ、札を出す
                    let heard = heardText(of: line)
                    if line.heard != nil || LineEdit.normalized(heard) != LineEdit.normalized(line.text) {
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
                    if let learning = learnings[line.id], learning.shown {
                        learningArea(line, learning)
                    }
                }
            }
        }
    }

    /// 「この直しを覚える」の所: トグル、2 つの欄 (聞き間違えた語 → 正しい語)、保存できない理由、説明の 1 行
    private func learningArea(_ line: Line, _ learning: Learning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("Remember this fix"), isOn: Binding(
                get: { learning.on },
                set: { learnOn[line.id] = $0 }
            ))
            if learning.on {
                HStack {
                    // 欄を自分で書き換えたら、2 つとも、その後は切り出し直さない
                    TextField(L("Misheard term"), text: Binding(
                        get: { learning.wrong },
                        set: { value in
                            fixedWrong[line.id] = value
                            if fixedRight[line.id] == nil { fixedRight[line.id] = learning.right }
                        }
                    ), prompt: Text(L("Misheard term")))
                    .labelsHidden()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField(L("Right term"), text: Binding(
                        get: { learning.right },
                        set: { value in
                            fixedRight[line.id] = value
                            if fixedWrong[line.id] == nil { fixedWrong[line.id] = learning.wrong }
                        }
                    ), prompt: Text(L("Right term")))
                    .labelsHidden()
                }
                if let problem = learning.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(L("From the next audit, the same mishearing gets this fix as a suggestion."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
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
