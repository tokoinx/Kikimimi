// 一覧の終わりへ小刻みに追いつく (TailCatchUp) のを使うかの切り替え。
// ふだんは macOS 15 以降だけ (macOS 14 では、終わりへ 1 回で飛んでも軽い)。
// 画面の重さの確認の最中だけ、環境変数 KIKIMIMI_TAIL_STEPS ("1" で使う、"0" で使わない) で変えられる
// (この Mac (macOS 14) で小刻みの道を通すため)。ふだんの起動では、環境変数を読まない。

import Foundation
import KikimimiCore

@MainActor
enum TailFollowSwitch {
    /// 環境変数の名前
    static let variable = "KIKIMIMI_TAIL_STEPS"

    /// この Mac が macOS 15 以降か
    static var osAtLeast15: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    /// 確認の最中に渡された環境変数の値 (ふだんの起動と、渡されていない時は nil)
    static var override: String? {
        UILoadHooks.isActive ? ProcessInfo.processInfo.environment[variable] : nil
    }

    /// 小刻みに追いつくのを使うか
    static var enabled: Bool {
        TailCatchUp.isEnabled(osAtLeast15: osAtLeast15, override: override)
    }
}
