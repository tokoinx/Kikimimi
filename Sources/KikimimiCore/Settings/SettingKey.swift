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
    /// 自由な文 (文字列で保存)。決まり (長さの上限・制御文字) は、設定の画面の欄とチャットの両方が使う
    case text(SettingTextRule)
    /// 数 (Double で保存。読む時に範囲に収める)
    case number(ClosedRange<Double>)
    /// JSON の文 (文字列で保存。中身は使う側が読む)
    case json
}

extension SettingKind {
    /// 文の設定の決まり。文の設定でなければ nil
    public var textRule: SettingTextRule? {
        if case .text(let rule) = self { return rule }
        return nil
    }
}

/// 文の設定の決まり (長さの上限と、制御文字を入れない事)。
/// 設定の画面の欄 (`fieldValue(new:old:)`) とチャットの案 (`accepts(_:)`) の両方が、ここを使う。
/// 長さは `String.count` (見た目の 1 文字を 1 と数える) で数える
public struct SettingTextRule: Sendable, Equatable {
    /// 長さの上限 (文字数)
    public let maxLength: Int

    public init(maxLength: Int) {
        self.maxLength = maxLength
    }

    /// 入れられない文字か (C0・DEL・C1 と、文の向きを変える印。向きの印は、見た目をごまかせるため)
    public static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    /// チャットの案: 決まりに合うか (上限を超える文や、制御文字の在る文は断る)
    public func accepts(_ value: String) -> Bool {
        value.count <= maxLength && !value.unicodeScalars.contains(where: { Self.isControl($0) })
    }

    /// 設定の欄: 打った後の文 `new` と打つ前の文 `old` から、残す文を返す。
    /// - 制御文字は、空白 1 つに替える (貼り付けた改行やタブで、語がくっつかないように)。
    /// - 上限を超えていて、`old` より長くなる入力は受け付けない (`old` を返す)。
    /// - 上限を超えていても、`old` より短くなる編集は受ける (前から保存してある長い値を、勝手に切らない。短くはできる)
    public func fieldValue(new: String, old: String) -> String {
        var cleaned = new
        if new.unicodeScalars.contains(where: { Self.isControl($0) }) {
            var scalars = String.UnicodeScalarView()
            for scalar in new.unicodeScalars {
                scalars.append(Self.isControl(scalar) ? " " : scalar)
            }
            cleaned = String(scalars)
        }
        if cleaned.count > maxLength && cleaned.count > old.count { return old }
        return cleaned
    }
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
            // 語彙のヒント: 400 字まで。制御文字は入れない (設定の画面の欄も、チャットの案も、この決まりを使う)
            return SettingDefinition(kind: .text(SettingTextRule(maxLength: 400)), defaultValue: .string(""))
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

    /// 文の設定の決まり。文の設定でなければ nil
    public var textRule: SettingTextRule? { definition.kind.textRule }

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

extension UILanguage {
    /// 確認用の起動 (--selftest-…) の画面の言語。設定の定義 (`SettingKey.uiLanguage` の確認用の値) から読む口は、ここの 1 つ。
    /// 定義の値が 13 の言語のどれでもなければ nil (`ChatSettingsLabelGuardTests.testSelfTestUILanguageComesFromTheDefinition` が落とす)
    public static var selfTest: UILanguage? {
        guard case .string(let code)? = SettingKey.uiLanguage.definition.selfTestValue else { return nil }
        return UILanguage(rawValue: code)
    }
}
