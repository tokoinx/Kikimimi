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

public enum Exporter {
    public static func render(_ t: Transcript, as format: ExportFormat) -> String {
        switch format {
        case .txt: return txt(t)
        case .srt: return srt(t)
        case .vtt: return vtt(t)
        case .md: return markdown(t)
        case .csv: return csv(t)
        case .json: return json(t)
        }
    }

    public static func txt(_ t: Transcript) -> String { t.text + "\n" }

    public static func srt(_ t: Transcript) -> String {
        t.segments.enumerated().map { i, s in
            "\(i + 1)\n\(TimeFormat.srt(s.start)) --> \(TimeFormat.srt(s.end))\n\(s.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ t: Transcript) -> String {
        let body = t.segments.map { s in
            "\(TimeFormat.vtt(s.start)) --> \(TimeFormat.vtt(s.end))\n\(s.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
        return "WEBVTT\n\n" + body
    }

    public static func markdown(_ t: Transcript) -> String {
        var lines = ["# \(t.sourceName)", ""]
        var meta: [String] = []
        if let l = t.language { meta.append("言語: \(Languages.name(for: l))") }
        if t.duration > 0 { meta.append("長さ: \(TimeFormat.short(t.duration))") }
        if let m = t.model { meta.append("モデル: \(m)") }
        if !meta.isEmpty { lines += [meta.joined(separator: " / "), ""] }
        lines += t.segments.map { "- **\(TimeFormat.short($0.start))** \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(_ t: Transcript) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["start,end,text"]
        rows += t.segments.map { String(format: "%.3f,%.3f,", $0.start, $0.end) + q($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return rows.joined(separator: "\n") + "\n"
    }

    public static func json(_ t: Transcript) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(t), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s + "\n"
    }
}
