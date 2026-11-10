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
    /// 文字起こしの言語 (nil なら、始めるときの設定)。始めたら、使った言語が入る
    var languageCode: String?
    /// 「日本語＋英語でやり直す」の案内を閉じた
    var mixedSuggestionDismissed = false

    // 文字起こしのあとの監査・翻訳
    /// これから行う監査・翻訳
    var postQueue: [PostTask] = []
    /// いま行っている監査・翻訳
    var postState: PostState = .idle
    /// 監査・翻訳のお知らせ (失敗・一部だけ訳せなかった など)
    var postNote: String?
    @ObservationIgnored var postCancel = CancelFlag()
    /// 録音のために一時停止した (メモリの少ない Mac)。録音を止めると続ける
    @ObservationIgnored var pausedForRecording = false

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

/// 設定のウインドウのタブ
enum SettingsTab: Hashable {
    case transcription
    case llm
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
    /// 設定で開いているタブ (保存しない。LLM の案内の「設定で選ぶ…」で「監査・翻訳」に切り替える)
    var settingsTab: SettingsTab = .transcription
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
    var llmModelID: String {
        didSet {
            save(llmModelID, "llmModelID")
            hasAdapter = llmStore.hasAdapter(forModelKey: adapterKey)
        }
    }
    var autoAudit: Bool { didSet { save(autoAudit, "autoAudit") } }
    var autoTranslate: Bool { didSet { save(autoTranslate, "autoTranslate") } }
    /// 原文と日本語訳を左右に並べて表示する
    var showBilingual: Bool { didSet { save(showBilingual, "showBilingual") } }
    /// 学習した直し (監査の一覧で利用者が決めた直し・設定で自分で書いた直し)。Mac の中だけに保存する
    var ledger = CorrectionLedger()
    /// 学習した直しを使う (監査の前に当てる・断った直しを出さない・正しい語を語彙のヒントに足す)
    var useLedger: Bool { didSet { save(useLedger, "useLedger") } }
    /// 追加学習の差分 (LoRA) を使う (選んでいる LLM 用の差分が入っているときだけ効く)
    var useAdapter: Bool { didSet { save(useAdapter, "useAdapter") } }
    /// 選んでいる LLM 用の差分が入っている
    var hasAdapter = false
    /// 差分を取り込んでいる
    var importingAdapter = false
    var installedLLMIDs: Set<String> = []
    var customLLMFiles: [String] = []
    var llmDownloads: [String: Double] = [:]
    /// 結果の画面の、LLM の取得の案内を閉じた (この起動のあいだだけ。始めの画面の案内も出さなくなる)
    var llmBannerDismissed = false
    /// 始めの画面の、LLM の取得の案内を閉じた (この起動のあいだだけ。結果の画面の案内は、これとは別に出す)
    var llmSetupCardDismissed = false
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
        useLedger = d.object(forKey: "useLedger") as? Bool ?? true
        useAdapter = d.object(forKey: "useAdapter") as? Bool ?? true
        llmStore = LLMModelStore(models: store)
        ledger = CorrectionLedger.load(from: ledgerURL)
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

    // MARK: 学習した直し

    /// 保存先 (モデルのフォルダのとなり: ~/Library/Application Support/Kikimimi/learned-corrections.json)
    var ledgerURL: URL {
        store.directory.deletingLastPathComponent().appendingPathComponent("learned-corrections.json")
    }

    private func saveLedger() {
        do {
            try ledger.save(to: ledgerURL)
        } catch {
            errorMessage = "学習した直しを保存できませんでした: " + error.localizedDescription
        }
    }

    /// 設定の画面で、利用者が自分で書いた直し (いつも当てる)
    @discardableResult
    func teachCorrection(wrong: String, right: String) -> Bool {
        guard ledger.teach(wrong: wrong, right: right) else { return false }
        saveLedger()
        return true
    }

    func removeCorrection(_ id: UUID) {
        ledger.remove(id)
        saveLedger()
    }

    /// 語彙のヒント: 設定で書いたものに、学習した正しい語を足したもの (文字起こし・監査・翻訳で使う)
    var effectiveHint: String {
        useLedger ? (ledger.glossary(adding: initialPrompt) ?? "") : initialPrompt
    }

    /// 作業中か (文字起こし・録音・監査・翻訳・モデルの取得や取り込み)。作業中は、ウインドウを閉じてもアプリを終了しない
    var isBusy: Bool {
        isRecording || importingLLM || importingAdapter || !downloads.isEmpty || !llmDownloads.isEmpty
            || jobs.contains { $0.isActive || $0.isPostActive }
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
        // 一覧に無い ID (前の版の設定など) も、おすすめに戻す (設定の選択肢に当てはまるものが無くなる)
        if !llmModelID.hasPrefix("file:"), LLMCatalog.spec(id: llmModelID) == nil {
            llmModelID = LLMCatalog.defaultModelID
        }
        hasAdapter = llmStore.hasAdapter(forModelKey: adapterKey)
    }

    // MARK: 追加学習の差分 (LoRA)

    /// 選んでいる LLM の、差分の名前 (一覧のモデルは ID、取り込んだ GGUF はファイル名から拡張子を除いたもの)。
    /// `tools/finetune/finetune.py --install` が置く名前と同じ
    var adapterKey: String {
        let current = currentLLM
        return current.spec?.id ?? current.url.deletingPathExtension().lastPathComponent
    }

    /// 監査・翻訳で使う差分 (使う設定で、選んでいる LLM 用のものが入っているときだけ)
    var activeAdapterPath: String? {
        useAdapter && hasAdapter ? llmStore.adapterURL(forModelKey: adapterKey).path : nil
    }

    func importAdapter() {
        guard isLLMInstalled else {
            errorMessage = "先に LLM を取得してください (差分は、選んでいる LLM に合わせて確かめます)。"
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = "追加学習の差分 (….lora.gguf) を選んでください。選んでいる LLM (\(currentLLM.name)) 用として入れます"
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = llmStore
        let key = adapterKey
        let modelURL = currentLLM.url
        importingAdapter = true
        Task {
            defer { importingAdapter = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.importAdapter(from: url, forModelKey: key, modelURL: modelURL)
                }.value
                llm.adapterChanged()
                refreshLLMInstalled()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeAdapter() {
        do {
            try llmStore.deleteAdapter(forModelKey: adapterKey)
        } catch {
            errorMessage = "削除できませんでした: \(error.localizedDescription)"
        }
        llm.adapterChanged()
        refreshLLMInstalled()
    }

    /// 学習用のデータに入れる「直す必要のなかった行」: 監査を終えた文字起こしの中で、監査が何も指摘しなかった行。
    /// 多すぎると書き出しが大きくなるだけなので、まんべんなく limit 行まで
    func cleanLinesForTraining(limit: Int = 600) -> [FineTuneData.CleanLine] {
        var lines: [FineTuneData.CleanLine] = []
        var seen = Set<String>()
        for job in jobs {
            guard let transcript = job.transcript, let audit = transcript.audit else { continue }
            let touched = Set(audit.changes.map(\.original.id))
            for segment in transcript.segments where !touched.contains(segment.id) {
                let text = segment.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard text.count >= 4, seen.insert(text).inserted else { continue }
                lines.append(FineTuneData.CleanLine(text: text, language: segment.language ?? transcript.language))
            }
        }
        guard lines.count > limit else { return lines }
        return (0..<limit).map { lines[$0 * lines.count / limit] }
    }

    /// 学習した直しから、追加学習 (LoRA) 用のデータを書き出す (`tools/finetune/finetune.py --data` に渡す)
    func exportTrainingData() {
        let clean = cleanLinesForTraining()
        let records = FineTuneData.records(ledger: ledger, cleanLines: clean)
        guard !records.isEmpty else {
            errorMessage = "書き出せる学習データがまだありません。監査の一覧で直しを反映したり元に戻したりすると、学習した直しがたまります。"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kikimimi-training.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        panel.canCreateDirectories = true
        panel.message = "学習データ \(records.count) 件を書き出します (この Mac の中だけで使います)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FineTuneData.jsonl(records).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
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
                errorMessage = "\(spec.displayName) を取得できませんでした: \(error.localizedDescription)\n\nHugging Face (huggingface.co) に接続できない場合は、設定の「監査・翻訳」タブの「手元の GGUF を追加…」から取り込めます。"
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

    /// LLM の置き場所 (画面に出す用。ホームは ~ で表す)
    var llmFolderPath: String {
        (llmStore.directory.path as NSString).abbreviatingWithTildeInPath
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

    /// 同じファイルを、別の言語の設定でもう一度文字起こしする (新しいジョブ。設定の言語は変えない)
    func retranscribe(_ job: Job, languageCode code: String) {
        guard let url = job.url else { return }
        // 置き換える文字起こしの監査・翻訳は止める (待っていると、やり直しがその後ろに回る。反映済みの結果は残す)
        cancelPost(job)
        let again = Job(name: job.name, url: url)
        again.languageCode = code
        jobs.insert(again, at: 0)
        job.mixedSuggestionDismissed = true
        select(again)
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
        let hadQueue = !job.postQueue.isEmpty
        job.postQueue.removeAll()
        if job.postState != .idle {
            job.postCancel.set()
        } else if hadQueue {
            // 録音のあいだ一時停止していた作業を取りやめた: 「録音を止めると続けます」を残さない
            job.postNote = "監査・翻訳を中止しました。反映済みの結果は残しています。"
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
        let before = transcript.audit?.changes.first { $0.id == change.id }
        transcript.setChange(change.id, applied: applied)
        job.transcript = transcript
        // 利用者が自分で決めた直しを覚える (次からは、反映した直しは先に当て、元に戻した直しは出さない)
        let after = transcript.audit?.changes.first { $0.id == change.id }
        if useLedger, let before, let after, before.kind == .fix, before.isApplied != after.isApplied,
           let wrong = before.wrong, let right = before.right {
            ledger.record(wrong: wrong, right: right, language: transcript.language(of: before.original),
                          example: before.original.text, accepted: after.isApplied)
            saveLedger()
        }
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
        let glossary = effectiveHint
        let learned = useLedger ? ledger : nil
        let adapter = activeAdapterPath
        let language = transcript.language
        defer { job.postState = .idle }
        defer {
            if job.pausedForRecording {
                job.pausedForRecording = false
                job.postNote = "録音のあいだ一時停止しています。録音を止めると続けます。"
            }
        }

        // メモリの少ない Mac では、LLM を読み込む前に Whisper を手放す
        if useLLM && MemoryBudget.isTight { service.unload() }
        let preparing = llm.isLoaded(modelPath: selection.url.path) ? "" : " (LLM を読み込み中)"
        /// 差分を読み込めなかったときの知らせ (差分なしで動かした)
        func adapterNote(_ note: String?) -> String? {
            guard let adapter, llm.failedAdapter() == adapter else { return note }
            let warning = "追加学習の差分を読み込めなかったので、差分なしで動かしました (設定の「監査・翻訳」で差分を入れ直すか、外してください)。"
            return note.map { $0 + " " + warning } ?? warning
        }

        do {
            switch task {
            case .audit:
                job.postState = .running(.audit, message: "監査中…", progress: nil)
                let segments = transcript.segmentsBeforeAudit
                let options = AuditOptions(glossary: glossary, ledger: learned)
                // 前に LLM で監査してあれば、やり直しの結果は最後にまとめて反映する
                // (途中で規則だけの結果を反映すると、前の LLM の直しといっしょに訳まで外れてしまう。中止したら前の結果のまま)
                let hadLLMAudit = transcript.audit?.model != nil
                // LLM を消したあとで、LLM の監査をやり直そうとした: 規則だけで上書きすると前の LLM の直しと訳が外れるので、そのままにする
                if hadLLMAudit && !useLLM {
                    job.postNote = "LLM が見つからないため、前の監査の結果のままにしました。LLM でもう一度見直すには、設定の「監査・翻訳」から LLM を取得してください。"
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
                    job.postNote = "LLM が未取得のため、繰り返しの見直しだけを行いました。聞き取りミスも見直すには、設定の「監査・翻訳」から LLM を取得してください。"
                    return
                }
                // 規則の見直しのあいだに、メモリの少ない Mac で録音が始まった: LLM は録音のあとで
                if pauseIfRecording(.audit, job: job) { return }
                job.postState = .running(.audit, message: "監査中…" + preparing, progress: nil)
                let partial = LockedBox<AuditReport>()
                do {
                    let report = try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                                   shouldCancel: { flag.isSet }) { engine in
                        try Auditor.audit(segments, language: language, options: options, generator: engine,
                                          modelName: selection.name + (engine.adapterPath == nil ? "" : " + 追加学習"),
                                          shouldCancel: { flag.isSet },
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
                    job.postNote = adapterNote(job.postNote)
                } catch {
                    let cancelled = flag.isSet || (error as? LLMError) == .cancelled
                    if hadLLMAudit {
                        // やり直しの途中: 前の監査の結果をそのまま残す
                        job.postNote = cancelled
                            ? "監査のやり直しを中止しました。前の監査の結果のままです。"
                            : "LLM で見直せなかったため、前の監査の結果のままです: " + error.localizedDescription
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
                        job.postNote = "監査を中止しました。見終えた所までの結果を反映しています。"
                    } else if adoptedPartial {
                        job.postNote = "LLM の見直しが途中で止まりました。見終えた所までの結果を反映しています: " + error.localizedDescription
                    } else {
                        job.postNote = "LLM で見直せなかったため、繰り返しの見直しだけを反映しました: " + error.localizedDescription
                    }
                    return
                }

            case .translate:
                guard useLLM else { return }
                if pauseIfRecording(.translate, job: job) { return }
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
                let (failed, all) = try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                                      shouldCancel: { flag.isSet }) { engine in
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
                job.postNote = adapterNote(job.postNote)
            }
        } catch {
            if flag.isSet || (error as? LLMError) == .cancelled {
                job.postNote = task == .audit ? "監査を中止しました。" : "翻訳を中止しました。訳せた所までは残しています。"
            } else {
                job.postNote = (task == .audit ? "監査" : "翻訳") + "できませんでした: " + error.localizedDescription
            }
        }
    }

    /// メモリの少ない Mac で録音中なら、この仕事を順番待ちの先頭に戻して true を返す (録音を止めると続ける)
    private func pauseIfRecording(_ task: PostTask, job: Job) -> Bool {
        guard isRecording, MemoryBudget.isTight else { return false }
        if !job.postQueue.contains(task) { job.postQueue.insert(task, at: 0) }
        job.pausedForRecording = true
        return true
    }

    /// メモリの少ない Mac で録音を始めるとき: 動いている監査・翻訳を止めて順番待ちの先頭に戻す
    /// (LLM を手放してから Whisper を読み込む。訳せた所・監査で見終えた所までは残り、録音を止めると続きから)
    private func pausePostTasksForRecording() {
        guard MemoryBudget.isTight else { return }
        for job in jobs {
            guard let task = job.postState.task else { continue }
            if !job.postQueue.contains(task) { job.postQueue.insert(task, at: 0) }
            job.pausedForRecording = true
            job.postCancel.set()
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
