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

    /// 保存に関わる変化 (AppModel が onChange で受け取り、少し待ってから保存する)
    enum Change {
        /// 状態が変わった (文字起こしが終わったら、はじめて保存する)
        case status
        /// 文字起こし・言語・版の一覧・音声の場所が変わった (document.json)
        case document
        /// メモが変わった (notes.md)
        case notes
    }

    let id: UUID
    let name: String
    var url: URL?
    /// 音声ファイルの場所 (ファイルが見つからなくなっても覚えておく。保存する)
    var sourcePath: String? {
        didSet { if sourcePath != oldValue { onChange?(self, .document) } }
    }
    let createdAt: Date
    var status: Status = .queued {
        didSet { if status != oldValue { onChange?(self, .status) } }
    }
    var progress: Double = 0
    var message: String = "順番待ち"
    /// 文字起こしの結果。中身が変わったら (続きが出た・監査や翻訳が入った・直しを反映した)、保存する
    var transcript: Transcript? {
        didSet { if transcript != oldValue { onChange?(self, .document) } }
    }
    var error: String?
    let isRecording: Bool
    let cancelFlag = CancelFlag()
    /// 録音した音声 (ファイルから読み直さずに使う)
    @ObservationIgnored var samples: [Float]?
    /// 文字起こしの言語 (nil なら、始めるときの設定)。始めたら、使った言語が入る
    var languageCode: String? {
        didSet { if languageCode != oldValue { onChange?(self, .document) } }
    }
    /// 「日本語＋英語でやり直す」の案内を閉じた
    var mixedSuggestionDismissed = false
    /// 日本語と英語が混ざっていたので、自動で「日本語＋英語」に切り替えた。切り替える前の言語 (設定の言語) が入る
    var autoMixedFrom: String? {
        didSet { if autoMixedFrom != oldValue { onChange?(self, .document) } }
    }
    /// 「自動で日本語＋英語にしました」の案内を閉じた
    var autoMixedNoticeDismissed = false
    /// 自動で「日本語＋英語」に切り替えない (案内の「〜だけでやり直す」で作ったジョブ)
    var allowsAutoMixed = true

    // 文字起こしのあとの監査・翻訳
    /// これから行う監査・翻訳
    var postQueue: [PostTask] = []
    /// いま行っている監査・翻訳
    var postState: PostState = .idle
    /// 監査・翻訳のお知らせ (失敗・一部だけ訳せなかった など)
    var postNote: String?
    /// 行の「訳」で頼まれた文の区間 (頼まれた順。訳し終えるまで残る。行ではこの区間に待ちの印を出す)
    var lineQueue: [UUID] = []
    /// 行の「訳」で頼まれた区間のうち、訳のある文を訳し直すもの (右クリックの「この文を訳し直す」)
    var lineRedo: Set<UUID> = []
    /// 行の「訳」を押したので、対訳の設定がオフでもこのジョブは対訳で表示する (設定には残さない。「対訳」を外すと消える)
    var showsLineTranslations = false
    @ObservationIgnored var postCancel = CancelFlag()
    /// 録音のために一時停止した (メモリの少ない Mac)。録音を止めると再開する
    @ObservationIgnored var pausedForRecording = false

    // 保存 (ライブラリ)
    /// メモ (notes.md に保存する)。これを見るのはメモの欄だけにする (一覧の行は見ない)
    var notes: String = "" {
        didSet {
            guard notes != oldValue else { return }
            notesRevision += 1
            let has = !notes.isEmpty
            if hasNotes != has { hasNotes = has }
            if notesSaved { notesSaved = false }
            onChange?(self, .notes)
        }
    }
    /// メモが空でない (空かどうかが変わったときだけ変わる。サイドバーの行と書き出しのメニューが見る)
    private(set) var hasNotes = false
    /// いまのメモを書き終えた (メモの欄の「保存しました」)
    var notesSaved = false
    /// メモを変えた回数 (書き終えたメモが、いまのメモと同じかを見分ける)
    @ObservationIgnored private(set) var notesRevision = 0
    /// 版の一覧 (新しい順)
    var versions: [VersionInfo] = [] {
        didSet { if versions != oldValue { onChange?(self, .document) } }
    }
    /// ライブラリに入れた (保存した・保存を頼んだ)。版と履歴は、このときだけ使える
    var inLibrary = false
    /// 版の保存・戻す・消すの最中
    var versionBusy = false
    /// 保存できなかったことを、もう知らせた (書き直すたびには知らせない)
    @ObservationIgnored var saveErrorReported = false
    /// document.json を書き終えた (まだなら、メモだけでなく全体を書く。はじめの保存が失敗したときも、メモの保存で書き直す)
    @ObservationIgnored var documentOnDisk = false
    /// 保存に関わる変化の受け口 (AppModel.adopt が入れる。一覧から外すと外す)
    @ObservationIgnored var onChange: (@MainActor (Job, Change) -> Void)?

    init(id: UUID = UUID(), name: String, url: URL?, isRecording: Bool = false, samples: [Float]? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.sourcePath = url?.path
        self.createdAt = createdAt
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
    /// 行の「訳」で頼まれた文だけを訳す (頼まれた文は Job.lineQueue。1 つの仕事で、待っている文をまとめて順に訳す)
    case translateLines
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
    let player: PlayerController
    /// 聞き取りの練習 (続けて流す・速さ・隠す・書き取り)。行の再生は、どこからでもこれを通す
    let practice: PracticeController

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
    /// 「日本語」「英語」「自動判定」のとき、日本語と英語が混ざった録音は自動で「日本語＋英語」で文字にする
    var autoMixedLanguage: Bool { didSet { save(autoMixedLanguage, "autoMixedLanguage") } }
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
    /// 結果の右にメモの欄を出す
    var showNotes: Bool { didSet { save(showNotes, "showNotes") } }
    /// メモの欄の幅 (pt)。メモの欄の左の区切りをつかんで変える
    var notesWidth: Double {
        didSet {
            let fitted = min(max(notesWidth, Self.notesWidthRange.lowerBound), Self.notesWidthRange.upperBound)
            if fitted != notesWidth { notesWidth = fitted }
            save(notesWidth, "notesWidth")
        }
    }
    /// メモの欄の幅の範囲 (pt)
    static let notesWidthRange: ClosedRange<Double> = 220...520
    /// 履歴の画面を開いているジョブ (nil なら閉じている)
    var historyJobID: Job.ID?
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
    /// 結果の保存先 (nil なら保存しない: 確認用の起動 --selftest-…)
    @ObservationIgnored private(set) var library: LibraryWriter?
    /// 少し待ってから document.json を書く予定 (ジョブの id ごと)
    @ObservationIgnored private var documentSaveTimers: [UUID: Task<Void, Never>] = [:]
    /// 少し待ってから notes.md を書く予定 (ジョブの id ごと)
    @ObservationIgnored private var notesSaveTimers: [UUID: Task<Void, Never>] = [:]

    init() {
        let player = PlayerController()
        self.player = player
        practice = PracticeController(player: player)
        let d = UserDefaults.standard
        languageCode = d.string(forKey: "languageCode") ?? "ja"
        let savedModel = d.string(forKey: "modelID") ?? ModelCatalog.defaultModelID
        modelID = ModelCatalog.spec(id: savedModel) == nil ? ModelCatalog.defaultModelID : savedModel
        preferAccuracy = d.object(forKey: "preferAccuracy") as? Bool ?? true
        useVAD = d.object(forKey: "useVAD") as? Bool ?? true
        filterHallucinations = d.object(forKey: "filterHallucinations") as? Bool ?? true
        autoMixedLanguage = d.object(forKey: "autoMixedLanguage") as? Bool ?? true
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
        initialPrompt = d.string(forKey: "initialPrompt") ?? ""
        llmModelID = d.string(forKey: "llmModelID") ?? LLMCatalog.defaultModelID
        autoAudit = d.object(forKey: "autoAudit") as? Bool ?? true
        autoTranslate = d.object(forKey: "autoTranslate") as? Bool ?? true
        showBilingual = d.object(forKey: "showBilingual") as? Bool ?? true
        showNotes = d.object(forKey: "showNotes") as? Bool ?? false
        notesWidth = min(max(d.object(forKey: "notesWidth") as? Double ?? 320, Self.notesWidthRange.lowerBound),
                         Self.notesWidthRange.upperBound)
        useLedger = d.object(forKey: "useLedger") as? Bool ?? true
        useAdapter = d.object(forKey: "useAdapter") as? Bool ?? true
        llmStore = LLMModelStore(models: store)
        let loaded = CorrectionLedger.loadKeepingUnreadable(from: ledgerURL)
        ledger = loaded.ledger
        if let aside = loaded.setAside {
            errorMessage = "学習した直しのファイルを読めなかったので、空の状態から始めます。元のファイルは「\(aside.lastPathComponent)」という名前で、同じフォルダにとってあります。"
        }
        if !Languages.isKnown(languageCode) { languageCode = "ja" }
        refreshInstalled()
        refreshLLMInstalled()
        // 確認用の起動 (--selftest-…) では保存しない (--selftest-ui-load は、確かめるときに一時フォルダを使う)
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest-") }) {
            library = LibraryWriter(store: LibraryStore(root: LibraryStore.defaultRoot()))
            loadLibrary()
        }
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
            adopt(job)
            if selectedJobID == nil || selectedJob?.isActive == false {
                select(job)
            }
        }
        ensureWorker()
    }

    /// 同じファイルを、別の言語の設定でもう一度文字起こしする (新しいジョブ。設定の言語は変えない)。
    /// autoMixed が false なら、日本語と英語が混ざっていても「日本語＋英語」に切り替えない
    func retranscribe(_ job: Job, languageCode code: String, autoMixed: Bool = true) {
        guard let url = job.url else { return }
        // 置き換える文字起こしの監査・翻訳は止める (待っていると、やり直しがその後ろに回る。反映済みの結果は残す)
        cancelPost(job)
        let again = Job(name: job.name, url: url)
        again.languageCode = code
        again.allowsAutoMixed = autoMixed
        adopt(again)
        job.mixedSuggestionDismissed = true
        job.autoMixedNoticeDismissed = true
        select(again)
        ensureWorker()
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
            job.message = "中止しました"
            // 録音の音声は WAV に保存してある。やり直しはそのファイルから読むので、メモリの分は手放す (1 時間で約 230 MB)
            if job.url != nil { job.samples = nil }
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
        job.lineQueue.removeAll()
        job.lineRedo.removeAll()
        // 録音のための一時停止を取りやめる (止まったあとに「録音を止めると再開します」と出さない)
        job.pausedForRecording = false
        if job.postState != .idle {
            job.postCancel.set()
        } else if hadQueue {
            // 録音のあいだ一時停止していた作業を取りやめた: 「録音を止めると再開します」を残さない
            job.postNote = "監査・翻訳を中止しました。反映済みの結果は残しています。"
        }
    }

    /// 一覧から外す (作業は止める)。保存した結果は delete で消す
    private func remove(_ job: Job) {
        if job.isActive { cancel(job) }
        cancelPost(job)
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { select(jobs.first) }
        if historyJobID == job.id { historyJobID = nil }
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
        // 認識の途中で届く区間の入れ物。終わり方ごとに閉じる (下の catch と、結果を入れる前)
        let live = Self.liveFeed(for: job)
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
                filterHallucinations: filterHallucinations,
                autoMixedLanguage: autoMixedLanguage && job.allowsAutoMixed
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
                        job.message = "認識をやり直しています…"
                    }
                },
                onStage: { stage in
                    Task { @MainActor in
                        guard job.status == .running else { return }
                        switch stage {
                        case .checkingLanguages:
                            job.message = "言語を確かめています…"
                        case .checkedLanguages(let probe):
                            if probe.isMixed {
                                job.message = "日本語と英語が混ざっています。「日本語＋英語」で文字にします…"
                            }
                        }
                    }
                },
                shouldCancel: { flag.isSet }
            )
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
            job.message = "完了"
        } catch let error as WhisperError where error == .cancelled {
            // 中止・失敗: 途中の結果が画面に残るので、貯まっている区間を先に足す (状態を変える前に。後始末もこれを含める)
            Self.applyLive(live.close(), to: job)
            job.status = .cancelled
            job.message = "中止しました"
            if job.url != nil { job.samples = nil }
            cleanPartialTranscript(of: job)
        } catch {
            Self.applyLive(live.close(), to: job)
            if job.cancelFlag.isSet {
                job.status = .cancelled
                job.message = "中止しました"
            } else {
                job.status = .failed
                job.error = error.localizedDescription
                job.message = "エラー"
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
    static func applyLive(_ batch: LiveSegmentBuffer.Batch?, to job: Job) {
        guard let batch, job.status == .running, var transcript = job.transcript else { return }
        batch.apply(to: &transcript.segments)
        job.transcript = transcript
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

    /// その区間を含む 1 文だけを日本語に訳す (行の「訳」)。redo は、訳のある文を訳し直す (行の右クリック)。
    /// 文のまとめ方とプロンプトは「翻訳」と同じなので、あとの「翻訳」「残りを翻訳」はこの文を飛ばす
    func translateLine(_ id: UUID, in job: Job, redo: Bool = false) {
        guard isLLMInstalled else {
            errorMessage = "日本語に訳すには、ローカル LLM「\(currentLLM.name)」が必要です。設定の「監査・翻訳」から取得してください。"
            return
        }
        guard job.status == .done, let transcript = job.transcript, !job.lineQueue.contains(id) else { return }
        // 訳し直しは、前の訳でまとめていた区間をすべて訳し直す (監査で文の区切りが変わっていても、訳の無い区間を残さない)
        let unit = redo
            ? Translator.redoUnitIDs(containing: id, in: transcript.segments, language: transcript.language)
            : Translator.unitIDs(containing: id, in: transcript.segments, language: transcript.language)
        // 同じ文の別の行がもう頼まれていれば、もう一度は訳さない
        let added = unit.filter { !job.lineQueue.contains($0) }
        guard !added.isEmpty else { return }
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
                job.postNote = Self.pausedNote
            }
        }
        // 一時停止から再開した: 「一時停止しています」を消す
        if job.postNote == Self.pausedNote { job.postNote = nil }

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
                let options = AuditOptions(glossary: glossary, ledger: learned,
                                           decisions: transcript.audit?.userDecisions ?? [:])
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
                job.postState = .running(.translateLines, message: "選んだ文を翻訳中…" + preparing, progress: nil)
                // 訳し直す文は、写しの上で訳を外してから文の区切りを決める (訳し終えるまで、画面には前の訳を残す)
                let segments = Translator.clearingTranslations(of: job.lineRedo.intersection(only), in: transcript.segments)
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
                    let failed = try Translator.translate(segments, language: language, options: options, only: only,
                                                          generator: engine, shouldCancel: { flag.isSet }) { batch, done, total in
                        all += batch
                        Task { @MainActor in
                            apply(batch)
                            guard case .running(.translateLines, _, _) = job.postState, job.postCancel === flag else { return }
                            job.postState = .running(.translateLines, message: "選んだ文を翻訳中 \(done)/\(total)",
                                                     progress: total > 0 ? Double(done) / Double(total) : nil)
                        }
                    }
                    return (failed, all)
                }
                apply(all)
                if failed > 0 {
                    job.postNote = "選んだ文のうち \(failed) 区間は訳せませんでした。行の「訳」をもう一度押すと、訳し直します。"
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

    /// 録音のあいだ一時停止しているときのお知らせ
    static let pausedNote = "録音のあいだ一時停止しています。録音を止めると再開します。"

    /// メモリの少ない Mac で録音中なら、この仕事を順番待ちの先頭に戻して true を返す (録音を止めると再開する)
    private func pauseIfRecording(_ task: PostTask, job: Job) -> Bool {
        guard isRecording, MemoryBudget.isTight else { return false }
        if !job.postQueue.contains(task) { job.postQueue.insert(task, at: 0) }
        job.pausedForRecording = true
        return true
    }

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

    /// 監査の結果を本文に反映する (前の監査の反映は元に戻し、利用者の決定は引き継ぐ)
    private func adopt(_ report: AuditReport, in job: Job) {
        guard var current = job.transcript else { return }
        current.adopt(report)
        job.transcript = current
    }

    /// 中止・失敗したジョブの途中結果にも、完了時と同じ繰り返しの後始末をかける (画面に残り、コピーもできるため)。
    /// 貯まっていた区間は先に足し、入れ物は閉じてある。状態も .running 以外にしてから呼ぶので、このあと遅れて届く区間は追加されない。
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
            errorMessage = "録音が短すぎます (0.5 秒未満)。"
            return
        }
        let url = try? saveRecording(samples, startedAt: started)
        let job = Job(name: "録音 \(Self.displayStamp.string(from: started))", url: url, isRecording: true, samples: samples)
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

    /// メモを書き出す (.md。中身はメモの文そのまま)
    func exportNotes() {
        guard let job = selectedJob, !job.notes.isEmpty else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "notes" : base)-メモ.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try job.notes.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// 対訳で表示しているか (対訳表示がオンか、そのジョブで行の「訳」を押した。そして、日本語以外が主な文字起こしか、訳が 1 つでもある)
    func isBilingual(_ stats: Transcript.TranslationStats, in job: Job) -> Bool {
        showsBilingual(job) && (stats.hasTranslation || stats.isMainlyForeign)
    }

    /// 「対訳」のチェック (対訳の設定がオンか、そのジョブで行の「訳」を押した)
    func showsBilingual(_ job: Job) -> Bool {
        showBilingual || job.showsLineTranslations
    }

    /// 「対訳」のチェックを変える。外したときは、行の「訳」で出していたこのジョブの対訳も隠す
    func setShowsBilingual(_ on: Bool, for job: Job) {
        if !on { job.showsLineTranslations = false }
        if showBilingual != on { showBilingual = on }
    }

    /// 結果の行をクリックして再生できるか (その文字起こしの音声をプレイヤーが開いている)
    func canPlayLines(of job: Job) -> Bool {
        job.url != nil && player.url == job.url
    }

    /// 本文をコピーする。対訳表示のときは原文と日本語訳を並べたもの
    func copySelectedText() {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let text: String
        let stats = transcript.translationStats
        if isBilingual(stats, in: job) && stats.hasTranslation {
            text = Exporter.txt(transcript, content: .bilingual)
        } else {
            text = transcript.text(withTimestamps: showTimestamps)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 1 行だけをコピーする (行の右クリックから。行のクリックは再生に使うので、行の文字は選べない)
    func copyLine(_ text: String, japanese: String?) {
        var lines = [text]
        if let japanese, japanese != text { lines.append(japanese) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - ライブラリ (結果の保存)

/// 版の残し方
enum VersionSaveMode: Equatable {
    /// 新しい版として残す
    case new
    /// いちばん新しい、自分で残した版に上書きする
    case overwriteLatest
}

extension AppModel {
    /// 保存した結果を読んだもの (音声ファイルがあるかも、裏で確かめておく)
    struct RestoredDocument: Sendable {
        let document: SavedDocument
        let audioExists: Bool
    }

    /// document.json を書くまでに待つ長さ (この間の変化は、まとめて 1 回で書く)
    private static let documentSaveDelay: UInt64 = 1_000_000_000
    /// notes.md を書くまでに待つ長さ
    private static let notesSaveDelay: UInt64 = 800_000_000
    /// 版に戻す前に、自動で残す版の名前
    static let beforeRestoreLabel = "戻す前の状態"

    /// 確認用 (--selftest-ui-load): この場所に保存する (前の結果は読まない)
    func useLibrary(at root: URL) {
        library = LibraryWriter(store: LibraryStore(root: root))
    }

    /// 起動したとき: 保存した結果を裏で読み、一覧の後ろに足す (選びはしない)
    fileprivate func loadLibrary() {
        guard let writer = library else { return }
        let deliver: @MainActor @Sendable ([RestoredDocument], [URL]) -> Void = { [weak self] documents, aside in
            self?.restore(documents, setAside: aside)
        }
        writer.async { store in
            let loaded = store.loadAll()
            let restored = loaded.documents.map { document in
                RestoredDocument(document: document,
                                 audioExists: document.sourcePath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            }
            let aside = loaded.setAside
            Task { @MainActor in deliver(restored, aside) }
        }
    }

    private func restore(_ documents: [RestoredDocument], setAside: [URL]) {
        for item in documents {
            let document = item.document
            guard !jobs.contains(where: { $0.id == document.id }) else { continue }
            // 音声ファイルが見つからなければ、再生はできない (場所は覚えておき、選び直せる)
            let url = item.audioExists ? document.sourcePath.map { URL(fileURLWithPath: $0) } : nil
            let job = Job(id: document.id, name: document.title, url: url, isRecording: document.isRecording,
                          createdAt: document.createdAt)
            job.sourcePath = document.sourcePath
            job.transcript = document.transcript
            job.languageCode = document.languageCode
            job.autoMixedFrom = document.autoMixedFrom
            job.versions = document.versions
            job.notes = document.notes
            job.status = .done
            job.progress = 1
            job.message = "完了"
            job.mixedSuggestionDismissed = true
            job.autoMixedNoticeDismissed = true
            job.inLibrary = true
            job.documentOnDisk = true
            adopt(job, at: jobs.count)
        }
        if !setAside.isEmpty {
            let text = "保存した結果のうち \(setAside.count) 件を読めなかったので、一覧に出していません。"
                + "元のファイルは、それぞれのフォルダに「document.unreadable-…」という名前でとってあります。"
            errorMessage = errorMessage.map { $0 + "\n\n" + text } ?? text
        }
    }

    /// ジョブを一覧に入れる (保存の受け口を付ける)。一覧にジョブを足すときは、いつもこれを使う
    func adopt(_ job: Job, at index: Int = 0) {
        job.onChange = { [weak self] job, change in
            self?.jobChanged(job, change)
        }
        jobs.insert(job, at: min(max(0, index), jobs.count))
        // もう終わっているジョブ (確認用に入れたものなど) は、ここではじめて保存する
        startSavingIfFinished(job)
    }

    /// ジョブの中身が変わった (Job.onChange から)。少し待ってから保存する
    private func jobChanged(_ job: Job, _ change: Job.Change) {
        guard library != nil, jobs.contains(where: { $0 === job }) else { return }
        switch change {
        case .status:
            startSavingIfFinished(job)
        case .document:
            if job.inLibrary { scheduleDocumentSave(job) }
        case .notes:
            if job.inLibrary { scheduleNotesSave(job) }
        }
    }

    /// 文字起こしが終わり、文がある: ライブラリに入れて、保存する (中止・失敗したものは保存しない)
    private func startSavingIfFinished(_ job: Job) {
        guard library != nil, !job.inLibrary, job.status == .done,
              let transcript = job.transcript, !transcript.segments.isEmpty else { return }
        job.inLibrary = true
        scheduleDocumentSave(job)
    }

    /// 保存する中身の写し (値なので、メインスレッドでは写すだけ。JSON にするのは裏の列)
    func snapshot(of job: Job) -> SavedDocument? {
        guard let transcript = job.transcript else { return nil }
        return SavedDocument(id: job.id, title: job.name, sourcePath: job.sourcePath, isRecording: job.isRecording,
                             createdAt: job.createdAt, updatedAt: Date(), languageCode: job.languageCode,
                             autoMixedFrom: job.autoMixedFrom, transcript: transcript, versions: job.versions,
                             notes: job.notes)
    }

    /// 1 秒ほどあとに document.json を書く。待っているあいだの変化は、その 1 回にまとめる
    /// (翻訳のように続けて変わるときも、1 秒に 1 回まで。書くときに、そのときの中身を写す)
    private func scheduleDocumentSave(_ job: Job) {
        let id = job.id
        guard documentSaveTimers[id] == nil else { return }
        documentSaveTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.documentSaveDelay)
            guard !Task.isCancelled else { return }
            self?.documentSaveDue(id)
        }
    }

    private func documentSaveDue(_ id: UUID) {
        documentSaveTimers[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        // 版の作業の最中は、終わるまで待つ (版の一覧を書きかえている最中に、古い一覧で書かない)
        if job.versionBusy {
            scheduleDocumentSave(job)
            return
        }
        writeDocument(job)
    }

    /// いまの中身を写して、裏の列で document.json と notes.md を書く
    private func writeDocument(_ job: Job) {
        guard let writer = library, job.status == .done, let document = snapshot(of: job) else { return }
        // notes.md もいっしょに書くので、待っているメモの保存は要らない
        notesSaveTimers.removeValue(forKey: job.id)?.cancel()
        let report = saveReporter(document: true)
        let id = job.id
        let revision = job.notesRevision
        writer.async { store in
            do {
                try store.save(document)
                Task { @MainActor in report(id, revision, nil) }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in report(id, revision, message) }
            }
        }
    }

    /// 0.8 秒ほどあとに notes.md だけを書く (document.json を書く予定があれば、そちらでいっしょに書く)
    private func scheduleNotesSave(_ job: Job) {
        let id = job.id
        guard notesSaveTimers[id] == nil, documentSaveTimers[id] == nil else { return }
        notesSaveTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.notesSaveDelay)
            guard !Task.isCancelled else { return }
            self?.notesSaveDue(id)
        }
    }

    private func notesSaveDue(_ id: UUID) {
        notesSaveTimers[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        writeNotesOrDocument(job)
    }

    /// メモを書く。document.json をまだ書けていなければ (はじめの保存の失敗など)、全体を書く
    /// (notes.md だけでは、フォルダが無いので何も書かれない)
    private func writeNotesOrDocument(_ job: Job) {
        if job.documentOnDisk {
            writeNotes(job)
        } else {
            writeDocument(job)
        }
    }

    private func writeNotes(_ job: Job) {
        guard let writer = library else { return }
        let id = job.id
        let text = job.notes
        let revision = job.notesRevision
        let report = saveReporter(document: false)
        writer.async { store in
            do {
                try store.saveNotes(id: id, text: text)
                Task { @MainActor in report(id, revision, nil) }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in report(id, revision, message) }
            }
        }
    }

    /// 裏の列から、書き終えたことを受け取る口 (メインスレッドで動く)
    private func saveReporter(document: Bool) -> @MainActor @Sendable (UUID, Int, String?) -> Void {
        { [weak self] id, revision, failure in
            self?.saveFinished(id, document: document, notesRevision: revision, failure: failure)
        }
    }

    private func saveFinished(_ id: UUID, document: Bool, notesRevision: Int, failure: String?) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if let failure {
            // 知らせるのは 1 回だけ (書き直すたびには出さない)。結果は一覧に残す
            if !job.saveErrorReported {
                job.saveErrorReported = true
                errorMessage = "「\(job.name)」を保存できませんでした (一覧には残しています): " + failure
            }
            return
        }
        job.saveErrorReported = false
        if document { job.documentOnDisk = true }
        // 書いたあとでメモが変わっていなければ、「保存しました」
        if job.notesRevision == notesRevision, !job.notesSaved { job.notesSaved = true }
    }

    /// 待っている保存を、いま列に積む
    private func dispatchPendingSaves(for id: UUID) {
        if let timer = documentSaveTimers.removeValue(forKey: id) {
            timer.cancel()
            if let job = jobs.first(where: { $0.id == id }) { writeDocument(job) }
        }
        if let timer = notesSaveTimers.removeValue(forKey: id) {
            timer.cancel()
            if let job = jobs.first(where: { $0.id == id }) { writeNotesOrDocument(job) }
        }
    }

    /// 待っている保存をすべて積み、書き終わるまで待つ (終了の前と、確認用)
    func flushLibrary() {
        guard let writer = library else { return }
        for id in Set(documentSaveTimers.keys).union(notesSaveTimers.keys) {
            dispatchPendingSaves(for: id)
        }
        writer.flush()
    }

    /// 結果を消す: 作業を止めて一覧から外し、保存したフォルダをゴミ箱に入れる
    /// (マイクの録音で、録音がアプリの録音フォルダにあれば、録音もゴミ箱へ)。
    /// ゴミ箱に入れるのも保存と同じ列で行うので、待っていた保存が、あとからフォルダを作り直すことはない
    func delete(_ job: Job) {
        let id = job.id
        documentSaveTimers.removeValue(forKey: id)?.cancel()
        notesSaveTimers.removeValue(forKey: id)?.cancel()
        job.onChange = nil
        let saved = job.inLibrary
        job.inLibrary = false
        remove(job)
        guard saved, let writer = library else { return }
        let folder = writer.store.folder(for: id)
        // 録音を、ほかのジョブ (「やり直す」で作ったもの) も使っていれば、録音は残す
        let sharedAudio = jobs.contains { $0.sourcePath != nil && $0.sourcePath == job.sourcePath }
        let recording = job.isRecording && !sharedAudio ? recordingInAppFolder(job.sourcePath) : nil
        let name = job.name
        let report: @MainActor @Sendable (String) -> Void = { [weak self] message in
            self?.errorMessage = message
        }
        writer.async { _ in
            do {
                try LibraryWriter.trash(folder)
            } catch {
                let message = "「\(name)」を消せませんでした: " + error.localizedDescription
                Task { @MainActor in report(message) }
            }
            if let recording { try? LibraryWriter.trash(recording) }
        }
    }

    /// アプリの録音フォルダの中のファイルなら、その場所 (ほかの所のファイルは消さない)
    private func recordingInAppFolder(_ path: String?) -> URL? {
        guard let path else { return nil }
        let folder = recordingsDirectory.standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path.hasPrefix(folder) ? url : nil
    }

    /// 保存したフォルダを Finder で表示する
    func revealInLibrary(_ job: Job) {
        guard let writer = library, job.inLibrary else { return }
        dispatchPendingSaves(for: job.id)
        writer.flush()
        NSWorkspace.shared.activateFileViewerSelecting([writer.store.folder(for: job.id)])
    }

    /// 音声ファイルを選び直す (動かした・名前を変えたとき)
    func relocateAudio(of job: Job) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.message = "「\(job.name)」の音声・動画ファイルを選んでください"
        panel.prompt = "選ぶ"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.url = url
        // 場所が変わったので保存する (Job.sourcePath の変化から)
        job.sourcePath = url.path
        if selectedJobID == job.id { player.load(url: url) }
    }

    /// 行の文をメモに引用する (行の右クリックの「メモに引用」)。メモの欄も出す
    func quoteToNotes(text: String, time: TimeInterval, in job: Job) {
        job.notes = NoteQuote.appending(NoteQuote.line(time: time, text: text), to: job.notes)
        if !showNotes { showNotes = true }
    }

    // MARK: 版 (履歴)

    /// 版を残す・戻す・消すことができるか (保存した、終わった結果で、監査・翻訳の最中でない)
    func canEditVersions(_ job: Job) -> Bool {
        library != nil && job.inLibrary && job.status == .done && !job.isPostActive && !job.versionBusy
    }

    /// 版の作業ができないときの説明 (できるときは nil)
    func versionBlockedReason(_ job: Job) -> String? {
        if library == nil || !job.inLibrary || job.status != .done { return "文字起こしが終わって保存した結果だけ、版を残せます。" }
        if job.isPostActive { return "監査・翻訳の最中は、版を残したり戻したりできません。終わってからにしてください。" }
        if job.versionBusy { return "版を書いています…" }
        return nil
    }

    /// いまの状態を版として残す
    @discardableResult
    func saveVersion(_ job: Job, label: String, mode: VersionSaveMode) async -> Bool {
        guard canEditVersions(job), let writer = library else { return false }
        // 待っている保存を先に積む (列の順に書くので、版はそのあとの状態になる)
        dispatchPendingSaves(for: job.id)
        guard let document = snapshot(of: job) else { return false }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let overwrite = mode == .overwriteLatest
        job.versionBusy = true
        defer { job.versionBusy = false }
        let result = await writer.run { (store: LibraryStore) throws -> SavedDocument in
            if overwrite { return try store.overwriteLatestVersion(of: document, label: name) }
            return try store.addVersion(to: document, label: name, origin: .manual)
        }
        switch result {
        case .success(let updated):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = updated.versions
            return true
        case .failure(let error):
            errorMessage = "版を保存できませんでした: " + error.localizedDescription
            return false
        }
    }

    /// 版に戻す。先に、いまの状態を版 (自動・「戻す前の状態」) として残してから、選んだ所 (文字起こしと訳・メモ) を置きかえる
    @discardableResult
    func restoreVersion(_ job: Job, versionID: UUID, transcript: Bool, notes: Bool) async -> Bool {
        guard transcript || notes, canEditVersions(job), let writer = library else { return false }
        dispatchPendingSaves(for: job.id)
        guard let document = snapshot(of: job) else { return false }
        job.versionBusy = true
        defer { job.versionBusy = false }
        let label = AppModel.beforeRestoreLabel
        let result = await writer.run { (store: LibraryStore) throws -> SavedDocument in
            // 版を先に読む (読めなければ、何も変えない)
            let version = try store.loadVersion(documentID: document.id, versionID: versionID)
            var restored = try store.addVersion(to: document, label: label, origin: .beforeRestore)
            restored = restored.restoring(version, transcript: transcript, notes: notes)
            restored.updatedAt = Date()
            try store.save(restored)
            return restored
        }
        switch result {
        case .success(let restored):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = restored.versions
            if transcript { job.transcript = restored.transcript }
            if notes { job.notes = restored.notes }
            return true
        case .failure(let error):
            errorMessage = "版に戻せませんでした: " + error.localizedDescription
            return false
        }
    }

    /// 版を 1 つ消す
    @discardableResult
    func deleteVersion(_ job: Job, versionID: UUID) async -> Bool {
        guard canEditVersions(job), let writer = library else { return false }
        dispatchPendingSaves(for: job.id)
        guard let document = snapshot(of: job) else { return false }
        job.versionBusy = true
        defer { job.versionBusy = false }
        let result = await writer.run { (store: LibraryStore) throws -> SavedDocument in
            try store.deleteVersion(of: document, versionID: versionID)
        }
        switch result {
        case .success(let updated):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = updated.versions
            return true
        case .failure(let error):
            errorMessage = "版を消せませんでした: " + error.localizedDescription
            return false
        }
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
