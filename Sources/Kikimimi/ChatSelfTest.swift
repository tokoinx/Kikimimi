import AppKit
import Foundation
import KikimimiCore
import KikimimiLLM
import KikimimiWhisper

/// `--selftest-ui-load` の中のチャットの確認 (CHAT CHECK)。LLM もネットワークも使わない。
/// 窓を開け、リサーチの 2 段の入れ方・札を押すまで設定が変わらない事・リサーチの鍵を断る事・
/// ページを読んだ回の案を出さない事・一覧の 20 項目の読み書き・設定の画面と同じ「変えられない時」・
/// 対訳の値が結果の画面のチェックと同じ事・札のラベルが設定の画面と同じ文である事・語彙のヒントの上限・
/// リサーチが切の時に読みに行かない事を確かめる。
/// 終わりに窓を閉じ、設定を元の値に戻す。`screenshots` があれば、絵 14〜17 を残す
@MainActor
enum ChatCheck {
    static func run(model: AppModel, screenshots: URL?, lines: inout [String]) async -> Bool {
        let chat = model.chat
        var failedStep: String?
        func step(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("CHAT CHECK: \(name) \(ok ? "ok" : "NG")" + (detail.isEmpty ? "" : " (\(detail))"))
            if !ok, failedStep == nil { failedStep = name }
        }
        // 始めの値を覚える (終わりに戻す)
        let catalog = model.chatCatalog
        var original: [String: String] = [:]
        for item in catalog {
            if let value = model.currentValue(for: item.key) { original[item.key] = value }
        }
        // 設定でない、確認が触る値 (終わりに戻す): 差分の有無と、選んでいる結果の対訳の印
        let originalHasAdapter = model.hasAdapter
        let originalHasTranslationAdapter = model.hasTranslationAdapter
        let bilingualJob = model.selectedJob
        let originalLineTranslations = bilingualJob?.showsLineTranslations
        // 対訳の設定そのもの (チャットの値は結果の印も見るので、値だけでは戻ったか分からない)
        let originalShowBilingual = model.showBilingual
        let originalFetcher = chat.fetcher
        let fetcher = CountingFetcher()
        chat.fetcher = fetcher
        chat.selfTestReset()
        // LLM が無い Mac (CI) でも、やり取りの所を出す (送る道は LLM を呼ばない)
        chat.selfTestReply = ""

        // 1. 窓を開ける
        AppDelegate.shared?.openChatWindow?()
        var window: NSWindow?
        for _ in 0..<40 {
            if let found = ChatWindow.all().first(where: { $0.isVisible }) {
                window = found
                break
            }
            await pause(0.25)
        }
        step("open the chat window", window != nil)
        if let window {
            var frame = window.frame
            frame.origin.y += frame.height - 640
            frame.size = CGSize(width: 480, height: 640)
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
        }
        await settle()
        if let window, let screenshots { lines.append(shot("14-chat-empty", window, screenshots)) }

        // 2. リサーチは 2 段でだけ入る
        step("research starts off", !chat.researchOn)
        chat.requestResearchOn()
        await settle()
        await pause(0.6)
        step("request alone keeps research off", !chat.researchOn && chat.showsResearchConfirm)
        if let window {
            if let sheet = window.attachedSheet {
                if let screenshots { lines.append(shot("15-chat-research-confirm", sheet, screenshots)) }
            } else {
                step("the confirmation sheet is shown", false)
            }
        }
        chat.confirmResearchOn()
        await settle()
        await pause(0.6)
        step("confirm turns research on", chat.researchOn && !chat.showsResearchConfirm)
        if let window, let screenshots { lines.append(shot("16-chat-research-on", window, screenshots)) }
        chat.turnResearchOff()
        step("turn off", !chat.researchOn)

        // 3. 案は、押すまで当てない
        model.useVAD = true
        let proposalID = chat.receive(reply: "I proposed turning off “Skip silence (VAD)”. Please confirm it in the app.\n[[set useVAD=off]]",
                                      pagesRead: false)
        let cards = proposalID.flatMap { chat.extras[$0]?.cards } ?? []
        step("one card for [[set useVAD=off]]", cards.count == 1 && cards.first?.state == .pending, "cards \(cards.count)")
        step("not applied before pressing Change", model.useVAD)
        await settle()
        if let window, let screenshots { lines.append(shot("17-chat-proposal", window, screenshots)) }
        if let proposalID, let card = cards.first {
            chat.apply(card: card.id, in: proposalID)
            let state = chat.extras[proposalID]?.cards.first?.state
            step("Change applies it", !model.useVAD && state == .applied)
        }
        model.useVAD = original[SettingKey.useVAD.rawValue] == "on"

        // 4. リサーチの鍵と、一覧に無い鍵は断る
        let researchReply = chat.receive(reply: "Sure.\n[[set chatResearch=on]]", pagesRead: false)
        let researchCards = researchReply.flatMap { chat.extras[$0]?.cards } ?? []
        step("[[set chatResearch=on]] gives no card", researchCards.isEmpty && !chat.researchOn)
        step("applyChatSetting refuses chatResearch", !model.applyChatSetting(key: ChatSettingsCatalog.researchKey, value: "on"))
        step("applyChatSetting refuses unknown keys", !model.applyChatSetting(key: "noSuchSetting", value: "on")
             && !model.applyChatSetting(key: SettingKey.notesWidth.rawValue, value: "400"))

        // 5. ページを読んだ回の案は、札にならない
        let pageReply = chat.receive(reply: "The page says so.\n[[set useVAD=off]]", pagesRead: true)
        let pageCards = pageReply.flatMap { chat.extras[$0]?.cards } ?? []
        step("no card after reading pages", pageCards.isEmpty && model.useVAD == (original[SettingKey.useVAD.rawValue] == "on"))

        // 6. 一覧の 20 項目の読み書き (どれも変えられる状態にしてから。変えられない時は、6b で見る)
        model.useVAD = true
        model.hasTranslationAdapter = true
        var missing: [String] = []
        var refused: [String] = []
        var changed: [String] = []
        var toggleFailures: [String] = []
        for item in catalog {
            // LLM を当て直すと、差分の有無が読み直される (didSet) ので、項目ごとに入れ直す
            model.hasTranslationAdapter = true
            guard let current = model.currentValue(for: item.key) else {
                missing.append(item.key)
                continue
            }
            if item.normalizedValue(current) == nil {
                // 一覧で選べない値 (手元の GGUF など): 当てられない事だけを見る
                lines.append("CHAT CHECK: \(item.key) has a value the chat cannot choose (\(current)); skipped")
                continue
            }
            if !model.applyChatSetting(key: item.key, value: current) { refused.append(item.key) }
            if model.currentValue(for: item.key) != current { changed.append(item.key) }
            if case .toggle = item.kind {
                let flipped = current == "on" ? "off" : "on"
                let ok = model.applyChatSetting(key: item.key, value: flipped) && model.currentValue(for: item.key) == flipped
                let back = model.applyChatSetting(key: item.key, value: current) && model.currentValue(for: item.key) == current
                if !ok || !back { toggleFailures.append(item.key) }
            }
        }
        step("catalog has 20 items", catalog.count == 20, "\(catalog.count)")
        step("every item has a current value", missing.isEmpty, missing.joined(separator: ","))
        step("every item accepts its current value", refused.isEmpty && changed.isEmpty,
             "refused [\(refused.joined(separator: ","))], changed [\(changed.joined(separator: ","))]")
        step("every toggle can be flipped and restored", toggleFailures.isEmpty, toggleFailures.joined(separator: ","))
        model.useVAD = original[SettingKey.useVAD.rawValue] == "on"
        model.hasTranslationAdapter = originalHasTranslationAdapter

        // 6b. 設定の画面で押せない時は、チャットからも変えられない (札は「変える」を出さず、理由を出す)
        let savedUseVAD = model.useVAD
        let savedAutoVADOff = model.autoVADOff
        let savedUseAdapter = model.useAdapter
        model.useVAD = false
        model.autoVADOff = false
        step("autoVADOff is unavailable while useVAD is off",
             model.unavailableReason(for: .autoVADOff) == .needsOn(.useVAD))
        step("applyChatSetting refuses autoVADOff while useVAD is off",
             !model.applyChatSetting(key: SettingKey.autoVADOff.rawValue, value: "on") && !model.autoVADOff)
        // 同じ答えの 2 枚: 1 枚目 (無音を飛ばすを入) を当てると、2 枚目が変えられるようになる (札は描く時に見る)
        let twoReply = chat.receive(reply: "I proposed both changes. Please confirm them in the app.\n[[set useVAD=on]]\n[[set autoVADOff=on]]",
                                    pagesRead: false)
        let twoCards = twoReply.flatMap { chat.extras[$0]?.cards } ?? []
        step("two cards: the second is unavailable until the first is applied",
             twoCards.count == 2 && twoCards.allSatisfy { $0.state == .pending } && model.unavailableReason(for: .autoVADOff) != nil,
             "cards \(twoCards.count)")
        await settle()
        if let window, let screenshots { lines.append(shot("18-chat-unavailable", window, screenshots)) }
        if let twoReply, twoCards.count == 2 {
            chat.apply(card: twoCards[0].id, in: twoReply)
            step("after the first card, autoVADOff can be changed",
                 model.useVAD && model.unavailableReason(for: .autoVADOff) == nil)
            chat.apply(card: twoCards[1].id, in: twoReply)
            step("the second card applies", chat.extras[twoReply]?.cards[1].state == .applied && model.autoVADOff)
        }
        model.useVAD = false
        step("useVAD off again: autoVADOff is unavailable again", model.unavailableReason(for: .autoVADOff) != nil)
        model.useVAD = true
        step("useVAD on: autoVADOff can be changed", model.unavailableReason(for: .autoVADOff) == nil
             && model.applyChatSetting(key: SettingKey.autoVADOff.rawValue, value: "off") && !model.autoVADOff)
        // 差分が 1 つも無い時の「差分を使う」
        model.hasAdapter = false
        model.hasTranslationAdapter = false
        let flippedAdapter = model.useAdapter ? "off" : "on"
        step("useAdapter is unavailable without adapters",
             model.unavailableReason(for: .useAdapter) == .noAdapter
             && !model.applyChatSetting(key: SettingKey.useAdapter.rawValue, value: flippedAdapter)
             && model.useAdapter == savedUseAdapter)
        model.hasTranslationAdapter = true
        step("useAdapter can be changed with an adapter",
             model.unavailableReason(for: .useAdapter) == nil
             && model.applyChatSetting(key: SettingKey.useAdapter.rawValue, value: flippedAdapter)
             && model.useAdapter != savedUseAdapter)
        model.useAdapter = savedUseAdapter
        model.hasAdapter = originalHasAdapter
        model.hasTranslationAdapter = originalHasTranslationAdapter
        model.useVAD = savedUseVAD
        model.autoVADOff = savedAutoVADOff

        // 6c. 対訳: チャットが読む値と書く道は、結果の画面の「対訳」のチェックと同じ
        if let job = bilingualJob {
            let savedSetting = model.showBilingual
            let savedMark = job.showsLineTranslations
            model.showBilingual = false
            job.showsLineTranslations = true
            step("bilingual: the chat reads the result screen's check (setting off, line mark on)",
                 model.currentValue(for: SettingKey.showBilingual.rawValue) == "on" && model.showsBilingual(job))
            step("bilingual: off from the chat clears the result's mark",
                 model.applyChatSetting(key: SettingKey.showBilingual.rawValue, value: "off")
                 && !job.showsLineTranslations && !model.showsBilingual(job)
                 && model.currentValue(for: SettingKey.showBilingual.rawValue) == "off")
            model.showBilingual = savedSetting
            job.showsLineTranslations = savedMark
        } else {
            lines.append("CHAT CHECK: bilingual follows the selected result skipped (no selected result)")
        }

        // 6d. 札のラベルは、設定の画面と同じ文 (設定の画面の部品と同じ書き方で比べる)
        func cardLabel(_ key: SettingKey) -> String? {
            model.chatCatalog.first { $0.key == key.rawValue }?.label(translationLanguage: model.translationLanguage)
        }
        step("card label: transcription model is the Settings label", cardLabel(.modelID) == L("Model"), cardLabel(.modelID) ?? "nil")
        step("card label: LLM is the Settings label", cardLabel(.llmModelID) == "LLM", cardLabel(.llmModelID) ?? "nil")
        let savedTarget = model.translationLanguage
        let firstLabel = cardLabel(.autoTranslate)
        step("card label: auto-translate is the Settings switch",
             firstLabel == SettingLabels.autoTranslate(target: savedTarget) && firstLabel?.contains("%") == false, firstLabel ?? "nil")
        let otherTarget = TranslationTarget.all.first { $0 != savedTarget } ?? savedTarget
        model.translationLanguage = otherTarget
        let otherLabel = cardLabel(.autoTranslate)
        step("card label: auto-translate follows the translation language",
             otherLabel == SettingLabels.autoTranslate(target: otherTarget) && otherLabel != firstLabel, otherLabel ?? "nil")
        model.translationLanguage = savedTarget

        // 6e. 語彙のヒント: 上限 (設定の定義の決まり) を超える案は断り、上限ちょうどは当てる
        let savedPrompt = model.initialPrompt
        let limit = ChatSettingsCatalog.initialPromptMaxLength
        let tooLong = String(repeating: "a", count: limit + 1)
        let longReply = chat.receive(reply: "Sure.\n[[set initialPrompt=\(tooLong)]]", pagesRead: false)
        let longCards = longReply.flatMap { chat.extras[$0]?.cards } ?? []
        step("vocabulary hints: \(limit + 1) characters give no card and are refused",
             longCards.isEmpty && !model.applyChatSetting(key: SettingKey.initialPrompt.rawValue, value: tooLong)
             && model.initialPrompt == savedPrompt)
        step("vocabulary hints: \(limit) characters are applied",
             model.applyChatSetting(key: SettingKey.initialPrompt.rawValue, value: String(repeating: "a", count: limit))
             && model.initialPrompt.count == limit)
        model.initialPrompt = savedPrompt

        // 7. リサーチが切の時は、URL の入った発言でも読みに行かない (LLM の手前まで: 答えは決めた文)
        chat.selfTestReply = "ok"
        chat.draft = "Please read https://www.apple.com/ and tell me about it"
        chat.send()
        let offFinished = await waitUntil(5) { !chat.isAnswering }
        let offNotices = chat.messages.last.flatMap { chat.extras[$0.id]?.notices } ?? []
        step("research off: no page fetch", offFinished && chat.fetchCount == 0 && fetcher.count == 0,
             "fetches \(chat.fetchCount)")
        step("research off: the answer tells that no page was read",
             offNotices.contains { $0.text == L("Research is off, so no web pages were read.") })
        // 比べるため: 入の時は (差し替えた偽物を) 1 回だけ読みに行く。ネットワークは使わない
        chat.requestResearchOn()
        chat.confirmResearchOn()
        chat.draft = "Please read https://www.apple.com/ and tell me about it"
        chat.send()
        let onFinished = await waitUntil(5) { !chat.isAnswering }
        step("research on: one page fetch (fake fetcher)", onFinished && chat.fetchCount == 1 && fetcher.count == 1,
             "fetches \(chat.fetchCount)")
        chat.turnResearchOff()

        // 7b. 答えが空 (止めても失敗してもいない・ほかの知らせも無い): 何も返らなかった訳を、発言に知らせる
        chat.selfTestReply = ""
        chat.draft = "Hello"
        chat.send()
        let emptyFinished = await waitUntil(5) { !chat.isAnswering }
        let lastMessage = chat.messages.last
        let emptyNotices = lastMessage.flatMap { chat.extras[$0.id]?.notices } ?? []
        step("an empty reply shows a notice",
             emptyFinished && lastMessage?.role == .user && lastMessage?.text == "Hello"
                && emptyNotices.count == 1 && emptyNotices.first?.kind == .warning
                && emptyNotices.first?.text == L("The LLM returned an empty answer."),
             "last role \(lastMessage.map { "\($0.role)" } ?? "none"), notices \(emptyNotices.map(\.text))")

        // 7c. LLM が失敗した (llama.cpp の失敗 -1 を、LLM を呼ぶ所で投げる): 発言に、失敗の知らせを 1 つ付ける。
        // その後、ふつうの答えは今までどおり出る
        let failure = LLMError.decodeFailed(-1)
        chat.selfTestError = failure
        chat.draft = "Hello again"
        chat.send()
        let failedFinished = await waitUntil(5) { !chat.isAnswering }
        let failedLast = chat.messages.last
        let failedNotices = failedLast.flatMap { chat.extras[$0.id]?.notices } ?? []
        step("an LLM failure shows the error",
             failedFinished && !chat.isAnswering && failedLast?.role == .user && failedLast?.text == "Hello again"
                && failedNotices.count == 1 && failedNotices.first?.kind == .error
                && failedNotices.first?.text == failure.localizedDescription
                && failedNotices.first?.text.contains("-1") == true,
             "last role \(failedLast.map { "\($0.role)" } ?? "none"), notices \(failedNotices.map(\.text))")
        chat.selfTestError = nil
        chat.selfTestReply = "Fine, thanks."
        chat.draft = "How are you?"
        chat.send()
        let afterFinished = await waitUntil(5) { !chat.isAnswering }
        let afterLast = chat.messages.last
        step("a normal reply works after the failure",
             afterFinished && afterLast?.role == .assistant && afterLast?.text == "Fine, thanks.",
             "last role \(afterLast.map { "\($0.role)" } ?? "none"), text \(afterLast?.text ?? "none")")
        chat.selfTestReply = ""

        // 8. 片付け: 窓を閉じ、設定を元の値に戻す
        chat.selfTestReset()
        chat.fetcher = originalFetcher
        for window in ChatWindow.all() { window.close() }
        await settle()
        var notRestored: [String] = []
        for item in catalog {
            guard let value = original[item.key] else { continue }
            if model.currentValue(for: item.key) != value {
                if item.normalizedValue(value) == nil || !model.applyChatSetting(key: item.key, value: value) {
                    notRestored.append(item.key)
                }
            }
        }
        model.hasAdapter = originalHasAdapter
        model.hasTranslationAdapter = originalHasTranslationAdapter
        model.showBilingual = originalShowBilingual
        if let bilingualJob, let originalLineTranslations { bilingualJob.showsLineTranslations = originalLineTranslations }
        step("settings restored", notRestored.isEmpty, notRestored.joined(separator: ","))
        step("the chat window is closed", !ChatWindow.all().contains { $0.isVisible })

        lines.append(failedStep.map { "CHAT CHECK FAILED: \($0)" } ?? "CHAT CHECK OK")
        return failedStep != nil
    }

    /// 設定の「追加学習 (LoRA)」の行で、GGUF でないファイルを選んだ時のお知らせ (LLM として選んだ時の文とは別)
    static func adapterMessageCheck(lines: inout [String]) -> Bool {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimimi-adapter-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appendingPathComponent("broken.lora.gguf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 4096).write(to: broken)
        } catch {
            lines.append("ADAPTER MESSAGE CHECK FAILED: could not write the test file")
            return true
        }
        let store = LLMModelStore(directory: folder.appendingPathComponent("LLM", isDirectory: true))
        var adapterMessage = ""
        var modelMessage = ""
        do { try store.importAdapter(from: broken, forModelKey: "x", kind: .audit, modelURL: broken) } catch {
            adapterMessage = error.localizedDescription
        }
        do { try store.importFile(from: broken) } catch {
            modelMessage = error.localizedDescription
        }
        let ok = adapterMessage == L("This is not a fine-tuning adapter (LoRA) in GGUF format. Choose a .gguf file that runs on llama.cpp.")
            && modelMessage == L("This is not an LLM in GGUF format. Choose a .gguf file that runs on llama.cpp.")
        lines.append(ok ? "ADAPTER MESSAGE CHECK OK"
                     : "ADAPTER MESSAGE CHECK FAILED: adapter \"\(adapterMessage)\", model \"\(modelMessage)\"")
        return !ok
    }

    /// 読みに行った回数を数える偽物 (ネットワークを使わない)
    final class CountingFetcher: ChatPageFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        private func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func fetch(_ url: URL) async throws -> ChatWebPage {
            increment()
            return ChatWebPage(url: url, title: "Test page", text: "This is a test page.")
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// メインが空くのを待ち、0.4 秒おく (絵が落ち着くまで)
    private static func settle() async {
        await pause(0.4)
        await Task.yield()
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await pause(0.05)
        }
        return condition()
    }

    /// 窓の絵を PNG で残す (タイトルバーとツールバーも入るよう、枠の view から撮る)
    private static func shot(_ name: String, _ window: NSWindow, _ directory: URL) -> String {
        let file = name + ".png"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let view = window.contentView?.superview ?? window.contentView else {
            return "UI LOAD: screenshot failed \(file): no view"
        }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return "UI LOAD: screenshot failed \(file): the view could not be drawn"
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return "UI LOAD: screenshot failed \(file): the view could not be drawn into a PNG"
        }
        do {
            try data.write(to: directory.appendingPathComponent(file))
        } catch {
            return "UI LOAD: screenshot failed \(file): \(error.localizedDescription)"
        }
        return "UI LOAD: screenshot \(file) \(rep.pixelsWide)x\(rep.pixelsHigh) (window frame)"
    }
}

/// `Kikimimi --selftest-chat <モデル.gguf> [--report <ファイル>]`
///
/// 画面を出さずに、本物の LLM でチャットの答えを確かめる。設定は読まず・書かない (今の値は、決めた既定の値)。
/// 1. 流れの確認: 1 つの発言で onText が 2 回以上呼ばれ、最後に渡った文が戻り値と同じ (CHAT STREAM OK / FAILED)。
///    やめた訳の確認: 小さな上限の答えは「上限」、ふつうの答えは「書き終えた」(CHAT FINISH: … ok / NG)。
/// 2. 測り: `ChatEvalCases.all` を 1 つずつ (履歴なし) 答えさせ、`ChatEval.score` で採点する (点は参考。落とさない)。
/// 終了コード: 0 = 流れとやめた訳の確認が通った、1 = 通らない・読み込めない、2 = 使い方の間違い
enum ChatSelfTest {
    /// 決めた既定の値 (利用者の設定は読まない)。設定の定義の、確認用の起動で決まった値か既定の値
    static let defaults: [String: String] = ChatSettingsCatalog.selfTestValues()

    static func run(arguments: [String]) -> Int32 {
        let usage = "usage: Kikimimi --selftest-chat <model.gguf> [--report <file>]"
        guard let i = arguments.firstIndex(of: "--selftest-chat"), i + 1 < arguments.count,
              FileManager.default.fileExists(atPath: arguments[i + 1]) else {
            log(usage)
            return 2
        }
        let modelPath = arguments[i + 1]
        let reportPath = arguments.firstIndex(of: "--report").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        var lines: [String] = []
        func out(_ line: String) {
            log(line)
            lines.append(line)
        }
        defer {
            if let reportPath {
                try? (lines.joined(separator: "\n") + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            }
        }
        out("llama.cpp: " + LlamaEngine.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        let catalog = ChatSettingsCatalog.items()
        let access = ChatSettingsSnapshot(values: defaults)
        do {
            var clock = Date()
            let engine = try LlamaEngine(modelPath: modelPath, options: LlamaOptions())
            out("loaded: \(engine.modelDescription), context \(engine.contextLength) tokens, \(engine.chatFormatDescription), \(seconds(since: clock))")

            // 1. 流れの確認
            clock = Date()
            let prompt = try ChatPromptBuilder.build(history: [], newUserText: "What can you do in this app?", catalog: catalog,
                                                     access: access, pages: [], researchOn: false, engine: engine)
            var calls = 0
            var last = ""
            let reply = try engine.generate(prompt, shouldCancel: { false }, onText: { text in
                calls += 1
                last = text
            })
            // ふつうの答えの、やめた訳 (答えの generate の直後に読む)
            let normalFinish = engine.lastFinish
            let streamOK = calls >= 2 && last == reply
            out("stream: \(calls) updates, \(reply.utf8.count) bytes, \(seconds(since: clock))")
            out(streamOK ? "CHAT STREAM OK" : "CHAT STREAM FAILED: \(calls) updates, last equals the reply: \(last == reply)")

            // 1b. やめた訳: 長い答えの要る依頼を、わざと小さな上限で答えさせると「上限」、ふつうの答えは「書き終えた」
            var tiny = try ChatPromptBuilder.build(history: [], newUserText: "Explain step by step, in detail, how to transcribe a recording and then audit and translate it in this app.",
                                                   catalog: catalog, access: access, pages: [], researchOn: false, engine: engine)
            tiny.maxTokens = 4
            let tinyReply = try engine.generate(tiny, shouldCancel: { false })
            let tinyFinish = engine.lastFinish
            let tinyOK = tinyFinish == .limit
            let normalOK = normalFinish == .complete
            out("CHAT FINISH: a tiny limit is reported as cut off: \(tinyOK ? "ok" : "NG") (finish \(tinyFinish), \(engine.tokenCount(tinyReply)) tokens)")
            out("CHAT FINISH: a normal answer is reported as complete: \(normalOK ? "ok" : "NG") (finish \(normalFinish), \(engine.tokenCount(reply)) tokens)")

            // 2. 測り
            var good = 0
            for item in ChatEvalCases.all {
                let casePrompt = try ChatPromptBuilder.build(history: [], newUserText: item.utterance, catalog: catalog,
                                                             access: access, pages: [], researchOn: false, engine: engine)
                let answer = try engine.generate(casePrompt, shouldCancel: { false })
                let ok = ChatEval.score(reply: answer, expected: item.expected, catalog: catalog)
                if ok { good += 1 }
                let expected = item.expected.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "none"
                let head = String(answer.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(160))
                out("CHAT EVAL: \(item.id) \(ok ? "ok" : "NG") | \(expected) | \(head)")
            }
            out("CHAT EVAL: \(good)/\(ChatEvalCases.all.count)")
            return streamOK && tinyOK && normalOK ? 0 : 1
        } catch {
            out("SELFTEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(date))
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
