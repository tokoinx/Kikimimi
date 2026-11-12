import Foundation

/// 練習で、行の文字を隠すかどうかの決まり。
///
/// 隠すのは日本語でない行だけ (日本語の行は、いつも見える)。行の言語は、区間の言語があればそれ、なければ文字起こしの言語。
/// - `.source`: 日本語でない行の原文を隠す。
/// - `.sourceAndTranslation`: 日本語でない行の原文と、その行の日本語訳の列も隠す。
/// 「この行を見る」で見せた行 (revealed) は、何も隠さない。
public enum HiddenText {
    /// 日本語の行か (言語の符号が "ja")
    public static func isJapanese(language: String?) -> Bool {
        language == "ja"
    }

    /// この行は、いまの隠し方で隠す対象か (見せたかどうかによらない)。目のボタンを出すかに使う
    public static func canHide(_ hide: PracticeSettings.Hide, language: String?) -> Bool {
        hide != .nothing && !isJapanese(language: language)
    }

    /// 原文を隠すか
    public static func hidesSource(_ hide: PracticeSettings.Hide, language: String?, revealed: Bool) -> Bool {
        canHide(hide, language: language) && !revealed
    }

    /// 日本語訳の列を隠すか
    public static func hidesTranslation(_ hide: PracticeSettings.Hide, language: String?, revealed: Bool) -> Bool {
        hide == .sourceAndTranslation && canHide(hide, language: language) && !revealed
    }

    /// 速さの名前 (「1.0×」「0.75×」)。小数のない速さも、小数点以下を 1 桁出す
    public static func rateLabel(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? String(format: "%.1f", rate) : String(format: "%g", rate)
        return text + "×"
    }
}
