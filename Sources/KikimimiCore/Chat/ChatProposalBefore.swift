import Foundation

/// チャットの札の「前の値」の決め方 (画面に頼らない所)
public enum ChatProposalBefore {
    /// 対訳 (`showBilingual`) の札の「前の値」。
    /// - setting: 対訳の設定そのものの値
    /// - shownForResult: 選んでいる結果での見え方 (設定が入、または行の「訳」の印)。結果を選んでいなければ nil
    /// - requested: 頼まれた値 (入なら true)
    ///
    /// 「入」を頼まれた時は、設定そのものの値を前の値にする (設定が切なら、行の「訳」の印で見えていても「切 → 入」の札になり、押すと設定が入になる)。
    /// 「切」を頼まれた時は、画面の見え方を前の値にする (見えているなら「入 → 切」の札になり、押すと結果の印も消える)。
    /// 結果を選んでいなければ、設定の値
    public static func bilingual(setting: Bool, shownForResult: Bool?, requested: Bool) -> Bool {
        if requested { return setting }
        return shownForResult ?? setting
    }
}
