import Foundation

/// この起動の種類。「確認用の起動かどうか」は、ここだけで決める
/// (ほかのファイルで `--selftest-` で始まるかを見ない。LaunchModeTests がソースを読んで確かめる)
public enum LaunchMode: Equatable, Sendable {
    /// ふつうの起動 (利用者が使う。設定を保存する)
    case app
    /// 確認用の起動: `--selftest-` で始まる引数が 1 つでも在る (利用者の本物の設定に書かない)
    case selfTest
    /// 窓を出さない道具の起動 (評価・書き出し・版の表示。KikimimiMain が見て、すぐに終わる)
    case tool

    /// 道具の起動の引数 (KikimimiMain が見ている物と同じ)
    public static let toolArguments: Set<String> = [
        "--eval-llm",
        "--export-translation-eval",
        "--export-translation-training",
        "--export-training",
        "--version"
    ]

    /// 引数から決める (確認用を先に見る。KikimimiMain も、確認用の引数を道具の引数より先に見る)
    public init(arguments: [String]) {
        if arguments.contains(where: { $0.hasPrefix("--selftest-") }) {
            self = .selfTest
        } else if arguments.contains(where: { Self.toolArguments.contains($0) }) {
            self = .tool
        } else {
            self = .app
        }
    }

    /// この起動の種類
    public static let current = LaunchMode(arguments: CommandLine.arguments)

    /// 確認用の起動か
    public var isSelfTest: Bool { self == .selfTest }

    /// 利用者の設定 (UserDefaults) に書いてよい起動か。ふつうの起動の時だけ
    public var writesSettings: Bool { self == .app }
}
