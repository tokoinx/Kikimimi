// 監査・翻訳の所: 予約・走らせる・中止・録音のための一時停止と、翻訳に渡す訳の記憶。

import Foundation
import KikimimiCore
import KikimimiLLM

extension AppModel {
    // MARK: 監査・翻訳

    /// 監査・翻訳を予約する。automatic は文字起こし直後の自動実行 (設定に従う)
    func schedulePostTasks(for job: Job, automatic: Bool, tasks: [PostTask]? = nil) {
        guard job.status == .done, let transcript = job.transcript, !transcript.segments.isEmpty else { return }
        var wanted = tasks ?? []
        if automatic {
            if autoAudit { wanted.append(.audit) }
            // 翻訳は LLM が手元にあり、訳す先の言語以外が主な文字起こしのときだけ (LLM が無ければ画面で取得を案内する)
            if autoTranslate, isLLMInstalled, transcript.isMainlyForeign(target: translationTarget(for: transcript)) {
                wanted.append(.translate)
            }
        }
        let added = wanted.filter { !job.postQueue.contains($0) && job.postState.task != $0 }
        guard !added.isEmpty else { return }
        // 前のお知らせは、新しく頼まれたときに消す (続けて動く仕事が、前の仕事の失敗の知らせを消さないように)
        if job.postState == .idle { job.postNote = nil }
        job.postQueue += added
        ensureWorker()
    }

    /// 監査をやり直す (前の監査の反映は元に戻してから見直す)
    func audit(_ job: Job) {
        schedulePostTasks(for: job, automatic: false, tasks: [.audit])
    }

    /// その結果の訳す先の言語。翻訳に関わる所 (訳す・訳していない数・対訳・行・練習の「隠す」・書き出し) は、すべてこれを使う。
    /// 訳が在れば、その結果が訳した言語 (1 つの結果の訳は 1 つの言語にそろえる。設定の言語が変わっても変えない)。
    /// 訳が無ければ設定の言語。ただし「〇〇語で訳し直す」で訳を外した結果は、訳が無い間も、選んだ言語
    /// (`retranslate` が translationLanguage を先に入れてある)
    func translationTarget(for transcript: Transcript) -> String {
        if let pending = transcript.translationLanguage, !transcript.hasTranslation {
            return TranslationTarget.normalized(pending)
        }
        return TranslationTarget.normalized(transcript.translationTarget(default: translationLanguage))
    }

    /// その結果の訳す先の言語の名前 (画面に出す。今の画面の言語での名前)
    func translationTargetName(for transcript: Transcript) -> String {
        TranslationTarget.displayName(for: translationTarget(for: transcript))
    }

    /// その結果の、訳す先の言語へ訳す時の翻訳の状況 (区間を 1 回だけ見て数える)
    func translationStats(of transcript: Transcript) -> Transcript.TranslationStats {
        transcript.translationStats(target: translationTarget(for: transcript))
    }

    /// LLM が無いので訳せない時の知らせ (target は訳す先の言語のコード)
    private func llmNeededForTranslation(_ target: String) -> String {
        L("Translating to %1$@ needs the local LLM “%2$@”. Download it in the “Audit & translation” tab of Settings.",
          TranslationTarget.displayName(for: target), currentLLM.name)
    }

    /// まだ訳していない区間を、その結果の訳す先の言語に訳す
    func translate(_ job: Job) {
        guard isLLMInstalled else {
            errorMessage = llmNeededForTranslation(job.transcript.map { translationTarget(for: $0) } ?? translationLanguage)
            return
        }
        schedulePostTasks(for: job, automatic: false, tasks: [.translate])
    }

    /// 訳す先を変えて訳し直す (結果の画面の「〇〇語で訳し直す…」。確かめてから呼ぶ)。
    /// (a) 今の状態を、履歴の版 (自動) として残す。版を残せない時 (保存していない結果・監査や翻訳の最中) は、
    ///     「戻す」と同じく何もしない。残せなかった時も何も変えない
    /// (b) 訳を全部外す (c) この結果の訳す先を target にして、翻訳を始める
    func retranslate(_ job: Job, into target: String) {
        let target = TranslationTarget.normalized(target)
        guard isLLMInstalled else {
            errorMessage = llmNeededForTranslation(target)
            return
        }
        guard job.status == .done, job.transcript != nil, canEditVersions(job) else { return }
        Task {
            guard await saveVersion(job, label: AppModel.beforeRetranslateLabel, mode: .new, origin: .beforeRestore) else { return }
            // 版を残しているあいだに、ほかの仕事が始まった・結果が変わった時は、訳を外さない (版は残る)
            guard job.status == .done, !job.isPostActive, var transcript = job.transcript else { return }
            transcript.removeAllTranslations()
            // 訳が 1 つも無い間も、この結果は target で訳す (translationTarget(for:) が見る)
            transcript.translationLanguage = target
            job.transcript = transcript
            schedulePostTasks(for: job, automatic: false, tasks: [.translate])
        }
    }

    /// その区間を含む 1 文だけを、その結果の訳す先の言語に訳す (行の「訳」)。redo は、訳のある文を訳し直す (行の右クリック)。
    /// 文のまとめ方とプロンプトは「翻訳」と同じなので、あとの「翻訳」「残りを翻訳」はこの文を飛ばす
    func translateLine(_ id: UUID, in job: Job, redo: Bool = false) {
        guard isLLMInstalled else {
            errorMessage = llmNeededForTranslation(job.transcript.map { translationTarget(for: $0) } ?? translationLanguage)
            return
        }
        guard job.status == .done, let transcript = job.transcript, !job.lineQueue.contains(id) else { return }
        let target = translationTarget(for: transcript)
        // 訳し直しは、前の訳でまとめていた区間をすべて訳し直す (監査で文の区切りが変わっていても、訳の無い区間を残さない)
        let unit = redo
            ? Translator.redoUnitIDs(containing: id, in: transcript.segments, language: transcript.language, target: target)
            : Translator.unitIDs(containing: id, in: transcript.segments, language: transcript.language, target: target)
        // 同じ文の別の行がもう頼まれていれば、もう一度は訳さない
        let added = unit.filter { !job.lineQueue.contains($0) }
        guard !added.isEmpty else { return }
        // 利用者が自分で「この文を訳し直す」を押した: その文の、利用者が直した訳の覚えを捨てる
        // (捨てないと、訳し直した機械の訳を置けない。訳し終えるまで、画面には今の訳を残す。訳の記憶には残す)
        if redo, var t = job.transcript, t.dropUserTranslations(touching: Set(unit)) {
            job.transcript = t
        }
        job.lineQueue += added
        if redo { job.lineRedo.insert(id) }
        // 訳した行が見えるように、このジョブだけ対訳で表示する (対訳の設定は変えない)
        job.showsLineTranslations = true
        schedulePostTasks(for: job, automatic: false, tasks: [.translateLines])
    }

    /// 監査の 1 か所を反映する / 元に戻す
    func setAuditChange(_ change: AuditChange, applied: Bool, in job: Job) {
        guard var transcript = job.transcript else { return }
        let before = transcript.audit?.changes.first { $0.id == change.id }
        // この直しを、利用者が前に自分で「反映する」と決めていたか (自動で反映されたものではなく)
        let wasAcceptedByUser = before.map { transcript.audit?.userDecisions?[$0.signature] == true } ?? false
        transcript.setChange(change.id, applied: applied)
        job.transcript = transcript
        // 利用者が自分で決めた直しを覚える (次からは、反映した直しは先に当て、元に戻した直しは出さない)
        let after = transcript.audit?.changes.first { $0.id == change.id }
        // いくつかの語をまとめた直し (学習した直しが 2 つ当たった行・学習した直しと LLM の直しをまとめた行) を反映したら、
        // どの組にも「反映」を覚える。元に戻したときは、どの語がいけなかったのかわからないので「元に戻す」とは覚えず、
        // 利用者が自分で反映していたものなら、その「反映」を取り消すだけにする (反映 → 元に戻す、で回数が増えていかないように。
        // この行での決定は、文字起こしの側に残る。監査をやり直しても、この行には当てない)
        if useLedger, let before, let after, before.kind == .fix, before.isApplied != after.isApplied {
            let pairs = before.decisionPairs
            for pair in pairs {
                if after.isApplied || pairs.count == 1 {
                    ledger.record(wrong: pair.wrong, right: pair.right, language: transcript.language(of: before.original),
                                  example: pairs.count == 1 ? before.original.text : nil, accepted: after.isApplied)
                } else if wasAcceptedByUser {
                    ledger.retract(wrong: pair.wrong, right: pair.right)
                }
            }
            if !pairs.isEmpty { saveLedger() }
        }
    }

    func revertAudit(of job: Job) {
        guard var transcript = job.transcript else { return }
        transcript.revertAllChanges()
        job.transcript = transcript
    }

    func runPost(_ task: PostTask, for job: Job) async {
        guard job.status == .done, let transcript = job.transcript, !transcript.segments.isEmpty else { return }
        let flag = CancelFlag()
        job.postCancel = flag
        let selection = currentLLM
        let useLLM = isLLMInstalled
        let glossary = effectiveHint
        let learned = useLedger ? ledger : nil
        // 監査には監査用の差分、翻訳 (全体・行・訳し直し) には翻訳用の差分だけ (`activeAdapterPath(for:)`)
        let adapter = activeAdapterPath(for: task.adapterKind)
        let language = transcript.language
        // 訳す先は、仕事を始めた時に決める (訳している途中に設定の言語が変わっても、この言語で終える)
        let target = translationTarget(for: transcript)
        defer { job.postState = .idle }
        defer {
            if job.pausedForRecording {
                job.pausedForRecording = false
                job.postNote = Self.pausedNote
                job.postNoteIsPause = true
            }
        }
        // 一時停止から再開した: 「一時停止しています」を消す (文ではなく印で見る。画面の言語が変わっていても消せるように)
        if job.postNoteIsPause { job.postNote = nil }

        // メモリの少ない Mac では、LLM を読み込む前に Whisper を手放す
        if useLLM && MemoryBudget.isTight { service.unload() }
        let preparing = !llm.isLoaded(modelPath: selection.url.path)
        /// 差分を読み込めなかったときの知らせ (差分なしで動かした)
        func adapterNote(_ note: String?) -> String? {
            guard let adapter, llm.failedAdapter() == adapter else { return note }
            let warning = L("Could not load the fine-tuning adapter, so it ran without it (add the adapter again or remove it in the “Audit & translation” tab of Settings).")
            return note.map { $0 + " " + warning } ?? warning
        }

        do {
            switch task {
            case .audit:
                job.postState = .running(.audit, message: L("Auditing…"), progress: nil)
                let segments = transcript.segmentsBeforeAudit
                let options = AuditOptions(glossary: glossary, ledger: learned,
                                           decisions: transcript.audit?.userDecisions ?? [:])
                // 前に LLM で監査してあれば、やり直しの結果は最後にまとめて反映する
                // (途中で規則だけの結果を反映すると、前の LLM の直しといっしょに訳まで外れてしまう。中止したら前の結果のまま)
                let hadLLMAudit = transcript.audit?.model != nil
                // LLM を消したあとで、LLM の監査をやり直そうとした: 規則だけで上書きすると前の LLM の直しと訳が外れるので、そのままにする
                if hadLLMAudit && !useLLM {
                    job.postNote = L("The LLM was not found, so the previous audit result is kept. To audit again with the LLM, download it in the “Audit & translation” tab of Settings.")
                    return
                }
                if !hadLLMAudit {
                    // 規則だけの見直しは数秒で終わるので、先に反映しておく (LLM が失敗・中止しても、ここまでは残る)。
                    // 長い録音では時間がかかるので、画面を止めないよう裏で回す
                    let rules = try await Task.detached(priority: .userInitiated) {
                        try Auditor.audit(segments, language: language, options: options, generator: nil,
                                          modelName: nil, shouldCancel: { flag.isSet })
                    }.value
                    if flag.isSet { throw LLMError.cancelled }
                    adopt(rules, in: job)
                }
                guard useLLM else {
                    // 学習した直しを使っている時は、それも当てたので、そう知らせる (文は AuditGuidance が選ぶ)
                    job.postNote = AuditGuidance.noLLMNote(usesLedger: learned != nil)
                    return
                }
                // 規則の見直しのあいだに、メモリの少ない Mac で録音が始まった: LLM は録音のあとで
                if pauseIfRecording(.audit, job: job) { return }
                job.postState = .running(.audit, message: preparing ? L("Auditing… (loading the LLM)") : L("Auditing…"), progress: nil)
                let partial = LockedBox<AuditReport>()
                do {
                    let report = try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                                   shouldCancel: { flag.isSet }) { engine in
                        try Auditor.audit(segments, language: language, options: options, generator: engine,
                                          modelName: engine.adapterPath == nil ? selection.name : L("%@ + fine-tuning", selection.name),
                                          shouldCancel: { flag.isSet },
                                          onProgress: { done, total in
                                              Task { @MainActor in
                                                  guard case .running(.audit, _, _) = job.postState, job.postCancel === flag else { return }
                                                  job.postState = .running(.audit, message: L("Auditing %1$d/%2$d", done, total),
                                                                           progress: total > 0 ? Double(done) / Double(total) : nil)
                                              }
                                          },
                                          onPartial: { partial.value = $0 })
                    }
                    adopt(report, in: job)
                    job.postNote = adapterNote(job.postNote)
                } catch {
                    let cancelled = flag.isSet || (error as? LLMError) == .cancelled
                    if hadLLMAudit {
                        // やり直しの途中: 前の監査の結果をそのまま残す
                        job.postNote = cancelled
                            ? L("The new audit was canceled. The previous audit result is kept.")
                            : L("The LLM could not audit, so the previous audit result is kept: %@", error.localizedDescription)
                        return
                    }
                    // はじめての監査: LLM が見終えたまとまりまでの結果を反映する (規則の結果は反映済み)
                    let adoptedPartial: Bool
                    if let done = partial.value, done.model != nil {
                        adopt(done, in: job)
                        adoptedPartial = true
                    } else {
                        adoptedPartial = false
                    }
                    if cancelled {
                        job.postNote = L("The audit was canceled. Results up to the point it reached are applied.")
                    } else if adoptedPartial {
                        job.postNote = L("The LLM audit stopped partway. Results up to the point it reached are applied: %@", error.localizedDescription)
                    } else {
                        job.postNote = L("The LLM could not audit, so only the repetition check was applied: %@", error.localizedDescription)
                    }
                    return
                }

            case .translate:
                // 「〇〇語で訳し直す」を中止した・失敗した (訳が 1 つも無い) 時は、訳す先の記録を外す
                // (残すと、設定の言語を変えても、この結果はその言語で訳し続ける)。録音のための一時停止では残す (続きで使う)
                defer {
                    if !job.pausedForRecording, var t = job.transcript, t.clearTranslationLanguageIfUntranslated() {
                        job.transcript = t
                    }
                }
                guard useLLM else { return }
                if pauseIfRecording(.translate, job: job) { return }
                job.postState = .running(.translate, message: preparing ? L("Translating… (loading the LLM)") : L("Translating…"), progress: nil)
                let segments = transcript.segments
                let sources = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                let options = TranslationOptions(glossary: glossary)
                // 覚えた訳 (訳す先が同じ物の写し)。全体の翻訳・「〇〇語で訳し直す」は、記憶を引く
                let memory = translationMemoryLookup(target: target)
                let apply: @MainActor ([TranslationResult]) -> Void = { batch in
                    guard !batch.isEmpty, var t = job.transcript else { return }
                    // 訳しているあいだに監査で文が変わった区間には付けない
                    for result in batch { t.apply(result, sources: sources) }
                    // 記憶から置いただけなら、訳した LLM の名前は変えない
                    if batch.contains(where: { !$0.fromMemory }) { t.translationModel = selection.name }
                    t.translationLanguage = target
                    job.transcript = t
                }
                /// 訳す (generator が nil なら、記憶だけで埋める)
                func run(_ generator: (any TextGenerating)?) throws -> (TranslationRunSummary, [TranslationResult]) {
                    var all: [TranslationResult] = []
                    let summary = try Translator.translateSummarizing(segments, language: language, target: target,
                                                                      options: options, memory: memory,
                                                                      generator: generator,
                                                                      shouldCancel: { flag.isSet }) { batch, done, total in
                        all += batch
                        Task { @MainActor in
                            apply(batch)
                            guard case .running(.translate, _, _) = job.postState, job.postCancel === flag else { return }
                            job.postState = .running(.translate, message: L("Translating %1$d/%2$d", done, total),
                                                     progress: total > 0 ? Double(done) / Double(total) : nil)
                        }
                    }
                    return (summary, all)
                }
                // 記憶だけで全部埋まる時は、LLM を読み込まない (引くのは辞書だけなので、ここで済ませる)
                let usesLLM = !Translator.memoryCoversAll(segments, language: language, target: target, memory: memory)
                let (summary, all) = usesLLM
                    ? try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                        shouldCancel: { flag.isSet }) { engine in try run(engine) }
                    : try run(nil)
                apply(all)
                // 訳せなかった行に、理由の覚えを残す (訳は置かない。訳の結果ではないので、訳した LLM の名前は変えない)
                if !summary.rejected.isEmpty, var t = job.transcript {
                    for result in summary.rejected { t.apply(result, sources: sources) }
                    job.transcript = t
                }
                let failed = summary.failed
                if failed > 0 {
                    job.postNote = LPlural(failed, one: "%d segment could not be translated. Click “Translate” again to translate only the rest.", other: "%d segments could not be translated. Click “Translate” again to translate only the rest.")
                }
                job.postNote = Self.memoryNote(job.postNote, used: summary.fromMemory)
                if usesLLM { job.postNote = adapterNote(job.postNote) }

            case .translateLines:
                guard useLLM else {
                    job.lineQueue.removeAll()
                    job.lineRedo.removeAll()
                    return
                }
                if pauseIfRecording(.translateLines, job: job) { return }
                // いま待っている文をまとめて訳す (このあいだに頼まれた文は、終わってから続けて訳す)
                let lines = job.lineQueue
                guard !lines.isEmpty else { return }
                let only = Set(lines)
                defer {
                    // 訳し終えた (訳せなかった) 文を待ちから外す。録音のための一時停止なら残し、録音のあとで続ける
                    if !job.pausedForRecording {
                        job.lineQueue.removeAll { only.contains($0) }
                        job.lineRedo.subtract(only)
                        if !job.lineQueue.isEmpty && !job.postQueue.contains(.translateLines) {
                            job.postQueue.append(.translateLines)
                        }
                    }
                }
                job.postState = .running(.translateLines, message: preparing ? L("Translating the selected sentences… (loading the LLM)") : L("Translating the selected sentences…"), progress: nil)
                // 訳し直す文は、写しの上で訳を外してから文の区切りを決める (訳し終えるまで、画面には前の訳を残す)
                let redo = job.lineRedo.intersection(only)
                let segments = Translator.clearingTranslations(of: redo, in: transcript.segments)
                let sources = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                let options = TranslationOptions(glossary: glossary)
                // 覚えた訳: 訳の無い 1 行だけを訳す時は引く。利用者が自分で押した「この文を訳し直す」の文は引かない
                // (機械の訳を見たい時の逃げ道)。前の訳でまとめていた区間を全部含めて、引かない区間にする
                let memory = translationMemoryLookup(target: target)
                let noMemory = Set(redo.flatMap { Translator.translationGroupIDs(of: $0, in: transcript.segments) })
                let apply: @MainActor ([TranslationResult]) -> Void = { batch in
                    guard !batch.isEmpty, var t = job.transcript else { return }
                    // 訳しているあいだに監査で文が変わった区間には付けない
                    for result in batch { t.apply(result, sources: sources) }
                    // 記憶から置いただけなら、訳した LLM の名前は変えない
                    if batch.contains(where: { !$0.fromMemory }) { t.translationModel = selection.name }
                    t.translationLanguage = target
                    job.transcript = t
                }
                /// 訳す (generator が nil なら、記憶だけで埋める)
                func run(_ generator: (any TextGenerating)?) throws -> (TranslationRunSummary, [TranslationResult]) {
                    var all: [TranslationResult] = []
                    let summary = try Translator.translateSummarizing(segments, language: language, target: target,
                                                                      options: options, only: only, memory: memory,
                                                                      memoryExcluding: noMemory,
                                                                      generator: generator,
                                                                      shouldCancel: { flag.isSet }) { batch, done, total in
                        all += batch
                        Task { @MainActor in
                            apply(batch)
                            guard case .running(.translateLines, _, _) = job.postState, job.postCancel === flag else { return }
                            job.postState = .running(.translateLines, message: L("Translating the selected sentences %1$d/%2$d", done, total),
                                                     progress: total > 0 ? Double(done) / Double(total) : nil)
                        }
                    }
                    return (summary, all)
                }
                // 記憶だけで全部埋まる時は、LLM を読み込まない
                let usesLLM = !Translator.memoryCoversAll(segments, language: language, target: target, only: only,
                                                          memory: memory, memoryExcluding: noMemory)
                let (summary, all) = usesLLM
                    ? try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                        shouldCancel: { flag.isSet }) { engine in try run(engine) }
                    : try run(nil)
                apply(all)
                // 訳せなかった行に、理由の覚えを残す (訳は置かない。訳の結果ではないので、訳した LLM の名前は変えない)
                if !summary.rejected.isEmpty, var t = job.transcript {
                    for result in summary.rejected { t.apply(result, sources: sources) }
                    job.transcript = t
                }
                let failed = summary.failed
                if failed > 0 {
                    job.postNote = LPlural(failed, one: "%d segment of the selected sentences could not be translated. Click “Translate line” on that line to retry.", other: "%d segments of the selected sentences could not be translated. Click “Translate line” on that line to retry.")
                }
                job.postNote = Self.memoryNote(job.postNote, used: summary.fromMemory)
                if usesLLM { job.postNote = adapterNote(job.postNote) }
            }
        } catch {
            if flag.isSet || (error as? LLMError) == .cancelled {
                job.postNote = task == .audit ? L("The audit was canceled.") : L("Translation was canceled. What was translated so far is kept.")
            } else {
                job.postNote = task == .audit ? L("Could not audit: %@", error.localizedDescription)
                    : L("Could not translate: %@", error.localizedDescription)
            }
        }
    }

    /// 録音のあいだ一時停止しているときのお知らせ
    static var pausedNote: String {
        L("Paused while recording. It resumes when you stop recording.")
    }

    /// メモリの少ない Mac で録音中なら、この仕事を順番待ちの先頭に戻して true を返す (録音を止めると再開する)
    private func pauseIfRecording(_ task: PostTask, job: Job) -> Bool {
        guard isRecording, MemoryBudget.isTight else { return false }
        if !job.postQueue.contains(task) { job.postQueue.insert(task, at: 0) }
        job.pausedForRecording = true
        return true
    }


    /// 監査の結果を本文に反映する (前の監査の反映は元に戻し、利用者の決定は引き継ぐ)
    private func adopt(_ report: AuditReport, in job: Job) {
        guard var current = job.transcript else { return }
        current.adopt(report)
        job.transcript = current
    }

    /// 次の翻訳に渡す、訳す先 target の記憶の写し (覚えた文と訳語の対)。設定が切・文も対も無ければ nil
    private func translationMemoryLookup(target: String) -> TranslationMemoryLookup? {
        translationMemory.lookup(target: target, reuse: reuseTranslationMemory)
    }

    /// 翻訳が終わった時の知らせに、記憶から置いた行の数を足す (0 なら何も足さない)
    private static func memoryNote(_ note: String?, used: Int) -> String? {
        guard used > 0 else { return note }
        let text = LPlural(used, one: "Used a remembered translation for %d line.", other: "Used remembered translations for %d lines.")
        return note.map { $0 + " " + text } ?? text
    }
}
