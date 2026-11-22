import Foundation

/// 設定 (UserDefaults) に書く、ただ 1 つの口。
/// アプリの中で設定に書く所は、全部これを通す (LaunchModeTests がソースを読んで確かめる)。
/// ふつうの起動の時だけ書く。確認用の起動・道具の起動では、何もしない
/// (確認が設定を変えて戻しても、決めていなかった項目に値が書かれてしまうため)。
/// ただ 1 つの例外は putBackAfterSelfTest で、確認用の起動の時だけ、macOS が書いた物を元に戻すために書く
public enum SettingsWriter {
    /// 値を保存する (nil なら消す)
    public static func set(_ value: Any?, forKey key: String) {
        set(value, forKey: key, mode: .current, defaults: .standard)
    }

    /// 設定 (SettingKey) の値を保存する。鍵の文字列は SettingKey から作る
    public static func set(_ value: Any?, for key: SettingKey) {
        set(value, forKey: key.rawValue)
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

    // MARK: 確認用の起動の、本物の設定の写し

    /// 確認用の起動の始め (ウインドウを作る前) に、本物の設定 (アプリの領域だけ。起動の引数の領域は含めない) の写しを取る。
    /// ふつうの起動・道具の起動では、何もしない
    public static func takeSnapshotForSelfTest() {
        guard let name = Bundle.main.bundleIdentifier else { return }
        takeSnapshotForSelfTest(mode: .current, defaults: .standard, domainName: name)
    }

    /// 確認用の起動の終わりに、写しと比べて変わった鍵を元に戻し、戻した鍵の名前を返す。
    /// 写しが無い時 (ふつうの起動・写しを取る前) は nil。
    ///
    /// `set` と向きが逆で、これは確認用の起動の時だけ書く。確認用の起動はアプリの設定を書かないが、
    /// macOS (AppKit・SwiftUI) は、ウインドウの位置や大きさ・左の一覧の幅などを、この口を通らずに本物の設定へ書く
    /// (確認の絵を撮る時の 1200 x 800 が、利用者のウインドウの大きさとして残っていた)。それを元に戻すために書く。
    /// 領域の全部を入れ替えず (setPersistentDomain を使わず)、変わった鍵だけを鍵ごとに戻す
    /// (同じ時に、利用者が別のアプリの写しで設定を変えていても、巻き戻す範囲を小さくするため)
    public static func putBackAfterSelfTest() -> [String]? {
        guard let name = Bundle.main.bundleIdentifier else { return nil }
        return putBackAfterSelfTest(mode: .current, defaults: .standard, domainName: name)
    }

    /// 取った写し (確認用の起動の時だけ入る)。別のスレッドの finish からも読むので、ロックで守る
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any]?
        func store(_ new: [String: Any]?) { lock.lock(); values = new; lock.unlock() }
        func load() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return values }
    }
    private static let snapshot = SnapshotBox()

    static func takeSnapshotForSelfTest(mode: LaunchMode, defaults: UserDefaults, domainName: String) {
        guard mode.isSelfTest else { return }
        snapshot.store(defaults.persistentDomain(forName: domainName) ?? [:])
    }

    static func putBackAfterSelfTest(mode: LaunchMode, defaults: UserDefaults, domainName: String) -> [String]? {
        guard mode.isSelfTest, let before = snapshot.load() else { return nil }
        let after = defaults.persistentDomain(forName: domainName) ?? [:]
        let changed = SettingsSnapshot.changedKeys(before: before, after: after)
        for key in changed {
            if let old = before[key] {
                defaults.set(old, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        // すぐに exit するので、ディスクへの書き出しを待つ
        if !changed.isEmpty { CFPreferencesAppSynchronize(domainName as CFString) }
        return changed
    }

    /// 試験用: 取った写しを捨てる
    static func clearSnapshotForTests() {
        snapshot.store(nil)
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
