import AppKit
import KikimimiCore
import SwiftUI

/// チャットの窓 (Window の id と、開いている窓を探す口)
enum ChatWindow {
    static let id = "chat"

    /// SwiftUI は、Window(id:) の窓に、id で始まる名前を付ける
    @MainActor
    static func all() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.identifier?.rawValue.hasPrefix(id) == true }
    }
}

/// LLM とのチャットの窓。上から: リサーチの帯・やり取り・入力・小さな説明
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chat = model.chat
        VStack(spacing: 0) {
            ResearchBanner()
            Divider()
            if model.isLLMInstalled || chat.selfTestReply != nil {
                ChatTranscript()
            } else {
                ChatNoLLMNotice()
            }
            Divider()
            ChatInputBar()
        }
        .frame(minWidth: 380, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chat.newChat()
                } label: {
                    Label(L("New chat"), systemImage: "square.and.pencil")
                }
                .help(L("New chat"))
                .disabled(chat.messages.isEmpty && !chat.isAnswering)
            }
        }
        // リサーチを入れるかの確認 (自分で作るシート。既定のボタンは「キャンセル」)
        .sheet(isPresented: Binding(
            get: { chat.showsResearchConfirm },
            set: { if !$0 { chat.cancelResearchOn() } }
        )) {
            ResearchConfirmSheet()
                .environment(model)
                .id(model.uiLanguage)
        }
        // 窓を閉じた時、監査・翻訳の仕事が無ければ、LLM を手放す
        .onDisappear { model.releaseLLMAfterChat() }
    }
}

/// リサーチの帯 (いつも見える)。切は灰色、入は橙色
struct ResearchBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chat = model.chat
        let on = chat.researchOn
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: on ? "exclamationmark.triangle.fill" : "network.slash")
                .font(.title3)
                .foregroundStyle(on ? Color.orange : Color.secondary)
            Text(on ? L("Research is on, at your own risk. You are responsible for any breakage or damage caused by Prompt Injection.")
                 : L("Research (reading web pages) is off. Turn it on only when you need it, at your own risk."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if on {
                Button(L("Turn off")) { chat.turnResearchOff() }
            } else {
                Button(L("Turn on…")) { chat.requestResearchOn() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(on ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08))
    }
}

/// リサーチを入れるかの確認のシート
struct ResearchConfirmSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chat = model.chat
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Turn on research at your own risk?"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.orange)
            Text(L("With research on, the chat reads the web pages whose URLs you write. A web page can contain hidden instructions (Prompt Injection) that make the LLM give wrong answers or propose changes you did not ask for. You are responsible for any breakage or damage caused by Prompt Injection."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Research turns off again every time you open the app."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                // Return で押されるのは「キャンセル」(入れるほうは、押した時だけ)
                Button(L("Cancel")) { chat.cancelResearchOn() }
                    .keyboardShortcut(.defaultAction)
                Button(L("Turn on at my own risk")) { chat.confirmResearchOn() }
            }
        }
        .padding(20)
        // esc でも閉じる (見えないボタン。「キャンセル」には Return を当てているので、esc はこちらで受ける)
        .background {
            Button(L("Close")) { chat.cancelResearchOn() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: 420)
    }
}

/// LLM が無い時の案内 (やり取りの所に出す)
struct ChatNoLLMNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = model.currentLLM
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L("The chat uses an LLM that runs on your Mac"))
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(L("%1$@ (about %2$@) is downloaded only once. Your transcriptions never leave your Mac.",
                   selection.name,
                   selection.spec.map { TimeFormat.bytes(Int64($0.approxMB) * 1_000_000) } ?? "—"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                LLMDownloadControls()
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// やり取りの一覧 (新しい発言で下へ送る)
struct ChatTranscript: View {
    @Environment(AppModel.self) private var model
    private let bottomID = "chat-bottom"

    var body: some View {
        let chat = model.chat
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty && !chat.isAnswering {
                        ChatEmptyGuide()
                    }
                    ForEach(chat.messages) { message in
                        ChatMessageRow(message: message, extras: chat.extras[message.id])
                            .id(message.id)
                    }
                    if chat.isAnswering {
                        ChatStreamingRow()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(12)
            }
            .onChange(of: chat.messages.count) {
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: chat.streamingText) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: chat.isAnswering) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

/// 空の時の案内と、押すと下書きに入る例
struct ChatEmptyGuide: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let examples = [
            L("What can I change from here?"),
            L("Turn off silence skipping"),
            L("Translate into Korean from now on"),
        ]
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Ask about Kikimimi, or ask it to change a setting. Nothing changes until you press “Change”."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(examples, id: \.self) { example in
                Button {
                    model.chat.draft = example
                } label: {
                    Label(example, systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 発言 1 つ (user は右、assistant は左) と、その下の札・ボタン・知らせ
struct ChatMessageRow: View {
    let message: ChatMessage
    let extras: ChatTurnExtras?

    var body: some View {
        let isUser = message.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if !message.text.isEmpty {
                HStack {
                    if isUser { Spacer(minLength: 40) }
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .fixedSize(horizontal: false, vertical: true)
                    if !isUser { Spacer(minLength: 40) }
                }
            }
            if let extras {
                ChatExtrasView(messageID: message.id, extras: extras)
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

/// 札・「設定を開く」・知らせ
struct ChatExtrasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let messageID: UUID
    let extras: ChatTurnExtras

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(extras.cards) { card in
                ChatProposalCardView(card: card, messageID: messageID)
            }
            ForEach(Array(extras.opens.enumerated()), id: \.offset) { _, open in
                Button(open.page.map { L("Open “%@” in Settings…", $0.label) } ?? L("Open settings…")) {
                    if let page = open.page { model.settingsTab = SettingsTab(page) }
                    openSettings()
                }
                .controlSize(.small)
            }
            ForEach(extras.notices) { notice in
                Label(notice.text, systemImage: Self.symbol(notice.kind))
                    .font(.caption)
                    .foregroundStyle(notice.kind == .error ? Color.red : (notice.kind == .warning ? Color.orange : Color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    static func symbol(_ kind: ChatNotice.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// 設定を変える案の札 1 つ (「項目名: 今の値 → 新しい値」と「変える」「やめる」)
struct ChatProposalCardView: View {
    @Environment(AppModel.self) private var model
    let card: ChatProposalCard
    let messageID: UUID

    var body: some View {
        let item = card.proposal.item
        let before = card.before.map { item.displayValue($0) } ?? "—"
        let after = item.displayValue(card.proposal.value)
        // ラベルは設定の画面と同じ文 (訳す先の名前が入る物は、今の訳す先の言語で作る)
        let label = item.label(translationLanguage: model.translationLanguage)
        // 今、変えられるか (描く時に、その場で見る: 同じ答えの前の札を当てると、押せるようになる事が在る)
        let unavailable = SettingKey(rawValue: item.key).flatMap { model.unavailableReason(for: $0) }
        VStack(alignment: .leading, spacing: 6) {
            Text(card.state == .alreadySet ? L("%1$@: %2$@", label, after) : L("%1$@: %2$@ → %3$@", label, before, after))
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            switch card.state {
            case .pending:
                if let unavailable {
                    // 変えられない時は「変える」を出さず、理由を出す
                    Label(unavailable.message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Cancel")) { model.chat.decline(card: card.id, in: messageID) }
                        .controlSize(.small)
                } else {
                    HStack {
                        Button(L("Change")) { model.chat.apply(card: card.id, in: messageID) }
                            .buttonStyle(.borderedProminent)
                        Button(L("Cancel")) { model.chat.decline(card: card.id, in: messageID) }
                    }
                    .controlSize(.small)
                }
            case .alreadySet:
                Text(L("It is already this value."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .applied:
                Label(L("Changed"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.green)
            case .declined, .failed:
                Label(L("Not changed"), systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

/// 答えを出している途中 (途中の文と、段階)
struct ChatStreamingRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chat = model.chat
        VStack(alignment: .leading, spacing: 6) {
            if !chat.streamingText.isEmpty {
                Text(chat.streamingText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Self.phaseText(chat.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func phaseText(_ phase: ChatPhase) -> String {
        switch phase {
        case .readingPages: return L("Reading web pages…")
        case .waitingForLLM: return L("Waiting for the LLM… (it is loading, or an audit or translation is using it)")
        case .answering, .idle: return L("Answering…")
        }
    }
}

/// 入力の欄 (Return で送る。日本語入力の変換を確定する Return では送らない: onSubmit は確定の後にだけ来る)
struct ChatInputBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = model.chat
        let ready = model.isLLMInstalled || chat.selfTestReply != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Message"), text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { chat.send() }
                    .disabled(!ready)
                if chat.isAnswering {
                    Button(L("Stop")) { chat.stop() }
                } else {
                    Button(L("Send")) { chat.send() }
                        .disabled(!chat.canSend)
                }
            }
            Text(L("The LLM runs on this Mac. Settings change only after you press “Change”."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { focused = ready }
    }
}

extension SettingsTab {
    /// チャットの「設定を開く」の行き先
    init(_ page: ChatSettingsPage) {
        switch page {
        case .general: self = .general
        case .transcription: self = .transcription
        case .llm: self = .llm
        @unknown default: self = .general
        }
    }
}

/// メニューの「LLM とチャット」(⇧⌘L) と、メインの窓のツールバーの絵だけのボタン
struct ChatWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    /// ツールバーの絵だけのボタンにする
    var iconOnly = false

    var body: some View {
        if iconOnly {
            Button {
                openWindow(id: ChatWindow.id)
            } label: {
                Label(L("Chat with the LLM"), systemImage: "bubble.left.and.bubble.right")
            }
            .labelStyle(.iconOnly)
            .help(L("Chat with the LLM"))
        } else {
            Button(L("Chat with the LLM")) { openWindow(id: ChatWindow.id) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
