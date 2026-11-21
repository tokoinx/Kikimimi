// 録音の所: 録音を始める・止める・保存する。

import Foundation
import KikimimiCore
import KikimimiWhisper

extension AppModel {
    // MARK: 録音
    func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        let recorder = LiveRecorder()
        recorder.onLevel = { [weak self] level in
            self?.recordingLevel = level
        }
        recorder.onInterrupted = { [weak self] error in
            guard let self else { return }
            self.stopRecording()
            self.errorMessage = L("Recording stopped because the input device changed. The recording so far will be transcribed. (%@)", error.localizedDescription)
        }
        do {
            try await recorder.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        self.recorder = recorder
        // 録音を始めたら、練習の続きは終わりにする
        practice.stop()
        isRecording = true
        recordingStartedAt = Date()
        livePreviewText = ""

        // プレビューのために、取得済みならモデルを先に読み込んでおく (メモリの少ない Mac では LLM を先に手放す)
        let spec = currentModel
        if MemoryBudget.isTight {
            pausePostTasksForRecording()
            llm.unload()
        }
        if store.isInstalled(spec) {
            let path = store.url(for: spec).path
            Task { try? await service.preload(modelPath: path) }
        }
        previewTask = Task { [weak self] in
            await self?.previewLoop()
        }
    }

    private func previewLoop() async {
        while isRecording, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard isRecording, livePreview, let recorder else { continue }
            let window = recorder.recentSamples(seconds: 12)
            guard window.count >= Int(LiveRecorder.sampleRate) else { continue }
            let spec = currentModel
            guard store.isInstalled(spec) else { continue }
            let candidates = Languages.candidates(for: languageCode) ?? []
            let options = WhisperOptions(
                language: candidates.first ?? languageCode,
                languageCandidates: candidates,
                useBeamSearch: false,
                singleSegment: true,
                noTimestamps: true,
                filterHallucinations: true
            )
            if let text = await service.preview(samples: window, modelPath: store.url(for: spec).path, options: options),
               isRecording, !text.isEmpty {
                livePreviewText = text
            }
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        previewTask?.cancel()
        previewTask = nil
        let samples = recorder.stop()
        self.recorder = nil
        isRecording = false
        recordingLevel = 0
        livePreviewText = ""
        let started = recordingStartedAt ?? Date()
        recordingStartedAt = nil
        // 録音中に止めておいた監査・翻訳 (メモリの少ない Mac) を続ける
        defer { ensureWorker() }

        guard samples.count >= Int(LiveRecorder.sampleRate / 2) else {
            errorMessage = L("The recording is too short (under 0.5 seconds).")
            return
        }
        let url = try? saveRecording(samples, startedAt: started)
        let job = Job(name: L("Recording %@", Self.displayStamp.string(from: started)), url: url, isRecording: true, samples: samples)
        adopt(job)
        select(job)
        ensureWorker()
    }

    /// 録音を置くフォルダ (モデルのフォルダのとなり: ~/Library/Application Support/Kikimimi/Recordings)
    var recordingsDirectory: URL {
        store.directory.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
    }

    private func saveRecording(_ samples: [Float], startedAt: Date) throws -> URL {
        let dir = recordingsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("録音-\(Self.fileStamp.string(from: startedAt)).wav") // l10n: keep (保存するファイルの名前)
        try WAV.encode(samples: samples, sampleRate: Int(LiveRecorder.sampleRate)).write(to: url)
        return url
    }

    private static let displayStamp: DateFormatter = {
        let f = DateFormatter()
        // 数だけの書式なので、言語に左右されない形にする (見た目は ja_JP の時と同じ)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// メモリの少ない Mac で録音を始めるとき: 動いている監査・翻訳を止めて順番待ちの先頭に戻す
    /// (LLM を手放してから Whisper を読み込む。訳せた所・監査で見終えた所までの結果は残る。録音を止めると再開する:
    /// 翻訳は残りだけを訳し、監査は始めから見直す)
    private func pausePostTasksForRecording() {
        guard MemoryBudget.isTight else { return }
        for job in jobs {
            guard let task = job.postState.task else { continue }
            if !job.postQueue.contains(task) { job.postQueue.insert(task, at: 0) }
            job.pausedForRecording = true
            job.postCancel.set()
        }
    }
}
