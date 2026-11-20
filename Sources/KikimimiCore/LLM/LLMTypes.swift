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
    /// 依頼に答え、出している途中の文を少しずつ渡す。onText には、毎回「そこまでの全文」を渡す
    /// (多バイト文字の途中では渡さない)。止めた時は `LLMError.cancelled` を投げる
    /// (呼ぶ側は、最後に受け取った全文を持っている)。
    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool, onText: ((String) -> Void)?) throws -> String
}

extension TextGenerating {
    /// 少しずつ出せない実装 (試験の偽物など) のための既定: 全部出し終えてから、全文を 1 回だけ渡す
    public func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool, onText: ((String) -> Void)?) throws -> String {
        let text = try generate(prompt, shouldCancel: shouldCancel)
        onText?(text)
        return text
    }
}

/// UTF-8 のバイト列のうち、文字として読み切れる所までの長さ。
/// 終わりが多バイト文字の途中 (トークンが 1 文字の一部だけを出した時) なら、その文字の手前までを返す
public enum UTF8Prefix {
    public static func completeLength(_ bytes: [UInt8]) -> Int {
        let count = bytes.count
        // 終わりから最大 3 バイト戻って、最後の文字の先頭のバイトを探す
        var back = 1
        while back <= min(4, count) {
            let byte = bytes[count - back]
            if byte & 0xC0 != 0x80 {
                // 先頭のバイト。この文字に要るバイト数
                let need: Int
                if byte & 0x80 == 0 { need = 1 }
                else if byte & 0xE0 == 0xC0 { need = 2 }
                else if byte & 0xF0 == 0xE0 { need = 3 }
                else if byte & 0xF8 == 0xF0 { need = 4 }
                else { return count } // 壊れたバイト。待っても直らないので、そのまま渡す
                return back < need ? count - back : count
            }
            back += 1
        }
        return count // 続きのバイトだけが並ぶ (壊れている)。待っても直らない
    }
}

public enum LLMError: LocalizedError, Equatable, Sendable {
    case modelLoadFailed(String)
    case contextFailed
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int32)
    case invalidGrammar
    case cancelled
    /// 追加学習の差分 (LoRA アダプタ) を読み込めない: ファイルが無い・壊れている・別のモデル用
    case adapterLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return L("Could not load the LLM model: %@. The file may be damaged, or its format is not yet supported by this app’s llama.cpp. Delete it in Settings and download it again.", (path as NSString).lastPathComponent)
        case .contextFailed:
            return L("Could not prepare the LLM’s working memory. There may not be enough memory. Close other apps, or choose a lighter model.")
        case .promptTooLong(let tokens, let limit):
            return L("The text for the LLM is too long (%1$d / %2$d tokens).", tokens, limit)
        case .decodeFailed(let code):
            return L("The LLM failed to compute (llama.cpp error %d).", Int(code))
        case .invalidGrammar:
            return L("Could not prepare the LLM’s output format (grammar).")
        case .cancelled:
            return L("Canceled.")
        case .adapterLoadFailed(let path):
            return L("Could not load the fine-tuning adapter (LoRA): %@. Check that it was made from the same model as the selected LLM. If you remove the adapter in Settings, the original model is used.", (path as NSString).lastPathComponent)
        }
    }
}
