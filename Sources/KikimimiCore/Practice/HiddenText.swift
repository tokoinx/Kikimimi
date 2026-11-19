import Foundation

/// 練習で、行の文字を隠すかどうかの決まり。
///
/// 隠すのは、訳す先の言語 (target。既定は日本語) でない行だけ (訳す先の言語の行は、いつも見える)。
/// 行の言語は、区間の言語があればそれ、なければ文字起こしの言語。
/// - `.source`: 訳す先の言語でない行の原文を隠す。
/// - `.sourceAndTranslation`: 訳す先の言語でない行の原文と、その行の訳の列も隠す。
/// 「この行を見る」で見せた行 (revealed) は、何も隠さない。
public enum HiddenText {
    /// 訳す先の言語の行か (言語の符号が target と同じ)
    public static func isInTarget(language: String?, target: String = "ja") -> Bool {
        language == target
    }

    /// この行は、いまの隠し方で隠す対象か (見せたかどうかによらない)。目のボタンを出すかに使う
    public static func canHide(_ hide: PracticeSettings.Hide, language: String?, target: String = "ja") -> Bool {
        hide != .nothing && !isInTarget(language: language, target: target)
    }

    /// 原文を隠すか
    public static func hidesSource(_ hide: PracticeSettings.Hide, language: String?, revealed: Bool,
                                   target: String = "ja") -> Bool {
        canHide(hide, language: language, target: target) && !revealed
    }

    /// 訳の列を隠すか
    public static func hidesTranslation(_ hide: PracticeSettings.Hide, language: String?, revealed: Bool,
                                        target: String = "ja") -> Bool {
        hide == .sourceAndTranslation && canHide(hide, language: language, target: target) && !revealed
    }

    /// 速さの名前 (「1.0×」「0.75×」)。小数のない速さも、小数点以下を 1 桁出す
    public static func rateLabel(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? String(format: "%.1f", rate) : String(format: "%g", rate)
        return text + "×"
    }
}
