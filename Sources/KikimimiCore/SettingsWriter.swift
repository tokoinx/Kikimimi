import Foundation

/// 設定 (UserDefaults) に書く、ただ 1 つの口。
/// アプリの中で設定に書く所は、全部これを通す (LaunchModeTests がソースを読んで確かめる)。
/// ふつうの起動の時だけ書く。確認用の起動・道具の起動では、何もしない
/// (確認が設定を変えて戻しても、決めていなかった項目に値が書かれてしまうため)
public enum SettingsWriter {
    /// 値を保存する (nil なら消す)
    public static func set(_ value: Any?, forKey key: String) {
        set(value, forKey: key, mode: .current, defaults: .standard)
    }

    /// 値を消す
    public static func remove(forKey key: String) {
        remove(forKey: key, mode: .current, defaults: .standard)
    }

    /// この起動のあいだだけ効く値を置く (保存しない。どの起動でも置く)。
    /// 引数の領域 (`-鍵 値` と同じ所) に足すので、保存してある値より先に読まれ、終われば消える
    public static func setForThisLaunch(_ values: [String: Any]) {
        setForThisLaunch(values, defaults: .standard)
    }

    // 試験のために、起動の種類と書く先を受ける形

    static func set(_ value: Any?, forKey key: String, mode: LaunchMode, defaults: UserDefaults) {
        guard mode.writesSettings else { return }
        defaults.set(value, forKey: key)
    }

    static func remove(forKey key: String, mode: LaunchMode, defaults: UserDefaults) {
        guard mode.writesSettings else { return }
        defaults.removeObject(forKey: key)
    }

    static func setForThisLaunch(_ values: [String: Any], defaults: UserDefaults) {
        let name = UserDefaults.argumentDomain
        var domain = defaults.volatileDomain(forName: name)
        for (key, value) in values { domain[key] = value }
        // 同じ名前の領域が在る時は、置き換える前に外す (起動の引数は、上で写して残してある)
        defaults.removeVolatileDomain(forName: name)
        defaults.setVolatileDomain(domain, forName: name)
    }
}
