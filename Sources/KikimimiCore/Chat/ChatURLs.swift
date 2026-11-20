import Foundation

/// チャットの発言の中の URL (リサーチで読むページ)
public enum ChatURLs {
    /// 1 回の発言で読むページの数の上限
    public static let maxCount = 3

    /// 発言の中の https の URL (書いてある順、重なりは 1 つに、3 つまで)。
    /// 読んでよい名前かどうかは見ない (`isAllowed` で別に確かめる。通らない物を利用者に知らせられるように)
    public static func urls(in text: String) -> [URL] {
        // URL に使える ASCII の文字だけを拾う (日本語の文に続けて書かれても、そこで切れる)
        guard let regex = try? NSRegularExpression(pattern: #"https://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#,
                                                   options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var found: [URL] = []
        var seen: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = trimTrailing(ns.substring(with: match.range))
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { continue }
            let identity = canonical(url)
            guard seen.insert(identity).inserted else { continue }
            found.append(url)
            if found.count == maxCount { break }
        }
        return found
    }

    /// 公開の名前のページだけを通す。通さない物: https 以外・localhost・.local・.internal などの内の名前・
    /// 点の無い名前・IP アドレスの直書き (IPv4・IPv6)・利用者名やパスワード入り・443 以外のポートの指定。
    ///
    /// 名前を引いた先の住所 (公開の名前が内の住所を指す場合) と、転送の先は、ここでは確かめられない。
    /// 読みに行く側で、転送の先にもこの関数を当てること
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        if let port = url.port, port != 443 { return false }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        // IPv6 (括弧つき・コロン入り) と、% の入った名前
        if host.contains(":") || host.contains("[") || host.contains("%") { return false }
        // 名前に使えない文字
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: { $0.isEmpty }) else { return false }
        // 最後の部分が数字だけ・16 進の形なら、IP アドレスの直書き (127.1・0x7f.1 などの短い形も)
        if let tld = labels.last, tld.allSatisfy(\.isNumber) || tld.hasPrefix("0x") { return false }
        let internalSuffixes = ["localhost", "local", "internal", "localdomain", "lan", "home", "corp", "intranet",
                                "private", "home.arpa", "arpa", "test", "invalid", "example", "onion"]
        for suffix in internalSuffixes where host == suffix || host.hasSuffix("." + suffix) {
            return false
        }
        return true
    }

    /// 重なりを見るための形 (# から後ろを外し、名前を小文字に)
    private static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.host = parts.host?.lowercased()
        var text = parts.string ?? url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 文の句読点として URL の後ろに付いた物を外す (閉じかっこは、開きかっこと対でない時だけ)
    private static func trimTrailing(_ raw: String) -> String {
        var s = raw
        while let last = s.last {
            if ".,;:!?'\"".contains(last) {
                s.removeLast()
            } else if last == ")" && s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count {
                s.removeLast()
            } else if last == "]" && s.filter({ $0 == "[" }).count < s.filter({ $0 == "]" }).count {
                s.removeLast()
            } else {
                break
            }
        }
        return s
    }
}
