// アプリ全体の状態 (AppModel) の本体。保存するプロパティの全部と、init・設定の保存・小さな計算プロパティを置く。
// 確認用の起動が保存先を変える 2 つの関数 (useTranslationMemory・useLibrary) もここに置き、private(set) の値に入れる所をこのファイルに限る。
// 役目ごとの関数は、AppModel+〜.swift の拡張に在る。

import Foundation
import KikimimiCore
import KikimimiWhisper
import Observation

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
            save(uiLanguage.rawValue, .uiLanguage)
            // macOS の鍵 (この app の設定ではないので、SettingKey には入れない)
            SettingsWriter.set([uiLanguage.localeIdentifier], forKey: "AppleLanguages")
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
    var languageCode: String { didSet { save(languageCode, .languageCode) } }
    var modelID: String { didSet { save(modelID, .modelID) } }
    var preferAccuracy: Bool { didSet { save(preferAccuracy, .preferAccuracy) } }
    var useVAD: Bool { didSet { save(useVAD, .useVAD) } }
    /// 無音を飛ばした (VAD) 結果が、音が続いているのに文字が少ない時は、自動で無音を飛ばさずにやり直す (歌・音楽のため)
    var autoVADOff: Bool { didSet { save(autoVADOff, .autoVADOff) } }
    var filterHallucinations: Bool { didSet { save(filterHallucinations, .filterHallucinations) } }
    /// 「日本語」「英語」「自動判定」のとき、日本語と英語が混ざった録音は自動で「日本語＋英語」で文字にする
    var autoMixedLanguage: Bool { didSet { save(autoMixedLanguage, .autoMixedLanguage) } }
    var livePreview: Bool { didSet { save(livePreview, .livePreview) } }
    var initialPrompt: String { didSet { save(initialPrompt, .initialPrompt) } }
    // 監査・翻訳 (ローカル LLM)
    /// 一覧のモデルの ID か、`file:` + 取り込んだ GGUF のファイル名
    var llmModelID: String {
        didSet {
            save(llmModelID, .llmModelID)
            refreshAdapters()
        }
    }
    var autoAudit: Bool { didSet { save(autoAudit, .autoAudit) } }
    var autoTranslate: Bool { didSet { save(autoTranslate, .autoTranslate) } }
    /// 利用者が選んだ訳す先の言語 (nil なら、まだ選んでいない)。確認用の起動 (--selftest-…) では、いつも "ja" で始め、保存しない
    private var chosenTranslationLanguage: String?
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
            // 確認用の起動では、SettingsWriter が書かない
            save(code, .translationLanguage)
        }
    }
    /// 原文と訳を左右に並べて表示する
    var showBilingual: Bool { didSet { save(showBilingual, .showBilingual) } }
    /// 結果の右にメモの欄を出す
    var showNotes: Bool { didSet { save(showNotes, .showNotes) } }
    /// メモの欄の幅 (pt)。メモの欄の左の区切りをつかんで変える
    var notesWidth: Double {
        didSet {
            let fitted = min(max(notesWidth, Self.notesWidthRange.lowerBound), Self.notesWidthRange.upperBound)
            if fitted != notesWidth { notesWidth = fitted }
            save(notesWidth, .notesWidth)
        }
    }
    /// メモの欄の幅の範囲 (pt。設定の定義と同じ)
    static let notesWidthRange: ClosedRange<Double> = SettingDefinition.notesWidthRange
    /// 履歴の画面を開いているジョブ (nil なら閉じている)
    var historyJobID: Job.ID?
    /// ゴミ箱に入れるかを確かめているジョブ (nil なら確かめの画面は閉じている)
    var pendingDeleteJobID: Job.ID?
    /// 学習した直し (監査の一覧で利用者が決めた直し・設定で自分で書いた直し)。Mac の中だけに保存する
    var ledger = CorrectionLedger()
    /// 学習した直しを使う (監査の前に当てる・断った直しを出さない・正しい語を語彙のヒントに足す)
    var useLedger: Bool { didSet { save(useLedger, .useLedger) } }
    /// 訳の記憶 (利用者が直した訳。Mac の中だけに保存する)。次の翻訳で同じ文に出た時に、LLM を呼ばずに置く
    /// (`reuseTranslationMemory` が入の時)。設定の「覚えた訳」の一覧が見るので、見張る (結果の一覧は読まない)
    var translationMemory = TranslationMemory()
    /// 覚えた訳を、次の翻訳に使う (切の時も、直した訳は記憶にたまる)
    var reuseTranslationMemory: Bool { didSet { save(reuseTranslationMemory, .reuseTranslationMemory) } }
    /// 訳の記憶の保存先 (学習した直しの台帳と同じフォルダの translation-memory.json)。
    /// 確認用の起動 (--selftest-…) では nil (利用者の本物の記憶を読まず・書かない。確認は useTranslationMemory(at:) で一時のファイルにする)
    @ObservationIgnored private(set) var translationMemoryURL: URL?
    /// 訳を直す画面 (対訳の行の「訳を直す…」) を開いている行 (nil なら閉じている)
    var translationEdit: TranslationEditRequest?
    /// 行を直す画面 (行の右クリックの「この行を直す…」・原文の「直した」の印) を開いている行 (nil なら閉じている)
    var lineEdit: LineEditRequest?
    /// 追加学習の差分 (LoRA) を使う (選んでいる LLM 用の差分が入っているときだけ効く)。
    /// 入・切は 1 つで、監査用・翻訳用の両方に効く
    var useAdapter: Bool { didSet { save(useAdapter, .useAdapter) } }
    /// 選んでいる LLM 用の、監査用の差分が入っている
    var hasAdapter = false
    /// 選んでいる LLM 用の、翻訳用の差分が入っている
    var hasTranslationAdapter = false
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
    /// LLM とのチャット (会話は保存しない。アプリを閉じると消える)
    let chat = ChatController()

    let store = ModelStore()
    let llmStore: LLMModelStore
    @ObservationIgnored let service = TranscriptionService()
    @ObservationIgnored let llm = LLMService()
    @ObservationIgnored var llmDownloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var worker: Task<Void, Never>?
    @ObservationIgnored var downloadTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored var recorder: LiveRecorder?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    @ObservationIgnored var vadTask: Task<String?, Never>?
    @ObservationIgnored var vadRetryAfter: Date?
    /// 結果の保存先 (nil なら保存しない: 確認用の起動 --selftest-…)
    @ObservationIgnored private(set) var library: LibraryWriter?
    /// 少し待ってから document.json を書く予定 (ジョブの id ごと)
    @ObservationIgnored var documentSaveTimers: [UUID: Task<Void, Never>] = [:]
    /// 少し待ってから notes.md を書く予定 (ジョブの id ごと)
    @ObservationIgnored var notesSaveTimers: [UUID: Task<Void, Never>] = [:]

    init() {
        let player = PlayerController()
        self.player = player
        practice = PracticeController(player: player)
        // 既定の値・確認用の起動で決まった値・読む時の直しは、SettingKey の定義から来る
        let settings = SettingsReader()
        uiLanguage = UILanguageSetting.startup.language
        L10n.language = UILanguageSetting.startup.language
        // 一覧に無い言語は "ja" に、一覧に無いモデルは既定のモデルに直る
        // (定義に既定の値が在るので、`??` の右には来ない)
        languageCode = settings.string(.languageCode) ?? "ja"
        modelID = settings.string(.modelID) ?? ModelCatalog.defaultModelID
        preferAccuracy = settings.bool(.preferAccuracy)
        useVAD = settings.bool(.useVAD)
        autoVADOff = settings.bool(.autoVADOff)
        filterHallucinations = settings.bool(.filterHallucinations)
        autoMixedLanguage = settings.bool(.autoMixedLanguage)
        livePreview = settings.bool(.livePreview)
        initialPrompt = settings.string(.initialPrompt) ?? ""
        // LLM は、ここでは直さない (手元の GGUF が在るので、refreshLLMInstalled() が受け持つ)
        llmModelID = settings.string(.llmModelID) ?? LLMCatalog.defaultModelID
        autoAudit = settings.bool(.autoAudit)
        autoTranslate = settings.bool(.autoTranslate)
        // 保存が無い間は nil (画面の言語と同じ)。確認用の起動では、設定を読まず、日本語に決める
        chosenTranslationLanguage = settings.string(.translationLanguage)
        showBilingual = settings.bool(.showBilingual)
        showNotes = settings.bool(.showNotes)
        notesWidth = settings.double(.notesWidth)
        useLedger = settings.bool(.useLedger)
        // 確認用の起動では、設定を読まず、入に決める (記憶は一時のファイルにするので、本物の記憶は使わない)
        reuseTranslationMemory = settings.bool(.reuseTranslationMemory)
        useAdapter = settings.bool(.useAdapter)
        llmStore = LLMModelStore(models: store)
        let loaded = CorrectionLedger.loadKeepingUnreadable(from: ledgerURL)
        ledger = loaded.ledger
        if let aside = loaded.setAside {
            errorMessage = L("Could not read the learned corrections file, so starting empty. The original file is kept in the same folder as “%@”.", aside.lastPathComponent)
        }
        if !LaunchMode.current.isSelfTest {
            let memoryURL = ledgerURL.deletingLastPathComponent().appendingPathComponent(TranslationMemory.fileName)
            translationMemoryURL = memoryURL
            let memory = TranslationMemory.loadKeepingUnreadable(from: memoryURL)
            translationMemory = memory.memory
            if let aside = memory.setAside {
                errorMessage = L("Could not read the translation memory file, so starting empty. The original file is kept in the same folder as “%@”.", aside.lastPathComponent)
            }
        }
        // 保存してあった話す言語が一覧に無かった時は、直した値を保存し直す (前と同じ動き)。
        // 初めの代入では didSet が動かないので、ここでもう一度代入する (didSet が保存する)
        if settings.savedStringIsFixed(.languageCode) { languageCode = settings.string(.languageCode) ?? "ja" }
        refreshInstalled()
        refreshLLMInstalled()
        // 確認用の起動 (--selftest-…) では保存しない (--selftest-ui-load は、確かめるときに一時フォルダを使う)
        if !LaunchMode.current.isSelfTest {
            library = LibraryWriter(store: LibraryStore(root: LibraryStore.defaultRoot()))
            loadLibrary()
        } else if let path = LaunchMode.handCheckLibraryPath() {
            // 行の画面を、手で触って確かめる時だけ: 起動の確認 (--selftest-launch) に、一時フォルダのライブラリを
            // 環境変数で渡すと、そこを開いて、そこへ保存する (利用者の本物のライブラリは、この形では開かない)
            library = LibraryWriter(store: LibraryStore(root: URL(fileURLWithPath: path, isDirectory: true)))
            loadLibrary()
        }
        chat.model = self
    }

    private func save(_ value: Any, _ key: SettingKey) {
        // 確認用の起動 (--selftest-…) では、SettingsWriter が利用者の本物の設定に書かない
        SettingsWriter.set(value, for: key)
    }

    var selectedJob: Job? {
        jobs.first { $0.id == selectedJobID }
    }

    /// 語彙のヒント: 設定で書いたものに、学習した正しい語を足したもの (文字起こし・監査・翻訳で使う)
    var effectiveHint: String {
        useLedger ? (ledger.glossary(adding: initialPrompt) ?? "") : initialPrompt
    }

    /// 作業中か (文字起こし・録音・監査・翻訳・モデルの取得や取り込み・チャットの答え)。作業中は、ウインドウを閉じてもアプリを終了しない
    var isBusy: Bool {
        isRecording || importingLLM || importingAdapter || !downloads.isEmpty || !llmDownloads.isEmpty
            || chat.isAnswering
            || jobs.contains { $0.isActive || $0.isPostActive }
    }

    var currentModel: WhisperModelSpec {
        ModelCatalog.spec(id: modelID) ?? ModelCatalog.all[0]
    }

    /// 訳の記憶を、このファイルで読み書きする (確認用の起動が、一時のファイルにするのに使う)。
    /// nil なら保存しない (記憶は空にする)
    func useTranslationMemory(at url: URL?) {
        translationMemoryURL = url
        translationMemory = url.map { TranslationMemory.load(from: $0) } ?? TranslationMemory()
    }

    /// 確認用 (--selftest-ui-load): この場所に保存する (前の結果は読まない)
    func useLibrary(at root: URL) {
        library = LibraryWriter(store: LibraryStore(root: root))
    }
}
