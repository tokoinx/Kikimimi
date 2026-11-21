/// 画面の重さの確認 (--selftest-ui-load) の終了コードの表。終了コードの数と、決め方は、ここだけに書く
/// (手順書 .claude/skills/kikimimi-verify/SKILL.md の表と合わない時は、UILoadExitTests が落ちる)
public enum UILoadExit: Int32, CaseIterable, Sendable {
    /// 成功
    case ok = 0
    /// メインのウインドウが出ない
    case noWindow = 1
    /// 終わらない (メインスレッドが止まった)
    case hang = 3
    /// 重い (UI LOAD: SLOW)
    case slow = 5
    /// 1 行だけの再生が行の終わりで止まらない・続きから再生しない
    case line = 6
    /// 保存の確認に失敗 (差分のお知らせの確認も、ここに入る)
    case library = 7
    /// 練習の確認に失敗
    case practice = 8
    /// チャットの確認に失敗
    case chat = 9

    /// 複数が失敗した時に返す順 (前に在る物が先)
    public static let precedence: [UILoadExit] = [.slow, .line, .library, .practice, .chat]

    /// 失敗した確認の集まりから、返す 1 つを決める。何も失敗していなければ .ok
    public static func decide(failed: Set<UILoadExit>) -> UILoadExit {
        precedence.first { failed.contains($0) } ?? .ok
    }
}
