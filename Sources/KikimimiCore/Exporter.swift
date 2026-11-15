import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt, srt, vtt, md, csv, json

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .txt: return "テキスト (.txt)"
        case .srt: return "字幕 SRT (.srt)"
        case .vtt: return "字幕 WebVTT (.vtt)"
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
    /// 日本語だけ (訳のある区間は訳、日本語の区間は原文)
    case japanese
    /// 原文と日本語訳を並べる (対訳)
    case bilingual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "原文"
        case .japanese: return "日本語訳"
        case .bilingual: return "対訳 (原文 + 日本語)"
        }
    }

    /// ファイル名に付ける印
    public var fileSuffix: String {
        switch self {
        case .original: return ""
        case .japanese: return ".ja"
        case .bilingual: return ".bilingual"
        }
    }

    /// この形式で選べるか (JSON はいつも全部入り)
    public static func available(for format: ExportFormat) -> [ExportContent] {
        format == .json ? [.original] : allCases
    }
}

public enum Exporter {
    public static func render(_ t: Transcript, as format: ExportFormat, content: ExportContent = .original) -> String {
        switch format {
        case .txt: return txt(t, content: content)
        case .srt: return srt(t, content: content)
        case .vtt: return vtt(t, content: content)
        case .md: return markdown(t, content: content)
        case .csv: return csv(t, content: content)
        case .json: return json(t)
        }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 書き出す 1 行 (字幕なら 1 枚)。原文は区間ごと、日本語訳・対訳は訳ごと (文が区間をまたぐときは 1 つにまとめる)
    struct Row {
        var start: TimeInterval
        var end: TimeInterval
        var original: String
        /// 日本語 (訳、またはもともと日本語の原文)。まだ訳がなければ nil
        var japanese: String?
        /// 原文の言語 (「日本語＋英語」で文字にしたときだけ)
        var language: String? = nil
    }

    static func rows(_ t: Transcript, _ content: ExportContent) -> [Row] {
        switch content {
        case .original:
            return t.segments.map {
                Row(start: $0.start, end: $0.end, original: clean($0.text), japanese: nil, language: $0.language)
            }
        case .japanese, .bilingual:
            return t.bilingualUnits().map {
                Row(start: $0.start, end: $0.end, original: clean($0.text), japanese: $0.japanese.map(clean),
                    language: $0.language)
            }
        }
    }

    /// 1 行に書く文
    static func lines(_ row: Row, _ content: ExportContent) -> [String] {
        switch content {
        case .original:
            return [row.original]
        case .japanese:
            return [row.japanese ?? row.original]
        case .bilingual:
            guard let ja = row.japanese, ja != row.original else { return [row.original] }
            return [row.original, ja]
        }
    }

    public static func txt(_ t: Transcript, content: ExportContent = .original) -> String {
        switch content {
        case .original:
            return t.text + "\n"
        case .japanese:
            return rows(t, content).map { lines($0, content)[0] }.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        case .bilingual:
            return rows(t, content).map { row in
                let l = lines(row, content)
                return "[\(TimeFormat.short(row.start))] " + l[0] + (l.count > 1 ? "\n        " + l[1] : "")
            }.joined(separator: "\n") + "\n"
        }
    }

    public static func srt(_ t: Transcript, content: ExportContent = .original) -> String {
        rows(t, content).enumerated().map { i, row in
            "\(i + 1)\n\(TimeFormat.srt(row.start)) --> \(TimeFormat.srt(row.end))\n\(lines(row, content).joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ t: Transcript, content: ExportContent = .original) -> String {
        let body = rows(t, content).map { row in
            "\(TimeFormat.vtt(row.start)) --> \(TimeFormat.vtt(row.end))\n\(lines(row, content).joined(separator: "\n"))\n"
        }.joined(separator: "\n")
        return "WEBVTT\n\n" + body
    }

    public static func markdown(_ t: Transcript, content: ExportContent = .original) -> String {
        var out = ["# \(t.sourceName)", ""]
        var meta: [String] = []
        if let l = t.languageLabel { meta.append("言語: \(l)") }
        if t.duration > 0 { meta.append("長さ: \(TimeFormat.short(t.duration))") }
        if let m = t.model { meta.append("モデル: \(m)") }
        if content != .original, let m = t.translationModel { meta.append("翻訳: \(m)") }
        if !meta.isEmpty { out += [meta.joined(separator: " / "), ""] }
        switch content {
        case .bilingual:
            func cell(_ s: String) -> String {
                s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            }
            out += ["| 時刻 | 原文 | 日本語訳 |", "| --- | --- | --- |"]
            out += rows(t, content).map { row in
                "| \(TimeFormat.short(row.start)) | \(cell(row.original)) | \(cell(row.japanese ?? "")) |"
            }
        case .original, .japanese:
            out += rows(t, content).map { "- **\(TimeFormat.short($0.start))** \(lines($0, content)[0])" }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func csv(_ t: Transcript, content: ExportContent = .original) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        // 2 つ以上の言語が混ざるとき (「日本語＋英語」) だけ、最後に原文の言語の列を足す (ほかはこれまでと同じ形)
        let mixed = t.spokenLanguages.count >= 2
        let languageHeader = mixed ? ",language" : ""
        func language(_ row: Row) -> String { mixed ? "," + (row.language ?? "") : "" }
        switch content {
        case .original, .japanese:
            var out = ["start,end,text" + languageHeader]
            out += rows(t, content).map {
                String(format: "%.3f,%.3f,", $0.start, $0.end) + q(lines($0, content)[0]) + language($0)
            }
            return out.joined(separator: "\n") + "\n"
        case .bilingual:
            var out = ["start,end,text,japanese" + languageHeader]
            out += rows(t, content).map {
                String(format: "%.3f,%.3f,", $0.start, $0.end) + q($0.original) + "," + q($0.japanese ?? "") + language($0)
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
