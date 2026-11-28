import Foundation

/// Web ページ (HTML) から、読む文だけを取り出す。外のライブラリは使わない
public enum WebPageText {
    /// 読む HTML の長さの上限 (UTF-16 の数)。これより後ろは見ない
    public static let maxHTMLLength = 2_000_000

    // タグの中身は `[^<>]*` で探す (`[^>]*` だと、閉じない `<` ごとに文の終わりまで探しに行き、長さの 2 乗の時間になる。
    // 2026-11-28 に、`<` だけが 3.2 万字並ぶ文で 6.5 秒かかった)。中に `<` を含む、めずらしいタグは、文として残る
    public static func extract(html: String) -> (title: String, text: String) {
        var s = html.count > maxHTMLLength ? String(html.prefix(maxHTMLLength)) : html

        // 中身ごと捨てる物: コメント・script・style・noscript・svg・template
        s = replace(#"<!--[\s\S]*?(?:-->|$)"#, in: s, with: " ")
        for tag in ["script", "style", "noscript", "svg", "template"] {
            s = replace("<\(tag)\\b[^<>]*>[\\s\\S]*?(?:</\(tag)\\s*>|$)", in: s, with: " ")
        }
        // 題名は、取り出してから本文から外す
        let titles = takeTitles(from: s)
        var title = ""
        if let inner = titles.title {
            title = collapse(decodeEntities(replace(#"<[^<>]*>"#, in: inner, with: "")))
                .replacingOccurrences(of: "\n", with: " ")
        }
        s = titles.rest
        // 区切りになるタグは改行に、表の升は空白に、ほかのタグは取るだけ
        s = replace(#"<(?:br|hr)\b[^<>]*>"#, in: s, with: "\n")
        s = replace(#"</?(?:p|div|li|ul|ol|dl|dt|dd|h[1-6]|tr|table|thead|tbody|section|article|header|footer|nav|aside|main|blockquote|pre|figure|figcaption|form|fieldset|details|summary|address)\b[^<>]*>"#,
                    in: s, with: "\n")
        s = replace(#"</?(?:td|th)\b[^<>]*>"#, in: s, with: " ")
        s = replace(#"<[^<>]*>"#, in: s, with: "")
        // 閉じていない < で始まるかけら (切れた HTML) は残す。文字参照を戻してから、空白をまとめる
        return (title, collapse(decodeEntities(s)))
    }

    /// 題名 (初めの、閉じている `<title …>…</title>` の中身) を取り出し、閉じている title を全部、本文から空白に変える。
    /// 正規表現で探すと、閉じない `<title>` ごとに文の終わりまで探し直す (長さの 2 乗の時間) ので、
    /// 文字の検索で、前から 1 度だけ見ていく。閉じない `<title>` は、タグとして後で取られ、その後ろの文は残る (前と同じ)
    static func takeTitles(from text: String) -> (title: String?, rest: String) {
        let ns = text as NSString
        let length = ns.length
        let lessThan: unichar = 60, greaterThan: unichar = 62
        var title: String?
        var rest = ""
        var copied = 0
        var from = 0
        while from < length {
            let open = ns.range(of: "<title", options: .caseInsensitive, range: NSRange(location: from, length: length - from))
            guard open.location != NSNotFound else { break }
            var cursor = open.location + open.length
            // `<titlex` のように、名前が続く物は title ではない
            if cursor < length, isWordUnit(ns.character(at: cursor)) {
                from = open.location + 1
                continue
            }
            // 開くタグの終わりの `>`。その前に `<` が来たら、タグではない
            var openEnd: Int?
            while cursor < length {
                let unit = ns.character(at: cursor)
                if unit == greaterThan { openEnd = cursor + 1; break }
                if unit == lessThan { break }
                cursor += 1
            }
            guard let contentStart = openEnd else {
                from = max(cursor, open.location + 1)
                continue
            }
            // 閉じるタグ `</title` + 空白 + `>`
            var close: (start: Int, end: Int)?
            var search = contentStart
            while search < length {
                let found = ns.range(of: "</title", options: .caseInsensitive,
                                     range: NSRange(location: search, length: length - search))
                guard found.location != NSNotFound else { break }
                var k = found.location + found.length
                while k < length, isSpaceUnit(ns.character(at: k)) { k += 1 }
                if k < length, ns.character(at: k) == greaterThan {
                    close = (found.location, k + 1)
                    break
                }
                search = found.location + 1
            }
            // 閉じる物が無ければ、この後ろの title も閉じない
            guard let close else { break }
            if title == nil {
                title = ns.substring(with: NSRange(location: contentStart, length: close.start - contentStart))
            }
            rest += ns.substring(with: NSRange(location: copied, length: open.location - copied))
            rest += " "
            copied = close.end
            from = close.end
        }
        rest += ns.substring(from: copied)
        return (title, rest)
    }

    /// 正規表現の `\w` の仲間 (文字・数字・`_`)。対になる半分の文字 (絵文字など) も、文字とみなす
    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isSpaceUnit(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
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
