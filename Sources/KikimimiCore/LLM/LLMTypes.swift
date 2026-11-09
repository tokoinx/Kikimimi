import Foundation

/// ローカル LLM への 1 回分の依頼。
public struct LLMPrompt: Sendable, Hashable {
    /// 役割や決まりごと (system)
    public var system: String
    /// 依頼の本文 (user)
    public var user: String
    /// 出力の形を縛る GBNF 文法 (llama.cpp の書式)。nil なら縛らない
    public var grammar: String?
    /// 出力の上限 (トークン数)
    public var maxTokens: Int
    /// 出力の 1 行の長さの上限 (UTF-8 のバイト数)。超えたらそこで打ち切る (同じ語を延々と繰り返す暴走の歯止め)
    public var maxLineBytes: Int?
    /// 手本のやりとり (依頼と答えの例)。本番の依頼の前に、会話の一部として見せる
    public var examples: [LLMExample]
    /// 日本語に出てこない文字 (簡体字など) を出させない (翻訳が中国語に流れるのを防ぐ)
    public var japaneseOnly: Bool

    public init(system: String, user: String, grammar: String? = nil, maxTokens: Int = 512, maxLineBytes: Int? = nil,
                examples: [LLMExample] = [], japaneseOnly: Bool = false) {
        self.system = system
        self.user = user
        self.grammar = grammar
        self.maxTokens = maxTokens
        self.maxLineBytes = maxLineBytes
        self.examples = examples
        self.japaneseOnly = japaneseOnly
    }
}

/// 手本のやりとり 1 回分
public struct LLMExample: Sendable, Hashable {
    public var user: String
    public var assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

/// 改行で終わった (書き切った) 行だけを取り出す。打ち切られた最後の行は使わない
public func completeLines(of output: String) -> [Substring] {
    // "\r\n" は Swift では 1 文字として扱われ "\n" で分けられないので、先にそろえる
    let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    lines.removeLast() // 最後の改行の後ろ (書き切っていない行、または空)
    return lines
}

/// 文章を生成できるもの。本番は llama.cpp (KikimimiLLM)、テストでは決まった答えを返す偽物を使う。
///
/// 呼び出しはブロッキング。同時に 1 本だけ呼ぶこと。
public protocol TextGenerating: AnyObject {
    /// 1 回に扱える長さ (プロンプトと出力の合計トークン数)
    var contextLength: Int { get }
    /// 文章のトークン数
    func tokenCount(_ text: String) -> Int
    /// 依頼に答える。shouldCancel が true を返したら `LLMError.cancelled` を投げる
    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String
}

public enum LLMError: LocalizedError, Equatable, Sendable {
    case modelLoadFailed(String)
    case contextFailed
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int32)
    case invalidGrammar
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "LLM のモデルを読み込めませんでした: \((path as NSString).lastPathComponent)。ファイルが壊れているか、このアプリの llama.cpp がまだ対応していない形式です。設定から削除して取り直してください。"
        case .contextFailed:
            return "LLM の作業領域を用意できませんでした。メモリが足りない可能性があります。ほかのアプリを閉じるか、軽いモデルを選んでください。"
        case .promptTooLong(let tokens, let limit):
            return "LLM に渡す文が長すぎます (\(tokens) / \(limit) トークン)。"
        case .decodeFailed(let code):
            return "LLM の計算に失敗しました (llama.cpp エラー \(code))。"
        case .invalidGrammar:
            return "LLM の出力の形式 (文法) を準備できませんでした。"
        case .cancelled:
            return "中止しました。"
        }
    }
}
