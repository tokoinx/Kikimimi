// 訳し直しの確認 (RETRANSLATE CHECK): 結果の画面の「〇〇語で訳し直す」の道 (AppModel.retranslate) を、
// LLM の代わり (決まった訳を返す生成器) で、最後まで通す。

import Foundation
import KikimimiCore

extension LoadRun {
    /// ふだんと同じ AppModel の関数で、訳の付いた結果を「別の言語で訳し直す」。
    /// LLM が無い時は何も変えずに知らせを出す事、LLM が在る時は、訳し直す前の状態が自動の版として 1 つだけ残り
    /// (メモリの上とディスクの上の両方)、訳が新しい言語の訳に置きかわる事、「いちばん新しい版に上書き」の相手が
    /// 自分で残した版のままである事を見る。
    /// 本物の設定・ライブラリには書かない: 結果は確認用のライブラリ (一時のフォルダ) に入れ、終わりに消す。
    /// LLM が在る事にするのも、LLM の代わりを入れるのも、この確認の間だけ (終わりに元に戻す)。
    /// 出力の行と、失敗したかを返す
    func retranslateCheck(root: URL) async -> (lines: [String], failed: Bool) {
        Self.live("retranslate check")
        var lines: [String] = []
        var failure: String?
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("RETRANSLATE: \(name): \(ok ? "ok" : "FAILED") (\(detail))")
            if !ok, failure == nil { failure = name }
        }
        // 確認の間だけ変える物の、始める前の値
        let installedBefore = model.installedLLMIDs
        let customBefore = model.customLLMFiles
        let errorBefore = model.errorMessage
        let selectedBefore = model.selectedJob
        let standIn = RetranslateStandIn()
        var made: Job?
        var failing: Job?
        var lineJob: Job?
        var editedJob: Job?
        let settingBefore = model.translationLanguage
        defer {
            // 変えた物を、始める前と同じに戻す (途中で失敗して戻った時も)
            model.llm.selfTestGenerator = nil
            model.installedLLMIDs = installedBefore
            model.customLLMFiles = customBefore
            model.errorMessage = errorBefore
            model.translationLanguage = settingBefore
            model.select(selectedBefore)
            if let made { model.delete(made) }
            if let failing { model.delete(failing) }
            if let lineJob { model.delete(lineJob) }
            if let editedJob { model.delete(editedJob) }
            model.flushLibrary()
        }

        // 1. 訳 (英語) の付いた、終わった結果を作り、保存されるのを待って、自分で残した版を 1 つ残す
        let sources = [
            "今日は確認用の短い録音です。",
            "訳し直す前の訳を、版に残します。",
            "新しい言語で、もう一度訳します。",
            "最後に、元に戻して片付けます。",
        ]
        let before = [
            "This is a short recording for the check.",
            "The translation before translating again is kept as a version.",
            "It is translated again into a new language.",
            "At the end, everything is put back and cleaned up.",
        ]
        let oldLanguage = "en", newLanguage = "fr"
        let job = makeTranslatedJob("Retranslate check (self-test)", sources: sources, translations: before,
                                    language: "ja", translationLanguage: oldLanguage)
        made = job
        model.select(job)
        model.flushLibrary()
        let store = LibraryStore(root: root)
        let savedNormally = FileManager.default.fileExists(atPath: store.documentURL(for: job.id).path)
        step("the translated result is saved", savedNormally && model.canEditVersions(job),
             "document.json \(savedNormally), versions allowed \(model.versionBlockedReason(job) ?? "yes")")
        let manualSaved = await model.saveVersion(job, label: "Manual version (self-test)", mode: .new)
        let manualID = job.versions.first?.id
        step("save a manual version", manualSaved && job.versions.count == 1 && job.versions.first?.origin == .manual,
             "saved \(manualSaved), versions \(job.versions.map { "\($0.origin)" }) (expected [manual])")
        guard let manualID else { return finishRetranslate(lines, failure: failure ?? "save a manual version") }
        let transcriptBefore = job.transcript

        // 2. LLM が無い時: 訳し直しを頼んでも、版は増えず、訳も変わらず、知らせが出る
        model.installedLLMIDs = []
        model.customLLMFiles = []
        model.errorMessage = nil
        let installedWithout = model.isLLMInstalled
        model.retranslate(job, into: newLanguage)
        // 版を残す仕事は Task の中なので、少し待ってから見る (LLM が無ければ、Task は始まらないはず)
        await UILoadSelfTest.sleep(0.5)
        let message = model.errorMessage
        step("without the LLM nothing changes and a message is shown",
             !installedWithout && job.versions.count == 1 && job.transcript == transcriptBefore
                && !(message ?? "").isEmpty && job.postQueue.isEmpty && job.postState == .idle,
             "LLM installed \(installedWithout), versions \(job.versions.count) (expected 1), "
                + "transcript unchanged \(job.transcript == transcriptBefore), message \(message.map { "\"\($0)\"" } ?? "none")")
        model.errorMessage = nil

        // 3. LLM が在る事にして (今の LLM の ID を、確認の間だけ入れる)、LLM の代わりで、別の言語へ訳し直す
        let current = model.currentLLM
        if let spec = current.spec {
            model.installedLLMIDs = installedBefore.union([spec.id])
        } else {
            model.customLLMFiles = customBefore + [current.url.lastPathComponent]
        }
        let answers = Dictionary(uniqueKeysWithValues: sources.enumerated().map {
            ($0.element, "Phrase retraduite pour le controle, ligne \(["un", "deux", "trois", "quatre"][$0.offset]).")
        })
        standIn.configure(answers: answers)
        model.llm.selfTestGenerator = standIn
        step("the LLM counts as installed for the check", model.isLLMInstalled,
             "current LLM \(current.name), installed \(model.isLLMInstalled)")
        model.retranslate(job, into: newLanguage)

        // 4. 自動の版が残り、翻訳の仕事が終わるまで待つ (20 秒まで)
        var versionSeen = false
        for _ in 0..<400 {
            if job.versions.contains(where: { $0.origin != .manual }) {
                versionSeen = true
                break
            }
            await UILoadSelfTest.sleep(0.05)
        }
        var finished = false
        if versionSeen {
            for _ in 0..<400 {
                if job.postQueue.isEmpty && job.postState == .idle && !job.versionBusy
                    && job.transcript?.translationLanguage == newLanguage && job.transcript?.hasTranslation == true {
                    finished = true
                    break
                }
                await UILoadSelfTest.sleep(0.05)
            }
        }
        step("retranslate through the model with the stand-in", versionSeen && finished && standIn.calls > 0,
             "automatic version seen \(versionSeen), translation finished \(finished), stand-in calls \(standIn.calls)")

        // (a) 訳し直す前の版が、メモリの上とディスクの上に 1 つだけ在る
        model.flushLibrary()
        let auto = job.versions.filter { $0.origin == .beforeRetranslation }
        let loaded = store.load(id: job.id)
        let autoOnDisk = loaded?.versions.filter { $0.origin == .beforeRetranslation } ?? []
        let versionFile = auto.first.map { store.versionURL(documentID: job.id, versionID: $0.id) }
        let fileExists = versionFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        step("one version before translating again, in memory and on disk",
             auto.count == 1 && autoOnDisk.count == 1 && autoOnDisk.first?.id == auto.first?.id && fileExists
                && job.versions.count == 2,
             "in memory \(auto.count), on disk \(autoOnDisk.count) (expected 1, 1), version file \(fileExists), "
                + "origins \(job.versions.map { "\($0.origin)" }) (expected [beforeRetranslation, manual])")

        // (b) その版の中身は、訳し直す前の訳と、前の訳した言語
        var versionTranslations: [String?] = []
        var versionLanguage: String?
        if let id = auto.first?.id, let version = try? store.loadVersion(documentID: job.id, versionID: id) {
            versionTranslations = version.transcript.segments.map(\.translation)
            versionLanguage = version.transcript.translationLanguage
        }
        step("the version keeps the translation before translating again",
             versionTranslations == before.map { Optional($0) } && versionLanguage == oldLanguage,
             "language \(versionLanguage ?? "none") (expected \(oldLanguage)), "
                + "translations \(versionTranslations == before.map { Optional($0) } ? "the same" : "\(versionTranslations)")")

        // (c) 翻訳の後: 訳した言語は新しい言語で、行の訳は LLM の代わりの答え (前の訳は残っていない)
        let after = job.transcript?.segments ?? []
        let expected = after.map { answers[$0.text] }
        let leftovers = after.filter { segment in before.contains { $0 == segment.translation } }.count
        step("the result is translated into the new language",
             job.transcript?.translationLanguage == newLanguage && after.count == sources.count
                && after.map(\.translation) == expected && !expected.contains(nil) && leftovers == 0,
             "language \(job.transcript?.translationLanguage ?? "none") (expected \(newLanguage)), "
                + "rows with the stand-in's translation \(zip(after.map(\.translation), expected).filter { $0.0 == $0.1 && $0.1 != nil }.count)"
                + " of \(sources.count), rows with the old translation \(leftovers)")

        // (d) 「いちばん新しい版に上書き」の相手は、自分で残した版のまま (自動の版ではない)
        let latestInMemory = model.snapshot(of: job)?.latestManualVersion?.id
        let latestOnDisk = loaded?.latestManualVersion?.id
        step("overwrite the newest version still means the manual version",
             latestInMemory == manualID && latestOnDisk == manualID,
             "in memory \(latestInMemory == manualID ? "the manual version" : latestInMemory?.uuidString ?? "none"), "
                + "on disk \(latestOnDisk == manualID ? "the manual version" : latestOnDisk?.uuidString ?? "none")")

        // (e) 履歴の画面の、自動の版の印
        let badge = HistorySheet.automaticBadge(for: .beforeRetranslation)
        let manualBadge = HistorySheet.automaticBadge(for: .manual)
        step("the history sheet marks the version as automatic",
             badge == L("Automatic (before translating again)") && manualBadge == nil,
             "badge \(badge ?? "none"), manual \(manualBadge ?? "none")")

        // 6. 翻訳の途中で LLM が失敗した時 (llama.cpp の失敗 -1 を、LLM の代わりが投げる)。
        // 半分だけ訳の在る別の結果を「翻訳」する: 失敗の知らせが出て、訳は変わらず、仕事が終わった状態に戻る。
        // そのあと、ふつうに答える LLM の代わりで「翻訳」すると、残りの行が訳される (止まったままにならない)
        let failSources = [
            "Please water the plants on Friday.",
            "Seven people joined the call from Osaka.",
            "The bridge downtown closes at midnight.",
            "Lunch will be served in the north hall.",
        ]
        let failBefore: [String?] = ["Arrosez les plantes vendredi.", nil, "Le pont ferme a minuit.", nil]
        let half = makeTranslatedJob("Translate failure check (self-test)", sources: failSources, translations: failBefore,
                                     language: "en", translationLanguage: "fr")
        failing = half
        let failAnswers = [
            failSources[1]: "Sept personnes ont rejoint l'appel depuis Osaka.",
            failSources[3]: "Le dejeuner sera servi dans la salle nord.",
        ]
        func idle(_ job: Job) -> Bool { job.postQueue.isEmpty && job.postState == .idle && !job.isPostActive }
        func waitIdle(_ job: Job) async -> Bool {
            for _ in 0..<400 {
                if idle(job) { return true }
                await UILoadSelfTest.sleep(0.05)
            }
            return false
        }
        let halfBefore = half.transcript
        let failuresBefore = standIn.failures
        standIn.configure(answers: failAnswers, failAfter: 0)
        model.translate(half)
        let finishedFailing = await waitIdle(half)
        let note = half.postNote ?? ""
        let error = LLMError.decodeFailed(-1).localizedDescription
        step("LLM fails while translating: the error is shown and nothing changes",
             finishedFailing && standIn.failures > failuresBefore
                && note == L("Could not translate: %@", error) && note.contains("-1")
                && half.transcript == halfBefore,
             "finished \(finishedFailing), idle \(idle(half)), failures \(standIn.failures - failuresBefore), "
                + "transcript unchanged \(half.transcript == halfBefore), note \"\(note)\"")

        let callsBefore = standIn.calls
        standIn.configure(answers: failAnswers)
        model.translate(half)
        let finishedAgain = await waitIdle(half)
        let translated = half.transcript?.segments.map(\.translation) ?? []
        let expectedAfter: [String?] = [failBefore[0], failAnswers[failSources[1]], failBefore[2], failAnswers[failSources[3]]]
        let noteAgain = half.postNote ?? ""
        step("the next translation with a working LLM finishes",
             finishedAgain && standIn.calls > callsBefore && translated == expectedAfter
                && !noteAgain.contains(error) && half.transcript?.translationLanguage == "fr",
             "finished \(finishedAgain), stand-in calls \(standIn.calls - callsBefore), "
                + "translations \(translated == expectedAfter ? "as expected" : "\(translated)"), note \"\(noteAgain)\"")

        // 7. 訳の無い結果で行の「訳」を押し、訳し始める前に設定の言語を変える: 待っている文は、押した時の言語で訳す。
        // 設定の言語は確認の間だけ変える (確認用の起動では、SettingsWriter が本物の設定に書かない。終わりに元に戻す)
        let lineSources = ["The library opens at nine.", "Bring your own cup, please."]
        let plain = makeTranslatedJob("Line language check (self-test)", sources: lineSources, translations: [nil, nil],
                                      language: "en", translationLanguage: nil)
        lineJob = plain
        let lineAnswer = "La bibliotheque ouvre a neuf heures."
        standIn.configure(answers: [lineSources[0]: lineAnswer])
        let clickLanguage = "fr", laterLanguage = "de"
        model.translationLanguage = clickLanguage
        if let first = plain.transcript?.segments.first?.id {
            model.translateLine(first, in: plain)
        }
        // 仕事は、この後に Task の中で始まる。その前に設定の言語を変える
        model.translationLanguage = laterLanguage
        let finishedLine = await waitIdle(plain)
        let lineTranslations = plain.transcript?.segments.map(\.translation) ?? []
        step("a language change after the click does not change the queued line's language",
             finishedLine && plain.transcript?.translationLanguage == clickLanguage
                && lineTranslations == [lineAnswer, nil] && plain.lineQueue.isEmpty,
             "finished \(finishedLine), language \(plain.transcript?.translationLanguage ?? "none") (expected \(clickLanguage), "
                + "setting \(model.translationLanguage)), translations \(lineTranslations == [lineAnswer, nil] ? "as expected" : "\(lineTranslations)")")
        model.translationLanguage = settingBefore

        // 8. 直した訳の文で「この文を訳し直す」を押し、LLM が失敗した: 直した訳も、印「直した」も残る。
        // そのあと、ふつうに答える LLM の代わりで訳し直すと、今までと同じく機械の訳になり、印は消える
        let editSources = ["The museum is closed on Mondays.", "Tickets are sold at the gate."]
        let edited = makeTranslatedJob("Edited redo check (self-test)", sources: editSources,
                                       translations: ["Le musee est ferme le lundi.", "Les billets sont vendus a l'entree."],
                                       language: "en", translationLanguage: "fr")
        editedJob = edited
        let own = "Le musee ferme ses portes chaque lundi."
        var mark = false
        if var t = edited.transcript, let first = t.segments.first?.id {
            mark = t.setUserTranslation(own, for: first)?.isEdited == true
            edited.transcript = t
            standIn.configure(answers: [:], failAfter: 0)
            model.translateLine(first, in: edited, redo: true)
        }
        let finishedRedo = await waitIdle(edited)
        let redoNote = edited.postNote ?? ""
        let head = edited.transcript?.segments.first
        let keptMark = head.flatMap { edited.transcript?.translationNote(for: $0.id) }?.isEdited == true
        step("a failed translate-again keeps the edited translation and its Edited mark",
             mark && finishedRedo && head?.translation == own && keptMark && redoNote == L("Could not translate: %@", error),
             "marked \(mark), finished \(finishedRedo), translation \(head?.translation == own ? "the edited one" : head?.translation ?? "none"), "
                + "Edited mark \(keptMark), note \"\(redoNote)\"")
        let redoAnswer = "Le musee est ferme tous les lundis."
        standIn.configure(answers: [editSources[0]: redoAnswer])
        if let first = edited.transcript?.segments.first?.id {
            model.translateLine(first, in: edited, redo: true)
        }
        let finishedRedoAgain = await waitIdle(edited)
        let headAgain = edited.transcript?.segments.first
        let markAgain = headAgain.flatMap { edited.transcript?.translationNote(for: $0.id) }?.isEdited == true
        step("a working translate-again replaces the edited translation as before",
             finishedRedoAgain && headAgain?.translation == redoAnswer && !markAgain,
             "finished \(finishedRedoAgain), translation \(headAgain?.translation ?? "none") (expected \(redoAnswer)), Edited mark \(markAgain)")
        return finishRetranslate(lines, failure: failure)
    }

    private func finishRetranslate(_ lines: [String], failure: String?) -> (lines: [String], failed: Bool) {
        (lines + [failure.map { "RETRANSLATE CHECK FAILED: \($0)" } ?? "RETRANSLATE CHECK OK"], failure != nil)
    }

    /// 確認用の、訳の付いた終わった結果を作って、モデルに入れる (確認用のライブラリに保存される)
    private func makeTranslatedJob(_ name: String, sources: [String], translations: [String?], language: String,
                                   translationLanguage: String?) -> Job {
        let job = Job(name: name, url: nil)
        let segments = sources.enumerated().map {
            TranscriptSegment(start: Double($0.offset) * 3, end: Double($0.offset) * 3 + 3, text: $0.element,
                              translation: translations[$0.offset])
        }
        job.transcript = Transcript(sourceName: name, segments: segments, language: language,
                                    duration: Double(sources.count) * 3, elapsed: 1,
                                    translationModel: "self-test", translationLanguage: translationLanguage)
        job.status = .done
        job.progress = 1
        job.message = L("Done")
        model.adopt(job, at: model.jobs.count)
        return job
    }
}

/// 訳し直しの確認の、LLM の代わり。「Lines to translate」の行 ([番号] 原文) に、決めた訳 (原文ごと) で答える。
/// 決めていない原文には、決まった印の文で答える (照らし合わせで落ちるように)。
/// failAfter を渡すと、configure の後にその回数だけ答え、その次から llama.cpp の失敗 (`LLMError.decodeFailed(-1)`) を投げる
/// (0 なら始めの依頼から)
final class RetranslateStandIn: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private var count = 0
    private var failAfter: Int?
    private var sinceConfigure = 0
    private var failedCount = 0

    /// これまでに答えた回数 (失敗を投げた回は数えない)
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// これまでに失敗を投げた回数
    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedCount
    }

    func configure(answers: [String: String], failAfter: Int? = nil) {
        lock.lock()
        self.answers = answers
        self.failAfter = failAfter
        sinceConfigure = 0
        lock.unlock()
    }

    var contextLength: Int { 8192 }

    func tokenCount(_ text: String) -> Int { text.utf8.count / 3 + 1 }

    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        lock.lock()
        if let failAfter, sinceConfigure >= failAfter {
            failedCount += 1
            lock.unlock()
            throw LLMError.decodeFailed(-1)
        }
        sinceConfigure += 1
        count += 1
        let answers = self.answers
        lock.unlock()
        guard let range = prompt.user.range(of: "Lines to translate:\n") else { return "" }
        var out: [String] = []
        for line in prompt.user[range.upperBound...].split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let number = line[line.index(after: line.startIndex)..<close]
            let source = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            out.append("[\(number)] \(answers[source] ?? "Unexpected line for the stand-in.")")
        }
        // 最後の行も改行で終える (答えを読む所は、改行で終わっていない最後の行を、書きかけとして捨てる)
        return out.map { $0 + "\n" }.joined()
    }
}
