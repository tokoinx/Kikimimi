import Foundation

/// Web ページ (HTML) から、読む文だけを取り出す。外のライブラリは使わない
public enum WebPageText {
    /// 読む HTML の長さの上限 (UTF-16 の数)。これより後ろは見ない
    public static let maxHTMLLength = 2_000_000

    public static func extract(html: String) -> (title: String, text: String) {
        var s = html.count > maxHTMLLength ? String(html.prefix(maxHTMLLength)) : html

        // 中身ごと捨てる物: コメント・script・style・noscript・svg・template
        s = replace(#"<!--[\s\S]*?(?:-->|$)"#, in: s, with: " ")
        for tag in ["script", "style", "noscript", "svg", "template"] {
            s = replace("<\(tag)\\b[^>]*>[\\s\\S]*?(?:</\(tag)\\s*>|$)", in: s, with: " ")
        }
        // 題名は、取り出してから本文から外す
        var title = ""
        if let range = firstMatch(#"<title\b[^>]*>([\s\S]*?)</title\s*>"#, in: s) {
            title = collapse(decodeEntities(replace(#"<[^>]*>"#, in: range, with: "")))
                .replacingOccurrences(of: "\n", with: " ")
        }
        s = replace(#"<title\b[^>]*>[\s\S]*?</title\s*>"#, in: s, with: " ")
        // 区切りになるタグは改行に、表の升は空白に、ほかのタグは取るだけ
        s = replace(#"<(?:br|hr)\b[^>]*>"#, in: s, with: "\n")
        s = replace(#"</?(?:p|div|li|ul|ol|dl|dt|dd|h[1-6]|tr|table|thead|tbody|section|article|header|footer|nav|aside|main|blockquote|pre|figure|figcaption|form|fieldset|details|summary|address)\b[^>]*>"#,
                    in: s, with: "\n")
        s = replace(#"</?(?:td|th)\b[^>]*>"#, in: s, with: " ")
        s = replace(#"<[^>]*>"#, in: s, with: "")
        // 閉じていない < で始まるかけら (切れた HTML) は残す。文字参照を戻してから、空白をまとめる
        return (title, collapse(decodeEntities(s)))
    }

    /// よく在る文字参照と、数値参照を戻す (1 回だけ。`&amp;lt;` は `&lt;` になる)
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        ]
        guard let regex = try? NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"#) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(scalarText)
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(scalarText)
            } else {
                replacement = named[name.lowercased()]
            }
            guard let replacement else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += replacement
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// 数値参照の文字。制御文字 (改行とタブを除く) と、文字でない番号は空白にする
    private static func scalarText(_ value: UInt32) -> String? {
        guard let scalar = Unicode.Scalar(value) else { return " " }
        if value == 0x0A || value == 0x09 { return String(Character(scalar)) }
        if value == 0xA0 { return " " }
        if ChatSettingItem.isControl(scalar) { return " " }
        return String(Character(scalar))
    }

    /// 行ごとに空白をまとめ、空行は 1 つまでにし、前後の空白を落とす
    static func collapse(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.components(separatedBy: "\n") {
            var line = ""
            var space = false
            for scalar in raw.unicodeScalars {
                if scalar == " " || scalar == "\t" || scalar.value == 0xA0 || scalar.value == 0x3000 || scalar.value == 0x0C || scalar.value == 0x0B {
                    space = true
                } else if ChatSettingItem.isControl(scalar) {
                    continue
                } else {
                    if space, !line.isEmpty { line.append(" ") }
                    space = false
                    line.unicodeScalars.append(scalar)
                }
            }
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
            } else {
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
