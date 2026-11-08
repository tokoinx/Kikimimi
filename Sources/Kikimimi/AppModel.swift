import AppKit
import Foundation
import KikimimiCore
import KikimimiWhisper
import Observation
import UniformTypeIdentifiers

/// 1 件の文字起こしジョブ (ファイル or 録音)
@MainActor
@Observable
final class Job: Identifiable {
    enum Status { case queued, running, done, failed, cancelled }

    let id = UUID()
    let name: String
    var url: URL?
    var status: Status = .queued
    var progress: Double = 0
    var message: String = "順番待ち"
    var transcript: Transcript?
    var error: String?
    let isRecording: Bool
    let cancelFlag = CancelFlag()
    /// 録音した音声 (ファイルから読み直さずに使う)
    @ObservationIgnored var samples: [Float]?

    init(name: String, url: URL?, isRecording: Bool = false, samples: [Float]? = nil) {
        self.name = name
        self.url = url
        self.isRecording = isRecording
        self.samples = samples
    }

    var isActive: Bool { status == .queued || status == .running }
}

enum ModelAvailability: Equatable {
    case installed
    case notInstalled
    case downloading(Double)
}

@MainActor
@Observable
final class AppModel {
    // MARK: 状態
    var jobs: [Job] = []
    var selectedJobID: Job.ID?
    var installedModelIDs: Set<String> = []
    var downloads: [String: Double] = [:]
    var errorMessage: String?
    var showTimestamps = true
    var searchText = ""
    let player = PlayerController()

    // 録音
    var isRecording = false
    var recordingStartedAt: Date?
    var recordingLevel: Float = 0
    var livePreviewText = ""

    // 設定 (UserDefaults に保存)
    var languageCode: String { didSet { save(languageCode, "languageCode") } }
    var modelID: String { didSet { save(modelID, "modelID") } }
    var preferAccuracy: Bool { didSet { save(preferAccuracy, "preferAccuracy") } }
    var useVAD: Bool { didSet { save(useVAD, "useVAD") } }
    var filterHallucinations: Bool { didSet { save(filterHallucinations, "filterHallucinations") } }
    var livePreview: Bool { didSet { save(livePreview, "livePreview") } }
    var initialPrompt: String { didSet { save(initialPrompt, "initialPrompt") } }

    let store = ModelStore()
    @ObservationIgnored private let service = TranscriptionService()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var recorder: LiveRecorder?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var vadTask: Task<String?, Never>?
    @ObservationIgnored private var vadRetryAfter: Date?

    init() {
        let d = UserDefaults.standard
        languageCode = d.string(forKey: "languageCode") ?? "ja"
        let savedModel = d.string(forKey: "modelID") ?? ModelCatalog.defaultModelID
        modelID = ModelCatalog.spec(id: savedModel) == nil ? ModelCatalog.defaultModelID : savedModel
        preferAccuracy = d.object(forKey: "preferAccuracy") as? Bool ?? true
        useVAD = d.object(forKey: "useVAD") as? Bool ?? true
        filterHallucinations = d.object(forKey: "filterHallucinations") as? Bool ?? true
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
        initialPrompt = d.string(forKey: "initialPrompt") ?? ""
        if !Languages.isKnown(languageCode) { languageCode = "ja" }
        refreshInstalled()
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var selectedJob: Job? {
        jobs.first { $0.id == selectedJobID }
    }

    var currentModel: WhisperModelSpec {
        ModelCatalog.spec(id: modelID) ?? ModelCatalog.all[0]
    }

    // MARK: モデル
    func refreshInstalled() {
        installedModelIDs = Set(ModelCatalog.all.filter { store.isInstalled($0) }.map(\.id))
    }

    func availability(of spec: WhisperModelSpec) -> ModelAvailability {
        if let fraction = downloads[spec.id] { return .downloading(fraction) }
        return installedModelIDs.contains(spec.id) ? .installed : .notInstalled
    }

    /// 同じモデルの取得は 1 本にまとめる。待っているジョブが中止されても、取得は最後まで続ける。
    private func startDownload(_ spec: WhisperModelSpec) -> Task<Void, Error> {
        if let running = downloadTasks[spec.id] { return running }
        let task = Task { try await self.performDownload(spec) }
        downloadTasks[spec.id] = task
        Task {
            _ = try? await task.value
            if downloadTasks[spec.id] == task { downloadTasks[spec.id] = nil }
        }
        return task
    }

    /// モデルが無ければダウンロードして、ファイルの場所を返す。
    /// cancelFlag を渡すと、取得の途中でも中止にすぐ反応する (取得そのものは裏で続く)。
    @discardableResult
    func ensureModel(_ spec: WhisperModelSpec, cancelFlag: CancelFlag? = nil) async throws -> URL {
        let url = store.url(for: spec)
        if store.isInstalled(spec) {
            if !installedModelIDs.contains(spec.id) { refreshInstalled() }
            return url
        }
        let task = startDownload(spec)
        if let cancelFlag {
            while downloadTasks[spec.id] == task {
                if cancelFlag.isSet { throw WhisperError.cancelled }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try await task.value // 取得に失敗していればここで投げる
        return url
    }

    func download(_ spec: WhisperModelSpec) {
        Task {
            do {
                try await ensureModel(spec)
            } catch is CancellationError {
            } catch {
                errorMessage = "\(spec.displayName) を取得できませんでした: \(error.localizedDescription)\n\nHugging Face (huggingface.co) に接続できない場合は、設定の「手元のファイルを追加」から .bin を取り込めます。"
            }
        }
    }

    private func performDownload(_ spec: WhisperModelSpec) async throws {
        downloads[spec.id] = 0
        defer { downloads[spec.id] = nil }
        try store.ensureDirectory()
        try await ModelDownloader.download(
            from: spec.downloadURL,
            to: store.url(for: spec),
            onProgress: { [weak self] fraction, _, _ in
                Task { @MainActor in
                    guard let self, self.downloads[spec.id] != nil else { return }
                    self.downloads[spec.id] = fraction
                }
            }
        )
        // 待っていたジョブが全部中止されていても「取得済み」に切り替える
        refreshInstalled()
        // オンラインのうちに、無音検出 (VAD) モデル (約 0.9 MB) も取っておく
        if useVAD {
            Task { _ = await self.vadModelPath() }
        }
    }

    func deleteModel(_ spec: WhisperModelSpec) {
        do {
            try store.delete(spec)
        } catch {
            errorMessage = "削除できませんでした: \(error.localizedDescription)"
        }
        refreshInstalled()
    }

    func importModelFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = "whisper.cpp のモデル (ggml-large-v3-turbo-q5_0.bin など) を選んでください"
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch try store.importFile(from: url) {
            case .model(let spec):
                refreshInstalled()
                modelID = spec.id
            case .vad:
                vadRetryAfter = nil
                errorMessage = "無音検出 (VAD) モデルを追加しました。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealModelsFolder() {
        try? store.ensureDirectory()
        NSWorkspace.shared.open(store.directory)
    }

    /// 無音スキップ用の VAD モデル (約 0.9 MB) の場所。無ければ取得する。
    /// 取れなければ VAD なしで続け、失敗したら 10 分は取り直さない (繋がらないネットワークで毎回待たせない)。
    private func vadModelPath() async -> String? {
        guard useVAD else { return nil }
        if store.isVADInstalled { return store.vadURL.path }
        if let retry = vadRetryAfter, Date() < retry { return nil }
        if let running = vadTask { return await running.value }

        let destination = store.vadURL
        let directory = store
        let task = Task<String?, Never> {
            do {
                try directory.ensureDirectory()
                // 0.9 MB なので 20 秒で見切る (子タスクを止めるとダウンロードも止まる)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await ModelDownloader.download(
                            from: ModelCatalog.vadURL,
                            to: destination,
                            validate: { ModelFile.isValidModel(at: $0, minimumBytes: 100_000) }
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(20))
                        throw URLError(.timedOut)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
                return destination.path
            } catch {
                return nil
            }
        }
        vadTask = task
        let path = await task.value
        vadTask = nil
        vadRetryAfter = path == nil ? Date().addingTimeInterval(10 * 60) : nil
        return path
    }

    // MARK: ファイル
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.message = "文字起こしする音声・動画ファイルを選んでください"
        panel.prompt = "文字起こし"
        if panel.runModal() == .OK {
            enqueue(panel.urls)
        }
    }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            let job = Job(name: url.lastPathComponent, url: url)
            jobs.insert(job, at: 0)
            if selectedJobID == nil || selectedJob?.isActive == false {
                select(job)
            }
        }
        ensureWorker()
    }

    func select(_ job: Job?) {
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
            job.message = "中止しました"
        case .running:
            job.cancelFlag.set()
            job.message = "中止しています…"
        default:
            break
        }
    }

    func remove(_ job: Job) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { select(jobs.first) }
    }

    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            defer { self?.worker = nil }
            while let self, let job = self.jobs.last(where: { $0.status == .queued }) {
                await self.run(job)
            }
        }
    }

    private func run(_ job: Job) async {
        job.status = .running
        job.progress = 0
        job.error = nil
        let spec = currentModel
        do {
            if !store.isInstalled(spec) {
                job.message = "\(spec.displayName) をダウンロード中 (初回のみ)…"
            }
            let modelURL = try await ensureModel(spec, cancelFlag: job.cancelFlag)
            if job.cancelFlag.isSet { throw WhisperError.cancelled }

            if useVAD && !store.isVADInstalled {
                job.message = "無音検出 (VAD) モデルを準備中…"
            }
            let vadPath = await vadModelPath()
            if job.cancelFlag.isSet { throw WhisperError.cancelled }

            let samples: [Float]
            if let recorded = job.samples {
                samples = recorded
            } else if let url = job.url {
                job.message = "音声を読み込み中…"
                samples = try await AudioDecoder.decode(url: url, cancelFlag: job.cancelFlag)
            } else {
                throw WhisperError.emptyAudio
            }
            job.samples = nil
            if job.cancelFlag.isSet { throw WhisperError.cancelled }

            let duration = Double(samples.count) / AudioDecoder.sampleRate
            job.transcript = Transcript(sourceName: job.name, model: spec.id, duration: duration)
            job.message = service.isReady(modelPath: modelURL.path, vad: vadPath != nil) ? "認識中…" : "モデルを読み込み中…"

            let options = WhisperOptions(
                language: languageCode,
                useBeamSearch: preferAccuracy,
                vadModelPath: vadPath,
                initialPrompt: initialPrompt,
                filterHallucinations: filterHallucinations
            )
            let flag = job.cancelFlag
            let started = Date()
            let output = try await service.transcribe(
                samples: samples,
                modelPath: modelURL.path,
                options: options,
                onProgress: { fraction in
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        job.progress = fraction
                        job.message = "認識中 \(Int(fraction * 100))%"
                    }
                },
                onSegment: { segment in
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        job.transcript?.segments.append(segment)
                    }
                },
                shouldCancel: { flag.isSet }
            )
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
            job.message = "完了"
        } catch let error as WhisperError where error == .cancelled {
            job.status = .cancelled
            job.message = "中止しました"
            cleanPartialTranscript(of: job)
        } catch {
            if job.cancelFlag.isSet {
                job.status = .cancelled
                job.message = "中止しました"
            } else {
                job.status = .failed
                job.error = error.localizedDescription
                job.message = "エラー"
            }
            cleanPartialTranscript(of: job)
        }
    }

    /// 中止・失敗したジョブの途中結果にも、完了時と同じ繰り返しの後始末をかける (画面に残り、コピーもできるため)。
    /// 状態を .running 以外にしてから呼ぶので、このあと遅れて届く区間は追加されない。
    private func cleanPartialTranscript(of job: Job) {
        guard filterHallucinations, var transcript = job.transcript, !transcript.segments.isEmpty else { return }
        transcript.segments = RepetitionFilter.clean(transcript.segments)
        job.transcript = transcript
    }

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
            self.errorMessage = "入力デバイスが切り替わったため録音を止めました。ここまでの録音を文字起こしします。(\(error.localizedDescription))"
        }
        do {
            try await recorder.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        self.recorder = recorder
        isRecording = true
        recordingStartedAt = Date()
        livePreviewText = ""

        // プレビューのために、取得済みならモデルを先に読み込んでおく
        let spec = currentModel
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
            let options = WhisperOptions(
                language: languageCode,
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

        guard samples.count >= Int(LiveRecorder.sampleRate / 2) else {
            errorMessage = "録音が短すぎます (0.5 秒未満)。"
            return
        }
        let url = try? saveRecording(samples, startedAt: started)
        let job = Job(name: "録音 \(Self.displayStamp.string(from: started))", url: url, isRecording: true, samples: samples)
        jobs.insert(job, at: 0)
        select(job)
        ensureWorker()
    }

    private func saveRecording(_ samples: [Float], startedAt: Date) throws -> URL {
        let dir = store.directory.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("録音-\(Self.fileStamp.string(from: startedAt)).wav")
        try WAV.encode(samples: samples, sampleRate: Int(LiveRecorder.sampleRate)).write(to: url)
        return url
    }

    private static let displayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: 書き出し
    func export(as format: ExportFormat) {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "transcript" : base).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.render(transcript, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    func copySelectedText() {
        guard let transcript = selectedJob?.transcript else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript.text(withTimestamps: showTimestamps), forType: .string)
    }
}
