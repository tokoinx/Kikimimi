import Foundation

/// 文字起こしの 1 区間。
public struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.text = text
    }

    public var duration: TimeInterval { end - start }
}

/// 1 ファイル (または 1 録音) の文字起こし結果。
public struct Transcript: Codable, Hashable, Sendable {
    public var sourceName: String
    public var segments: [TranscriptSegment]
    /// 言語コード (ja, en など)。自動判定の結果が入る。
    public var language: String?
    public var model: String?
    public var duration: TimeInterval
    public var elapsed: TimeInterval

    public init(sourceName: String, segments: [TranscriptSegment] = [], language: String? = nil,
                model: String? = nil, duration: TimeInterval = 0, elapsed: TimeInterval = 0) {
        self.sourceName = sourceName
        self.segments = segments
        self.language = language
        self.model = model
        self.duration = duration
        self.elapsed = elapsed
    }

    /// 本文 (1 区間 1 行)
    public var text: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// `[mm:ss] 本文` 形式
    public func text(withTimestamps: Bool) -> String {
        guard withTimestamps else { return text }
        return segments.map { "[\(TimeFormat.short($0.start))] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

    /// 実時間比 (処理秒 / 音声秒)。小さいほど速い。
    public var realTimeFactor: Double? {
        duration > 0 && elapsed > 0 ? elapsed / duration : nil
    }
}

public enum TimeFormat {
    private static func split(_ seconds: TimeInterval) -> (h: Int, m: Int, s: Int, ms: Int) {
        let total = Int((max(0, seconds) * 1000).rounded())
        return (total / 3_600_000, total % 3_600_000 / 60_000, total % 60_000 / 1000, total % 1000)
    }

    /// `HH:MM:SS,mmm` (SRT)
    public static func srt(_ seconds: TimeInterval) -> String {
        let t = split(seconds)
        return String(format: "%02d:%02d:%02d,%03d", t.h, t.m, t.s, t.ms)
    }

    /// `HH:MM:SS.mmm` (WebVTT)
    public static func vtt(_ seconds: TimeInterval) -> String {
        let t = split(seconds)
        return String(format: "%02d:%02d:%02d.%03d", t.h, t.m, t.s, t.ms)
    }

    /// `mm:ss` または `h:mm:ss`
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `1.2 GB` のような表記
    public static func bytes(_ count: Int64) -> String {
        let mb = Double(count) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }
}
