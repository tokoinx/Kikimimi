import Foundation

/// 結果の一覧の 1 行 (区間 1 つ、または訳 1 つ分の区間)
public struct TranscriptListItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let japanese: String?
    public let isOriginalJapanese: Bool
    /// この行に当たる監査の直し
    public let changes: [AuditChange]
    /// 原文の言語の印 (英・日)。2 つの言語が混ざる文字起こしのときだけ
    public var languageTag: String?
    /// 行の「訳」を出す (日本語以外で、まだ訳がない)
    public var canTranslate: Bool
    /// 訳がある文の行 (右クリックで訳し直せる)
    public var isTranslated: Bool

    public init(id: UUID, start: TimeInterval, end: TimeInterval, text: String, japanese: String?,
                isOriginalJapanese: Bool, changes: [AuditChange], languageTag: String? = nil,
                canTranslate: Bool = false, isTranslated: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.japanese = japanese
        self.isOriginalJapanese = isOriginalJapanese
        self.changes = changes
        self.languageTag = languageTag
        self.canTranslate = canTranslate
        self.isTranslated = isTranslated
    }
}

/// 行の言語の印
public enum LanguageTag {
    public static func short(_ code: String?) -> String? {
        switch code {
        case "ja": return "日"
        case "en": return "英"
        default: return nil
        }
    }
}

/// 結果の画面で、区間の数だけ手間がかかるもの (翻訳の状況・言語の名前・一覧の行) を覚えておく。
/// 文字起こし・ジョブ・表示の条件が同じなら、前に作ったものを返す
/// (文字起こしの比べは、区間の数が違えばすぐ終わり、同じ配列ならその場で同じとわかる)。
///
/// 文字起こし中は、区間が末尾に増えるたびに (数千行の録音では 1 秒に何度も) 呼ばれる。
/// 前の文字起こしに末尾の区間を足しただけ (同じジョブ・終わっていない・表示の条件も同じ・ほかは何も変わらない) なら、
/// 足した区間の分だけ行と数を足す (前の区間が変わっていないかは、区間をそのまま比べて確かめる。作り直すより軽い)。
/// 行の id は区間の id のままなので、一覧は足した行を差し込むだけになる。
/// それ以外 (やり直し・終わった・監査や訳が入った・検索語や対訳を変えた・2 つめの言語が出て行の印が付く など) と、
/// 迷うときは、すべての区間から作り直す
public final class TranscriptRowCache {
    public struct Summary: Equatable {
        public var stats = Transcript.TranslationStats()
        public var spokenLanguages: [String] = []
        public var languageLabel: String?

        public init(stats: Transcript.TranslationStats = Transcript.TranslationStats(), spokenLanguages: [String] = [],
                    languageLabel: String? = nil) {
            self.stats = stats
            self.spokenLanguages = spokenLanguages
            self.languageLabel = languageLabel
        }
    }

    /// 前に作ったときの条件 (文字起こしのほか)
    private struct Condition: Equatable {
        let job: UUID
        let done: Bool
        var bilingual = false
        var query = ""
    }

    private var summaryCondition: Condition?
    private var summaryBase: Transcript?
    private var summaryTally = LanguageTally()
    private var summaryValue = Summary()

    private var itemsCondition: Condition?
    private var itemsBase: Transcript?
    private var itemsTally = LanguageTally()
    /// 監査の直し (元の区間の id ごと)
    private var itemsChanges: [UUID: AuditChange] = [:]
    /// 行に言語の印を付けている
    private var itemsTags = false
    /// 検索で絞る前の、最後の行の id
    private var itemsLastID: UUID?
    private var itemsValue: [TranscriptListItem] = []

    /// 確かめる用: 前の summary / items で、足した区間の分だけを作ったか (作り直したら false、前のものを返したら変えない)
    public private(set) var lastSummaryWasAppend = false
    public private(set) var lastItemsWasAppend = false

    public init() {}

    /// 翻訳の状況と、話された言語・言語の名前。翻訳の状況は、文字起こしが終わってから数える
    /// (最中は区間が増えるたびに数え直すことになるため)
    public func summary(of transcript: Transcript, job: UUID, done: Bool) -> Summary {
        let condition = Condition(job: job, done: done)
        if condition == summaryCondition, let base = summaryBase {
            if base == transcript { return summaryValue }
            if !done, let added = Self.appended(transcript, to: base) {
                summaryTally.add(added)
                let spoken = summaryTally.ranked
                summaryValue = Summary(spokenLanguages: spoken,
                                       languageLabel: Transcript.languageLabel(spoken: spoken, language: transcript.language))
                summaryBase = transcript
                lastSummaryWasAppend = true
                return summaryValue
            }
        }
        var tally = LanguageTally()
        tally.add(transcript.segments)
        let spoken = tally.ranked
        let stats = done ? transcript.translationStats : Transcript.TranslationStats()
        summaryValue = Summary(stats: stats, spokenLanguages: spoken,
                               languageLabel: Transcript.languageLabel(spoken: spoken, language: transcript.language))
        summaryTally = tally
        summaryBase = transcript
        summaryCondition = condition
        lastSummaryWasAppend = false
        return summaryValue
    }

    /// 一覧に出す行 (対訳表示なら訳ごと、そうでなければ区間ごと)。検索語で絞る
    public func items(of transcript: Transcript, job: UUID, done: Bool, bilingual: Bool, query: String) -> [TranscriptListItem] {
        let condition = Condition(job: job, done: done, bilingual: bilingual, query: query)
        if condition == itemsCondition, let base = itemsBase {
            if base == transcript { return itemsValue }
            if !done, let added = Self.appended(transcript, to: base), appendItems(added, to: transcript, base: base,
                                                                                    condition: condition) {
                lastItemsWasAppend = true
                return itemsValue
            }
        }
        rebuildItems(transcript, condition: condition)
        lastItemsWasAppend = false
        return itemsValue
    }

    // MARK: 作り直す

    private func rebuildItems(_ transcript: Transcript, condition: Condition) {
        let q = condition.query.trimmingCharacters(in: .whitespaces)
        let changes = Dictionary((transcript.audit?.changes ?? []).map { ($0.original.id, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var tally = LanguageTally()
        tally.add(transcript.segments)
        // 「日本語＋英語」で 2 つの言語が混ざるときだけ、行に言語の印 (英・日) を付ける
        let tags = tally.ranked.count >= 2
        // 行の「訳」は、文字起こしが終わってから (訳がある文 = ほかの区間の訳に含まれる区間も、訳がある行として扱う)
        let done = condition.done
        let covered = done ? transcript.coveredIDs : Set<UUID>()
        var items: [TranscriptListItem]
        if condition.bilingual {
            items = transcript.bilingualUnits().map {
                Self.item($0, changes: changes, tags: tags, done: done, covered: covered)
            }
        } else {
            items = transcript.segments.map {
                Self.item($0, in: transcript, changes: changes, tags: tags, done: done, covered: covered)
            }
        }
        itemsLastID = items.last?.id
        if !q.isEmpty { items = items.filter { Self.matches($0, q) } }
        itemsValue = items
        itemsCondition = condition
        itemsBase = transcript
        itemsTally = tally
        itemsChanges = changes
        itemsTags = tags
    }

    // MARK: 末尾に足す

    /// 区間を足しただけなら、足した区間の分の行を足す。足せない (作り直す) なら false (何も変えない)
    private func appendItems(_ added: ArraySlice<TranscriptSegment>, to transcript: Transcript, base: Transcript,
                             condition: Condition) -> Bool {
        if condition.bilingual {
            // 対訳の行は、訳がいくつかの区間にまたがると 1 行にまとまる。足した区間がそれぞれ 1 行になるときだけ
            // (前の最後の区間がそれだけで 1 行で、続きを含む訳を持たない。足した区間も続きを含む訳を持たない)
            guard itemsLastID == base.segments.last?.id else { return false }
            if let last = base.segments.last, Self.joinsFollowing(last) { return false }
            if added.contains(where: Self.joinsFollowing) { return false }
        }
        var tally = itemsTally
        tally.add(added)
        // 2 つめの言語が出た (または消えた): すべての行の印が変わる
        guard (tally.ranked.count >= 2) == itemsTags else { return false }
        let q = condition.query.trimmingCharacters(in: .whitespaces)
        let covered = Set<UUID>()
        var items: [TranscriptListItem]
        if condition.bilingual {
            items = added.map {
                Self.item(transcript.bilingualUnit([$0]), changes: itemsChanges, tags: itemsTags, done: false, covered: covered)
            }
        } else {
            items = added.map {
                Self.item($0, in: transcript, changes: itemsChanges, tags: itemsTags, done: false, covered: covered)
            }
        }
        if let last = items.last { itemsLastID = last.id }
        if !q.isEmpty { items = items.filter { Self.matches($0, q) } }
        itemsValue.append(contentsOf: items)
        itemsBase = transcript
        itemsTally = tally
        return true
    }

    /// 訳がこの区間の後ろの区間も含む (対訳では、後ろの区間と 1 行になる)
    private static func joinsFollowing(_ segment: TranscriptSegment) -> Bool {
        segment.translation != nil && !(segment.translationCovers ?? []).isEmpty
    }

    /// new が base の末尾に区間を足しただけなら、足した区間 (1 つ以上)。ほかが少しでも違えば nil
    static func appended(_ new: Transcript, to base: Transcript) -> ArraySlice<TranscriptSegment>? {
        let count = base.segments.count
        guard new.segments.count > count,
              new.sourceName == base.sourceName, new.language == base.language, new.model == base.model,
              new.duration == base.duration, new.elapsed == base.elapsed, new.audit == base.audit,
              new.translationModel == base.translationModel,
              new.segments[..<count].elementsEqual(base.segments) else { return nil }
        return new.segments[count...]
    }

    // MARK: 行を作る (作り直すときも、足すときも、ここで作る)

    private static func item(_ seg: TranscriptSegment, in transcript: Transcript, changes: [UUID: AuditChange], tags: Bool,
                             done: Bool, covered: Set<UUID>) -> TranscriptListItem {
        let translated = seg.translation != nil || covered.contains(seg.id)
        return TranscriptListItem(id: seg.id, start: seg.start, end: seg.end, text: seg.text,
                                  japanese: nil, isOriginalJapanese: false, changes: changes[seg.id].map { [$0] } ?? [],
                                  languageTag: tags ? LanguageTag.short(seg.language) : nil,
                                  canTranslate: done && !translated && transcript.needsTranslation(seg),
                                  isTranslated: done && translated)
    }

    private static func item(_ unit: Transcript.BilingualUnit, changes: [UUID: AuditChange], tags: Bool, done: Bool,
                             covered: Set<UUID>) -> TranscriptListItem {
        let translated = unit.segments[0].translation != nil
        return TranscriptListItem(id: unit.id, start: unit.start, end: unit.end, text: unit.text,
                                  japanese: unit.japanese, isOriginalJapanese: unit.isOriginalJapanese,
                                  changes: unit.segments.compactMap { changes[$0.id] },
                                  languageTag: tags ? LanguageTag.short(unit.language) : nil,
                                  canTranslate: done && unit.japanese == nil && !covered.contains(unit.id),
                                  isTranslated: done && translated)
    }

    /// 検索語 (前後の空白を除いたもの) を含む行か
    private static func matches(_ item: TranscriptListItem, _ q: String) -> Bool {
        item.text.localizedCaseInsensitiveContains(q) || (item.japanese?.localizedCaseInsensitiveContains(q) ?? false)
    }
}
