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
    /// 自由な文 (長さの上限つき。制御文字は入れられない)
    case text(maxLength: Int)
}

/// チャットから変える案を出せる設定 1 つ
public struct ChatSettingItem: Sendable, Equatable {
    /// UserDefaults の名前 (AppModel の設定の名前と同じ)
    public let key: String
    /// 画面のラベルの鍵 (設定の画面と同じ英語の鍵。`label` で今の言語の文になる)
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

    /// 画面に出すラベル (今の画面の言語)
    public var label: String { L10n.lookup(labelKey) }

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
        case .text(let maxLength):
            guard value.count <= maxLength else { return nil }
            guard !value.unicodeScalars.contains(where: { Self.isControl($0) }) else { return nil }
            return value
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

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // C0・DEL・C1 と、文の向きを変える印 (見た目をごまかせる)
        return v < 0x20 || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }
}

/// チャットから変える案を出せる設定の一覧
public enum ChatSettingsCatalog {
    /// チャットの窓の「リサーチ」のスイッチの名前。一覧には決して入れない
    /// (チャットの答えでインターネットへの扉を開けられないように。アプリの側も、この名前の提案は当てない)
    public static let researchKey = "chatResearch"

    /// 一覧に入れない名前 (チャットから決して変えない物)
    public static let excludedKeys: Set<String> = [researchKey, "notesWidth", "practice"]

    /// 語彙のヒントの長さの上限 (文字数)
    public static let initialPromptMaxLength = 400

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

        let all: [ChatSettingItem] = [
            // 一般
            ChatSettingItem(key: "uiLanguage", labelKey: LKey("Display language"),
                            summary: "Language of the app's menus and windows.",
                            kind: .choice(uiLanguages), page: .general),
            // 文字起こし
            ChatSettingItem(key: "languageCode", labelKey: LKey("Spoken language"),
                            summary: "Language spoken in recordings. auto = detect it; ja+en = recordings that switch between Japanese and English (2-4 times slower).",
                            kind: .choice(spoken), page: .transcription),
            ChatSettingItem(key: "modelID", labelKey: LKey("Transcription model"),
                            summary: "Whisper speech recognition model. Larger is more accurate but slower. It must be downloaded in Settings.",
                            kind: .choice(whisper), page: .transcription),
            ChatSettingItem(key: "preferAccuracy", labelKey: LKey("Prefer accuracy (beam search)"),
                            summary: "Beam search: a little more accurate, but slower.",
                            kind: .toggle, page: .transcription),
            ChatSettingItem(key: "useVAD", labelKey: LKey("Skip silence (VAD)"),
                            summary: "Skip silent parts (VAD). Faster and fewer made-up lines; singing may be skipped.",
                            kind: .toggle, page: .transcription),
            ChatSettingItem(key: "autoVADOff",
                            labelKey: LKey("When there is continuous sound but very little text, transcribe again without skipping silence"),
                            summary: "If a recording has continuous sound but very little text, transcribe it again without skipping silence.",
                            kind: .toggle, page: .transcription),
            ChatSettingItem(key: "filterHallucinations", labelKey: LKey("Remove common misrecognitions and repeated sentences"),
                            summary: "Remove common made-up lines and repeated sentences from transcriptions.",
                            kind: .toggle, page: .transcription),
            ChatSettingItem(key: "autoMixedLanguage",
                            labelKey: LKey("Automatically transcribe recordings that mix Japanese and English as “Japanese + English”"),
                            summary: "Detect recordings that mix Japanese and English and transcribe them as ja+en. Needs useVAD on.",
                            kind: .toggle, page: .transcription),
            ChatSettingItem(key: "livePreview", labelKey: LKey("Show a preview while recording"),
                            summary: "Show the text while recording.",
                            kind: .toggle, page: .transcription),
            ChatSettingItem(key: "initialPrompt", labelKey: LKey("Vocabulary hints"),
                            summary: "Vocabulary hints: proper nouns and technical terms, so they come out with this spelling. Plain text, one line.",
                            kind: .text(maxLength: initialPromptMaxLength), page: .transcription),
            // 監査・翻訳
            ChatSettingItem(key: "llmModelID", labelKey: LKey("LLM model"),
                            summary: "Local LLM used for audit, translation, and this chat. Larger is smarter but slower. It must be downloaded in Settings.",
                            kind: .choice(llms), page: .llm),
            ChatSettingItem(key: "autoAudit", labelKey: LKey("Audit after transcription (check for repetitions and mishearings)"),
                            summary: "After transcription, the LLM checks for repetitions and mishearings.",
                            kind: .toggle, page: .llm),
            ChatSettingItem(key: "translationLanguage", labelKey: LKey("Translate into"),
                            summary: "Language that translations are made into.",
                            kind: .choice(targets), page: .llm),
            ChatSettingItem(key: "autoTranslate", labelKey: LKey("Translate other languages automatically"),
                            summary: "After transcription, translate segments that are not in the translation language into it.",
                            kind: .toggle, page: .llm),
            ChatSettingItem(key: "useLedger", labelKey: LKey("Remember the fixes decided in the audit list and use them from next time"),
                            summary: "Remember fixes decided in the audit list and use them in later audits.",
                            kind: .toggle, page: .llm),
            ChatSettingItem(key: "reuseTranslationMemory", labelKey: LKey("Use remembered translations in the next translation"),
                            summary: "Reuse translations the user edited before, instead of asking the LLM again.",
                            kind: .toggle, page: .llm),
            ChatSettingItem(key: "useAdapter",
                            labelKey: LKey("Use the adapters (the audit adapter for audit, the translation adapter for translation)"),
                            summary: "Use the added fine-tuning adapters (LoRA) on top of the LLM.",
                            kind: .toggle, page: .llm),
            // 結果の画面
            ChatSettingItem(key: "showBilingual", labelKey: LKey("Bilingual"),
                            summary: "On the result screen, show the original and the translation side by side.",
                            kind: .toggle, page: nil),
            ChatSettingItem(key: "showNotes", labelKey: LKey("Notes"),
                            summary: "On the result screen, show the notes pane on the right.",
                            kind: .toggle, page: nil),
            ChatSettingItem(key: "practiceDictation", labelKey: LKey("Show the dictation box"),
                            summary: "Show the dictation box under the result, for listening practice.",
                            kind: .toggle, page: nil),
        ]
        return all.filter { !excludedKeys.contains($0.key) }
    }
}
