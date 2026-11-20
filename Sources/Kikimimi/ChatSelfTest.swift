import AppKit
import Foundation
import KikimimiCore
import KikimimiLLM
import KikimimiWhisper

/// `--selftest-ui-load` の中のチャットの確認 (CHAT CHECK)。LLM もネットワークも使わない。
/// 窓を開け、リサーチの 2 段の入れ方・札を押すまで設定が変わらない事・リサーチの鍵を断る事・
/// ページを読んだ回の案を出さない事・一覧の 20 項目の読み書き・リサーチが切の時に読みに行かない事を確かめる。
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

        // 6. 一覧の 20 項目の読み書き
        var missing: [String] = []
        var refused: [String] = []
        var changed: [String] = []
        var toggleFailures: [String] = []
        for item in catalog {
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
/// 2. 測り: `ChatEvalCases.all` を 1 つずつ (履歴なし) 答えさせ、`ChatEval.score` で採点する (点は参考。落とさない)。
/// 終了コード: 0 = 流れの確認が通った、1 = 通らない・読み込めない、2 = 使い方の間違い
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
            let streamOK = calls >= 2 && last == reply
            out("stream: \(calls) updates, \(reply.utf8.count) bytes, \(seconds(since: clock))")
            out(streamOK ? "CHAT STREAM OK" : "CHAT STREAM FAILED: \(calls) updates, last equals the reply: \(last == reply)")

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
            return streamOK ? 0 : 1
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
