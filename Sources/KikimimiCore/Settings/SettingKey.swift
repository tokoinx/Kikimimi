import Foundation

/// 設定 (UserDefaults に保存する物) の名前。case の名前が、そのまま保存の鍵の文字列になる。
/// 設定の鍵の文字列を書いてよいのは、このファイルだけ (SettingsGuardTests がソースを読んで確かめる)。
/// 並びは、チャットの一覧の並び (チャットに出さない物も、近い所に置く)。
/// `@frozen` は、アプリの側の `switch` に `@unknown default` を要らなくするため
/// (KikimimiCore は library evolution で作るので、付けないと網羅の検査が効かない)
@frozen public enum SettingKey: String, CaseIterable, Sendable {
    // 一般
    case uiLanguage
    // 文字起こし
    case languageCode
    case modelID
    case preferAccuracy
    case useVAD
    case autoVADOff
    case filterHallucinations
    case autoMixedLanguage
    case livePreview
    case initialPrompt
    // 監査・翻訳
    case llmModelID
    case autoAudit
    case translationLanguage
    case autoTranslate
    case useLedger
    case reuseTranslationMemory
    case useAdapter
    // 結果の画面
    case showBilingual
    case showNotes
    case notesWidth
    case practice
    case practiceDictation
}

/// 選ぶ設定の、選択肢の出所
public enum SettingChoices: Sendable, Equatable, CaseIterable {
    /// 画面の言語 (`UILanguage.allCases`)
    case uiLanguages
    /// 話す言語 (`Languages.all`)
    case spokenLanguages
    /// 文字起こしのモデル (`ModelCatalog.all`)
    case whisperModels
    /// LLM (`LLMCatalog.all`)
    case llmModels
    /// 訳す先の言語 (`TranslationTarget.all`)
    case translationTargets

    /// 選べる値のコード (保存する値と同じ)
    public var values: [String] {
        switch self {
        case .uiLanguages: return UILanguage.allCases.map(\.rawValue)
        case .spokenLanguages: return Languages.all.map(\.code)
        case .whisperModels: return ModelCatalog.all.map(\.id)
        case .llmModels: return LLMCatalog.all.map(\.id)
        case .translationTargets: return TranslationTarget.all
        }
    }
}

/// 設定の種類 (保存する値の型も、これで決まる)
public enum SettingKind: Sendable, Equatable {
    /// 入り切り (Bool で保存)
    case toggle
    /// 決まった値から 1 つ (文字列で保存)
    case choice(SettingChoices)
    /// 自由な文 (文字列で保存)
    case text
    /// 数 (Double で保存。読む時に範囲に収める)
    case number(ClosedRange<Double>)
    /// JSON の文 (文字列で保存。中身は使う側が読む)
    case json
}

/// 設定の値 1 つ (既定の値・確認用の起動で決まった値に使う)
public enum SettingValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case double(Double)
}

/// 設定 1 つの定義
public struct SettingDefinition: Sendable, Equatable {
    public let kind: SettingKind
    /// 保存が無い時 (や、読めない時) の値。nil は「保存が無い間は決めない」
    /// (uiLanguage は macOS の言語から、translationLanguage は画面の言語から決まる。practice は PracticeSettings の既定)
    public let defaultValue: SettingValue?
    /// 確認用の起動 (--selftest-…) で、保存を読まずに決める値。nil なら、ふつうに読む
    public let selfTestValue: SettingValue?

    public init(kind: SettingKind, defaultValue: SettingValue?, selfTestValue: SettingValue? = nil) {
        self.kind = kind
        self.defaultValue = defaultValue
        self.selfTestValue = selfTestValue
    }

    /// メモの欄の幅の範囲 (pt)
    public static let notesWidthRange: ClosedRange<Double> = 220...520
}

extension SettingKey {
    /// この設定の定義。設定を足したら、ここに足す (足し忘れは、コンパイルが止める)
    public var definition: SettingDefinition {
        switch self {
        case .uiLanguage:
            // 確認用の起動は日本語 (絵の説明が日本語の画面を前提にしているため)
            return SettingDefinition(kind: .choice(.uiLanguages), defaultValue: nil, selfTestValue: .string("ja"))
        case .languageCode:
            return SettingDefinition(kind: .choice(.spokenLanguages), defaultValue: .string("ja"))
        case .modelID:
            return SettingDefinition(kind: .choice(.whisperModels), defaultValue: .string(ModelCatalog.defaultModelID))
        case .preferAccuracy:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .useVAD:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .autoVADOff:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .filterHallucinations:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .autoMixedLanguage:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .livePreview:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .initialPrompt:
            return SettingDefinition(kind: .text, defaultValue: .string(""))
        case .llmModelID:
            return SettingDefinition(kind: .choice(.llmModels), defaultValue: .string(LLMCatalog.defaultModelID))
        case .autoAudit:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .translationLanguage:
            // 確認用の起動は日本語 (絵と確認が、日本語へ訳す前提のため)
            return SettingDefinition(kind: .choice(.translationTargets), defaultValue: nil, selfTestValue: .string("ja"))
        case .autoTranslate:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .useLedger:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .reuseTranslationMemory:
            // 確認用の起動は入 (記憶は一時のファイルにするので、本物の記憶は使わない)
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true), selfTestValue: .bool(true))
        case .useAdapter:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .showBilingual:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(true))
        case .showNotes:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(false))
        case .notesWidth:
            return SettingDefinition(kind: .number(SettingDefinition.notesWidthRange), defaultValue: .double(320))
        case .practice:
            return SettingDefinition(kind: .json, defaultValue: nil)
        case .practiceDictation:
            return SettingDefinition(kind: .toggle, defaultValue: .bool(false))
        }
    }

    /// 保存してあった文を、読む時に直す。nil を返すと、既定の値になる
    func fixStored(_ raw: String) -> String? {
        switch self {
        case .uiLanguage: return UILanguage(rawValue: raw) == nil ? nil : raw
        case .languageCode: return Languages.isKnown(raw) ? raw : nil
        case .modelID: return ModelCatalog.spec(id: raw) == nil ? nil : raw
        // LLM は直さない (`file:` で始まる手元の GGUF が在るので、アプリの refreshLLMInstalled() が受け持つ)
        case .llmModelID: return raw
        case .translationLanguage: return TranslationTarget.normalized(raw)
        case .initialPrompt, .practice: return raw
        case .preferAccuracy, .useVAD, .autoVADOff, .filterHallucinations, .autoMixedLanguage, .livePreview,
             .autoAudit, .autoTranslate, .useLedger, .reuseTranslationMemory, .useAdapter,
             .showBilingual, .showNotes, .notesWidth, .practiceDictation:
            return raw
        }
    }
}
