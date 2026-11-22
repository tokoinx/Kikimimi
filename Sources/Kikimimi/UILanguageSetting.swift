// 画面の言語を、起動の一番初めに決める所。

import Foundation
import KikimimiCore

/// 画面の言語を、起動の一番初め (画面や文を作る前) に決める
enum UILanguageSetting {
    // 保存の鍵は SettingKey.uiLanguage

    struct Startup: Equatable, Sendable {
        let language: UILanguage
        /// 設定を読み書きする起動か (確認用の起動と、`--ui-language` で言語を決めた起動は、読まず・書かない)
        let persists: Bool
    }

    /// この起動の言語 (KikimimiMain が初めに L10n.language に入れる。AppModel も同じ値で始める)
    static let startup = resolve(arguments: CommandLine.arguments, defaults: .standard,
                                 preferredLanguages: Locale.preferredLanguages)

    /// - `--ui-language <コード>` が在れば、その言語 (保存しない。画面を見比べるため)。
    /// - 確認用の起動 (`--selftest-…`) は、設定の定義の確認用の値の言語 (今は日本語。絵の説明が日本語の画面を前提にしているため。設定を読まず・書かない)。
    /// - ほかは、保存した言語。無ければ、macOS の言語が 13 の中に在ればそれ、無ければ英語
    static func resolve(arguments: [String], defaults: UserDefaults, preferredLanguages: [String]) -> Startup {
        let mode = LaunchMode(arguments: arguments)
        let selfTest = mode.isSelfTest
        if let i = arguments.firstIndex(of: "--ui-language") {
            let code = i + 1 < arguments.count ? arguments[i + 1] : ""
            if let language = UILanguage(rawValue: code) {
                return Startup(language: language, persists: false)
            }
            LaunchLog.note("unknown --ui-language \"\(code)\"; ignored")
        }
        if selfTest {
            // 言語は、設定の定義の確認用の値 (SettingKey.uiLanguage)。読めない時 (試験が落とす) は、macOS の言語から決める
            return Startup(language: UILanguage.selfTest ?? UILanguage.initial(preferredLanguages: preferredLanguages), persists: false)
        }
        // 読む口は、一覧に無い言語を nil にする (この後で macOS の言語から決める)
        if let saved = SettingsReader(defaults: defaults, mode: mode).string(.uiLanguage).flatMap(UILanguage.init(rawValue:)) {
            return Startup(language: saved, persists: true)
        }
        return Startup(language: UILanguage.initial(preferredLanguages: preferredLanguages), persists: true)
    }
}
