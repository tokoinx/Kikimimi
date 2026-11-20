import Foundation

/// 設定 (UserDefaults) を読む、ただ 1 つの口。書く口は SettingsWriter。
/// 既定の値・確認用の起動で決まった値・読む時の直しは、SettingKey の定義から来る。
/// アプリの中で設定を読む所は、全部これを通す (SettingsGuardTests がソースを読んで確かめる)。
/// 読むのは `UserDefaults.standard` のままなので、`-llmModelID qwen3.5-4b` のような起動の引数での上書きも効く
public struct SettingsReader {
    let defaults: UserDefaults
    let mode: LaunchMode

    /// 試験では、別の UserDefaults と起動の種類を渡す
    public init(defaults: UserDefaults = .standard, mode: LaunchMode = .current) {
        self.defaults = defaults
        self.mode = mode
    }

    /// 入り切りの設定。保存が無い時・型が違う時は既定の値
    public func bool(_ key: SettingKey) -> Bool {
        let definition = key.definition
        if mode.isSelfTest, case .bool(let fixed)? = definition.selfTestValue { return fixed }
        let fallback: Bool
        if case .bool(let value)? = definition.defaultValue { fallback = value } else { fallback = false }
        return defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    /// 文の設定 (選ぶ・文・JSON)。保存が無い時・読めない時は既定の値 (既定が無ければ nil)
    public func string(_ key: SettingKey) -> String? {
        let definition = key.definition
        if mode.isSelfTest, case .string(let fixed)? = definition.selfTestValue { return fixed }
        var fallback: String?
        if case .string(let value)? = definition.defaultValue { fallback = value }
        guard let saved = defaults.string(forKey: key.rawValue) else { return fallback }
        return key.fixStored(saved) ?? fallback
    }

    /// 保存してある文が、読む時の直しで変わったか (一覧に無い値など)。
    /// 確認用の起動で決まった値の物と、文で保存していない物は false
    public func savedStringIsFixed(_ key: SettingKey) -> Bool {
        if mode.isSelfTest, key.definition.selfTestValue != nil { return false }
        guard let saved = defaults.string(forKey: key.rawValue) else { return false }
        return key.fixStored(saved) != saved
    }

    /// 数の設定。保存が無い時・型が違う時は既定の値。範囲が在れば、その中に収める
    public func double(_ key: SettingKey) -> Double {
        let definition = key.definition
        if mode.isSelfTest, case .double(let fixed)? = definition.selfTestValue { return fixed }
        let fallback: Double
        if case .double(let value)? = definition.defaultValue { fallback = value } else { fallback = 0 }
        let value = defaults.object(forKey: key.rawValue) as? Double ?? fallback
        guard case .number(let range) = definition.kind else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
