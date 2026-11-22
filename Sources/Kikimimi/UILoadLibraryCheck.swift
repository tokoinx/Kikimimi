// 保存の確認 (LIBRARY CHECK) と、そのあとの絵 (07・08・11〜13・19・20)。

import AppKit
import Foundation
import KikimimiCore

// MARK: 保存の確認 (LIBRARY CHECK)

extension LoadRun {
    /// ふだんと同じ AppModel の関数で、保存・メモ・版 (新しく・上書き・戻す)・消すを行い、フォルダを読み直して比べる。
    /// 出力の行と、失敗したかを返す
    func libraryCheck(root: URL) async -> (lines: [String], failed: Bool) {
        Self.live("library check")
        var lines: [String] = ["library: a temporary folder for this run: \(root.path)"]
        var failure: String?
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("LIBRARY: \(name): \(ok ? "ok" : "FAILED") (\(detail))")
            if !ok, failure == nil { failure = name }
        }
        let fm = FileManager.default
        let store = LibraryStore(root: root)
        let job = doneBilingual

        // 1. 終わったジョブ 2 つは、ふだんの道 (終わったジョブを一覧に入れたとき) で保存されている。文字起こし中のジョブは保存しない
        model.flushLibrary()
        let bilingualSaved = fm.fileExists(atPath: store.documentURL(for: doneBilingual.id).path)
        let plainSaved = fm.fileExists(atPath: store.documentURL(for: donePlain.id).path)
        let runningSaved = fm.fileExists(atPath: store.folder(for: running.id).path)
        step("saved by the normal path", bilingualSaved && plainSaved && !runningSaved,
             "finished (bilingual) \(bilingualSaved), finished (plain) \(plainSaved), running job \(runningSaved);"
             + " expected true, true, false")

        // 2. 行数の行の結果を、裏の列で書く時間 (ふだんの保存と同じ列・同じ書き方)
        if let writer = model.library, let document = model.snapshot(of: job) {
            let rows = document.transcript.segments.count
            let result = await writer.run { (store: LibraryStore) throws -> Double in
                let start = DispatchTime.now().uptimeNanoseconds
                try store.save(document)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            switch result {
            case .success(let ms):
                lines.append(String(format: "LIBRARY: saved %d rows in %.0f ms (background)", rows, ms))
            case .failure(let error):
                step("save \(rows) rows on the background queue", false, error.localizedDescription)
            }
        } else {
            step("save on the background queue", false, "the model has no library or the job has no transcript")
        }

        // 3. メモと版: A (新しく) → B (新しく) → C (いちばん新しい版に上書き) → A のメモだけに戻す
        let notesA = "A のメモ: have you ever は「〜したことがある」。\n"
        let notesB = "B のメモ\n"
        let notesC = "C のメモ\n"
        step("versions allowed on the finished job", model.canEditVersions(job), model.versionBlockedReason(job) ?? "allowed")
        job.notes = notesA
        let savedA = await model.saveVersion(job, label: "A", mode: .new)
        step("save version A (new)", savedA && job.versions.count == 1, "versions \(job.versions.count), expected 1")
        job.notes = notesB
        let savedB = await model.saveVersion(job, label: "B", mode: .new)
        step("save version B (new)", savedB && job.versions.count == 2, "versions \(job.versions.count), expected 2")
        job.notes = notesC
        let savedC = await model.saveVersion(job, label: "C", mode: .overwriteLatest)
        let labels = job.versions.map { $0.label }
        step("save C over the newest version", savedC && labels == ["C", "A"],
             "versions \(labels), expected [\"C\", \"A\"]")
        let transcriptBefore = job.transcript
        if let a = job.versions.first(where: { $0.label == "A" }) {
            let restored = await model.restoreVersion(job, versionID: a.id, transcript: false, notes: true)
            let newest = job.versions.first
            step("restore version A, notes only",
                 restored && job.notes == notesA && job.transcript == transcriptBefore && job.versions.count == 3
                    && newest?.origin == .beforeRestore,
                 "notes of A \(job.notes == notesA), transcript unchanged \(job.transcript == transcriptBefore),"
                 + " versions \(job.versions.count) (expected 3), newest origin \(newest.map { "\($0.origin)" } ?? "none")")
            // 自動で残した版には、戻す前のメモ (C) が入っている
            let kept = newest.flatMap { try? store.loadVersion(documentID: job.id, versionID: $0.id) }
            step("the automatic version holds the state before the restore", kept?.notes == notesC,
                 "notes \(kept.map { "\($0.notes.count) characters" } ?? "unreadable")")
        } else {
            step("restore version A, notes only", false, "version A is missing")
        }

        // 3b. 訳を直す・機械の訳に戻す (ふだんと同じ AppModel の関数で)。確認用の起動では、利用者の本物の訳の記憶を
        // 読まず・書かない (保存先が無い)。確かめる間だけ、記憶を一時のファイルにし、終わったら消して保存先を外す
        let valid = job.transcript?.validTranslationNotes.values
        let edited = valid?.filter(\.isEdited).count ?? 0
        let flagged = valid?.filter(\.isFlagged).count ?? 0
        let marked = job.transcript?.translationReview?.count ?? 0
        step("rows with edited and flagged translations", edited > 0 && flagged > 0 && edited + flagged == marked,
             "valid edited notes \(edited), flagged \(flagged) of \(marked) (expected the sum, both more than 0)")
        // 「要確認」の数は、行を作る時に数えた物 (一覧の見出しが出す数) と、結果の覚えの数が同じ
        if let transcript = job.transcript {
            let cache = TranscriptRowCache()
            let counted = cache.items(of: transcript, job: job.id, done: true, bilingual: true, query: "",
                                      target: model.translationTarget(for: transcript)).filter(\.needsTranslationReview).count
            step("count rows that need review", cache.flaggedItemIDs.count == flagged && counted == flagged,
                 "row cache \(cache.flaggedItemIDs.count), rows \(counted), notes \(flagged) (expected the same)")
        }
        // 印の付いた訳に「この訳でよい」: 印が消え、覚えの出どころが "confirmed" になる (印の符号は残る)。
        // 絵 13 のために、印の付いた行を 1 つは残す (確かめるのは 2 つめの印の行)
        let flaggedHeads = job.transcript.map { t in t.segments.map(\.id).filter { t.translationNote(for: $0)?.isFlagged == true } } ?? []
        if flaggedHeads.count >= 2 {
            let head = flaggedHeads[1]
            let confirmed = model.confirmTranslation(head: head, in: job)
            let note = job.transcript?.translationNote(for: head)
            let left = job.transcript?.flaggedTranslationCount ?? -1
            step("confirm a flagged translation through the model",
                 confirmed && note?.origin == TranslationNote.confirmed && note?.isFlagged == false
                    && note?.flags == [TranslationGate.number] && left == flaggedHeads.count - 1,
                 "confirmed \(confirmed), note \(note?.origin ?? "none"), flags \(note?.flags ?? []), "
                    + "left \(left) (expected \(flaggedHeads.count - 1))")
            // 「この訳でよい」は、その印の検査の「誤りの印」の数に 1 つ足す (保存先が無いので、数は記憶の中だけ)
            let counted = job.transcript.map { t in
                model.translationMemory.gate.first {
                    $0.check == TranslationGate.number && $0.target == model.translationTarget(for: t)
                }?.confirmed ?? 0
            } ?? 0
            step("count “this translation is fine” for the check", counted >= 1 && note?.vote == TranslationNote.confirmed,
                 "confirmed count \(counted), vote \(note?.vote ?? "none") (expected 1 or more, confirmed)")
        } else {
            step("confirm a flagged translation through the model", false,
                 "\(flaggedHeads.count) flagged rows (expected 2 or more)")
        }
        step("the self-test does not use the real translation memory", model.translationMemoryURL == nil,
             "memory file \(model.translationMemoryURL?.path ?? "none") (expected none)")
        let memoryURL = root.deletingLastPathComponent()
            .appendingPathComponent("kikimimi-ui-load-memory-\(UUID().uuidString).json")
        model.useTranslationMemory(at: memoryURL)
        if let transcript = job.transcript,
           let target = transcript.segments.first(where: { $0.translation != nil && transcript.translationNote(for: $0.id) == nil }) {
            let text = "確認用に直した訳"
            let saved = model.setTranslation(text, head: target.id, in: job)
            let note = job.transcript?.translationNote(for: target.id)
            let remembered = TranslationMemory.load(from: memoryURL).sentences
            step("edit a translation through the model",
                 saved && note?.isEdited == true && note?.machine == target.translation
                    && remembered.count == 1 && remembered.first?.translation == text,
                 "saved \(saved), note \(note?.origin ?? "none"), memory \(remembered.count) (expected 1)")
            // 直した訳の再利用: 写しの上でその文の訳を外し、記憶だけで訳し直す (LLM は使わない: generator は nil)。
            // 記憶に在る文は訳が入り、覚えが "memory" になる。ジョブの結果は変えない
            if let current = job.transcript {
                var copy = current
                copy.segments = Translator.clearingTranslations(of: [target.id], in: current.segments)
                copy.translationReview = nil
                let sources = Dictionary(copy.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                var results: [TranslationResult] = []
                let summary = try? Translator.translateSummarizing(
                    copy.segments, language: copy.language, target: model.translationTarget(for: current), only: [target.id],
                    memory: model.translationMemory.lookup(target: model.translationTarget(for: current)), generator: nil,
                    shouldCancel: { false }) { batch, _, _ in results += batch }
                for result in results { copy.apply(result, sources: sources) }
                let reused = copy.segments.first { $0.id == target.id }?.translation
                let reusedNote = copy.translationNote(for: target.id)
                step("reuse a remembered translation without the LLM",
                     summary?.fromMemory == 1 && summary?.sentToLLM == 0 && reused == text && reusedNote?.isRemembered == true,
                     "from memory \(summary?.fromMemory ?? -1), sent \(summary?.sentToLLM ?? -1), "
                        + "note \(reusedNote?.origin ?? "none") (expected 1, 0, memory)")
            }
            model.revertTranslation(head: target.id, in: job)
            let restored = job.transcript?.segments.first { $0.id == target.id }?.translation
            let after = TranslationMemory.load(from: memoryURL).sentences
            step("restore the machine translation through the model",
                 restored == target.translation && job.transcript?.translationNote(for: target.id) == nil && after.isEmpty,
                 "restored \(restored == target.translation), memory \(after.count) (expected 0)")
        } else {
            step("edit a translation through the model", false, "no translated row without a note")
        }
        // 関門が判定から学ぶ: 「この訳でよい」を 5 回数えると、その検査 (数の抜け) が、その訳す先で止まる。
        // [元に戻す] で数を 0 に戻すと、また印を出す (一時の記憶のファイルで。結果の一覧には触らない)
        if let transcript = job.transcript {
            let gateTarget = model.translationTarget(for: transcript)
            for _ in 0..<TranslationMemory.gateMinimumJudgements {
                model.countGateVote(flags: [TranslationGate.number], target: gateTarget, confirmed: 1)
            }
            let stopped = model.translationMemory.suppressedChecks(target: gateTarget)
            let lookup = model.translationMemory.lookup(target: gateTarget, reuse: false)
            step("a check stops after five “this translation is fine”",
                 stopped == [TranslationGate.number] && lookup?.suppressedChecks == [TranslationGate.number]
                    && model.translationMemory.suppressedGate.count == 1,
                 "suppressed \(stopped.sorted()), lookup \(lookup?.suppressedChecks.sorted() ?? []), "
                    + "listed \(model.translationMemory.suppressedGate.count) (expected number, number, 1)")
            model.resetGateCheck(TranslationGate.number, target: gateTarget)
            let saved = TranslationMemory.load(from: memoryURL)
            step("undo a stopped check",
                 model.translationMemory.suppressedChecks(target: gateTarget).isEmpty && saved.gate.isEmpty
                    && model.translationMemory.lookup(target: gateTarget, reuse: false) == nil,
                 "suppressed \(model.translationMemory.suppressedChecks(target: gateTarget).sorted()), "
                    + "saved counts \(saved.gate.count) (expected none)")
        }
        model.useTranslationMemory(at: nil)
        try? fm.removeItem(at: memoryURL)

        // 3c. 聞き取った文を直す・戻す (ふだんと同じ AppModel の関数で)
        lineEditSteps(job: job, root: root, step: step)

        // 4. 書き終えてから、新しい LibraryStore で読み直して比べる
        model.flushLibrary()
        if let loaded = LibraryStore(root: root).load(id: job.id) {
            let sameID = loaded.id == job.id
            let sameTranscript = loaded.transcript == job.transcript
            let sameNotes = loaded.notes == job.notes
            let sameVersions = loaded.versions.map { $0.id } == job.versions.map { $0.id }
            step("reload with a fresh LibraryStore", sameID && sameTranscript && sameNotes && sameVersions,
                 "id \(sameID), transcript equal \(sameTranscript), notes equal \(sameNotes),"
                 + " versions \(loaded.versions.count) of \(job.versions.count) in the same order \(sameVersions)")
        } else {
            step("reload with a fresh LibraryStore", false, "document.json could not be read")
        }

        // 5. 小さなジョブを、モデルから消す: フォルダが無くなる
        let small = Job(name: "消す確認 (確認用)", url: nil)
        small.transcript = Transcript(sourceName: small.name, segments: UILoadSelfTest.makeSegments(0..<10),
                                      language: "en", duration: 10 * UILoadSelfTest.rowSpacing, elapsed: 1)
        small.status = .done
        small.progress = 1
        small.message = "完了"
        model.adopt(small, at: model.jobs.count)
        model.flushLibrary()
        let existed = fm.fileExists(atPath: store.folder(for: small.id).path)
        // 確かめの画面に出す計画: ゴミ箱に入れるフォルダは、このあと無くなるフォルダと同じ
        let plan = model.deletionPlan(for: small)
        let expectedFolder = store.folder(for: small.id).standardizedFileURL
        let planned = plan.libraryFolder?.standardizedFileURL
        step("the deletion plan names the folder that is removed", planned == expectedFolder && plan.recording == nil,
             "planned \(planned?.path ?? "none"), expected \(expectedFolder.path), recording \(plan.recording?.path ?? "none")")
        model.delete(small)
        model.flushLibrary()
        let remains = fm.fileExists(atPath: store.folder(for: small.id).path)
        let listed = model.jobs.contains { $0 === small }
        step("delete a small job through the model", existed && !remains && !listed,
             "folder before \(existed), after \(remains), still listed \(listed)")

        lines.append(failure.map { "LIBRARY CHECK FAILED: \($0)" } ?? "LIBRARY CHECK OK")
        return (lines, failure != nil)
    }

    /// 保存の確認の段 3c: 訳の在る 1 行 (監査の直し・訳の覚え・ほかの区間との訳のまとまりが無い行) を直し、
    /// 文・記録・訳・保存・一覧の行を見てから戻す。終わりに、訳を元の訳に置き直し、結果を直す前と同じにする
    /// (ほかの段と絵が使う結果を変えない)
    private func lineEditSteps(job: Job, root: URL, step: (String, Bool, String) -> Void) {
        guard let before = job.transcript,
              let original = before.segments.first(where: { s in
                  s.translation != nil && (s.translationCovers ?? []).isEmpty && !before.coveredIDs.contains(s.id)
                      && before.audit?.change(forSegment: s.id) == nil && before.translationNote(for: s.id) == nil
              }) else {
            step("edit a line through the model", false, "no translated row without an audit change or a note")
            return
        }
        let id = original.id
        // 英語の行なので、英語で直す (日本語で直すと、訳す要らない行になり、行の「訳」が出ない)
        let text = "A line edited by the self-test."
        let saved = model.setLineText(text, segment: id, in: job)
        let now = job.transcript?.segments.first { $0.id == id }
        let edit = job.transcript?.lineEdit(forSegment: id)
        step("edit a line through the model",
             saved && now?.text == text && edit?.heard == original.text && edit?.edited == text,
             "saved \(saved), text changed \(now?.text == text), heard kept \(edit?.heard == original.text)")
        step("editing a line removes its translation", now?.translation == nil && now != nil,
             "translation \(now?.translation == nil ? "removed" : "still there")")
        // 新しい LibraryStore で読み直すと、直した文と記録が同じ
        model.flushLibrary()
        let loaded = LibraryStore(root: root).load(id: job.id)?.transcript
        step("reload an edited line with a fresh LibraryStore",
             loaded != nil && loaded == job.transcript && loaded?.lineEdit(forSegment: id) == edit,
             "read \(loaded != nil), transcript equal \(loaded == job.transcript)")
        // 一覧の行 (単言語・対訳の両方) に、聞き取った文が出る
        if let transcript = job.transcript {
            let target = model.translationTarget(for: transcript)
            let plain = TranscriptRowCache().items(of: transcript, job: job.id, done: true, bilingual: false, query: "",
                                                   target: target).first { $0.id == id }
            let bilingual = TranscriptRowCache().items(of: transcript, job: job.id, done: true, bilingual: true, query: "",
                                                       target: target).first { $0.editSegmentIDs.contains(id) }
            step("the list row shows the edited line",
                 plain?.heard == original.text && bilingual?.heard == original.text && plain?.canTranslate == true,
                 "plain \(plain?.heard == original.text), bilingual \(bilingual?.heard == original.text), "
                    + "translate button \(plain?.canTranslate ?? false)")
        }
        let reverted = model.revertLineEdit(id, in: job)
        let back = job.transcript?.segments.first { $0.id == id }
        step("restore the heard text through the model",
             reverted && back?.text == original.text && job.transcript?.lineEdit(forSegment: id) == nil
                && job.transcript?.lineEdits == nil,
             "reverted \(reverted), text back \(back?.text == original.text), records \(job.transcript?.lineEdits?.count ?? 0)")
        // 訳を元の訳に置き直す (戻しても訳は消えたまま。ほかの段のために、確認用にだけ置き直す)
        if var t = job.transcript, let i = t.segments.firstIndex(where: { $0.id == id }) {
            t.segments[i].translation = original.translation
            t.segments[i].translationCovers = original.translationCovers
            job.transcript = t
        }
        step("the job is the same as before the line edit", job.transcript == before,
             "same \(job.transcript == before)")
        groupedLineEditSteps(job: job, step: step)
    }

    /// 2 つの区間を 1 つの訳のまとまりにできる所: 訳の在る区間 (監査の直し・訳の覚え・ほかの区間との訳のまとまりが無い) と、
    /// そのすぐ後ろの訳の無い区間 (監査の直し・覚えが無く、ほかの訳に含まれていない)。位置は先の区間の物。
    /// 確認用の結果には、いくつかの区間から成る訳のまとまりが無いので、確かめる間だけ作る
    static func groupablePair(in t: Transcript) -> (head: TranscriptSegment, next: TranscriptSegment, index: Int)? {
        let covered = t.coveredIDs
        func plain(_ s: TranscriptSegment) -> Bool {
            (s.translationCovers ?? []).isEmpty && !covered.contains(s.id) && t.audit?.change(forSegment: s.id) == nil
                && t.translationNote(for: s.id) == nil
        }
        for i in t.segments.indices.dropLast() {
            let head = t.segments[i], next = t.segments[i + 1]
            if head.translation != nil, next.translation == nil, plain(head), plain(next) { return (head, next, i) }
        }
        return nil
    }

    /// 保存の確認の段 3d: 2 つの区間から成る対訳の行を作り、2 つ目の区間を model を通して直して戻す。
    /// 終わりに、まとまりを外し、結果を前と同じにする
    private func groupedLineEditSteps(job: Job, step: (String, Bool, String) -> Void) {
        guard let before = job.transcript, let pair = Self.groupablePair(in: before) else {
            step("a bilingual row of two segments lists both", false, "no pair of rows to group")
            return
        }
        let (head, next, index) = pair
        let ids = [head.id, next.id]
        // 2 つの区間を 1 つの訳のまとまりにする (訳し直して、文がまとまった形)
        func group() {
            guard var t = job.transcript else { return }
            t.segments[index].translation = head.translation
            t.segments[index].translationCovers = [next.id]
            job.transcript = t
        }
        func row() -> TranscriptListItem? {
            guard let t = job.transcript else { return nil }
            return TranscriptRowCache().items(of: t, job: job.id, done: true, bilingual: true, query: "",
                                              target: model.translationTarget(for: t)).first { $0.id == head.id }
        }
        group()
        let first = row()
        step("a bilingual row of two segments lists both", first?.segmentIDs == ids && first?.heard == nil,
             "segments \(first?.segmentIDs?.count ?? 0) (expected 2), edited \(first?.isEditedLine ?? false)")
        let text = "確認用に直した 2 つ目の区間"
        let saved = model.setLineTexts([next.id: text], in: job)
        let split = job.transcript?.segments[index].translation == nil
        group()
        let edited = row()
        step("edit the second segment of a bilingual row through the model",
             saved && split && edited?.segmentIDs == ids && edited?.text == Transcript.join([head.text, text])
                && edited?.heard == Transcript.join([head.text, next.text]),
             "saved \(saved), translation removed \(split), segments \(edited?.segmentIDs?.count ?? 0), "
                + "edited \(edited?.isEditedLine ?? false)")
        let reverted = model.revertLineEdits(ids, in: job)
        if var t = job.transcript {
            t.segments[index].translation = head.translation
            t.segments[index].translationCovers = head.translationCovers
            job.transcript = t
        }
        step("restore the second segment and put the job back",
             reverted && job.transcript == before && job.transcript?.lineEdits == nil,
             "reverted \(reverted), same as before \(job.transcript == before)")
    }

    /// 保存の確認のあとの絵: 07 メモの欄、08 履歴の画面、11 ゴミ箱に入れるかの確かめの画面
    /// (08 と 11 は、シートのウインドウそのものを撮る。メインのウインドウを描いても、シートは入らない)
    func takeLibraryScreenshots(into directory: URL) async -> [String] {
        guard let window = MainWindow.all().first(where: { $0.isVisible }) else {
            return ["UI LOAD: screenshot failed (07, 08): no visible main window"]
        }
        var lines: [String] = []
        let job = doneBilingual
        let wasShowingNotes = model.showNotes

        // 7. 終わったジョブ (対訳) で、メモの欄を出したところ (引用した行を 1 つ含むメモ)
        Self.live("scene 07: the notes pane")
        model.select(job)
        var notes = "have you ever ＝「〜したことがある」。経験をたずねるときの言い方。\n\n聞き取れなかった所: 3 行目の後半。\n"
        if let segment = job.transcript?.segments.first {
            notes = NoteQuote.appending(NoteQuote.line(time: segment.start, text: segment.text), to: notes)
        }
        job.notes = notes
        model.showNotes = true
        await settle()
        lines += await scroll(to: job.transcript?.segments.first?.id, .top, for: "07")
        lines.append(shot("07-notes-pane", in: window, to: directory))

        // 8. 同じジョブの履歴の画面 (版が 3 つ以上で、1 つは自動で残したもの)
        Self.live("scene 08: the history sheet")
        if job.versions.count < 3 || !job.versions.contains(where: { $0.origin == .beforeRestore }) {
            lines.append("UI LOAD: screenshot 08-history-sheet.png: the job has \(job.versions.count) versions"
                         + " (expected 3 or more, one automatic)")
        }
        model.historyJobID = job.id
        await settle()
        // シートが出きるまで待つ
        await UILoadSelfTest.sleep(0.6)
        await settle()
        if let sheet = window.attachedSheet {
            lines.append(shot("08-history-sheet", in: sheet, to: directory))
        } else {
            lines.append("UI LOAD: screenshot failed 08-history-sheet.png: the history sheet is not shown")
        }
        model.historyJobID = nil
        await settle()
        // 履歴の画面が閉じきるまで待つ (次のシートを出せるように)
        await UILoadSelfTest.sleep(0.6)
        await settle()

        // 12. 同じジョブの、訳を直す画面 (直した訳の行を開いたところ。機械の訳と「機械の訳に戻す」が出る)。撮ったら閉じる
        Self.live("scene 12: the translation edit sheet")
        if let head = job.transcript?.translationReview?.first(where: \.isEdited)?.head {
            model.requestTranslationEdit(head, in: job)
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
            if let sheet = window.attachedSheet, model.translationEdit != nil {
                lines.append(shot("12-translation-edit", in: sheet, to: directory))
            } else {
                lines.append("UI LOAD: screenshot failed 12-translation-edit.png: the translation edit sheet is not shown")
            }
            model.translationEdit = nil
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
        } else {
            lines.append("UI LOAD: screenshot failed 12-translation-edit.png: no edited translation in the job")
        }

        // 13. 同じジョブの、「要確認」の行を開いた訳を直す画面 (上に理由の行と、「この訳でよい」が出る)。撮ったら閉じる
        Self.live("scene 13: the translation edit sheet of a flagged row")
        if let transcript = job.transcript,
           let head = transcript.segments.first(where: { transcript.translationNote(for: $0.id)?.isFlagged == true })?.id {
            model.requestTranslationEdit(head, in: job)
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
            if let sheet = window.attachedSheet, model.translationEdit != nil {
                lines.append(shot("13-translation-check", in: sheet, to: directory))
            } else {
                lines.append("UI LOAD: screenshot failed 13-translation-check.png: the translation edit sheet is not shown")
            }
            model.translationEdit = nil
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
        } else {
            lines.append("UI LOAD: screenshot failed 13-translation-check.png: no flagged translation in the job")
        }

        // 19. 同じジョブの、行を直す画面 (直した行を開いたところ。聞き取った文・「聞き取った文に戻す」・訳が消える注意が出る)。
        // 直した後に訳し直した行の形にする (確認用に、元の訳を置き直す)。撮ったら閉じ、直しを戻して、結果を前と同じにする
        Self.live("scene 19: the line edit sheet")
        if let before = job.transcript,
           let original = before.segments.first(where: { s in
               s.translation != nil && (s.translationCovers ?? []).isEmpty && !before.coveredIDs.contains(s.id)
                   && before.audit?.change(forSegment: s.id) == nil && before.translationNote(for: s.id) == nil
           }),
           model.setLineText(original.text + " (edited)", segment: original.id, in: job),
           var edited = job.transcript, let i = edited.segments.firstIndex(where: { $0.id == original.id }) {
            edited.segments[i].translation = original.translation
            job.transcript = edited
            model.requestLineEdit([original.id], in: job)
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
            if let sheet = window.attachedSheet, model.lineEdit != nil {
                lines.append(shot("19-line-edit", in: sheet, to: directory))
            } else {
                lines.append("UI LOAD: screenshot failed 19-line-edit.png: the line edit sheet is not shown")
            }
            model.lineEdit = nil
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
            model.revertLineEdit(original.id, in: job)
            if var t = job.transcript, let k = t.segments.firstIndex(where: { $0.id == original.id }) {
                t.segments[k].translation = original.translation
                t.segments[k].translationCovers = original.translationCovers
                job.transcript = t
            }
            if job.transcript != before {
                lines.append("UI LOAD: screenshot 19-line-edit.png: the job was not put back as it was")
            }
        } else {
            lines.append("UI LOAD: screenshot failed 19-line-edit.png: no translated row to edit")
        }

        // 20. 同じジョブの、2 つの区間から成る対訳の行の、行を直す画面 (2 つ目の区間を直して、訳し直した形。
        // 区間ごとの時刻と入力欄、直した区間の聞き取った文)。撮ったら閉じ、直しとまとまりを外して、結果を前と同じにする
        Self.live("scene 20: the line edit sheet of a row of two segments")
        if let before = job.transcript, let (head, next, index) = Self.groupablePair(in: before),
           model.setLineTexts([next.id: next.text + "（確認用に直した）"], in: job),
           var grouped = job.transcript {
            grouped.segments[index].translation = head.translation
            grouped.segments[index].translationCovers = [next.id]
            job.transcript = grouped
            model.requestLineEdit([head.id, next.id], in: job)
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
            if let sheet = window.attachedSheet, model.lineEdit != nil {
                lines.append(shot("20-line-edit-two-segments", in: sheet, to: directory))
            } else {
                lines.append("UI LOAD: screenshot failed 20-line-edit-two-segments.png: the line edit sheet is not shown")
            }
            model.lineEdit = nil
            await settle()
            await UILoadSelfTest.sleep(0.6)
            await settle()
            model.revertLineEdits([head.id, next.id], in: job)
            if var t = job.transcript {
                t.segments[index].translation = head.translation
                t.segments[index].translationCovers = head.translationCovers
                job.transcript = t
            }
            if job.transcript != before {
                lines.append("UI LOAD: screenshot 20-line-edit-two-segments.png: the job was not put back as it was")
            }
        } else {
            lines.append("UI LOAD: screenshot failed 20-line-edit-two-segments.png: no pair of rows to group")
        }

        // 11. 同じジョブの、ゴミ箱に入れるかの確かめの画面 (保存した結果と、残る元の音声ファイル)。
        // 撮ったら閉じる (このジョブは消さない)
        Self.live("scene 11: the delete confirmation sheet")
        let plan = model.deletionPlan(for: job)
        if plan.libraryFolder == nil || plan.keptAudio == nil {
            lines.append("UI LOAD: screenshot 11-delete-confirm.png: the plan has folder \(plan.libraryFolder != nil),"
                         + " kept audio \(plan.keptAudio != nil) (expected both)")
        }
        model.requestDelete(job)
        await settle()
        await UILoadSelfTest.sleep(0.6)
        await settle()
        if let sheet = window.attachedSheet, model.pendingDeleteJobID == job.id {
            lines.append(shot("11-delete-confirm", in: sheet, to: directory))
        } else {
            lines.append("UI LOAD: screenshot failed 11-delete-confirm.png: the delete confirmation sheet is not shown")
        }
        model.pendingDeleteJobID = nil
        await settle()
        await UILoadSelfTest.sleep(0.6)
        await settle()
        if model.showNotes != wasShowingNotes { model.showNotes = wasShowingNotes }
        return lines
    }
}
