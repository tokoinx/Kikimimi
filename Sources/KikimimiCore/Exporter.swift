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

    /// 1 区間に書く文 (行のまとまり)
    static func lines(_ t: Transcript, _ s: TranscriptSegment, _ content: ExportContent) -> [String] {
        let original = clean(s.text)
        switch content {
        case .original:
            return [original]
        case .japanese:
            return [clean(t.japaneseText(of: s) ?? original)]
        case .bilingual:
            guard let ja = t.japaneseText(of: s).map(clean), ja != original else { return [original] }
            return [original, ja]
        }
    }

    public static func txt(_ t: Transcript, content: ExportContent = .original) -> String {
        switch content {
        case .original:
            return t.text + "\n"
        case .japanese:
            return t.segments.map { lines(t, $0, .japanese)[0] }.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        case .bilingual:
            return t.segments.map { s in
                let l = lines(t, s, .bilingual)
                return "[\(TimeFormat.short(s.start))] " + l[0] + (l.count > 1 ? "\n        " + l[1] : "")
            }.joined(separator: "\n") + "\n"
        }
    }

    public static func srt(_ t: Transcript, content: ExportContent = .original) -> String {
        t.segments.enumerated().map { i, s in
            "\(i + 1)\n\(TimeFormat.srt(s.start)) --> \(TimeFormat.srt(s.end))\n\(lines(t, s, content).joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ t: Transcript, content: ExportContent = .original) -> String {
        let body = t.segments.map { s in
            "\(TimeFormat.vtt(s.start)) --> \(TimeFormat.vtt(s.end))\n\(lines(t, s, content).joined(separator: "\n"))\n"
        }.joined(separator: "\n")
        return "WEBVTT\n\n" + body
    }

    public static func markdown(_ t: Transcript, content: ExportContent = .original) -> String {
        var out = ["# \(t.sourceName)", ""]
        var meta: [String] = []
        if let l = t.language { meta.append("言語: \(Languages.name(for: l))") }
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
            out += t.segments.map { s in
                "| \(TimeFormat.short(s.start)) | \(cell(clean(s.text))) | \(cell(t.japaneseText(of: s).map(clean) ?? "")) |"
            }
        case .original, .japanese:
            out += t.segments.map { "- **\(TimeFormat.short($0.start))** \(lines(t, $0, content)[0])" }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func csv(_ t: Transcript, content: ExportContent = .original) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        switch content {
        case .original, .japanese:
            var rows = ["start,end,text"]
            rows += t.segments.map { String(format: "%.3f,%.3f,", $0.start, $0.end) + q(lines(t, $0, content)[0]) }
            return rows.joined(separator: "\n") + "\n"
        case .bilingual:
            var rows = ["start,end,text,japanese"]
            rows += t.segments.map {
                String(format: "%.3f,%.3f,", $0.start, $0.end) + q(clean($0.text)) + "," + q(t.japaneseText(of: $0).map(clean) ?? "")
            }
            return rows.joined(separator: "\n") + "\n"
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
