import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt, srt, vtt, md, csv, json

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .txt: return L("Text (.txt)")
        case .srt: return L("Subtitles SRT (.srt)")
        case .vtt: return L("Subtitles WebVTT (.vtt)")
        case .md: return "Markdown (.md)"
        case .csv: return "CSV (.csv)"
        case .json: return "JSON (.json)"
        }
    }
}

/// 何を書き出すか
public enum ExportContent: String, CaseIterable, Identifiable, Sendable {
    /// 原文だけ
    case original
    /// 訳だけ (訳のある区間は訳、もともと訳す先の言語の区間は原文)
    case translation
    /// 原文と訳を並べる (対訳)
    case bilingual

    public var id: String { rawValue }

    /// 画面に出す名前。target は訳した言語のコード (「日本語訳」「対訳 (原文 + 日本語)」の「日本語」の所)
    public func displayName(target: String) -> String {
        switch self {
        case .original: return L("Original")
        case .translation: return L("%@ translation", TranslationTarget.displayName(for: target))
        case .bilingual: return L("Bilingual (original + %@)", TranslationTarget.displayName(for: target))
        }
    }

    /// ファイル名に付ける印 (訳は言語のコード。日本語なら「.ja」)
    public func fileSuffix(target: String) -> String {
        switch self {
        case .original: return ""
        case .translation: return ".\(target)"
        case .bilingual: return ".bilingual"
        }
    }

    /// この形式で選べるか (JSON はいつも全部入り)
    public static func available(for format: ExportFormat) -> [ExportContent] {
        format == .json ? [.original] : allCases
    }
}

/// 書き出し。訳・対訳の訳す先の言語 (target) は、渡さなければ結果が訳した言語 (`Transcript.translationTarget(default: "ja")`)
public enum Exporter {
    public static func render(_ t: Transcript, as format: ExportFormat, content: ExportContent = .original,
                              target: String? = nil) -> String {
        switch format {
        case .txt: return txt(t, content: content, target: target)
        case .srt: return srt(t, content: content, target: target)
        case .vtt: return vtt(t, content: content, target: target)
        case .md: return markdown(t, content: content, target: target)
        case .csv: return csv(t, content: content, target: target)
        case .json: return json(t)
        }
    }

    /// 訳す先の言語 (渡されなければ、結果が訳した言語)
    static func resolvedTarget(_ t: Transcript, _ target: String?) -> String {
        target ?? t.translationTarget(default: "ja")
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 書き出す 1 行 (字幕なら 1 枚)。原文は区間ごと、訳・対訳は訳ごと (文が区間をまたぐときは 1 つにまとめる)
    struct Row {
        var start: TimeInterval
        var end: TimeInterval
        var original: String
        /// 訳、またはもともと訳す先の言語の原文。まだ訳がなければ nil
        var translation: String?
        /// 原文の言語 (「日本語＋英語」で文字にしたときだけ)
        var language: String? = nil
    }

    static func rows(_ t: Transcript, _ content: ExportContent, target: String) -> [Row] {
        switch content {
        case .original:
            return t.segments.map {
                Row(start: $0.start, end: $0.end, original: clean($0.text), translation: nil, language: $0.language)
            }
        case .translation, .bilingual:
            return t.bilingualUnits(target: target).map {
                Row(start: $0.start, end: $0.end, original: clean($0.text), translation: $0.translation.map(clean),
                    language: $0.language)
            }
        }
    }

    /// 1 行に書く文
    static func lines(_ row: Row, _ content: ExportContent) -> [String] {
        switch content {
        case .original:
            return [row.original]
        case .translation:
            return [row.translation ?? row.original]
        case .bilingual:
            guard let tr = row.translation, tr != row.original else { return [row.original] }
            return [row.original, tr]
        }
    }

    public static func txt(_ t: Transcript, content: ExportContent = .original, target: String? = nil) -> String {
        let target = resolvedTarget(t, target)
        switch content {
        case .original:
            return t.text + "\n"
        case .translation:
            return rows(t, content, target: target).map { lines($0, content)[0] }.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        case .bilingual:
            return rows(t, content, target: target).map { row in
                let l = lines(row, content)
                return "[\(TimeFormat.short(row.start))] " + l[0] + (l.count > 1 ? "\n        " + l[1] : "")
            }.joined(separator: "\n") + "\n"
        }
    }

    public static func srt(_ t: Transcript, content: ExportContent = .original, target: String? = nil) -> String {
        rows(t, content, target: resolvedTarget(t, target)).enumerated().map { i, row in
            "\(i + 1)\n\(TimeFormat.srt(row.start)) --> \(TimeFormat.srt(row.end))\n\(lines(row, content).joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ t: Transcript, content: ExportContent = .original, target: String? = nil) -> String {
        let body = rows(t, content, target: resolvedTarget(t, target)).map { row in
            "\(TimeFormat.vtt(row.start)) --> \(TimeFormat.vtt(row.end))\n\(lines(row, content).joined(separator: "\n"))\n"
        }.joined(separator: "\n")
        return "WEBVTT\n\n" + body
    }

    public static func markdown(_ t: Transcript, content: ExportContent = .original, target: String? = nil) -> String {
        let target = resolvedTarget(t, target)
        var out = ["# \(t.sourceName)", ""]
        var meta: [String] = []
        if let l = t.languageLabel { meta.append(L("Language: %@", l)) }
        if t.duration > 0 { meta.append(L("Length: %@", TimeFormat.short(t.duration))) }
        if let m = t.model { meta.append(L("Model: %@", m)) }
        if content != .original, let m = t.translationModel { meta.append(L("Translation: %@", m)) }
        if !meta.isEmpty { out += [meta.joined(separator: " / "), ""] }
        switch content {
        case .bilingual:
            func cell(_ s: String) -> String {
                s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            }
            out += [L("| Time | Original | %@ translation |", TranslationTarget.displayName(for: target)), "| --- | --- | --- |"]
            out += rows(t, content, target: target).map { row in
                "| \(TimeFormat.short(row.start)) | \(cell(row.original)) | \(cell(row.translation ?? "")) |"
            }
        case .original, .translation:
            out += rows(t, content, target: target).map { "- **\(TimeFormat.short($0.start))** \(lines($0, content)[0])" }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func csv(_ t: Transcript, content: ExportContent = .original, target: String? = nil) -> String {
        let target = resolvedTarget(t, target)
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        // 2 つ以上の言語が混ざるとき (「日本語＋英語」) だけ、最後に原文の言語の列を足す (ほかはこれまでと同じ形)
        let mixed = t.spokenLanguages.count >= 2
        let languageHeader = mixed ? ",language" : ""
        func language(_ row: Row) -> String { mixed ? "," + (row.language ?? "") : "" }
        switch content {
        case .original, .translation:
            var out = ["start,end,text" + languageHeader]
            out += rows(t, content, target: target).map {
                String(format: "%.3f,%.3f,", $0.start, $0.end) + q(lines($0, content)[0]) + language($0)
            }
            return out.joined(separator: "\n") + "\n"
        case .bilingual:
            // 訳の列の名前: 日本語へ訳した時は、これまでと同じ「japanese」
            let column = target == "ja" ? "japanese" : "translation"
            var out = ["start,end,text,\(column)" + languageHeader]
            out += rows(t, content, target: target).map {
                String(format: "%.3f,%.3f,", $0.start, $0.end) + q($0.original) + "," + q($0.translation ?? "") + language($0)
            }
            return out.joined(separator: "\n") + "\n"
        }
    }

    public static func json(_ t: Transcript) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(t), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s + "\n"
    }
}
