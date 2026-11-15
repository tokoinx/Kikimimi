import Foundation

/// 訳の覚え 1 つ: 対訳の 1 行 (訳のまとまり 1 つ) の訳について、覚えておく事。
///
/// 覚えは区間に持たせず、結果 (`Transcript.translationReview`) にまとめて置く。
/// 覚えた時の原文と訳を `signature` に残し、今の原文・訳と合わない覚えは、無い物と扱う
/// (訳を外す・戻す所 (監査の直し・削除・元に戻す など) を、全部は直さずに済ませるため)。
public struct TranslationNote: Codable, Hashable, Sendable {
    /// 訳のまとまりの先頭の区間 (訳を持つ区間)
    public var head: UUID
    /// 覚えた時の原文と訳 (原文 + U+0001 + 訳)。`Transcript.reviewSignature(source:translation:)` で作る
    public var signature: String
    /// 印の理由の符号 (今は使わない。後で、訳の関門の印を入れる)
    public var flags: [String]
    /// 印の説明 (今は使わない)
    public var detail: String?
    /// 訳の出どころの符号 ("edited" = 利用者が直した。後で "llm"・"memory"・"confirmed" が増える)。
    /// 知らない符号でも全体が読めるよう、enum にしない
    public var origin: String
    /// 利用者が直す前の機械の訳 (訳が無い行に、利用者が自分で書いた時は nil)
    public var machine: String?

    /// 利用者が直した訳の符号
    public static let edited = "edited"

    public init(head: UUID, signature: String, flags: [String] = [], detail: String? = nil, origin: String,
                machine: String? = nil) {
        self.head = head
        self.signature = signature
        self.flags = flags
        self.detail = detail
        self.origin = origin
        self.machine = machine
    }

    enum CodingKeys: String, CodingKey {
        case head, signature, flags, detail, origin, machine
    }

    /// 欠けている項目は補って読む (印の理由が無い・出どころが無い覚えも読める)
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        head = try c.decode(UUID.self, forKey: .head)
        signature = try c.decode(String.self, forKey: .signature)
        flags = (try? c.decodeIfPresent([String].self, forKey: .flags)) ?? []
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        origin = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? ""
        machine = try? c.decodeIfPresent(String.self, forKey: .machine)
    }

    /// 利用者が直した訳の覚えか
    public var isEdited: Bool { origin == Self.edited }
}

extension Transcript {
    /// 覚えの signature を作る (原文 + U+0001 + 訳)
    public static func reviewSignature(source: String, translation: String) -> String {
        source + "\u{1}" + translation
    }

    /// 区間 head の訳のまとまりの原文 (head と、その訳に含めた区間の文をつないだ物)。head が無ければ nil
    public func translationSource(ofHead head: UUID) -> String? {
        guard let index = segments.firstIndex(where: { $0.id == head }) else { return nil }
        return translationSource(at: index)
    }

    /// 位置 index の区間の訳のまとまりの原文
    func translationSource(at index: Int) -> String {
        let covers = segments[index].translationCovers ?? []
        var texts = [segments[index].text]
        let following = segments.dropFirst(index + 1).prefix(covers.count)
        if following.count == covers.count, zip(following, covers).allSatisfy({ $0.id == $1 }) {
            texts += following.map(\.text)
        } else {
            // ふつうは、まとめた区間はすぐ後ろに並ぶ (normalizeTranslationUnits)。並んでいない時だけ探す
            texts += covers.compactMap { id in segments.first { $0.id == id }?.text }
        }
        return Transcript.join(texts)
    }

    /// 位置 index の区間 (訳を持つ区間) に対して、覚えが今も合うか
    func noteMatches(_ note: TranslationNote, at index: Int) -> Bool {
        guard segments[index].id == note.head, let translation = segments[index].translation else { return false }
        return note.signature == Self.reviewSignature(source: translationSource(at: index), translation: translation)
    }

    /// 区間 head の今の覚え (原文と訳が、覚えた時と同じ物だけ)。無ければ nil
    public func translationNote(for head: UUID) -> TranslationNote? {
        guard let notes = translationReview, !notes.isEmpty,
              let index = segments.firstIndex(where: { $0.id == head }) else { return nil }
        return notes.last { $0.head == head && noteMatches($0, at: index) }
    }

    /// 今も合う覚え (先頭の区間の id ごと)。覚えが無ければ、区間を見ずに空を返す
    public var validTranslationNotes: [UUID: TranslationNote] {
        guard let notes = translationReview, !notes.isEmpty else { return [:] }
        let heads = Set(notes.map(\.head))
        var out: [UUID: TranslationNote] = [:]
        for index in segments.indices where heads.contains(segments[index].id) {
            if let note = notes.last(where: { $0.head == segments[index].id && noteMatches($0, at: index) }) {
                out[note.head] = note
            }
        }
        return out
    }

    /// 利用者が直した訳が守っている区間 (今も合う "edited" の覚えの、まとまりの区間すべて)。
    /// 機械の訳は、ここに当たるまとまりに置かない (`apply(_:sources:)`)
    public var userTranslatedIDs: Set<UUID> {
        guard let notes = translationReview, notes.contains(where: \.isEdited) else { return [] }
        var ids = Set<UUID>()
        for note in notes where note.isEdited {
            guard let index = segments.firstIndex(where: { $0.id == note.head }), noteMatches(note, at: index) else { continue }
            ids.insert(note.head)
            ids.formUnion(segments[index].translationCovers ?? [])
        }
        return ids
    }

    /// 利用者の訳を置く (対訳の行の「訳を直す…」)。id は、その行のどの区間でもよい (その区間を含む訳のまとまりに置く)。
    /// まとまりの区切り (どの区間を含めるか) は変えない。訳は前後の空白を外し、改行は空白にする。
    /// 置いたら、その覚えを返す。何もしなかった (区間が無い・空の訳・今の訳と同じ) 時は nil。
    /// 直した訳を、直す前の機械の訳と同じに戻した時は、機械の訳に戻す (覚えを捨てる) ので nil
    @discardableResult
    public mutating func setUserTranslation(_ text: String, for id: UUID) -> TranslationNote? {
        let cleaned = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let head = Translator.translationGroupIDs(of: id, in: segments).first,
              let index = segments.firstIndex(where: { $0.id == head }) else { return nil }
        let existing = translationNote(for: head)
        let current = segments[index].translation
        if let existing, existing.isEdited {
            if cleaned == existing.machine {
                revertUserTranslation(of: head)
                return nil
            }
            if cleaned == current { return nil }
        } else if cleaned == current {
            return nil
        }
        // 直す前の機械の訳: もう直してあれば、初めに直した時の機械の訳を残す
        let machine = existing?.isEdited == true ? existing?.machine : current
        segments[index].translation = cleaned
        let note = TranslationNote(head: head,
                                   signature: Self.reviewSignature(source: translationSource(at: index), translation: cleaned),
                                   origin: TranslationNote.edited, machine: machine)
        var notes = (translationReview ?? []).filter { $0.head != head }
        notes.append(note)
        translationReview = notes
        pruneTranslationReview()
        return note
    }

    /// 利用者が直した訳を、機械の訳に戻す (直す前に機械の訳が無かった行は、訳を外す)。
    /// 戻したら、捨てた覚えを返す。直した訳でなければ nil (何も変えない)
    @discardableResult
    public mutating func revertUserTranslation(of id: UUID) -> TranslationNote? {
        guard let head = Translator.translationGroupIDs(of: id, in: segments).first,
              let index = segments.firstIndex(where: { $0.id == head }),
              let note = translationNote(for: head), note.isEdited else { return nil }
        segments[index].translation = note.machine
        if note.machine == nil { segments[index].translationCovers = nil }
        translationReview = (translationReview ?? []).filter { $0.head != head }
        pruneTranslationReview()
        return note
    }

    /// 区間 ids を含む訳のまとまりの、利用者の訳の覚えを捨てる (利用者が自分で「この文を訳し直す」を押した時)。
    /// 訳そのものは残す (訳し終えるまで、画面には前の訳を出す)。捨てたら true
    @discardableResult
    public mutating func dropUserTranslations(touching ids: Set<UUID>) -> Bool {
        guard let notes = translationReview, !notes.isEmpty, !ids.isEmpty else { return false }
        var dropped = Set<UUID>()
        for note in notes where note.isEdited {
            guard let index = segments.firstIndex(where: { $0.id == note.head }) else { continue }
            let group = [note.head] + (segments[index].translationCovers ?? [])
            if group.contains(where: ids.contains) { dropped.insert(note.head) }
        }
        guard !dropped.isEmpty else { return false }
        let kept = notes.filter { !($0.isEdited && dropped.contains($0.head)) }
        translationReview = kept.isEmpty ? nil : kept
        return true
    }

    /// 今の原文・訳と合わなくなった覚えを捨てる (覚えが空になったら nil にする)
    public mutating func pruneTranslationReview() {
        guard let notes = translationReview else { return }
        let valid = validTranslationNotes
        let kept = notes.filter { valid[$0.head] == $0 }
        translationReview = kept.isEmpty ? nil : kept
    }
}
