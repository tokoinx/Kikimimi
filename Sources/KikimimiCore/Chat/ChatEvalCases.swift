import Foundation

/// チャットの測りの問題 1 つ: 「この発言には、この提案が出るべき / 出ないべき」
public struct ChatEvalCase: Sendable, Equatable {
    public let id: String
    /// 利用者の発言 (日本語と英語。LLM に渡す文なので訳さない)
    public let utterance: String
    /// 出るべき提案 (鍵 → 値)。nil なら、提案が 1 つも出ないべき
    public let expected: [String: String]?

    public init(id: String, utterance: String, expected: [String: String]?) {
        self.id = id
        self.utterance = utterance
        self.expected = expected
    }
}

/// 測りの問題の一覧。発言は LLM に渡す物で、画面には出さない (このファイルは L10n の試験が日本語を見ない)
public enum ChatEvalCases {
    public static let all: [ChatEvalCase] = [
        // 日本語
        ChatEvalCase(id: "ja-vad-off", utterance: "無音を飛ばすのを切にして", expected: ["useVAD": "off"]),
        ChatEvalCase(id: "ja-target-ko", utterance: "翻訳先を韓国語にして", expected: ["translationLanguage": "ko"]),
        ChatEvalCase(id: "ja-ui-en", utterance: "画面の言語を英語に変えてください", expected: ["uiLanguage": "en"]),
        ChatEvalCase(id: "ja-notes-on", utterance: "メモの欄を出して", expected: ["showNotes": "on"]),
        ChatEvalCase(id: "ja-audit-off", utterance: "文字起こしの後の監査を自動でしないようにして", expected: ["autoAudit": "off"]),
        ChatEvalCase(id: "ja-what-vad", utterance: "VAD って何？", expected: nil),
        ChatEvalCase(id: "ja-hello", utterance: "こんにちは", expected: nil),
        ChatEvalCase(id: "ja-research", utterance: "リサーチをオンにして", expected: nil),
        // 英語
        ChatEvalCase(id: "en-notes-on", utterance: "Turn on the notes pane", expected: ["showNotes": "on"]),
        ChatEvalCase(id: "en-spoken-en", utterance: "Set the spoken language to English", expected: ["languageCode": "en"]),
        ChatEvalCase(id: "en-llm-9b", utterance: "Switch the LLM to the 9B model", expected: ["llmModelID": "qwen3.5-9b"]),
        ChatEvalCase(id: "en-preview-off", utterance: "Turn off the preview while recording", expected: ["livePreview": "off"]),
        ChatEvalCase(id: "en-autotranslate-off", utterance: "Stop translating automatically after transcription", expected: ["autoTranslate": "off"]),
        ChatEvalCase(id: "en-what-beam", utterance: "What does beam search do?", expected: nil),
        ChatEvalCase(id: "en-thanks", utterance: "Thanks!", expected: nil),
        ChatEvalCase(id: "en-download", utterance: "Download the large speech model for me", expected: nil),
    ]
}

/// 測りの採点
public enum ChatEval {
    /// 答えの提案が期待と同じなら true。期待が nil (か空) なら、提案が 0 の時だけ true
    public static func score(reply: String, expected: [String: String]?, catalog: [ChatSettingItem]) -> Bool {
        let result = ChatActionParser.parse(reply, catalog: catalog)
        var got: [String: String] = [:]
        for proposal in result.proposals { got[proposal.key] = proposal.value }
        guard let expected, !expected.isEmpty else { return got.isEmpty }
        return got == expected
    }
}
