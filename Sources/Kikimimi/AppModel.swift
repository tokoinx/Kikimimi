import AppKit
import Foundation
import KikimimiCore
import KikimimiLLM
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

    // 文字起こしのあとの監査・翻訳
    /// これから行う監査・翻訳
    var postQueue: [PostTask] = []
    /// いま行っている監査・翻訳
    var postState: PostState = .idle
    /// 監査・翻訳のお知らせ (失敗・一部だけ訳せなかった など)
    var postNote: String?
    @ObservationIgnored var postCancel = CancelFlag()

    init(name: String, url: URL?, isRecording: Bool = false, samples: [Float]? = nil) {
        self.name = name
        self.url = url
        self.isRecording = isRecording
        self.samples = samples
    }

    var isActive: Bool { status == .queued || status == .running }
    /// 監査・翻訳が待っている / 動いている
    var isPostActive: Bool { !postQueue.isEmpty || postState != .idle }
}

/// 文字起こしのあとに行う仕事
enum PostTask: Equatable {
    case audit
    case translate
}

enum PostState: Equatable {
    case idle
    case running(PostTask, message: String, progress: Double?)
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
    // 監査・翻訳 (ローカル LLM)
    /// 一覧のモデルの ID か、`file:` + 取り込んだ GGUF のファイル名
    var llmModelID: String { didSet { save(llmModelID, "llmModelID") } }
    var autoAudit: Bool { didSet { save(autoAudit, "autoAudit") } }
    var autoTranslate: Bool { didSet { save(autoTranslate, "autoTranslate") } }
    /// 原文と日本語訳を左右に並べて表示する
    var showBilingual: Bool { didSet { save(showBilingual, "showBilingual") } }
    var installedLLMIDs: Set<String> = []
    var customLLMFiles: [String] = []
    var llmDownloads: [String: Double] = [:]
    /// LLM の取得の案内を閉じた (この起動のあいだだけ)
    var llmBannerDismissed = false
    /// 手元の GGUF を取り込んでいる
    var importingLLM = false

    let store = ModelStore()
    let llmStore: LLMModelStore
    @ObservationIgnored private let service = TranscriptionService()
    @ObservationIgnored private let llm = LLMService()
    @ObservationIgnored private var llmDownloadTasks: [String: Task<Void, Never>] = [:]
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
        llmModelID = d.string(forKey: "llmModelID") ?? LLMCatalog.defaultModelID
        autoAudit = d.object(forKey: "autoAudit") as? Bool ?? true
        autoTranslate = d.object(forKey: "autoTranslate") as? Bool ?? true
        showBilingual = d.object(forKey: "showBilingual") as? Bool ?? true
        llmStore = LLMModelStore(models: store)
        if !Languages.isKnown(languageCode) { languageCode = "ja" }
        refreshInstalled()
        refreshLLMInstalled()
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
            @unknown default:
                // KikimimiWhisper は library evolution でビルドしているため、将来の値にも備える
                refreshInstalled()
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

    // MARK: 監査・翻訳のモデル (ローカル LLM)
    struct LLMSelection: Equatable {
        let id: String
        let name: String
        let url: URL
        let spec: LLMModelSpec?
    }

    /// 選んでいる LLM
    var currentLLM: LLMSelection {
        if llmModelID.hasPrefix("file:") {
            let name = String(llmModelID.dropFirst(5))
            return LLMSelection(id: llmModelID, name: (name as NSString).deletingPathExtension,
                                url: llmStore.url(forFile: name), spec: nil)
        }
        let spec = LLMCatalog.spec(id: llmModelID) ?? LLMCatalog.all[0]
        return LLMSelection(id: spec.id, name: spec.displayName, url: llmStore.url(for: spec), spec: spec)
    }

    var isLLMInstalled: Bool {
        let current = currentLLM
        if let spec = current.spec { return installedLLMIDs.contains(spec.id) }
        return customLLMFiles.contains(current.url.lastPathComponent)
    }

    func refreshLLMInstalled() {
        installedLLMIDs = Set(LLMCatalog.all.filter { llmStore.isInstalled($0) }.map(\.id))
        customLLMFiles = llmStore.customFiles()
        // 選んでいた取り込みのモデルが消えていたら、一覧のおすすめに戻す
        if llmModelID.hasPrefix("file:"), !customLLMFiles.contains(String(llmModelID.dropFirst(5))) {
            llmModelID = LLMCatalog.defaultModelID
        }
    }

    func llmAvailability(of spec: LLMModelSpec) -> ModelAvailability {
        if let fraction = llmDownloads[spec.id] { return .downloading(fraction) }
        return installedLLMIDs.contains(spec.id) ? .installed : .notInstalled
    }

    func downloadLLM(_ spec: LLMModelSpec) {
        guard llmDownloadTasks[spec.id] == nil else { return }
        llmDownloads[spec.id] = 0
        llmDownloadTasks[spec.id] = Task {
            defer {
                llmDownloads[spec.id] = nil
                llmDownloadTasks[spec.id] = nil
                // どう終わっても置き場所を見直す (中止がちょうど置き終えた直後に届いても、取得済みと表示できるように)
                refreshLLMInstalled()
            }
            do {
                try llmStore.ensureDirectory()
                let resolved = try await HuggingFaceResolver.resolve(spec)
                try Task.checkCancellation()
                let size = resolved.expectedSize
                let sha = resolved.sha256
                try await ModelDownloader.download(
                    from: resolved.url,
                    to: llmStore.url(for: spec),
                    validate: { FileHash.validateDownload(at: $0, expectedSize: size, sha256: sha) },
                    onProgress: { [weak self] fraction, _, _ in
                        Task { @MainActor in
                            guard let self, self.llmDownloads[spec.id] != nil else { return }
                            self.llmDownloads[spec.id] = fraction
                        }
                    }
                )
                refreshLLMInstalled()
                // 中止されていたら、見直し・翻訳は始めない
                try Task.checkCancellation()
                // 取得のきっかけになった結果 (いま開いているもの) を、そのまま LLM で見直し・翻訳する
                if currentLLM.spec?.id == spec.id, let job = selectedJob, job.status == .done, let t = job.transcript {
                    var tasks: [PostTask] = []
                    if autoAudit, t.audit?.model == nil { tasks.append(.audit) }
                    if autoTranslate, t.isMainlyForeign, t.untranslatedCount > 0 { tasks.append(.translate) }
                    if !tasks.isEmpty { schedulePostTasks(for: job, automatic: false, tasks: tasks) }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = "\(spec.displayName) を取得できませんでした: \(error.localizedDescription)\n\nHugging Face (huggingface.co) に接続できない場合は、設定の「手元の GGUF を追加」から取り込めます。"
            }
        }
    }

    func cancelLLMDownload(_ spec: LLMModelSpec) {
        llmDownloadTasks[spec.id]?.cancel()
    }

    func deleteLLM(_ spec: LLMModelSpec) {
        deleteLLMFile(spec.fileName)
    }

    func deleteLLMFile(_ name: String) {
        llm.unload()
        do {
            try llmStore.delete(fileNamed: name)
        } catch {
            errorMessage = "削除できませんでした: \(error.localizedDescription)"
        }
        refreshLLMInstalled()
    }

    func importLLMFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = "llama.cpp で動く LLM (.gguf) を選んでください"
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = llmStore
        importingLLM = true
        Task {
            defer { importingLLM = false }
            do {
                // 数 GB を写すので、画面を止めないよう裏で行う
                let name = try await Task.detached(priority: .userInitiated) { try store.importFile(from: url) }.value
                refreshLLMInstalled()
                if let spec = LLMCatalog.all.first(where: { $0.fileName == name }) {
                    llmModelID = spec.id
                } else {
                    llmModelID = "file:" + name
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealLLMFolder() {
        try? llmStore.ensureDirectory()
        NSWorkspace.shared.open(llmStore.directory)
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
            cancelPost(job)
        }
    }

    /// 監査・翻訳を止める (反映済みの結果は残す)
    func cancelPost(_ job: Job) {
        job.postQueue.removeAll()
        if job.postState != .idle {
            job.postCancel.set()
        }
    }

    func remove(_ job: Job) {
        if job.isActive { cancel(job) }
        cancelPost(job)
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { select(jobs.first) }
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

    private func ensureWorker() {
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
            // 手が空いたら LLM を手放す (数 GB のメモリを空ける。次に使うときは数秒で読み直せる)
            self?.llm.unload()
        }
    }

    private func run(_ job: Job) async {
        job.status = .running
        job.progress = 0
        job.error = nil
        if MemoryBudget.isTight { llm.unload() }
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

    // MARK: 監査・翻訳

    /// 監査・翻訳を予約する。automatic は文字起こし直後の自動実行 (設定に従う)
    func schedulePostTasks(for job: Job, automatic: Bool, tasks: [PostTask]? = nil) {
        guard job.status == .done, let transcript = job.transcript, !transcript.segments.isEmpty else { return }
        var wanted = tasks ?? []
        if automatic {
            if autoAudit { wanted.append(.audit) }
            // 翻訳は LLM が手元にあり、日本語以外が主な文字起こしのときだけ (LLM が無ければ画面で取得を案内する)
            if autoTranslate, isLLMInstalled, transcript.isMainlyForeign { wanted.append(.translate) }
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

    /// まだ訳していない区間を日本語に訳す
    func translate(_ job: Job) {
        guard isLLMInstalled else {
            errorMessage = "日本語に訳すには、ローカル LLM「\(currentLLM.name)」が必要です。設定の「監査・翻訳」から取得してください。"
            return
        }
        schedulePostTasks(for: job, automatic: false, tasks: [.translate])
    }

    /// 監査の 1 か所を反映する / 元に戻す
    func setAuditChange(_ change: AuditChange, applied: Bool, in job: Job) {
        guard var transcript = job.transcript else { return }
        transcript.setChange(change.id, applied: applied)
        job.transcript = transcript
    }

    func revertAudit(of job: Job) {
        guard var transcript = job.transcript else { return }
        transcript.revertAllChanges()
        job.transcript = transcript
    }

    private func runPost(_ task: PostTask, for job: Job) async {
        guard job.status == .done, let transcript = job.transcript, !transcript.segments.isEmpty else { return }
        let flag = CancelFlag()
        job.postCancel = flag
        let selection = currentLLM
        let useLLM = isLLMInstalled
        let glossary = initialPrompt
        let language = transcript.language
        defer { job.postState = .idle }

        // メモリの少ない Mac では、LLM を読み込む前に Whisper を手放す
        if useLLM && MemoryBudget.isTight { service.unload() }
        let preparing = llm.isLoaded(modelPath: selection.url.path) ? "" : " (LLM を読み込み中)"

        do {
            switch task {
            case .audit:
                job.postState = .running(.audit, message: "監査中…", progress: nil)
                let segments = transcript.segmentsBeforeAudit
                let options = AuditOptions(glossary: glossary)
                // 規則だけの見直しは数秒で終わるので、先に反映しておく (LLM が失敗・中止しても、ここまでは残る)。
                // 長い録音では時間がかかるので、画面を止めないよう裏で回す
                let rules = try await Task.detached(priority: .userInitiated) {
                    try Auditor.audit(segments, language: language, options: options, generator: nil,
                                      modelName: nil, shouldCancel: { flag.isSet })
                }.value
                if flag.isSet { throw LLMError.cancelled }
                adopt(rules, in: job)
                guard useLLM else {
                    job.postNote = "LLM が未取得のため、繰り返しの見直しだけを行いました。聞き取りミスも見直すには、設定の「監査・翻訳」から LLM を取得してください。"
                    return
                }
                job.postState = .running(.audit, message: "監査中…" + preparing, progress: nil)
                let partial = LockedBox<AuditReport>()
                do {
                    let report = try await llm.run(modelPath: selection.url.path, shouldCancel: { flag.isSet }) { engine in
                        try Auditor.audit(segments, language: language, options: options, generator: engine,
                                          modelName: selection.name, shouldCancel: { flag.isSet },
                                          onProgress: { done, total in
                                              Task { @MainActor in
                                                  guard case .running(.audit, _, _) = job.postState, job.postCancel === flag else { return }
                                                  job.postState = .running(.audit, message: "監査中 \(done)/\(total)",
                                                                           progress: total > 0 ? Double(done) / Double(total) : nil)
                                              }
                                          },
                                          onPartial: { partial.value = $0 })
                    }
                    adopt(report, in: job)
                } catch {
                    // 中止・失敗: LLM が見終えたまとまりまでの結果を反映する (規則の結果は反映済み)
                    if let done = partial.value, done.model != nil { adopt(done, in: job) }
                    if flag.isSet || (error as? LLMError) == .cancelled {
                        job.postNote = "監査を中止しました。見終えた所までの結果を反映しています。"
                    } else {
                        job.postNote = "LLM で見直せなかったため、繰り返しの見直しだけを反映しました: " + error.localizedDescription
                    }
                    return
                }

            case .translate:
                guard useLLM else { return }
                job.postState = .running(.translate, message: "翻訳中…" + preparing, progress: nil)
                let segments = transcript.segments
                let sources = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                let options = TranslationOptions(glossary: glossary)
                let apply: @MainActor ([TranslationResult]) -> Void = { batch in
                    guard !batch.isEmpty, var t = job.transcript else { return }
                    // 訳しているあいだに監査で文が変わった区間には付けない
                    for result in batch { t.apply(result, sources: sources) }
                    t.translationModel = selection.name
                    job.transcript = t
                }
                let (failed, all) = try await llm.run(modelPath: selection.url.path, shouldCancel: { flag.isSet }) { engine in
                    var all: [TranslationResult] = []
                    let failed = try Translator.translate(segments, language: language, options: options, generator: engine,
                                                          shouldCancel: { flag.isSet }) { batch, done, total in
                        all += batch
                        Task { @MainActor in
                            apply(batch)
                            guard case .running(.translate, _, _) = job.postState, job.postCancel === flag else { return }
                            job.postState = .running(.translate, message: "翻訳中 \(done)/\(total)",
                                                     progress: total > 0 ? Double(done) / Double(total) : nil)
                        }
                    }
                    return (failed, all)
                }
                apply(all)
                if failed > 0 {
                    job.postNote = "\(failed) 区間は訳せませんでした。もう一度「翻訳」を押すと、残りだけを訳し直します。"
                }
            }
        } catch let error as LLMError where error == .cancelled {
            job.postNote = "中止しました。ここまでの結果は残しています。"
        } catch {
            if flag.isSet {
                job.postNote = "中止しました。ここまでの結果は残しています。"
            } else {
                job.postNote = (task == .audit ? "監査" : "翻訳") + "できませんでした: " + error.localizedDescription
            }
        }
    }

    /// 監査の結果を本文に反映する (前の監査の反映は元に戻し、利用者の決定は引き継ぐ)
    private func adopt(_ report: AuditReport, in job: Job) {
        guard var current = job.transcript else { return }
        current.adopt(report)
        job.transcript = current
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

        // プレビューのために、取得済みならモデルを先に読み込んでおく (メモリの少ない Mac では LLM を先に手放す)
        let spec = currentModel
        if MemoryBudget.isTight { llm.unload() }
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
        // 録音中に止めておいた監査・翻訳 (メモリの少ない Mac) を続ける
        defer { ensureWorker() }

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
    func export(as format: ExportFormat, content: ExportContent = .original) {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "transcript" : base)\(content.fileSuffix).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.render(transcript, as: format, content: content).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// 対訳で表示しているか (対訳表示がオンで、日本語以外が主な文字起こしか、訳が 1 つでもある)
    func isBilingual(_ stats: Transcript.TranslationStats) -> Bool {
        showBilingual && (stats.hasTranslation || stats.isMainlyForeign)
    }

    /// 本文をコピーする。対訳表示のときは原文と日本語訳を並べたもの
    func copySelectedText() {
        guard let transcript = selectedJob?.transcript else { return }
        let text: String
        let stats = transcript.translationStats
        if isBilingual(stats) && stats.hasTranslation {
            text = Exporter.txt(transcript, content: .bilingual)
        } else {
            text = transcript.text(withTimestamps: showTimestamps)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// スレッドをまたいで最新の値を受け渡す入れ物
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension PostState {
    /// 動いている仕事 (なければ nil)
    var task: PostTask? {
        if case .running(let task, _, _) = self { return task }
        return nil
    }
}
