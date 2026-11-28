import Foundation

/// チャットの窓の段階
/// (`@frozen`: このパッケージはいつも全体を一緒に作り直すので、case を足した時は、使う側の switch がコンパイルで止まるほうがよい)
@frozen public enum ChatPhase: Equatable, Sendable {
    /// 待っていない
    case idle
    /// リサーチで Web ページを読んでいる
    case readingPages
    /// LLM を待っている (モデルの読み込みか、監査・翻訳が先に使っている)
    case waitingForLLM
    /// 答えを出している
    case answering
}

/// チャットが LLM を使っている間の、監査・翻訳の進み具合の文
public enum ChatPause {
    /// 進み具合の文を「チャットが答えている間、止めています」に替えるか。
    /// LLM は同時に 1 つなので、チャットが答えている間 (`.answering`) は、後の仕事 (監査・翻訳。どれも LLM を使う) は待っている。
    /// 替えるのは、その結果の後の仕事が進んでいる途中 (`postTaskRunning`) の時だけ。
    /// チャットが LLM を待っているだけ・ページを読んでいる間は、後の仕事が LLM を使っているので、替えない
    public static func replacesProgress(chatPhase: ChatPhase, postTaskRunning: Bool) -> Bool {
        postTaskRunning && chatPhase == .answering
    }
}
