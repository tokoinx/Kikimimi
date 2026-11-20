import Foundation
import KikimimiCore
import KikimimiLLM
import Observation

/// チャットの窓の段階
enum ChatPhase: Equatable {
    /// 待っていない
    case idle
    /// リサーチで Web ページを読んでいる
    case readingPages
    /// LLM を待っている (モデルの読み込みか、監査・翻訳が先に使っている)
    case waitingForLLM
    /// 答えを出している
    case answering
}

/// 答えに付ける「設定を変える案」の札
struct ChatProposalCard: Identifiable, Equatable {
    enum State: Equatable {
        /// 押すのを待っている
        case pending
        /// 今の値と同じ (ボタンを出さない)
        case alreadySet
        /// 当てた
        case applied
        /// やめた
        case declined
        /// 当てられなかった
        case failed
    }

    let id: UUID
    let proposal: ChatSettingProposal
    /// 答えを受け取った時の値 (保存する形。分からなければ nil)
    let before: String?
    var state: State
}

/// 発言の下に出す知らせ
struct ChatNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case warning
        case error
    }

    let id = UUID()
    let kind: Kind
    /// 作った時の画面の言語の文
    let text: String
}

/// 発言 1 つに付く物 (札・「設定を開く」・知らせ)
struct ChatTurnExtras: Equatable {
    var cards: [ChatProposalCard] = []
    var opens: [ChatOpenSettings] = []
    var notices: [ChatNotice] = []
    /// 「止める」で止めた答え
    var stopped = false
}

/// チャットに見せる、今の設定の値の写し (LLM のスレッドから読むので、値だけを持つ)
struct ChatSettingsSnapshot: ChatSettingsAccess, Sendable {
    let values: [String: String]

    func currentValue(for key: String) -> String? { values[key] }
}

/// Web ページを読む口 (確認用に差し替えられる)
protocol ChatPageFetching: Sendable {
    func fetch(_ url: URL) async throws -> ChatWebPage
}

/// LLM とのチャットの状態と動き。会話も、リサーチの入り切りも保存しない (アプリを開くたびに空・切)
@MainActor
@Observable
final class ChatController {
    /// やり取り (答えは、印を取り除いた見える文)
    private(set) var messages: [ChatMessage] = []
    /// 発言ごとの札・ボタン・知らせ (発言の id ごと)
    private(set) var extras: [UUID: ChatTurnExtras] = [:]
    /// 出している途中の答え (印を隠した物)
    private(set) var streamingText = ""
    private(set) var phase: ChatPhase = .idle
    /// リサーチ (Web ページを読む)。保存しない。チャットの答えからは決して変えない。
    /// 入れるのは requestResearchOn → 確認のシート → confirmResearchOn の 2 段だけ
    private(set) var researchOn = false
    /// リサーチを入れるかの確認のシートを出している
    var showsResearchConfirm = false
    /// 入力の欄の文
    var draft = ""

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var fetcher: ChatPageFetching = ChatWebFetcher()
    /// Web ページを読みに行った回数 (確認用)
    @ObservationIgnored private(set) var fetchCount = 0
    /// 確認用: 入れると、LLM を呼ばずに、この文を答えにする (LLM の手前までの道を確かめる)
    @ObservationIgnored var selfTestReply: String?
    @ObservationIgnored private var cancelFlag: CancelFlag?
    /// 何回目のやり取りか (「新しいチャット」の後に、前の答えが入らないように)
    @ObservationIgnored private var serial = 0

    /// 答えを出している途中の、書き換えの間引き (1 秒に 20 回まで)
    static let streamInterval: TimeInterval = 0.05

    var isAnswering: Bool { phase != .idle }

    // MARK: リサーチ

    /// 「入れる…」: 確認のシートを出すだけ (まだ入れない)
    func requestResearchOn() {
        showsResearchConfirm = true
    }

    /// 確認のシートの「自己責任で入れる」
    func confirmResearchOn() {
        researchOn = true
        showsResearchConfirm = false
    }

    /// 確認のシートの「キャンセル」
    func cancelResearchOn() {
        showsResearchConfirm = false
    }

    /// 「切る」(確認なし)
    func turnResearchOff() {
        researchOn = false
    }

    // MARK: やり取り

    /// 「新しいチャット」: 会話を空にする (答えの途中なら止める)
    func newChat() {
        stop()
        serial += 1
        messages = []
        extras = [:]
        streamingText = ""
        phase = .idle
        draft = ""
    }

    /// 送れるか (LLM が入っていて、答えを待っていない)
    var canSend: Bool {
        guard let model, !isAnswering else { return false }
        guard selfTestReply != nil || model.isLLMInstalled else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 下書きを送る
    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        let history = messages
        let user = ChatMessage(role: .user, text: text)
        messages.append(user)
        let flag = CancelFlag()
        cancelFlag = flag
        serial += 1
        let turn = serial
        streamingText = ""
        phase = .waitingForLLM
        Task { await runTurn(userID: user.id, text: text, history: history, flag: flag, turn: turn) }
    }

    /// 「止める」: そこまでの見える文を答えとして残す
    func stop() {
        cancelFlag?.set()
    }

    private func runTurn(userID: UUID, text: String, history: [ChatMessage], flag: CancelFlag, turn: Int) async {
        let read = await readPages(in: text, flag: flag, turn: turn)
        guard turn == serial, let model else { return }
        var notices = read.notices
        if flag.isSet {
            finish(reply: "", pagesRead: !read.pages.isEmpty, notices: notices, stopped: true, userID: userID)
            return
        }
        phase = .waitingForLLM
        if let canned = selfTestReply {
            finish(reply: canned, pagesRead: !read.pages.isEmpty, notices: notices, stopped: false, userID: userID)
            return
        }
        let snapshot = model.chatSettingsSnapshot()
        let catalog = model.chatCatalog
        let research = researchOn
        let pages = read.pages
        let latest = LockedBox<String>()
        let throttle = StreamThrottle(interval: Self.streamInterval)
        do {
            let reply = try await model.runChatLLM(shouldCancel: { flag.isSet }) { [weak self] engine in
                // ここから LLM の番 (読み込みと、先の監査・翻訳が終わった)
                Task { @MainActor in self?.began(turn: turn) }
                let prompt = try ChatPromptBuilder.build(history: history, newUserText: text, catalog: catalog,
                                                         access: snapshot, pages: pages, researchOn: research,
                                                         engine: engine)
                return try engine.generate(prompt, shouldCancel: { flag.isSet }, onText: { full in
                    latest.value = full
                    if throttle.shouldSend() {
                        Task { @MainActor in self?.stream(full, turn: turn) }
                    }
                })
            }
            guard turn == serial else { return }
            finish(reply: reply, pagesRead: !pages.isEmpty, notices: notices, stopped: false, userID: userID)
        } catch LLMError.cancelled {
            guard turn == serial else { return }
            finish(reply: latest.value ?? "", pagesRead: !pages.isEmpty, notices: notices, stopped: true, userID: userID)
        } catch {
            guard turn == serial else { return }
            notices.append(ChatNotice(kind: .error, text: error.localizedDescription))
            finish(reply: "", pagesRead: !pages.isEmpty, notices: notices, stopped: false, userID: userID)
        }
    }

    private func began(turn: Int) {
        guard turn == serial, phase == .waitingForLLM else { return }
        phase = .answering
    }

    private func stream(_ full: String, turn: Int) {
        guard turn == serial, isAnswering else { return }
        phase = .answering
        streamingText = ChatActionParser.visiblePrefix(full)
    }

    /// 発言の URL のページを読む。リサーチが切なら、読まずに知らせだけを返す
    private func readPages(in text: String, flag: CancelFlag, turn: Int) async -> (pages: [ChatWebPage], notices: [ChatNotice]) {
        let urls = ChatURLs.urls(in: text)
        guard !urls.isEmpty else { return ([], []) }
        guard researchOn else {
            return ([], [ChatNotice(kind: .info, text: L("Research is off, so no web pages were read."))])
        }
        phase = .readingPages
        var pages: [ChatWebPage] = []
        var notices: [ChatNotice] = []
        for url in urls {
            if flag.isSet || turn != serial { break }
            guard ChatURLs.isAllowed(url) else {
                notices.append(ChatNotice(kind: .warning, text: L("Could not read %1$@: %2$@", url.absoluteString,
                                                                  L("Only public https pages can be read."))))
                continue
            }
            fetchCount += 1
            do {
                let page = try await fetcher.fetch(url)
                pages.append(page)
                notices.append(ChatNotice(kind: .info, text: page.title.isEmpty
                                          ? L("Read %@", url.absoluteString)
                                          : L("Read “%1$@” (%2$@)", page.title, url.absoluteString)))
            } catch {
                notices.append(ChatNotice(kind: .warning, text: L("Could not read %1$@: %2$@", url.absoluteString,
                                                                  error.localizedDescription)))
            }
        }
        return (pages, notices)
    }

    /// 答えを受け取る (LLM の答えと、確認用に決めた答えの、共通の入り口)。
    /// 足した assistant の発言の id を返す (答えが空で、足さなかった時は nil)
    @discardableResult
    func receive(reply: String, pagesRead: Bool, notices: [ChatNotice] = [], stopped: Bool = false) -> UUID? {
        guard let model else { return nil }
        var extra = ChatTurnExtras(notices: notices, stopped: stopped)
        let visible: String
        if stopped {
            // 止めた答えは、見える所だけを残し、案は出さない
            visible = ChatActionParser.visiblePrefix(reply).trimmingCharacters(in: .whitespacesAndNewlines)
            extra.notices.append(ChatNotice(kind: .info, text: L("Stopped.")))
        } else {
            // ページを読んだ回は、外から来た文に動かされうるので、設定の案を当てない
            let parsed = ChatActionParser.parse(reply, catalog: model.chatCatalog, allowSettings: !pagesRead)
            visible = parsed.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            extra.cards = parsed.proposals.map { proposal in
                let current = model.currentValue(for: proposal.key)
                let before = current.map { proposal.item.normalizedValue($0) ?? $0 }
                return ChatProposalCard(id: UUID(), proposal: proposal, before: before,
                                        state: before == proposal.value ? .alreadySet : .pending)
            }
            extra.opens = parsed.opens
            if pagesRead, parsed.rejected.contains(where: { $0.lowercased().hasPrefix("[[set") }) {
                extra.notices.append(ChatNotice(kind: .warning, text: L("Web pages were read for this answer, so its setting changes are not offered.")))
            }
            if !parsed.rejected.isEmpty {
                extra.notices.append(ChatNotice(kind: .warning, text: LPlural(parsed.rejected.count,
                    one: "%d action in the answer was not used.", other: "%d actions in the answer were not used.")))
            }
        }
        guard !visible.isEmpty || !extra.cards.isEmpty || !extra.opens.isEmpty else {
            // 答えが空: 発言に知らせだけを付ける (その回の user の発言は、対にならないので、次の依頼の履歴に入らない)
            if let last = messages.last, last.role == .user {
                var userExtra = extras[last.id] ?? ChatTurnExtras()
                userExtra.notices += extra.notices
                userExtra.stopped = stopped
                extras[last.id] = userExtra
            } else if !extra.notices.isEmpty {
                let message = ChatMessage(role: .assistant, text: "")
                messages.append(message)
                extras[message.id] = extra
                return message.id
            }
            return nil
        }
        let message = ChatMessage(role: .assistant, text: visible)
        messages.append(message)
        extras[message.id] = extra
        return message.id
    }

    private func finish(reply: String, pagesRead: Bool, notices: [ChatNotice], stopped: Bool, userID: UUID) {
        streamingText = ""
        phase = .idle
        cancelFlag = nil
        receive(reply: reply, pagesRead: pagesRead, notices: notices, stopped: stopped)
    }

    // MARK: 札

    /// 札の「変える」。利用者が押した時だけ呼ぶ
    func apply(card id: UUID, in messageID: UUID) {
        guard let model, var extra = extras[messageID],
              let index = extra.cards.firstIndex(where: { $0.id == id }), extra.cards[index].state == .pending else { return }
        let proposal = extra.cards[index].proposal
        let applied = model.applyChatSetting(key: proposal.key, value: proposal.value)
        extra.cards[index].state = applied ? .applied : .failed
        if applied {
            switch proposal.key {
            case "uiLanguage" where model.needsReopenForLanguage:
                extra.notices.append(ChatNotice(kind: .info, text: L("The text on screen has already changed. Standard menu bar items (Edit, Window, and so on) change when you reopen Kikimimi.")))
            case "modelID" where model.availability(of: model.currentModel) == .notInstalled,
                 "llmModelID" where !model.isLLMInstalled:
                extra.notices.append(ChatNotice(kind: .info, text: L("This model is not downloaded yet. Download it in Settings.")))
            default:
                break
            }
        } else {
            extra.notices.append(ChatNotice(kind: .error, text: L("This setting could not be changed.")))
        }
        extras[messageID] = extra
    }

    /// 札の「やめる」
    func decline(card id: UUID, in messageID: UUID) {
        guard var extra = extras[messageID],
              let index = extra.cards.firstIndex(where: { $0.id == id }), extra.cards[index].state == .pending else { return }
        extra.cards[index].state = .declined
        extras[messageID] = extra
    }

    /// 確認用: 窓の中身を空にし、リサーチを切に戻す
    func selfTestReset() {
        newChat()
        researchOn = false
        showsResearchConfirm = false
        selfTestReply = nil
    }
}

/// 出している途中の文を、画面へ渡す回数を間引く (どのスレッドからでも呼べる)
final class StreamThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// 前に渡してから interval 秒たっていれば true (その時刻を覚える)
    func shouldSend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
