import Foundation

/// 文字起こしの 1 区間。
public struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// 日本語訳 (まだ訳していなければ nil)
    public var translation: String?
    /// 1 つの文が何区間かに分かれているとき、この区間の訳に一緒に含めた後ろの区間の ID。
    /// 文の途中で区間を区切って訳すと、日本語の語順のせいで訳が隣の区間にずれるので、文ごとに訳す
    public var translationCovers: [UUID]?
    /// この区間で話されている言語 (「日本語＋英語」で文字にしたときだけ入る。ほかは文字起こし全体の言語を使う)
    public var language: String?

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String, translation: String? = nil,
                translationCovers: [UUID]? = nil, language: String? = nil) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.text = text
        self.translation = translation
        self.translationCovers = translationCovers
        self.language = language
    }

    public var duration: TimeInterval { end - start }
}

/// 1 ファイル (または 1 録音) の文字起こし結果。
public struct Transcript: Codable, Hashable, Sendable {
    public var sourceName: String
    public var segments: [TranscriptSegment]
    /// 言語コード (ja, en など)。自動判定の結果が入る。「日本語＋英語」では、いちばん長く話されていた言語
    public var language: String?
    public var model: String?
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    /// 監査 (聞き取りミス・繰り返しの見直し) の結果
    public var audit: AuditReport?
    /// 翻訳に使った LLM の名前
    public var translationModel: String?

    public init(sourceName: String, segments: [TranscriptSegment] = [], language: String? = nil,
                model: String? = nil, duration: TimeInterval = 0, elapsed: TimeInterval = 0,
                audit: AuditReport? = nil, translationModel: String? = nil) {
        self.sourceName = sourceName
        self.segments = segments
        self.language = language
        self.model = model
        self.duration = duration
        self.elapsed = elapsed
        self.audit = audit
        self.translationModel = translationModel
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

    /// 区間ごとの言語 (「日本語＋英語」で文字にしたもの) を、話された時間の長い順に並べたもの。区間に言語が無ければ空
    public var spokenLanguages: [String] {
        var tally = LanguageTally()
        tally.add(segments)
        return tally.ranked
    }

    /// 画面や書き出しに出す言語の名前。2 つ以上の言語なら「英語＋日本語」のようにつなぐ
    public var languageLabel: String? {
        Self.languageLabel(spoken: spokenLanguages, language: language)
    }

    /// languageLabel の中身 (spoken は spokenLanguages。結果の一覧の覚えておく所 TranscriptRowCache も使う)
    static func languageLabel(spoken: [String], language: String?) -> String? {
        if spoken.count >= 2 { return spoken.map { Languages.name(for: $0) }.joined(separator: "＋") }
        guard let code = language ?? spoken.first, !code.isEmpty else { return nil }
        return Languages.name(for: code)
    }

    /// 区間の言語 (区間に無ければ文字起こし全体の言語)
    public func language(of segment: TranscriptSegment) -> String? {
        segment.language ?? language
    }

    /// 日本語に訳す必要がある区間か (日本語の文字でも、「日本語＋英語」で日本語とわかっている区間でもない)
    public func needsTranslation(_ segment: TranscriptSegment) -> Bool {
        Translator.needsTranslation(segment, transcriptLanguage: language)
    }

    /// 翻訳の状況 (画面の表示に使う。区間を 1 回だけ見て数える)
    public struct TranslationStats: Equatable, Sendable {
        /// 日本語訳が 1 つでもある
        public var hasTranslation = false
        /// 日本語に訳す必要がある区間の数 (日本語の区間や、数字・記号だけの区間は数えない)
        public var translatable = 0
        /// 訳す必要があるのに、まだ訳がない区間の数
        public var untranslated = 0
        /// 日本語以外が主な文字起こしか (自動翻訳と対訳表示の対象)。文字を含む区間の 2 割以上が日本語以外なら true。
        /// 日本語の講演に英語の相づちが数行まじる程度では false (対訳にしても右の列がほぼ原文の繰り返しになるため)
        public var isMainlyForeign = false

        /// まだ数えていない状態 (すべて 0)
        public init() {}
    }

    public var translationStats: TranslationStats {
        var stats = TranslationStats()
        let covered = coveredIDs
        var lettered = 0
        for s in segments {
            if s.translation != nil { stats.hasTranslation = true }
            guard Script.hasLetters(s.text) else { continue }
            lettered += 1
            guard needsTranslation(s) else { continue }
            stats.translatable += 1
            if s.translation == nil && !covered.contains(s.id) { stats.untranslated += 1 }
        }
        stats.isMainlyForeign = lettered > 0 && Double(stats.translatable) >= Double(lettered) * 0.2
        return stats
    }

    public var hasTranslation: Bool { segments.contains { $0.translation != nil } }
    public var translatableCount: Int { translationStats.translatable }
    public var untranslatedCount: Int { translationStats.untranslated }
    public var isMainlyForeign: Bool { translationStats.isMainlyForeign }

    /// ほかの区間の訳に含まれている区間 (文の続き)
    public var coveredIDs: Set<UUID> {
        var ids = Set<UUID>()
        for s in segments where s.translation != nil {
            for id in s.translationCovers ?? [] { ids.insert(id) }
        }
        return ids
    }

    /// 右の列 (日本語) に出す文: 訳があれば訳、訳す必要のない区間は原文のまま (文の続きの区間は nil)
    public func japaneseText(of segment: TranscriptSegment) -> String? {
        if let t = segment.translation { return t }
        return needsTranslation(segment) ? nil : segment.text
    }

    /// 対訳の 1 行 (1 つの訳と、それに当たる区間)。ふつうは 1 区間、文が分かれていれば数区間
    public struct BilingualUnit: Identifiable, Hashable, Sendable {
        public var segments: [TranscriptSegment]
        /// 日本語訳。もともと日本語の区間は原文。まだ訳がなければ nil
        public var japanese: String?
        /// もともと日本語の区間 (右の列には原文をそのまま出す)
        public var isOriginalJapanese: Bool

        public var id: UUID { segments[0].id }
        /// 原文の言語 (「日本語＋英語」で文字にしたときだけ入る。先頭の区間の言語)
        public var language: String? { segments[0].language }
        public var start: TimeInterval { segments[0].start }
        public var end: TimeInterval { segments[segments.count - 1].end }
        /// 原文 (区間をつないだもの)
        public var text: String { Transcript.join(segments.map(\.text)) }
    }

    /// 対訳の行に分ける (訳がいくつかの区間にまたがるものは 1 行にまとめる)
    public func bilingualUnits() -> [BilingualUnit] {
        var units: [BilingualUnit] = []
        var i = 0
        while i < segments.count {
            let head = segments[i]
            var members = [head]
            i += 1
            if head.translation != nil, let covers = head.translationCovers, !covers.isEmpty {
                let set = Set(covers)
                while i < segments.count, set.contains(segments[i].id) {
                    members.append(segments[i])
                    i += 1
                }
            }
            units.append(bilingualUnit(members))
        }
        return units
    }

    /// 区間 (先頭が訳を持つ区間、続きはその訳に含まれる区間) から、対訳の 1 行を作る
    func bilingualUnit(_ members: [TranscriptSegment]) -> BilingualUnit {
        let head = members[0]
        let needs = needsTranslation(head)
        return BilingualUnit(segments: members,
                             japanese: head.translation ?? (needs ? nil : head.text),
                             isOriginalJapanese: head.translation == nil && !needs)
    }

    /// 区間の文をつなぐ。語を空白で区切らない文字 (漢字・かな・全角の記号) の境目以外には空白を入れる
    /// (英語だけでなく、ロシア語・韓国語・フランス語なども語がくっつかないように)
    public static func join(_ texts: [String]) -> String {
        var out = ""
        for raw in texts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let last = out.unicodeScalars.last, let first = t.unicodeScalars.first,
               !Script.isUnspacedCJK(last) && !Script.isUnspacedCJK(first) {
                out += " "
            }
            out += t
        }
        return out
    }

    /// 区間の訳を消す。文の続きとしてほかの区間の訳に含まれていれば、その訳も消す (文が変わったら訳し直す)
    public mutating func invalidateTranslation(of id: UUID) {
        for i in segments.indices where segments[i].id == id || (segments[i].translationCovers?.contains(id) ?? false) {
            segments[i].translation = nil
            segments[i].translationCovers = nil
        }
    }

    /// 文ごとの訳のまとまりを点検する: まとめた区間が訳の区間のすぐ後ろに順に並んでいない (削除・元に戻す で
    /// あいだに区間が入った、まとめた区間が無くなった、ほかの訳を持っている) ものは、訳を消して訳し直しにする
    public mutating func normalizeTranslationUnits() {
        for i in segments.indices {
            guard let covers = segments[i].translationCovers, !covers.isEmpty else {
                segments[i].translationCovers = nil
                continue
            }
            let following = segments.dropFirst(i + 1).prefix(covers.count)
            let intact = segments[i].translation != nil && following.count == covers.count
                && zip(following, covers).allSatisfy { $0.id == $1 && $0.translation == nil }
            if !intact {
                segments[i].translation = nil
                segments[i].translationCovers = nil
            }
        }
    }
}

/// 区間ごとの言語を、話された時間とともに数える (Transcript.spokenLanguages と、結果の一覧の覚えておく所が使う。
/// 区間を足していけるので、文字起こし中に区間が増えたときは、増えた分だけを数える)
struct LanguageTally: Equatable {
    private var seconds: [String: TimeInterval] = [:]
    /// 出てきた順
    private var order: [String] = []

    mutating func add<S: Sequence>(_ segments: S) where S.Element == TranscriptSegment {
        for s in segments {
            guard let code = s.language else { continue }
            if seconds[code] == nil { order.append(code) }
            seconds[code, default: 0] += s.duration
        }
    }

    /// 話された時間の長い順。同じ長さなら先に出てきた言語を前に (並びを毎回同じにする)
    var ranked: [String] {
        order.enumerated()
            .sorted { a, b in
                let ta = seconds[a.element] ?? 0, tb = seconds[b.element] ?? 0
                return ta != tb ? ta > tb : a.offset < b.offset
            }
            .map(\.element)
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
