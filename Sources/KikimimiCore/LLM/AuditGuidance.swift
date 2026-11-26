import Foundation

/// LLM が無い時に、監査が何を見直すかを言う文を選ぶ (ボタンの説明・青い帯・監査の後の知らせが、同じ決め方を使う)。
/// 学習した直しを使っている時 (usesLedger) は、それも当てるので、そう言う
public enum AuditGuidance {
    /// 「監査」ボタンの説明。LLM が在る時は、LLM で見直すと言う (学習した直しの有無で変わらない)
    public static func buttonHelp(llmInstalled: Bool, usesLedger: Bool) -> String {
        if llmInstalled {
            return L("Check for repetitions and mishearings with the LLM on your Mac")
        }
        return usesLedger
            ? L("Check for repetitions and apply learned corrections (to also check for other mishearings, download an LLM in Settings)")
            : L("Check for repetitions (to also check for mishearings, download an LLM in Settings)")
    }

    /// LLM が要る事を知らせる青い帯の見出し (翻訳を案内しない時)
    public static func bannerHeadline(usesLedger: Bool) -> String {
        usesLedger
            ? L("The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions and learned corrections are checked)")
            : L("The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions are checked)")
    }

    /// LLM が無いまま監査を終えた後の知らせ
    public static func noLLMNote(usesLedger: Bool) -> String {
        usesLedger
            ? L("No LLM has been downloaded, so only repetitions and learned corrections were checked. To also check for other mishearings, download an LLM in the “Audit & translation” tab of Settings.")
            : L("No LLM has been downloaded, so only repetitions were checked. To also check for mishearings, download an LLM in the “Audit & translation” tab of Settings.")
    }
}
