import Foundation

/// 答えの中の「設定を変える案」1 つ。アプリは、利用者に確かめてから当てる
public struct ChatSettingProposal: Sendable, Equatable {
    public let key: String
    /// 保存する形の新しい値 (toggle は "on" / "off"、choice は値のコード)
    public let value: String
    /// その設定 (ラベルや、値の画面での名前を引くため)
    public let item: ChatSettingItem

    public init(key: String, value: String, item: ChatSettingItem) {
        self.key = key
        self.value = value
        self.item = item
    }
}

/// 答えの中の「設定の画面を開く」印 1 つ。page が nil なら、タブを決めずに開く
public struct ChatOpenSettings: Sendable, Equatable {
    public let page: ChatSettingsPage?

    public init(page: ChatSettingsPage?) {
        self.page = page
    }
}

/// 答えを読み取った結果
public struct ChatParseResult: Sendable, Equatable {
    /// 印を取り除いた、画面に出す文
    public var visibleText: String
    /// 当ててよい形の、設定を変える案 (同じ鍵は後の物。5 つまで)
    public var proposals: [ChatSettingProposal]
    /// 設定の画面を開く印 (重なりは 1 つに)
    public var opens: [ChatOpenSettings]
    /// 当てない印 (知らない鍵・取れない値・多すぎる案など)。書いてあったままの形
    public var rejected: [String]
}

/// 答えの中の動作の印 `[[set 鍵=値]]`・`[[open settings]]`・`[[open settings=general|transcription|llm]]` を読む
public enum ChatActionParser {
    /// 1 回の答えで受ける、設定を変える案の数の上限
    public static let maxProposals = 5

    /// 印を読み取り、見える文から取り除く。
    /// - Parameter allowSettings: false なら `[[set …]]` をすべて rejected にする
    ///   (Web ページを読んだ回など、外から来た文に動かされうる時)
    public static func parse(_ text: String, catalog: [ChatSettingItem], allowSettings: Bool = true) -> ChatParseResult {
        let markers = findMarkers(in: text)
        var proposals: [ChatSettingProposal] = []
        var opens: [ChatOpenSettings] = []
        var rejected: [String] = []

        for marker in markers {
            switch marker.action {
            case .set(let rawKey, let rawValue):
                guard allowSettings,
                      let item = catalog.first(where: { $0.key.lowercased() == rawKey.lowercased() }),
                      !ChatSettingsCatalog.excludedKeys.contains(item.key),
                      let value = item.normalizedValue(rawValue) else {
                    rejected.append(marker.raw)
                    continue
                }
                // 同じ鍵が 2 回なら後の物
                proposals.removeAll { $0.key == item.key }
                proposals.append(ChatSettingProposal(key: item.key, value: value, item: item))
            case .open(let page):
                let open = ChatOpenSettings(page: page)
                if !opens.contains(open) { opens.append(open) }
            case .invalid:
                rejected.append(marker.raw)
            }
        }
        if proposals.count > maxProposals {
            // 多すぎる分は当てない (書いてあった順の、後ろの物)
            for extra in proposals[maxProposals...] {
                rejected.append("[[set \(extra.key)=\(extra.value)]]")
            }
            proposals = Array(proposals.prefix(maxProposals))
        }
        return ChatParseResult(visibleText: removing(markers, from: text), proposals: proposals, opens: opens, rejected: rejected)
    }

    /// 少しずつ出している途中の文から、画面に出してよい所を返す。
    /// 書き終えた印は取り除き、閉じていない `[[` から後ろ (と、終わりの `[` 1 つ) は隠す
    public static func visiblePrefix(_ partial: String) -> String {
        var text = partial
        if let open = text.range(of: "[[", options: .backwards), text.range(of: "]]", range: open.upperBound..<text.endIndex) == nil {
            text = String(text[..<open.lowerBound])
        }
        if text.hasSuffix("[") { text.removeLast() }
        return removing(findMarkers(in: text), from: text)
    }

    /// 文から、書き終えた動作の印を取り除く (過去の答えを LLM に見せ直す時など)
    public static func stripMarkers(_ text: String) -> String {
        removing(findMarkers(in: text), from: text)
    }

    // MARK: - 実装

    enum Action: Equatable {
        case set(key: String, value: String)
        case open(ChatSettingsPage?)
        /// set か open の形だが、読めない
        case invalid
    }

    struct Marker {
        let range: Range<String.Index>
        let raw: String
        let action: Action
    }

    /// `[[` … `]]` のうち、set か open で始まる物
    static func findMarkers(in text: String) -> [Marker] {
        var markers: [Marker] = []
        var cursor = text.startIndex
        while let open = text.range(of: "[[", range: cursor..<text.endIndex) {
            guard let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) else { break }
            let inner = String(text[open.upperBound..<close.lowerBound])
            if let action = action(of: inner) {
                markers.append(Marker(range: open.lowerBound..<close.upperBound,
                                      raw: String(text[open.lowerBound..<close.upperBound]), action: action))
                cursor = close.upperBound
            } else {
                // 印でない [[ … ]] (文の一部)。1 字先から探し直す
                cursor = text.index(after: open.lowerBound)
            }
        }
        return markers
    }

    static func action(of inner: String) -> Action? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("set"), let after = lower.dropFirst(3).first, after == " " || after == "\t" || after == ":" {
            let body = trimmed.dropFirst(4)
            guard let eq = body.firstIndex(of: "=") else { return .invalid }
            let key = body[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: eq)...])
            guard !key.isEmpty else { return .invalid }
            return .set(key: key, value: value)
        }
        if lower.hasPrefix("open") {
            var rest = lower.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("settings") else { return lower == "open" ? .invalid : nil }
            rest = String(rest.dropFirst("settings".count)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .open(nil) }
            guard let sep = rest.first, sep == "=" || sep == ":" else { return .invalid }
            let name = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            switch name {
            case "general": return .open(.general)
            case "transcription": return .open(.transcription)
            case "llm", "audit", "translation", "audit & translation", "audit&translation": return .open(.llm)
            default: return .invalid
            }
        }
        return nil
    }

    /// 印を取り除き、印だけだった行と、続いた空行と、終わりの空白を片付ける
    static func removing(_ markers: [Marker], from text: String) -> String {
        guard !markers.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for marker in markers {
            out += text[cursor..<marker.range.lowerBound]
            cursor = marker.range.upperBound
        }
        out += text[cursor...]
        // 行末の空白を落とし、3 つ以上続く改行 (空行 2 つ以上) を 1 つの空行にする
        let lines = out.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return String(l)
        }
        var cleaned: [String] = []
        for line in lines {
            if line.isEmpty, cleaned.last?.isEmpty == true { continue }
            cleaned.append(line)
        }
        while cleaned.last?.isEmpty == true { cleaned.removeLast() }
        return cleaned.joined(separator: "\n")
    }
}
