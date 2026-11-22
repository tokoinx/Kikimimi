import Foundation

/// 確認用の起動の始めに取る、本物の設定 (アプリの領域) の写しと、終わりに比べる手順。
/// 確認用の起動は、アプリの設定を書かない (SettingsWriter.set が止める)。けれども、macOS (AppKit・SwiftUI) は
/// ウインドウの位置や左の一覧の幅を、この道を通らずに本物の設定へ書く。そこで、始めに写しを取り、
/// 終わる時に、変わった鍵だけを元に戻す (戻すのは SettingsWriter.putBackAfterSelfTest)。
/// ここには、比べる所と、出力の行を作る所 (どちらも純粋な関数) を置く
public enum SettingsSnapshot {
    /// 2 つの値が同じか。設定の値は、文字列・数・真偽・日付・データ・配列・辞書なので、NSObject の isEqual で比べる
    /// (配列・辞書は、中身まで比べる)
    public static func same(_ a: Any, _ b: Any) -> Bool {
        guard let x = a as? NSObject, let y = b as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// 写し (before) と今 (after) で、変わった鍵・増えた鍵・消えた鍵を、名前の順で返す
    public static func changedKeys(before: [String: Any], after: [String: Any]) -> [String] {
        var keys = Set<String>()
        for (key, value) in after {
            if let old = before[key] {
                if !same(old, value) { keys.insert(key) }
            } else {
                keys.insert(key)
            }
        }
        for key in before.keys where after[key] == nil {
            keys.insert(key)
        }
        return keys.sorted()
    }

    /// 出力に出す時、鍵の名前 1 つの長さの上限
    public static let nameLimit = 80
    /// 出力に出す時、名前を並べる数の上限 (残りは「and N more」)
    public static let listLimit = 6

    /// 戻した鍵の一覧から、出力の行を作る (英語。画面の文ではないので L は通さない)。
    /// アプリの設定の鍵 (SettingKey の名前) は、別の行で大きく知らせる
    /// (確認用の起動がアプリの設定を書かない、という決まりが破れた印)
    public static func reportLines(restored: [String],
                                   appKeys: Set<String> = Set(SettingKey.allCases.map(\.rawValue))) -> [String] {
        guard !restored.isEmpty else { return ["REAL SETTINGS: unchanged"] }
        let system = restored.filter { !appKeys.contains($0) }
        let app = restored.filter { appKeys.contains($0) }
        var lines: [String] = []
        if !system.isEmpty {
            let noun = system.count == 1 ? "key" : "keys"
            lines.append("REAL SETTINGS: put back \(system.count) \(noun) the system wrote during the self-test: "
                         + list(system))
        }
        if !app.isEmpty {
            lines.append("REAL SETTINGS: APP SETTINGS CHANGED DURING THE SELF-TEST (put back): " + list(app))
        }
        return lines
    }

    /// 名前を「, 」でつなぐ。長い名前は切り、多い時は初めの数個と「and N more」
    static func list(_ names: [String]) -> String {
        let shown = names.prefix(listLimit).map { name -> String in
            name.count > nameLimit ? String(name.prefix(nameLimit)) + "..." : name
        }
        var text = shown.joined(separator: ", ")
        if names.count > listLimit { text += ", and \(names.count - listLimit) more" }
        return text
    }

    /// 出力の行に、設定の行を入れる。最後の行が合格の行 (okLine) なら、その前に入れる
    /// (合格の行は、いつも最後の行にしておく)。そうでなければ、終わりに足す
    public static func insert(_ report: [String], into lines: [String], before okLine: String) -> [String] {
        guard !report.isEmpty else { return lines }
        if lines.last == okLine {
            return Array(lines.dropLast()) + report + [okLine]
        }
        return lines + report
    }
}
