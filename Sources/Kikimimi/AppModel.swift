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
    var message: String = L("Waiting")
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
    /// このジョブだけの、無音を飛ばす (VAD) の指定 (「やり直す」で作ったジョブ。保存しない)。
    /// nil = 設定に従う。true = VAD を使う (自動で VAD なしでやり直さない)。false = VAD を使わない
    var vadOverride: Bool?
    /// 音が続いているのに文字が少なかったので、自動で無音を飛ばさずに (VAD なしで) 文字起こしし直した結果を使っている
    var vadSkippedAutomatically = false {
        didSet { if vadSkippedAutomatically != oldValue { onChange?(self, .document) } }
    }
    /// 「無音を飛ばさずに文字起こししました」の案内を閉じた
    var vadSkippedNoticeDismissed = false
    /// 「設定の訳す先と違う言語に訳してあります」の案内を閉じた (この起動のあいだだけ。保存しない)
    var translationLanguageNoticeDismissed = false

    // 文字起こしのあとの監査・翻訳
    /// これから行う監査・翻訳
    var postQueue: [PostTask] = []
    /// いま行っている監査・翻訳
    var postState: PostState = .idle
    /// 監査・翻訳のお知らせ (失敗・一部だけ訳せなかった など)
    var postNote: String? {
        didSet { postNoteIsPause = false }
    }
    /// postNote が「録音のあいだ一時停止しています」の知らせ (文ではなく、この印で見分ける)
    @ObservationIgnored var postNoteIsPause = false
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
    case general
    case transcription
    case llm
}

/// 画面の言語を、起動の一番初め (画面や文を作る前) に決める
enum UILanguageSetting {
    /// UserDefaults のキー
    static let defaultsKey = "uiLanguage"

    struct Startup: Equatable, Sendable {
        let language: UILanguage
        /// 設定を読み書きする起動か (確認用の起動と、`--ui-language` で言語を決めた起動は、読まず・書かない)
        let persists: Bool
    }

    /// この起動の言語 (KikimimiMain が初めに L10n.language に入れる。AppModel も同じ値で始める)
    static let startup = resolve(arguments: CommandLine.arguments, defaults: .standard,
                                 preferredLanguages: Locale.preferredLanguages)

    /// - `--ui-language <コード>` が在れば、その言語 (保存しない。画面を見比べるため)。
    /// - 確認用の起動 (`--selftest-…`) は、日本語 (絵の説明が日本語の画面を前提にしているため。設定を読まず・書かない)。
    /// - ほかは、保存した言語。無ければ、macOS の言語が 13 の中に在ればそれ、無ければ英語
    static func resolve(arguments: [String], defaults: UserDefaults, preferredLanguages: [String]) -> Startup {
        let selfTest = arguments.contains { $0.hasPrefix("--selftest-") }
        if let i = arguments.firstIndex(of: "--ui-language") {
            let code = i + 1 < arguments.count ? arguments[i + 1] : ""
            if let language = UILanguage(rawValue: code) {
                return Startup(language: language, persists: false)
            }
            LaunchLog.note("unknown --ui-language \"\(code)\"; ignored")
        }
        if selfTest { return Startup(language: .ja, persists: false) }
        if let saved = defaults.string(forKey: defaultsKey).flatMap(UILanguage.init(rawValue:)) {
            return Startup(language: saved, persists: true)
        }
        return Startup(language: UILanguage.initial(preferredLanguages: preferredLanguages), persists: true)
    }
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
    var settingsTab: SettingsTab = .general
    let player: PlayerController
    /// 聞き取りの練習 (続けて流す・速さ・隠す・書き取り)。行の再生は、どこからでもこれを通す
    let practice: PracticeController

    // 録音
    var isRecording = false
    var recordingStartedAt: Date?
    var recordingLevel: Float = 0
    var livePreviewText = ""

    // 設定 (UserDefaults に保存)
    /// 画面の言語 (キー uiLanguage)。変えると、文を今の言語で引き直し (画面は `.id(uiLanguage)` で作り直す)、
    /// macOS が出す決まりのメニュー (編集・ウインドウなど) の言語 (AppleLanguages) を、次の起動から変える
    var uiLanguage: UILanguage {
        didSet {
            guard uiLanguage != oldValue else { return }
            L10n.language = uiLanguage
            // 確認用の起動と、--ui-language で言語を決めた起動では、保存しない
            guard UILanguageSetting.startup.persists else { return }
            save(uiLanguage.rawValue, UILanguageSetting.defaultsKey)
            save([uiLanguage.localeIdentifier], "AppleLanguages")
            // 開き直しの案内を、作り直した設定の画面に出す (作り直しの後に出すので、少し後にする)。
            // 起動した時の言語に戻した時は出さない
            showsLanguageChangedAlert = false
            guard needsReopenForLanguage else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showsLanguageChangedAlert = self.needsReopenForLanguage
            }
        }
    }
    /// 起動した時の画面の言語 (macOS が出す決まりのメニューは、この言語のまま。開き直すと今の言語になる)
    let launchUILanguage = UILanguageSetting.startup.language
    /// 画面の言語を変えた時の、開き直しの案内 (設定の画面のアラート) を出している
    var showsLanguageChangedAlert = false
    /// 画面の言語を変えてから、まだ開き直していない (設定の「一般」に、開き直しの案内を出す)。
    /// 設定を保存しない起動 (確認用の起動・--ui-language) では、出さない
    var needsReopenForLanguage: Bool {
        UILanguageSetting.startup.persists && uiLanguage != launchUILanguage
    }
    var languageCode: String { didSet { save(languageCode, "languageCode") } }
    var modelID: String { didSet { save(modelID, "modelID") } }
    var preferAccuracy: Bool { didSet { save(preferAccuracy, "preferAccuracy") } }
    var useVAD: Bool { didSet { save(useVAD, "useVAD") } }
    /// 無音を飛ばした (VAD) 結果が、音が続いているのに文字が少ない時は、自動で無音を飛ばさずにやり直す (歌・音楽のため)
    var autoVADOff: Bool { didSet { save(autoVADOff, "autoVADOff") } }
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
    /// 利用者が選んだ訳す先の言語 (nil なら、まだ選んでいない)。確認用の起動 (--selftest-…) では、いつも "ja" で始め、保存しない
    private var chosenTranslationLanguage: String?
    /// 確認用の起動 (--selftest-…)。設定を保存しない
    private static let isSelfTestLaunch = CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest-") })
    /// 設定の、訳す先の言語 (13 言語のコード。UserDefaults の translationLanguage)。
    /// 選んでいなければ、今の画面の言語 (保存はしない。利用者が選んだ時に初めて保存する)。
    /// 確認用の起動では日本語 (絵と確認が、日本語へ訳す前提のため)。
    /// もう訳の在る結果は、これではなく、その結果の言語で訳す (`translationTarget(for:)`)
    var translationLanguage: String {
        get { TranslationTarget.normalized(chosenTranslationLanguage ?? uiLanguage.rawValue) }
        set {
            let code = TranslationTarget.normalized(newValue)
            guard code != chosenTranslationLanguage else { return }
            chosenTranslationLanguage = code
            if !Self.isSelfTestLaunch { save(code, "translationLanguage") }
        }
    }
    /// 原文と訳を左右に並べて表示する
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
    /// ゴミ箱に入れるかを確かめているジョブ (nil なら確かめの画面は閉じている)
    var pendingDeleteJobID: Job.ID?
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
        uiLanguage = UILanguageSetting.startup.language
        L10n.language = UILanguageSetting.startup.language
        languageCode = d.string(forKey: "languageCode") ?? "ja"
        let savedModel = d.string(forKey: "modelID") ?? ModelCatalog.defaultModelID
        modelID = ModelCatalog.spec(id: savedModel) == nil ? ModelCatalog.defaultModelID : savedModel
        preferAccuracy = d.object(forKey: "preferAccuracy") as? Bool ?? true
        useVAD = d.object(forKey: "useVAD") as? Bool ?? true
        autoVADOff = d.object(forKey: "autoVADOff") as? Bool ?? true
        filterHallucinations = d.object(forKey: "filterHallucinations") as? Bool ?? true
        autoMixedLanguage = d.object(forKey: "autoMixedLanguage") as? Bool ?? true
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
        initialPrompt = d.string(forKey: "initialPrompt") ?? ""
        llmModelID = d.string(forKey: "llmModelID") ?? LLMCatalog.defaultModelID
        autoAudit = d.object(forKey: "autoAudit") as? Bool ?? true
        autoTranslate = d.object(forKey: "autoTranslate") as? Bool ?? true
        // 確認用の起動では、設定を読まず、日本語に決める
        chosenTranslationLanguage = Self.isSelfTestLaunch
            ? "ja" : d.string(forKey: "translationLanguage").map { TranslationTarget.normalized($0) }
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
            errorMessage = L("Could not read the learned corrections file, so starting empty. The original file is kept in the same folder as “%@”.", aside.lastPathComponent)
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
            errorMessage = L("Could not save the learned corrections: %@", error.localizedDescription)
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
                errorMessage = L("Could not download %1$@: %2$@\n\nIf you cannot connect to Hugging Face (huggingface.co), you can add a .bin file with “Add a local file…” in Settings.", spec.displayName, error.localizedDescription)
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
            errorMessage = L("Could not delete: %@", error.localizedDescription)
        }
        refreshInstalled()
    }

    func importModelFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = L("Choose a whisper.cpp model (such as ggml-large-v3-turbo-q5_0.bin)")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch try store.importFile(from: url) {
            case .model(let spec):
                refreshInstalled()
                modelID = spec.id
            case .vad:
                vadRetryAfter = nil
                errorMessage = L("Added the silence detection (VAD) model.")
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
    /// - Parameter enabled: VAD を使うか (nil なら設定に従う。ジョブだけの指定は Job.vadOverride)
    private func vadModelPath(enabled: Bool? = nil) async -> String? {
        guard enabled ?? useVAD else { return nil }
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
            errorMessage = L("Download an LLM first (the adapter is checked against the selected LLM).")
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = L("Choose a fine-tuning adapter (….lora.gguf). It will be added for the selected LLM (%@)", currentLLM.name)
        panel.prompt = L("Add")
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
            errorMessage = L("Could not delete: %@", error.localizedDescription)
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
            errorMessage = L("There is no training data to export yet. Learned corrections build up when you apply or undo corrections in the audit list.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kikimimi-training.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        panel.canCreateDirectories = true
        panel.message = LPlural(records.count, one: "Exports %d training record (used only on this Mac)", other: "Exports %d training records (used only on this Mac)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FineTuneData.jsonl(records).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L("Could not save: %@", error.localizedDescription)
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
                    let stats = translationStats(of: t)
                    if autoTranslate, stats.isMainlyForeign, stats.untranslated > 0 { tasks.append(.translate) }
                    if !tasks.isEmpty { schedulePostTasks(for: job, automatic: false, tasks: tasks) }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = L("Could not download %1$@: %2$@\n\nIf you cannot connect to Hugging Face (huggingface.co), you can add it with “Add a local GGUF…” in the “Audit & translation” tab of Settings.", spec.displayName, error.localizedDescription)
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
            errorMessage = L("Could not delete: %@", error.localizedDescription)
        }
        refreshLLMInstalled()
    }

    func importLLMFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = L("Choose an LLM (.gguf) that runs on llama.cpp")
        panel.prompt = L("Add")
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
        let again = Job(name: job.name, url: url)
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
    ///   - vad: 無音を飛ばす (VAD)。nil = 設定に従う、true = 使う (自動で VAD なしでやり直さない)、false = 使わない
    func redo(_ job: Job, languageCode code: String? = nil, vad: Bool? = nil) {
        guard canRedo(job) else { return }
        retranscribe(job, languageCode: code ?? job.languageCode, autoMixed: job.allowsAutoMixed, vad: vad)
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
                    job.postNote = L("No LLM has been downloaded, so only repetitions were checked. To also check for mishearings, download an LLM in the “Audit & translation” tab of Settings.")
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
                guard useLLM else { return }
                if pauseIfRecording(.translate, job: job) { return }
                job.postState = .running(.translate, message: preparing ? L("Translating… (loading the LLM)") : L("Translating…"), progress: nil)
                let segments = transcript.segments
                let sources = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                let options = TranslationOptions(glossary: glossary)
                let apply: @MainActor ([TranslationResult]) -> Void = { batch in
                    guard !batch.isEmpty, var t = job.transcript else { return }
                    // 訳しているあいだに監査で文が変わった区間には付けない
                    for result in batch { t.apply(result, sources: sources) }
                    t.translationModel = selection.name
                    t.translationLanguage = target
                    job.transcript = t
                }
                let (failed, all) = try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                                      shouldCancel: { flag.isSet }) { engine in
                    var all: [TranslationResult] = []
                    let failed = try Translator.translate(segments, language: language, target: target, options: options,
                                                          generator: engine,
                                                          shouldCancel: { flag.isSet }) { batch, done, total in
                        all += batch
                        Task { @MainActor in
                            apply(batch)
                            guard case .running(.translate, _, _) = job.postState, job.postCancel === flag else { return }
                            job.postState = .running(.translate, message: L("Translating %1$d/%2$d", done, total),
                                                     progress: total > 0 ? Double(done) / Double(total) : nil)
                        }
                    }
                    return (failed, all)
                }
                apply(all)
                if failed > 0 {
                    job.postNote = LPlural(failed, one: "%d segment could not be translated. Click “Translate” again to translate only the rest.", other: "%d segments could not be translated. Click “Translate” again to translate only the rest.")
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
                job.postState = .running(.translateLines, message: preparing ? L("Translating the selected sentences… (loading the LLM)") : L("Translating the selected sentences…"), progress: nil)
                // 訳し直す文は、写しの上で訳を外してから文の区切りを決める (訳し終えるまで、画面には前の訳を残す)
                let segments = Translator.clearingTranslations(of: job.lineRedo.intersection(only), in: transcript.segments)
                let sources = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                let options = TranslationOptions(glossary: glossary)
                let apply: @MainActor ([TranslationResult]) -> Void = { batch in
                    guard !batch.isEmpty, var t = job.transcript else { return }
                    // 訳しているあいだに監査で文が変わった区間には付けない
                    for result in batch { t.apply(result, sources: sources) }
                    t.translationModel = selection.name
                    t.translationLanguage = target
                    job.transcript = t
                }
                let (failed, all) = try await llm.run(modelPath: selection.url.path, adapterPath: adapter,
                                                      shouldCancel: { flag.isSet }) { engine in
                    var all: [TranslationResult] = []
                    let failed = try Translator.translate(segments, language: language, target: target, options: options,
                                                          only: only,
                                                          generator: engine, shouldCancel: { flag.isSet }) { batch, done, total in
                        all += batch
                        Task { @MainActor in
                            apply(batch)
                            guard case .running(.translateLines, _, _) = job.postState, job.postCancel === flag else { return }
                            job.postState = .running(.translateLines, message: L("Translating the selected sentences %1$d/%2$d", done, total),
                                                     progress: total > 0 ? Double(done) / Double(total) : nil)
                        }
                    }
                    return (failed, all)
                }
                apply(all)
                if failed > 0 {
                    job.postNote = LPlural(failed, one: "%d segment of the selected sentences could not be translated. Click “Translate line” on that line to retry.", other: "%d segments of the selected sentences could not be translated. Click “Translate line” on that line to retry.")
                }
                job.postNote = adapterNote(job.postNote)
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

    // MARK: 書き出し
    func export(as format: ExportFormat, content: ExportContent = .original) {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        // 訳・対訳は、その結果の訳す先の言語で書き出す (ファイルの名前の印も、その言語のコード)
        let target = translationTarget(for: transcript)
        panel.nameFieldStringValue = "\(base.isEmpty ? "transcript" : base)\(content.fileSuffix(target: target)).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.render(transcript, as: format, content: content, target: target)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L("Could not save: %@", error.localizedDescription)
        }
    }

    /// メモを書き出す (.md。中身はメモの文そのまま)
    func exportNotes() {
        guard let job = selectedJob, !job.notes.isEmpty else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "notes" : base)-メモ.md" // l10n: keep (保存するファイルの名前)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try job.notes.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L("Could not save: %@", error.localizedDescription)
        }
    }

    /// 対訳で表示しているか (対訳表示がオンか、そのジョブで行の「訳」を押した。そして、訳す先の言語以外が主な文字起こしか、
    /// 訳が 1 つでもある)。stats は、その結果の訳す先の言語で数えたもの (`translationStats(of:)`)
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

    /// 本文をコピーする。対訳表示のときは原文と訳を並べたもの
    func copySelectedText() {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let text: String
        let target = translationTarget(for: transcript)
        let stats = transcript.translationStats(target: target)
        if isBilingual(stats, in: job) && stats.hasTranslation {
            text = Exporter.txt(transcript, content: .bilingual, target: target)
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
    /// (保存される名前なので、作った時の画面の言語のまま残る。版を見分ける時は、名前ではなく origin で見る)
    static var beforeRestoreLabel: String { L("Before restoring") }
    /// 訳す先を変えて訳し直す前に、自動で残す版の名前 (保存される名前なので、作った時の画面の言語のまま残る)
    static var beforeRetranslateLabel: String { L("Before changing the translation language") }

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
            job.vadSkippedAutomatically = document.vadSkippedAutomatically
            job.versions = document.versions
            job.notes = document.notes
            job.status = .done
            job.progress = 1
            job.message = L("Done")
            job.mixedSuggestionDismissed = true
            job.autoMixedNoticeDismissed = true
            job.vadSkippedNoticeDismissed = true
            job.inLibrary = true
            job.documentOnDisk = true
            adopt(job, at: jobs.count)
        }
        if !setAside.isEmpty {
            let text = LPlural(setAside.count,
                               one: "%d saved result could not be read, so it is not in the list. The original file is kept in its folder as “document.unreadable-…”.",
                               other: "%d saved results could not be read, so they are not in the list. The original files are kept in their folders as “document.unreadable-…”.")
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
                             autoMixedFrom: job.autoMixedFrom,
                             vadSkippedAutomatically: job.vadSkippedAutomatically, transcript: transcript, versions: job.versions,
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
                errorMessage = L("Could not save “%1$@” (it stays in the list): %2$@", job.name, failure)
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
        panel.message = L("Choose the audio or video file for “%@”", job.name)
        panel.prompt = L("Choose")
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
        if library == nil || !job.inLibrary || job.status != .done { return L("Versions can be saved only for finished, saved transcription results.") }
        if job.isPostActive { return L("You cannot save or restore versions during audit or translation. Wait until it finishes.") }
        if job.versionBusy { return L("Saving the version…") }
        return nil
    }

    /// いまの状態を版として残す。origin は、新しい版のときの残し方 (自分で残した版か、自動で残した版か)
    @discardableResult
    func saveVersion(_ job: Job, label: String, mode: VersionSaveMode,
                     origin: VersionInfo.Origin = .manual) async -> Bool {
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
            return try store.addVersion(to: document, label: name, origin: origin)
        }
        switch result {
        case .success(let updated):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = updated.versions
            return true
        case .failure(let error):
            errorMessage = L("Could not save the version: %@", error.localizedDescription)
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
            errorMessage = L("Could not restore the version: %@", error.localizedDescription)
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
            errorMessage = L("Could not delete the version: %@", error.localizedDescription)
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
