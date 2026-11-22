import XCTest
@testable import KikimimiCore

/// 答えの中の動作の印の読み取りと、設定の一覧
final class ChatParserTests: XCTestCase {
    let catalog = ChatSettingsCatalog.items()

    func testValidProposalsAreReadAndRemovedFromText() {
        let reply = "無音を飛ばす設定を切にする案を出しました。\n[[set useVAD=off]]\n[[set translationLanguage=ko]]"
        let r = ChatActionParser.parse(reply, catalog: catalog)
        XCTAssertEqual(r.visibleText, "無音を飛ばす設定を切にする案を出しました。")
        XCTAssertEqual(r.proposals.map(\.key), ["useVAD", "translationLanguage"])
        XCTAssertEqual(r.proposals.map(\.value), ["off", "ko"])
        XCTAssertEqual(r.proposals[0].item.labelKey, "Skip silence (VAD)")
        XCTAssertTrue(r.rejected.isEmpty)
        XCTAssertTrue(r.opens.isEmpty)
    }

    func testLenientCaseSpacesAndBooleanWords() {
        let r = ChatActionParser.parse("ok [[ SET  showNotes = TRUE ]] [[set preferaccuracy=No]] [[set uiLanguage= JA ]]",
                                       catalog: catalog)
        XCTAssertEqual(r.proposals.map(\.key), ["showNotes", "preferAccuracy", "uiLanguage"])
        XCTAssertEqual(r.proposals.map(\.value), ["on", "off", "ja"])
        XCTAssertEqual(r.visibleText, "ok")
    }

    func testChoiceAcceptsEnglishNameAndModelIDs() {
        let r = ChatActionParser.parse("[[set translationLanguage=Korean]][[set llmModelID=qwen3.5-9b]][[set modelID=small-q5_1]]",
                                       catalog: catalog)
        XCTAssertEqual(r.proposals.map(\.value), ["ko", "qwen3.5-9b", "small-q5_1"])
    }

    func testUnknownKeysBadValuesAndExcludedKeysAreRejected() {
        let reply = "[[set chatResearch=on]] [[set notesWidth=500]] [[set nothing=1]] [[set useVAD=maybe]] " +
            "[[set translationLanguage=xx]] [[set llmModelID=file:mine.gguf]] [[set useVAD]]"
        let r = ChatActionParser.parse(reply, catalog: catalog)
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertEqual(r.rejected.count, 7)
        XCTAssertEqual(r.visibleText, "")
    }

    func testTextValueLimits() {
        let ok = ChatActionParser.parse("[[set initialPrompt=Roblox, Kikimimi]]", catalog: catalog)
        XCTAssertEqual(ok.proposals.first?.value, "Roblox, Kikimimi")
        let quoted = ChatActionParser.parse("[[set initialPrompt=\"Lua, Roblox\"]]", catalog: catalog)
        XCTAssertEqual(quoted.proposals.first?.value, "Lua, Roblox")
        let long = String(repeating: "a", count: ChatSettingsCatalog.initialPromptMaxLength + 1)
        XCTAssertTrue(ChatActionParser.parse("[[set initialPrompt=\(long)]]", catalog: catalog).proposals.isEmpty)
        let control = ChatActionParser.parse("[[set initialPrompt=a\u{07}b]]", catalog: catalog)
        XCTAssertTrue(control.proposals.isEmpty)
        XCTAssertEqual(control.rejected.count, 1)
        let newline = ChatActionParser.parse("[[set initialPrompt=a\nb]]", catalog: catalog)
        XCTAssertTrue(newline.proposals.isEmpty)
    }

    func testSameKeyTwiceKeepsTheLaterOne() {
        let r = ChatActionParser.parse("[[set useVAD=off]] [[set showNotes=on]] [[set useVAD=on]]", catalog: catalog)
        XCTAssertEqual(r.proposals.map(\.key), ["showNotes", "useVAD"])
        XCTAssertEqual(r.proposals.last?.value, "on")
    }

    func testAtMostFiveProposals() {
        let keys = ["useVAD", "showNotes", "livePreview", "autoAudit", "autoTranslate", "useLedger", "useAdapter"]
        let reply = keys.map { "[[set \($0)=off]]" }.joined(separator: "\n")
        let r = ChatActionParser.parse(reply, catalog: catalog)
        XCTAssertEqual(r.proposals.map(\.key), Array(keys.prefix(5)))
        XCTAssertEqual(r.rejected.count, 2)
    }

    func testSettingsAreRejectedWhenNotAllowed() {
        let r = ChatActionParser.parse("[[set useVAD=off]] [[open settings=llm]]", catalog: catalog, allowSettings: false)
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertEqual(r.rejected, ["[[set useVAD=off]]"])
        XCTAssertEqual(r.opens, [ChatOpenSettings(page: .llm)])
    }

    func testOpenSettings() {
        let r = ChatActionParser.parse("Go to Settings.\n[[open settings]]\n[[Open Settings = Transcription]]\n[[open settings=llm]]\n[[open settings=llm]]\n[[open settings=nowhere]]",
                                       catalog: catalog)
        XCTAssertEqual(r.opens, [ChatOpenSettings(page: nil), ChatOpenSettings(page: .transcription), ChatOpenSettings(page: .llm)])
        XCTAssertEqual(r.rejected, ["[[open settings=nowhere]]"])
        XCTAssertEqual(r.visibleText, "Go to Settings.")
    }

    func testOtherDoubleBracketsStayInTheText() {
        let r = ChatActionParser.parse("See [[wiki link]] and [[openai]].", catalog: catalog)
        XCTAssertEqual(r.visibleText, "See [[wiki link]] and [[openai]].")
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testVisiblePrefixHidesUnfinishedMarkers() {
        XCTAssertEqual(ChatActionParser.visiblePrefix("案を出しました。\n[[se"), "案を出しました。\n")
        XCTAssertEqual(ChatActionParser.visiblePrefix("案を出しました。\n["), "案を出しました。\n")
        XCTAssertEqual(ChatActionParser.visiblePrefix("案です。\n[[set useVAD=off]]\n[[set show"), "案です。")
        XCTAssertEqual(ChatActionParser.visiblePrefix("Hello wor"), "Hello wor")
        XCTAssertEqual(ChatActionParser.visiblePrefix("a [[set useVAD=off]"), "a ")
    }

    func testCatalogHasTheSettingsAndNeverTheResearchSwitch() {
        let keys = Set(catalog.map(\.key))
        let expected: Set<String> = ["uiLanguage", "languageCode", "modelID", "preferAccuracy", "useVAD", "autoVADOff",
                                     "filterHallucinations", "autoMixedLanguage", "livePreview", "initialPrompt", "llmModelID",
                                     "autoAudit", "autoTranslate", "translationLanguage", "showBilingual", "showNotes",
                                     "useLedger", "reuseTranslationMemory", "useAdapter", "practiceDictation"]
        XCTAssertEqual(keys, expected)
        XCTAssertFalse(keys.contains(ChatSettingsCatalog.researchKey))
        XCTAssertEqual(catalog.count, keys.count, "keys are unique")
        // ラベルは、どれも 12 の表に在る鍵。置き換えの印が在るのは、訳す先の名前が入る文 (自動の翻訳) だけ。
        // 訳さない語 (LLM) は表に入れない
        for item in catalog {
            if item.labelKey == SettingLabels.autoTranslateKey {
                XCTAssertEqual(item.key, "autoTranslate")
            } else {
                XCTAssertFalse(item.labelKey.contains("%"), item.key)
            }
            if SettingLabels.untranslated.contains(item.labelKey) {
                XCTAssertNil(L10nTables.tables[.ja]?[item.labelKey], item.key)
            } else {
                XCTAssertNotNil(L10nTables.tables[.ja]?[item.labelKey], item.key)
            }
            // 札に出すラベルに、置き換えの印が残らない
            for target in ["ja", "en", "ko"] {
                XCTAssertFalse(item.label(translationLanguage: target).contains("%"), item.key)
            }
        }
        // 言語とモデルの値
        guard case .choice(let spoken) = catalog.first(where: { $0.key == "languageCode" })?.kind else { return XCTFail() }
        XCTAssertEqual(spoken.map(\.value), Languages.all.map(\.code))
        guard case .choice(let llms) = catalog.first(where: { $0.key == "llmModelID" })?.kind else { return XCTFail() }
        XCTAssertEqual(llms.map(\.value), ["qwen3.5-4b", "qwen3.5-2b", "qwen3.5-9b"])
        guard case .choice(let targets) = catalog.first(where: { $0.key == "translationLanguage" })?.kind else { return XCTFail() }
        XCTAssertEqual(targets.count, 13)
    }

    func testCatalogTakesTheModelListsFromTheCaller() {
        let items = ChatSettingsCatalog.items(whisperModels: [ModelCatalog.all[0]], llmModels: [LLMCatalog.all[1]])
        guard case .choice(let whisper) = items.first(where: { $0.key == "modelID" })?.kind,
              case .choice(let llms) = items.first(where: { $0.key == "llmModelID" })?.kind else { return XCTFail() }
        XCTAssertEqual(whisper.map(\.value), [ModelCatalog.all[0].id])
        XCTAssertEqual(llms.map(\.value), ["qwen3.5-2b"])
    }

    func testDisplayValue() {
        L10n.language = .ja
        defer { L10n.language = .en }
        let vad = catalog.first { $0.key == "useVAD" }!
        XCTAssertEqual(vad.displayValue("off"), "オフ")
        XCTAssertEqual(vad.label(translationLanguage: "ja"), "無音を飛ばす (VAD)")
        let target = catalog.first { $0.key == "translationLanguage" }!
        XCTAssertEqual(target.displayValue("ko"), "韓国語")
    }

    func testEvalScoring() {
        XCTAssertTrue(ChatEval.score(reply: "ok\n[[set useVAD=off]]", expected: ["useVAD": "off"], catalog: catalog))
        XCTAssertFalse(ChatEval.score(reply: "ok\n[[set useVAD=on]]", expected: ["useVAD": "off"], catalog: catalog))
        XCTAssertFalse(ChatEval.score(reply: "ok", expected: ["useVAD": "off"], catalog: catalog))
        XCTAssertTrue(ChatEval.score(reply: "VAD is…", expected: nil, catalog: catalog))
        XCTAssertFalse(ChatEval.score(reply: "VAD is…\n[[set useVAD=off]]", expected: nil, catalog: catalog))
        // 期待の値は、どれも一覧で取れる値
        XCTAssertGreaterThanOrEqual(ChatEvalCases.all.count, 16)
        for c in ChatEvalCases.all {
            for (key, value) in c.expected ?? [:] {
                let item = catalog.first { $0.key == key }
                XCTAssertEqual(item?.normalizedValue(value), value, c.id)
            }
        }
    }
}
