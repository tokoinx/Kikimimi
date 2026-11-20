import Foundation

/// チャットの発言の主
public enum ChatRole: String, Sendable, Equatable, Codable {
    case user
    case assistant
}

/// チャットの発言 1 つ
public struct ChatMessage: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var role: ChatRole
    public var text: String

    public init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// リサーチで読んだ Web ページ 1 つ (文は `WebPageText.extract` で取り出した物)
public struct ChatWebPage: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var text: String

    public init(url: URL, title: String, text: String) {
        self.url = url
        self.title = title
        self.text = text
    }
}

/// 今の設定の値を読む口。アプリの側 (AppModel) が実装する。
/// 値の書き方は `ChatSettingItem` と同じ (toggle は "on" / "off"、choice は値のコード、text はその文)。
/// 書く方は Core には無い (アプリの側が提案を受けて、利用者に確かめてから自分で当てる)
public protocol ChatSettingsAccess {
    func currentValue(for key: String) -> String?
}

public enum ChatError: LocalizedError, Equatable, Sendable {
    /// 今の発言だけで、LLM が一度に読める長さを超える
    case messageTooLong

    public var errorDescription: String? {
        switch self {
        case .messageTooLong:
            return L("Your message is too long. Shorten it and send it again.")
        }
    }
}
