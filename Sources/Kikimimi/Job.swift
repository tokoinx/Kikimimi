// 1 件の文字起こしジョブ (Job) と、その仕事・状態を表す小さな型。
// AppModel と画面の両方が使う。

import Foundation
import KikimimiCore
import Observation

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

/// 訳を直す画面で直している行 (結果のジョブと、その行の区間。区間は、行のどの区間でもよい)
struct TranslationEditRequest: Equatable {
    let jobID: UUID
    let segmentID: UUID
}

/// 文字起こしのあとに行う仕事
enum PostTask: Equatable {
    case audit
    case translate
    /// 行の「訳」で頼まれた文だけを訳す (頼まれた文は Job.lineQueue。1 つの仕事で、待っている文をまとめて順に訳す)
    case translateLines

    /// この仕事に渡す追加学習の差分の種類 (監査は監査用、翻訳は翻訳用)
    var adapterKind: AdapterKind {
        switch self {
        case .audit: return .audit
        case .translate, .translateLines: return .translation
        }
    }
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
