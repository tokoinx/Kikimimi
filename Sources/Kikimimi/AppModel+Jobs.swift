// ジョブの所: ファイルを開く・落とす・読み込む、仕事の順番待ち、文字起こしを走らせる所、
// 結果を消す (ゴミ箱に入れる)。

import AppKit
import Foundation
import KikimimiCore
import KikimimiWhisper
import UniformTypeIdentifiers

extension AppModel {
    // MARK: ファイル
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.message = L("Choose audio or video files to transcribe")
        panel.prompt = L("Transcribe")
        if panel.runModal() == .OK {
            enqueue(panel.urls)
        }
    }

    /// ウインドウに落としたファイルを読み込む。音声・動画のファイルだけを、落とした順に順番待ちへ入れる。
    /// 録音中は何も読み込まない (知らせは、落とす時の枠で出す)。
    /// 読み込まなかった物が在れば、名前を知らせる。1 つでも読み込んだら true を返す
    @discardableResult
    func importDropped(_ urls: [URL]) -> Bool {
        guard !isRecording else { return false }
        let (accepted, rejected) = MediaImport.split(urls)
        if !accepted.isEmpty {
            enqueue(accepted)
        }
        if !rejected.isEmpty {
            let limit = 5
            let shown = rejected.prefix(limit).map { $0.lastPathComponent }
            var names = shown.dropFirst().reduce(shown[0]) { L("%1$@, %2$@", $0, $1) }
            if rejected.count > limit {
                names = L("%1$@, %2$@", names, LPlural(rejected.count - limit, one: "and %d more", other: "and %d more"))
            }
            errorMessage = L("These are not audio or video files, so they were not opened:\n%@", names)
        }
        return !accepted.isEmpty
    }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            let job = Job(name: url.lastPathComponent, url: url)
            adopt(job)
            if selectedJobID == nil || selectedJob?.isActive == false {
                select(job)
            }
        }
        ensureWorker()
    }

    /// 同じファイルを、別の言語の設定でもう一度文字起こしする (新しいジョブ。設定の言語は変えない)。
    /// autoMixed が false なら、日本語と英語が混ざっていても「日本語＋英語」に切り替えない
    /// vad は、このジョブだけの無音を飛ばす (VAD) の指定 (Job.vadOverride。nil なら設定に従う)
    func retranscribe(_ job: Job, languageCode code: String?, autoMixed: Bool = true, vad: Bool? = nil) {
        guard let url = job.url else { return }
        // 置き換える文字起こしの監査・翻訳は止める (待っていると、やり直しがその後ろに回る。反映済みの結果は残す)
        cancelPost(job)
        // 録音から作った結果は、やり直しても録音の印を残す (結果をゴミ箱に入れる時、録音もゴミ箱へ移すため)
        let again = Job(name: job.name, url: url, isRecording: job.isRecording)
        again.languageCode = code
        again.allowsAutoMixed = autoMixed
        again.vadOverride = vad
        adopt(again)
        job.mixedSuggestionDismissed = true
        job.autoMixedNoticeDismissed = true
        job.vadSkippedNoticeDismissed = true
        select(again)
        ensureWorker()
    }

    /// 「やり直す」を使えるか: 音声ファイルが在り、文字起こしが終わった・失敗した・中止した結果で、録音中でない
    func canRedo(_ job: Job?) -> Bool {
        guard let job, !isRecording, let url = job.url else { return false }
        switch job.status {
        case .done, .failed, .cancelled:
            return FileManager.default.fileExists(atPath: url.path)
        case .queued, .running:
            return false
        }
    }

    /// その結果だけの指定で、もう一度文字起こしする (新しいジョブ。元の結果は残す。設定は変えない)。
    /// - Parameters:
    ///   - code: 言語。nil なら、元のジョブと同じ言語 (使った言語)
    ///   - vad: 無音を飛ばす (VAD)。nil = 元のジョブと同じ (元のジョブにも指定が無ければ設定に従う)、
    ///     true = 使う (自動で VAD なしでやり直さない)、false = 使わない
    func redo(_ job: Job, languageCode code: String? = nil, vad: Bool? = nil) {
        guard canRedo(job) else { return }
        retranscribe(job, languageCode: code ?? job.languageCode, autoMixed: job.allowsAutoMixed, vad: vad ?? job.vadOverride)
    }

    func select(_ job: Job?) {
        // 別のジョブを選んだら、練習の続きは終わりにする (同じ音声のジョブでも)
        practice.select(job)
        selectedJobID = job?.id
        searchText = ""
        if let url = job?.url {
            player.load(url: url)
        } else {
            player.unload()
        }
    }

    func cancel(_ job: Job) {
        switch job.status {
        case .queued:
            job.status = .cancelled
            job.message = L("Canceled")
            // 録音の音声は WAV に保存してある。やり直しはそのファイルから読むので、メモリの分は手放す (1 時間で約 230 MB)
            if job.url != nil { job.samples = nil }
        case .running:
            job.cancelFlag.set()
            job.message = L("Canceling…")
        default:
            cancelPost(job)
        }
    }

    /// 監査・翻訳を止める (反映済みの結果は残す)
    func cancelPost(_ job: Job) {
        let hadQueue = !job.postQueue.isEmpty
        job.postQueue.removeAll()
        job.lineQueue.removeAll()
        job.lineRedo.removeAll()
        // 録音のための一時停止を取りやめる (止まったあとに「録音を止めると再開します」と出さない)
        job.pausedForRecording = false
        if job.postState != .idle {
            job.postCancel.set()
        } else if hadQueue {
            // 録音のあいだ一時停止していた作業を取りやめた: 「録音を止めると再開します」を残さない
            job.postNote = L("Audit and translation were canceled. Results already applied are kept.")
        }
    }

    /// 一覧から外す (作業は止める)。保存した結果は delete で消す
    private func remove(_ job: Job) {
        if job.isActive { cancel(job) }
        cancelPost(job)
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { select(jobs.first) }
        if historyJobID == job.id { historyJobID = nil }
        if pendingDeleteJobID == job.id { pendingDeleteJobID = nil }
        if translationEdit?.jobID == job.id { translationEdit = nil }
        if lineEdit?.jobID == job.id { lineEdit = nil }
    }

    private enum Work {
        case transcribe(Job)
        case post(Job, PostTask)
    }

    /// 次の仕事: 文字起こしが終わったジョブの監査・翻訳を先に (古い順)、その次に待っている文字起こし。
    /// メモリの少ない Mac では、録音中は監査・翻訳を始めない (プレビューの Whisper を手放さずに済むように。止めたら続ける)
    private func nextWork() -> Work? {
        let holdPost = isRecording && MemoryBudget.isTight
        if !holdPost, let job = jobs.last(where: { $0.status == .done && !$0.postQueue.isEmpty }) {
            return .post(job, job.postQueue.removeFirst())
        }
        if let job = jobs.last(where: { $0.status == .queued }) {
            return .transcribe(job)
        }
        return nil
    }

    func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            defer { self?.worker = nil }
            while let self, let work = self.nextWork() {
                switch work {
                case .transcribe(let job):
                    await self.run(job)
                    if job.status == .done { self.schedulePostTasks(for: job, automatic: true) }
                case .post(let job, let task):
                    await self.runPost(task, for: job)
                }
            }
            // 手が空いたら LLM を手放す (数 GB のメモリを空ける。次に使うときは数秒で読み直せる)。
            // チャットが答えを出している最中でも壊れない: unload は LLM の列の後ろに並ぶので、
            // 答えを出し終えてから手放す (答えの途中の engine は、その body が持っている)
            self?.llm.unload()
        }
    }

    private func run(_ job: Job) async {
        job.status = .running
        job.progress = 0
        job.error = nil
        if MemoryBudget.isTight { llm.unload() }
        let spec = currentModel
        // 認識の途中で届く区間の入れ物。終わり方ごとに閉じる (下の catch と、結果を入れる前)
        let live = Self.liveFeed(for: job)
        do {
            if !store.isInstalled(spec) {
                job.message = L("Downloading %@ (first time only)…", spec.displayName)
            }
            let modelURL = try await ensureModel(spec, cancelFlag: job.cancelFlag)
            if job.cancelFlag.isSet { throw WhisperError.cancelled }

            // 無音を飛ばす (VAD) は、ジョブだけの指定 (「やり直す」) を設定より先に見る
            let wantsVAD = job.vadOverride ?? useVAD
            if wantsVAD && !store.isVADInstalled {
                job.message = L("Preparing the silence detection (VAD) model…")
            }
            let vadPath = await vadModelPath(enabled: wantsVAD)
            if job.cancelFlag.isSet { throw WhisperError.cancelled }

            let samples: [Float]
            if let recorded = job.samples {
                samples = recorded
            } else if let url = job.url {
                job.message = L("Loading audio…")
                samples = try await AudioDecoder.decode(url: url, cancelFlag: job.cancelFlag)
            } else {
                throw WhisperError.emptyAudio
            }
            job.samples = nil
            if job.cancelFlag.isSet { throw WhisperError.cancelled }

            let duration = Double(samples.count) / AudioDecoder.sampleRate
            job.transcript = Transcript(sourceName: job.name, model: spec.id, duration: duration)
            job.message = service.isReady(modelPath: modelURL.path, vad: vadPath != nil) ? L("Transcribing…") : L("Loading model…")

            // 「日本語＋英語」は、区切りごとに日本語か英語かを判定して、その言語で文字にする
            let code = job.languageCode ?? languageCode
            job.languageCode = code
            let candidates = Languages.candidates(for: code) ?? []
            let options = WhisperOptions(
                language: candidates.first ?? code,
                languageCandidates: candidates,
                useBeamSearch: preferAccuracy,
                vadModelPath: vadPath,
                initialPrompt: effectiveHint,
                filterHallucinations: filterHallucinations,
                autoMixedLanguage: autoMixedLanguage && job.allowsAutoMixed
            )
            let flag = job.cancelFlag
            let started = Date()
            // 自動で VAD なしでやり直すのは、設定に従うジョブだけ (「無音を飛ばしてやり直す」のジョブではしない)
            let autoOff = job.vadOverride == nil && autoVADOff
            // VAD なしでやり直している最中か (進み具合の知らせを変える。メインスレッドだけで触る)
            let phase = RunPhase()
            let result = try await service.transcribe(
                samples: samples,
                modelPath: modelURL.path,
                options: options,
                autoVADOff: autoOff,
                onProgress: { fraction in
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        job.progress = fraction
                        job.message = phase.withoutVAD
                            ? L("Very little text even though there is continuous sound, so transcribing again without skipping silence… %d%%", Int(fraction * 100))
                            : L("Transcribing %d%%", Int(fraction * 100))
                    }
                },
                onSegment: { segment in
                    // 区間は貯めておき、少しずつまとめて画面へ出す (LiveSegmentBuffer。行が多いほど間をあける)
                    live.append(segment)
                },
                onRestart: {
                    // whisper が途中で失敗して、始めからやり直す: そこまでに出した区間を消す (同じ文が 2 度並ばないように)。
                    // 貯めている区間も捨て、次にまとめて出すときに、画面の区間を消してから足す
                    live.restart()
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        job.progress = 0
                        job.message = L("Restarting transcription…")
                    }
                },
                onVADRetry: { _ in
                    // 音が続いているのに文字が少ないので、VAD なしでやり直す: 初めの結果の区間を画面から消し
                    // (やり直しの区間と混ざらないように)、進み具合を 0 から出し直す
                    live.restart()
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        phase.withoutVAD = true
                        job.progress = 0
                        job.message = Self.vadRetryMessage
                    }
                },
                onStage: { stage in
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        switch stage {
                        case .checkingLanguages:
                            job.message = L("Checking the spoken language…")
                        case .checkedLanguages(let probe):
                            if probe.isMixed {
                                job.message = L("Japanese and English are mixed. Transcribing as “Japanese + English”…")
                            }
                        }
                    }
                },
                shouldCancel: { flag.isSet }
            )
            let output = result.output
            // 自動で VAD なしでやり直し、その結果を採った: 印を残す (結果の画面に案内を出す)
            job.vadSkippedAutomatically = result.vadRetry?.usedRetry == true
            // 日本語と英語が混ざっていたので「日本語＋英語」で文字にした: このジョブは「日本語＋英語」として扱う
            // (英 / 日 の印・英語の行の翻訳など)
            if output.probe?.isMixed == true {
                job.autoMixedFrom = code
                job.languageCode = Languages.japaneseEnglish.code
            }
            // 貯まっている途中の区間は捨てる: 結果 (output.segments) はすべての区間を持ち、画面の区間をまるごと置き換える
            // (先に足すと、一覧を作り直す回数が 1 回増えるだけで、行は同じになる)。閉じたあとに届く区間も足さない
            live.close()
            job.transcript = Transcript(
                sourceName: job.name,
                segments: output.segments,
                language: output.language,
                model: spec.id,
                duration: duration,
                elapsed: Date().timeIntervalSince(started)
            )
            job.status = .done
            job.progress = 1
            job.message = L("Done")
        } catch let error as WhisperError where error == .cancelled {
            // 中止・失敗: 途中の結果が画面に残るので、貯まっている区間を先に足す (状態を変える前に。後始末もこれを含める)
            Self.applyLive(live.close(), to: job)
            job.status = .cancelled
            job.message = L("Canceled")
            if job.url != nil { job.samples = nil }
            cleanPartialTranscript(of: job)
        } catch {
            Self.applyLive(live.close(), to: job)
            if job.cancelFlag.isSet {
                job.status = .cancelled
                job.message = L("Canceled")
            } else {
                job.status = .failed
                job.error = error.localizedDescription
                job.message = L("Error")
            }
            // 音声を読む前に止まった録音: WAV に保存してあれば、メモリの分は手放す
            if job.url != nil { job.samples = nil }
            cleanPartialTranscript(of: job)
        }
    }

    /// 認識の途中で届く区間を、まとめて job.transcript に足す入れ物を作る。
    /// 最初の区間が届いてから少し待って (LiveSegmentBuffer.interval(forRows:): 画面に出ている行が 500 未満なら 0.25 秒、
    /// 2000 までは 0.5 秒、それより多ければ 1 秒)、メインスレッドで、そのあいだに届いた分を 1 回の代入で足す
    /// (一覧に行を足すのは、多くても 1 秒に 4 回。「日本語＋英語」で数百の区間がいっぺんに届いても 1 回)。
    /// AppModel.run と、画面の重さの確認 (--selftest-ui-load) が使う。
    /// applied は確認だけで使う: まとめて足したあとに、足した区間の数と、足し始めた時刻 (uptime のナノ秒) を受け取る
    static func liveFeed(for job: Job,
                         applied: (@MainActor @Sendable (_ count: Int, _ started: UInt64) -> Void)? = nil) -> LiveSegmentBuffer {
        LiveSegmentBuffer { buffer in
            Task { @MainActor in
                // 待つ長さは、知らせを受けた時点の行の数で決める (やり直しで行が消えたあとは、また短く)
                let wait = LiveSegmentBuffer.interval(forRows: job.transcript?.segments.count ?? 0)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                let started = DispatchTime.now().uptimeNanoseconds
                let batch = buffer.take()
                applyLive(batch, to: job)
                if let batch, let applied { applied(batch.segments.count, started) }
            }
        }
    }

    /// まとめた区間を足す。文字起こし中のジョブだけ (止まったあとに遅れて届いた分は、これまでどおり足さない)
    /// 自動で VAD なしでやり直している間の知らせ
    static var vadRetryMessage: String {
        L("Very little text even though there is continuous sound, so transcribing again without skipping silence…")
    }

    /// 文字起こしの段階 (run の中だけで使う。メインスレッドだけで触る)
    @MainActor
    final class RunPhase {
        /// 自動で VAD なしでやり直している
        var withoutVAD = false
    }

    static func applyLive(_ batch: LiveSegmentBuffer.Batch?, to job: Job) {
        guard let batch, job.status == .running, var transcript = job.transcript else { return }
        batch.apply(to: &transcript.segments)
        job.transcript = transcript
    }

    /// 中止・失敗したジョブの途中結果にも、完了時と同じ繰り返しの後始末をかける (画面に残り、コピーもできるため)。
    /// 貯まっていた区間は先に足し、入れ物は閉じてある。状態も .running 以外にしてから呼ぶので、このあと遅れて届く区間は追加されない。
    private func cleanPartialTranscript(of job: Job) {
        guard filterHallucinations, var transcript = job.transcript, !transcript.segments.isEmpty else { return }
        transcript.segments = RepetitionFilter.clean(transcript.segments)
        job.transcript = transcript
    }

    /// 結果を消す: 作業を止めて一覧から外し、保存したフォルダをゴミ箱に入れる
    /// (マイクの録音で、録音がアプリの録音フォルダにあれば、録音もゴミ箱へ)。
    /// ゴミ箱に入れるのも保存と同じ列で行うので、待っていた保存が、あとからフォルダを作り直すことはない
    /// ゴミ箱に入れる計画を消す前に取り、その計画のとおりに消す (確認の画面に出した物と、消す物を同じにする)
    func delete(_ job: Job) {
        let plan = deletionPlan(for: job)
        let id = job.id
        documentSaveTimers.removeValue(forKey: id)?.cancel()
        notesSaveTimers.removeValue(forKey: id)?.cancel()
        job.onChange = nil
        job.inLibrary = false
        remove(job)
        guard !plan.isEmpty, let writer = library else { return }
        let folder = plan.libraryFolder
        let recording = plan.recording
        let name = job.name
        let report: @MainActor @Sendable (String) -> Void = { [weak self] message in
            self?.errorMessage = message
        }
        writer.async { _ in
            if let folder {
                do {
                    try LibraryWriter.trash(folder)
                } catch {
                    let message = L("Could not delete “%1$@”: %2$@", name, error.localizedDescription)
                    Task { @MainActor in report(message) }
                }
            }
            if let recording { try? LibraryWriter.trash(recording) }
        }
    }

    /// ゴミ箱に入れる時に、何が消えて何が残るか。
    /// 保存した結果なら、保存のフォルダ。マイクの録音で、録音がアプリの録音フォルダに在り、
    /// ほかのジョブ (「やり直す」で作ったもの) が同じ録音を使っていなければ、録音も。元の音声ファイルは残す
    func deletionPlan(for job: Job) -> DeletionPlan {
        let folder = library?.store.folder(for: job.id)
        let shared = jobs.contains { $0.id != job.id && $0.sourcePath != nil && $0.sourcePath == job.sourcePath }
        return DeletionPlan.make(isSaved: job.inLibrary, libraryFolder: folder, isRecording: job.isRecording,
                                 sourcePath: job.sourcePath, recordingsDirectory: recordingsDirectory,
                                 audioUsedByOtherJobs: shared, isWorking: job.isActive || job.isPostActive)
    }

    /// ゴミ箱に入れるかを確かめる画面を出す (右クリック・ツールバー・メニュー・Delete キーのどれからも)。
    /// 確認なしで消える道は作らない。録音中は受けない
    func requestDelete(_ job: Job?) {
        guard !isRecording, let job, jobs.contains(where: { $0.id == job.id }) else { return }
        pendingDeleteJobID = job.id
    }
}
