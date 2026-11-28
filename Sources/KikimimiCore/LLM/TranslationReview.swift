import Foundation

/// 訳の覚え 1 つ: 対訳の 1 行 (訳のまとまり 1 つ) の訳について、覚えておく事。
///
/// 覚えは区間に持たせず、結果 (`Transcript.translationReview`) にまとめて置く。
/// 覚えた時の原文と訳を `signature` に残し、今の原文・訳と合わない覚えは、無い物と扱う
/// (訳を外す・戻す所 (監査の直し・削除・元に戻す など) を、全部は直さずに済ませるため)。
public struct TranslationNote: Codable, Hashable, Sendable {
    /// 訳のまとまりの先頭の区間 (訳を持つ区間)
    public var head: UUID
    /// 覚えた時の原文と訳 (原文 + U+0001 + 訳)。`Transcript.reviewSignature(source:translation:)` で作る。
    /// 訳せなかった行の覚えは、訳を空にして作る (原文 + U+0001)。後から訳が入れば合わなくなり、無い物になる
    public var signature: String
    /// 訳の関門 (`TranslationGate`) の印の符号。"llm" なら、要確認の理由 (訳の無い行なら、訳せなかった理由)。
    /// "confirmed"・"edited" でも残す (後で、検査の誤り・当たりの数を数えるため)
    public var flags: [String]
    /// 印の説明 (消えた数など。`TranslationGate.Finding.detail`)
    public var detail: String?
    /// 訳の出どころの符号 ("edited" = 利用者が直した、"memory" = 訳の記憶から置いた、
    /// "llm" = 関門の印が付いた機械の訳・訳せなかった行、"confirmed" = 印の付いた訳を、利用者が「この訳でよい」とした)。
    /// 知らない符号でも全体が読めるよう、enum にしない
    public var origin: String
    /// 利用者が直す前の機械の訳 (訳が無い行に、利用者が自分で書いた時・記憶から置いた時は nil)
    public var machine: String?
    /// 訳の関門の判定の数 (`TranslationMemory.gate`) に、この訳で足した判定 ("confirmed" か "edited")。
    /// 足していなければ nil。同じ訳に 2 度足さないため、また「機械の訳に戻す」で足した分を引くために持つ
    public var vote: String?

    /// 利用者が直した訳の符号
    public static let edited = "edited"
    /// 訳の記憶 (前に利用者が直した同じ文の訳) から、LLM を呼ばずに置いた訳の符号。
    /// 機械の訳の上書きからは守らない (守るのは "edited" だけ)
    public static let memory = "memory"
    /// 関門の印が付いた機械の訳 (または、訳せなかった行の理由) の符号。機械の訳の上書きからは守らない
    public static let llm = "llm"
    /// 印の付いた訳を、利用者が「この訳でよい」とした符号。印は出さない。機械の訳の上書きからは守らない
    public static let confirmed = "confirmed"

    public init(head: UUID, signature: String, flags: [String] = [], detail: String? = nil, origin: String,
                machine: String? = nil, vote: String? = nil) {
        self.head = head
        self.signature = signature
        self.flags = flags
        self.detail = detail
        self.origin = origin
        self.machine = machine
        self.vote = vote
    }

    enum CodingKeys: String, CodingKey {
        case head, signature, flags, detail, origin, machine, vote
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
        vote = try? c.decodeIfPresent(String.self, forKey: .vote)
    }

    /// 利用者が直した訳の覚えか
    public var isEdited: Bool { origin == Self.edited }

    /// 訳の記憶から置いた訳の覚えか
    public var isRemembered: Bool { origin == Self.memory }

    /// 関門の印が付いた、機械の訳 (または訳せなかった行) の覚えか。訳の在る行なら「要確認」
    public var isFlagged: Bool { origin == Self.llm && !flags.isEmpty }

    /// 利用者が「この訳でよい」とした覚えか
    public var isConfirmed: Bool { origin == Self.confirmed }
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

    /// 位置 index の区間 (訳を持つ区間) に対して、覚えが今も合うか。
    /// 訳の無い区間は、訳を空として比べる (訳せなかった行の理由の覚えだけが合う)
    func noteMatches(_ note: TranslationNote, at index: Int) -> Bool {
        guard segments[index].id == note.head else { return false }
        return note.signature == Self.reviewSignature(source: translationSource(at: index),
                                                      translation: segments[index].translation ?? "")
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
        // 関門の印 (と説明) は残す: 後で「検査が当たった数」を数えるため (印の出し方は "edited" のまま)。
        // 判定の印 (vote): 印の付いた機械の訳 ("llm") をまだ数えずに直した時は "edited" (呼ぶ側が数を足す)。
        // ほか (もう直してある・「この訳でよい」の後に直した) は、前の覚えの物をそのまま持つ
        let vote = existing?.isFlagged == true && existing?.vote == nil ? TranslationNote.edited : existing?.vote
        let note = TranslationNote(head: head,
                                   signature: Self.reviewSignature(source: translationSource(at: index), translation: cleaned),
                                   flags: existing?.flags ?? [], detail: existing?.detail,
                                   origin: TranslationNote.edited, machine: machine, vote: vote)
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
        var notes = (translationReview ?? []).filter { $0.head != head }
        // 印の付いた機械の訳を直していた時は、戻した機械の訳に「要確認」の印を戻す。
        // 直して足した判定 ("edited") は、呼ぶ側が引くので外す。「この訳でよい」で足した判定は残す (2 度足さない)
        if let machine = note.machine, !note.flags.isEmpty {
            notes.append(TranslationNote(head: head,
                                         signature: Self.reviewSignature(source: translationSource(at: index),
                                                                         translation: machine),
                                         flags: note.flags, detail: note.detail, origin: TranslationNote.llm,
                                         vote: note.vote == TranslationNote.edited ? nil : note.vote))
        }
        translationReview = notes
        pruneTranslationReview()
        return note
    }

    /// 印の付いた機械の訳を「この訳でよい」とする (覚えの出どころを "confirmed" に変える。印と説明は残す)。
    /// まだ判定を数えていない訳なら、判定の印 (vote) を "confirmed" にする (返した覚えの vote を見て、呼ぶ側が数を足す。
    /// 前から vote が在る覚えは、そのまま)。
    /// id は、その行のどの区間でもよい。変えたら、その覚えを返す。印の付いた訳でなければ nil (何も変えない)
    @discardableResult
    public mutating func confirmTranslation(of id: UUID) -> TranslationNote? {
        guard let head = Translator.translationGroupIDs(of: id, in: segments).first,
              let index = segments.firstIndex(where: { $0.id == head }), segments[index].translation != nil,
              var note = translationNote(for: head), note.isFlagged else { return nil }
        note.origin = TranslationNote.confirmed
        if note.vote == nil { note.vote = TranslationNote.confirmed }
        var notes = (translationReview ?? []).filter { $0.head != head }
        notes.append(note)
        translationReview = notes
        return note
    }

    /// 「要確認」の行の数 (訳の在る行で、今も合う "llm" の印の覚え)
    public var flaggedTranslationCount: Int {
        let valid = validTranslationNotes
        guard !valid.isEmpty else { return 0 }
        return segments.reduce(0) { $0 + ($1.translation != nil && valid[$1.id]?.isFlagged == true ? 1 : 0) }
    }

    /// 区間 ids を含む訳のまとまりの、利用者の訳の覚えを捨てる (利用者が自分で「この文を訳し直す」を押した時)。
    /// 訳そのものは残す (訳し終えるまで、画面には前の訳を出す)。捨てたら true
    @discardableResult
    public mutating func dropUserTranslations(touching ids: Set<UUID>) -> Bool {
        guard let notes = translationReview else { return false }
        let dropped = Set(userTranslationNotes(touching: ids).map(\.head))
        guard !dropped.isEmpty else { return false }
        let kept = notes.filter { !($0.isEdited && dropped.contains($0.head)) }
        translationReview = kept.isEmpty ? nil : kept
        return true
    }

    /// 区間 ids を含む訳のまとまりの、利用者が直した訳の覚え ("edited")。
    /// 「この文を訳し直す」を押した時に写しておき、訳し直した結果を置く時に `applyRedone(_:sources:replacing:)` へ渡す
    public func userTranslationNotes(touching ids: Set<UUID>) -> [TranslationNote] {
        guard let notes = translationReview, !notes.isEmpty, !ids.isEmpty else { return [] }
        return notes.filter { note in
            guard note.isEdited, let index = segments.firstIndex(where: { $0.id == note.head }) else { return false }
            return ([note.head] + (segments[index].translationCovers ?? [])).contains(where: ids.contains)
        }
    }

    /// 利用者が自分で「この文を訳し直す」を押した文に、訳し直した結果を 1 つ置く。
    /// edited は、押した時に写した、その文の直した訳の覚え (`userTranslationNotes(touching:)`)。
    /// 機械の訳を置ける時だけ、その結果のまとまりに当たる覚えを捨ててから置く (直した訳が機械の訳になり、印「直した」も消える)。
    /// 訳せなかった結果 (理由だけの結果) の時と、置けなかった時は、訳も覚えも変えない (直した訳と印「直した」が残る)。
    /// 押した後に利用者がもう 1 度直した訳は、覚えが写しと違うので捨てない (その訳を守る)。
    /// edited が空なら `apply(_:sources:)` と同じ。置いたら true
    @discardableResult
    public mutating func applyRedone(_ result: TranslationResult, sources: [UUID: String],
                                     replacing edited: [TranslationNote]) -> Bool {
        guard !result.isRejection, !edited.isEmpty, let notes = translationReview else {
            return apply(result, sources: sources)
        }
        let ids = Set([result.head] + result.covers)
        // 写した覚えのうち、この結果のまとまりに当たる物 (今の区間で見る)
        let touching = edited.filter { note in
            guard let index = segments.firstIndex(where: { $0.id == note.head }) else { return false }
            return ([note.head] + (segments[index].translationCovers ?? [])).contains(where: ids.contains)
        }
        let kept = notes.filter { !touching.contains($0) }
        guard kept.count < notes.count else { return apply(result, sources: sources) }
        translationReview = kept.isEmpty ? nil : kept
        if apply(result, sources: sources) { return true }
        // 置けなかった: 捨てた覚えを戻す
        translationReview = notes
        return false
    }

    /// 今の原文・訳と合わなくなった覚えを捨てる (覚えが空になったら nil にする)
    public mutating func pruneTranslationReview() {
        guard let notes = translationReview else { return }
        let valid = validTranslationNotes
        let kept = notes.filter { valid[$0.head] == $0 }
        translationReview = kept.isEmpty ? nil : kept
    }
}

extension TranslationNote {
    /// 印の理由を、画面の言語の文にした物 (印の符号の順に 1 つずつ)。知らない符号は出さない。
    /// 数の抜けは、説明 (`detail` の "number: …") の数を、訳語の抜けは "term: …" の「X → Y」を文に入れる
    public var reasonTexts: [String] {
        flags.compactMap { Self.reasonText($0, detail: detail) }
    }

    /// 印の符号 1 つの理由の文 (知らない符号は nil)
    public static func reasonText(_ flag: String, detail: String?) -> String? {
        switch flag {
        case TranslationGate.language: return L("The translation may not be in the target language.")
        case TranslationGate.number:
            let numbers = detailPart(TranslationGate.number, in: detail) ?? ""
            return L("A number from the original is missing: %@", numbers)
        case TranslationGate.term:
            let terms = detailPart(TranslationGate.term, in: detail) ?? ""
            return L("Your term is not in the translation: %@", terms)
        case TranslationGate.copied: return L("The translation is the same as the original.")
        case TranslationGate.repeated: return L("The same words repeat many times.")
        case TranslationGate.short: return L("The translation is much shorter than the original. Part of it may be missing.")
        case TranslationGate.script: return L("The translation used the wrong kind of letters, so it was not used.")
        case TranslationGate.long: return L("The translation was far too long, so it was not used.")
        case TranslationGate.failed: return L("The model returned no translation for this line.")
        default: return nil
        }
    }

    /// 説明 ("number: 4000, 15; term: Roblox") から、符号 flag の部分 ("4000, 15") を取り出す。無ければ nil
    static func detailPart(_ flag: String, in detail: String?) -> String? {
        guard let detail else { return nil }
        let prefix = flag + ": "
        for part in detail.components(separatedBy: "; ") where part.hasPrefix(prefix) {
            return String(part.dropFirst(prefix.count))
        }
        return nil
    }
}
