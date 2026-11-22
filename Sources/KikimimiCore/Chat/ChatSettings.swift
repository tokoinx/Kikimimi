import Foundation

/// 設定の画面のタブ (チャットから「設定を開く」時の行き先)
public enum ChatSettingsPage: String, Sendable, Equatable, CaseIterable {
    case general
    case transcription
    case llm

    /// タブの名前の鍵 (設定の画面のタブと同じ鍵)
    public var labelKey: String {
        switch self {
        case .general: return LKey("General")
        case .transcription: return LKey("Transcription")
        case .llm: return LKey("Audit & translation")
        }
    }

    /// 画面に出す名前 (今の画面の言語)
    public var label: String { L10n.lookup(labelKey) }
}

/// 選べる値 1 つ
public struct ChatChoice: Sendable, Equatable {
    /// 保存する値のコード (UserDefaults の値と同じ)
    public let value: String
    /// LLM に見せる英語の名前 (訳さない)
    public let englishName: String
    /// 画面に出す名前の鍵 (表に無い物は、そのまま出る)
    public let displayKey: String

    public init(value: String, englishName: String, displayKey: String) {
        self.value = value
        self.englishName = englishName
        self.displayKey = displayKey
    }

    /// 画面に出す名前 (今の画面の言語)
    public var displayName: String { L10n.lookup(displayKey) }
}

/// 設定の種類
public enum ChatSettingKind: Sendable, Equatable {
    /// 入り切り。値は "on" / "off"
    case toggle
    /// 決まった値から 1 つ
    case choice([ChatChoice])
    /// 自由な文。決まり (長さの上限・制御文字は入れられない) は、設定の定義 (`SettingKind.text`) から来る
    case text(SettingTextRule)
}

/// チャットから変える案を出せる設定 1 つ
public struct ChatSettingItem: Sendable, Equatable {
    /// UserDefaults の名前 (AppModel の設定の名前と同じ)
    public let key: String
    /// 画面のラベルの鍵 (設定の画面と同じ英語の鍵。`label(translationLanguage:)` で今の言語の文になる)。
    /// 設定の画面のコードに同じ鍵が在る事は、`ChatSettingsLabelGuardTests.testChatLabelsAreTheSettingsScreenLabels` が見る
    public let labelKey: String
    /// LLM に見せる短い説明 (英語。訳さない)
    public let summary: String
    public let kind: ChatSettingKind
    /// この設定が在る設定の画面のタブ。結果の画面で変える物 (対訳・メモ・書き取り) は nil
    public let page: ChatSettingsPage?

    public init(key: String, labelKey: String, summary: String, kind: ChatSettingKind, page: ChatSettingsPage?) {
        self.key = key
        self.labelKey = labelKey
        self.summary = summary
        self.kind = kind
        self.page = page
    }

    /// 画面に出すラベル (今の画面の言語)。訳す先の名前が入る文 (自動の翻訳) は、渡した訳す先の言語で作る。
    /// 訳さない語 (LLM) は、そのまま
    public func label(translationLanguage: String) -> String {
        if labelKey == SettingLabels.autoTranslateKey { return SettingLabels.autoTranslate(target: translationLanguage) }
        if SettingLabels.untranslated.contains(labelKey) { return labelKey }
        return L10n.lookup(labelKey)
    }

    /// LLM が書いた値を、保存する形にする (toggle は "on" / "off"、choice は値のコード)。取れない値なら nil。
    /// 大文字小文字と前後の空白にはゆるい。toggle は true/false・yes/no・1/0 も受ける。
    /// choice は、値のコードのほかに英語の名前でも受ける
    public func normalizedValue(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 囲みの引用符 ("…" '…' “…”) は外す
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "“" && last == "”") {
            value = String(value.dropFirst().dropLast())
        }
        switch kind {
        case .toggle:
            switch value.lowercased() {
            case "on", "true", "yes", "1": return "on"
            case "off", "false", "no", "0": return "off"
            default: return nil
            }
        case .choice(let choices):
            let lower = value.lowercased()
            if let hit = choices.first(where: { $0.value.lowercased() == lower }) { return hit.value }
            if let hit = choices.first(where: { $0.englishName.lowercased() == lower }) { return hit.value }
            return nil
        case .text(let rule):
            return rule.accepts(value) ? value : nil
        }
    }

    /// 値を画面に出す形にする (toggle は “On” / “Off”、choice はその名前、text はそのまま)
    public func displayValue(_ value: String) -> String {
        switch kind {
        case .toggle:
            return value == "on" ? L("On") : L("Off")
        case .choice(let choices):
            return choices.first { $0.value == value }?.displayName ?? value
        case .text:
            return value
        }
    }

    /// 入れられない文字か (決まりは `SettingTextRule.isControl` の 1 か所)
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        SettingTextRule.isControl(scalar)
    }
}

/// チャットに出す時の出し方 (チャットだけの物。鍵・種類・選択肢は SettingKey の定義から来る)
public struct ChatSettingPresentation: Sendable, Equatable {
    /// 画面のラベルの鍵 (設定の画面と同じ英語の鍵。
    /// 同じである事は `ChatSettingsLabelGuardTests.testChatLabelsAreTheSettingsScreenLabels` が見る)
    public let labelKey: String
    /// LLM に見せる短い説明 (英語。訳さない)
    public let summary: String
    /// この設定が在る設定の画面のタブ。結果の画面で変える物 (対訳・メモ・書き取り) は nil
    public let page: ChatSettingsPage?

    public init(labelKey: String, summary: String, page: ChatSettingsPage?) {
        self.labelKey = labelKey
        self.summary = summary
        self.page = page
    }
}

extension SettingKey {
    /// チャットに出す時の出し方。nil は、チャットに出さない (チャットから決して変えない)。
    /// 設定を足したら、ここで出すか出さないかを決める (決め忘れは、コンパイルが止める)。
    /// 一覧の並びは、SettingKey の case の並び
    public var chatPresentation: ChatSettingPresentation? {
        switch self {
        // 一般
        case .uiLanguage:
            return ChatSettingPresentation(labelKey: LKey("Display language"),
                                           summary: "Language of the app's menus and windows.",
                                           page: .general)
        // 文字起こし
        case .languageCode:
            return ChatSettingPresentation(labelKey: LKey("Spoken language"),
                                           summary: "Language spoken in recordings. auto = detect it; ja+en = recordings that switch between Japanese and English (2-4 times slower).",
                                           page: .transcription)
        case .modelID:
            return ChatSettingPresentation(labelKey: LKey("Model"),
                                           summary: "Whisper speech recognition model. Larger is more accurate but slower. It must be downloaded in Settings.",
                                           page: .transcription)
        case .preferAccuracy:
            return ChatSettingPresentation(labelKey: LKey("Prefer accuracy (beam search)"),
                                           summary: "Beam search: a little more accurate, but slower.",
                                           page: .transcription)
        case .useVAD:
            return ChatSettingPresentation(labelKey: LKey("Skip silence (VAD)"),
                                           summary: "Skip silent parts (VAD). Faster and fewer made-up lines; singing may be skipped.",
                                           page: .transcription)
        case .autoVADOff:
            return ChatSettingPresentation(labelKey: LKey("When there is continuous sound but very little text, transcribe again without skipping silence"),
                                           summary: "If a recording has continuous sound but very little text, transcribe it again without skipping silence.",
                                           page: .transcription)
        case .filterHallucinations:
            return ChatSettingPresentation(labelKey: LKey("Remove common misrecognitions and repeated sentences"),
                                           summary: "Remove common made-up lines and repeated sentences from transcriptions.",
                                           page: .transcription)
        case .autoMixedLanguage:
            return ChatSettingPresentation(labelKey: LKey("Automatically transcribe recordings that mix Japanese and English as “Japanese + English”"),
                                           summary: "Detect recordings that mix Japanese and English and transcribe them as ja+en. Needs useVAD on.",
                                           page: .transcription)
        case .livePreview:
            return ChatSettingPresentation(labelKey: LKey("Show a preview while recording"),
                                           summary: "Show the text while recording.",
                                           page: .transcription)
        case .initialPrompt:
            return ChatSettingPresentation(labelKey: LKey("Vocabulary hints"),
                                           summary: "Vocabulary hints: proper nouns and technical terms, so they come out with this spelling. Plain text, one line.",
                                           page: .transcription)
        // 監査・翻訳
        case .llmModelID:
            return ChatSettingPresentation(labelKey: SettingLabels.llm,
                                           summary: "Local LLM used for audit, translation, and this chat. Larger is smarter but slower. It must be downloaded in Settings.",
                                           page: .llm)
        case .autoAudit:
            return ChatSettingPresentation(labelKey: LKey("Audit after transcription (check for repetitions and mishearings)"),
                                           summary: "After transcription, the LLM checks for repetitions and mishearings.",
                                           page: .llm)
        case .translationLanguage:
            return ChatSettingPresentation(labelKey: LKey("Translate into"),
                                           summary: "Language that translations are made into.",
                                           page: .llm)
        case .autoTranslate:
            return ChatSettingPresentation(labelKey: SettingLabels.autoTranslateKey,
                                           summary: "After transcription, translate segments that are not in the translation language into it.",
                                           page: .llm)
        case .useLedger:
            return ChatSettingPresentation(labelKey: LKey("Remember the fixes decided in the audit list and use them from next time"),
                                           summary: "Remember fixes decided in the audit list and use them in later audits.",
                                           page: .llm)
        case .reuseTranslationMemory:
            return ChatSettingPresentation(labelKey: LKey("Use remembered translations in the next translation"),
                                           summary: "Reuse translations the user edited before, instead of asking the LLM again.",
                                           page: .llm)
        case .useAdapter:
            return ChatSettingPresentation(labelKey: LKey("Use the adapters (the audit adapter for audit, the translation adapter for translation)"),
                                           summary: "Use the added fine-tuning adapters (LoRA) on top of the LLM.",
                                           page: .llm)
        // 結果の画面
        case .showBilingual:
            return ChatSettingPresentation(labelKey: LKey("Bilingual"),
                                           summary: "On the result screen, show the original and the translation side by side.",
                                           page: nil)
        case .showNotes:
            return ChatSettingPresentation(labelKey: LKey("Notes"),
                                           summary: "On the result screen, show the notes pane on the right.",
                                           page: nil)
        case .practiceDictation:
            return ChatSettingPresentation(labelKey: LKey("Show the dictation box"),
                                           summary: "Show the dictation box under the result, for listening practice.",
                                           page: nil)
        // チャットから変えない物 (メモの欄の幅は手で動かす物、練習の設定は JSON の組)
        case .notesWidth, .practice:
            return nil
        }
    }
}

/// 今、設定を変えられない理由 (設定の画面は部品を押せなくし、チャットの札は「変える」の代わりにこの文を出す)。
/// どの設定がいつ変えられないかは、アプリの `AppModel.unavailableReason(for:)` の 1 か所で決める
public enum SettingUnavailableReason: Sendable, Equatable {
    /// 先に、この設定を入にする必要が在る
    case needsOn(SettingKey)
    /// 差分 (LoRA) が 1 つも入っていない
    case noAdapter

    /// 画面に出す文 (今の画面の言語)。相手の設定の名前は、チャットの札と同じラベル
    public var message: String {
        switch self {
        case .needsOn(let other):
            let name = other.chatPresentation.map { L10n.lookup($0.labelKey) } ?? other.rawValue
            return L("Turn on “%@” first.", name)
        case .noAdapter:
            return L("No adapter is added. Add one in Settings first.")
        }
    }
}

/// 設定の画面とチャットの札が、同じ文を出すためのラベル (どちらも、ここを使う)
public enum SettingLabels {
    /// 訳さない語 「LLM」(設定の画面のピッカーと、チャットの札のラベル)
    public static let llm = "LLM"
    /// 訳さない語の一覧 (表を引かず、そのまま出す)
    public static let untranslated: Set<String> = [llm]
    /// 自動の翻訳のスイッチのラベルの鍵 (訳す先の名前が 2 つ入る)
    public static let autoTranslateKey = LKey("Translate segments that are not in %1$@ into %2$@")

    /// 自動の翻訳のスイッチのラベル (訳す先の言語の名前を入れた文)。設定の画面のスイッチも、チャットの札も、これを呼ぶ
    public static func autoTranslate(target: String) -> String {
        let name = TranslationTarget.displayName(for: target)
        return L("Translate segments that are not in %1$@ into %2$@", name, name)
    }
}

/// チャットから変える案を出せる設定の一覧
public enum ChatSettingsCatalog {
    /// チャットの窓の「リサーチ」のスイッチの名前。一覧には決して入れない
    /// (チャットの答えでインターネットへの扉を開けられないように。アプリの側も、この名前の提案は当てない)
    public static let researchKey = "chatResearch"

    /// 一覧に入れない名前 (チャットから決して変えない物): リサーチの鍵と、チャットに出さない設定
    public static let excludedKeys: Set<String> = Set(
        [researchKey] + SettingKey.allCases.filter { $0.chatPresentation == nil }.map(\.rawValue)
    )

    /// 語彙のヒントの長さの上限 (文字数)。決まりは設定の定義 (`SettingKey.initialPrompt` の `.text`) に在る
    public static let initialPromptMaxLength = SettingKey.initialPrompt.textRule?.maxLength ?? 0

    /// 一覧を作る。Whisper と LLM のモデルの一覧は、引数で変えられる (試験や、アプリが見せる物を絞る時)。
    /// 手元の GGUF (`file:…`) の LLM は、チャットからは選ばせない
    public static func items(whisperModels: [WhisperModelSpec] = ModelCatalog.all,
                             llmModels: [LLMModelSpec] = LLMCatalog.all) -> [ChatSettingItem] {
        let uiLanguages = UILanguage.allCases.map {
            ChatChoice(value: $0.rawValue, englishName: TranslationTarget.englishName(for: $0.rawValue), displayKey: $0.nativeName)
        }
        let spoken = Languages.all.map { ChatChoice(value: $0.code, englishName: $0.nameKey, displayKey: $0.nameKey) }
        let whisper = whisperModels.map {
            ChatChoice(value: $0.id, englishName: $0.displayNameKey, displayKey: $0.displayNameKey)
        }
        let llms = llmModels.filter { !$0.id.hasPrefix("file:") }.map {
            ChatChoice(value: $0.id, englishName: $0.displayNameKey, displayKey: $0.displayNameKey)
        }
        let targets = TranslationTarget.all.map { code in
            ChatChoice(value: code, englishName: TranslationTarget.englishName(for: code),
                       displayKey: Languages.all.first { $0.code == code }?.nameKey ?? code)
        }
        func choices(_ source: SettingChoices) -> [ChatChoice] {
            switch source {
            case .uiLanguages: return uiLanguages
            case .spokenLanguages: return spoken
            case .whisperModels: return whisper
            case .llmModels: return llms
            case .translationTargets: return targets
            }
        }
        // チャットで見せる種類 (数と JSON は、チャットでは扱わない)
        func chatKind(_ kind: SettingKind) -> ChatSettingKind? {
            switch kind {
            case .toggle: return .toggle
            case .choice(let source): return .choice(choices(source))
            // 文の設定 (今は語彙のヒントだけ)。決まりは、設定の画面の欄と同じ定義の物
            case .text(let rule): return .text(rule)
            case .number, .json: return nil
            }
        }

        let all: [ChatSettingItem] = SettingKey.allCases.compactMap { key in
            guard let presentation = key.chatPresentation, let kind = chatKind(key.definition.kind) else { return nil }
            return ChatSettingItem(key: key.rawValue, labelKey: presentation.labelKey, summary: presentation.summary,
                                   kind: kind, page: presentation.page)
        }
        return all.filter { !excludedKeys.contains($0.key) }
    }

    /// 確認用の起動の始めの値 (チャットの値の書き方。toggle は "on" / "off")。
    /// `--selftest-chat` が、利用者の設定を読まずに使う。定義の「確認用の起動で決まった値」か、既定の値
    public static func selfTestValues() -> [String: String] {
        var values: [String: String] = [:]
        for key in SettingKey.allCases where key.chatPresentation != nil {
            let definition = key.definition
            switch definition.selfTestValue ?? definition.defaultValue {
            case .bool(let value)?: values[key.rawValue] = value ? "on" : "off"
            case .string(let value)?: values[key.rawValue] = value
            case .double(let value)?: values[key.rawValue] = String(value)
            case nil: break
            }
        }
        return values
    }
}
