import Foundation

/// 利用者が手で直した、聞き取った文の記録 (行の右クリックの「この行を直す…」)。
/// 区間には項目を足さず、結果 (`Transcript.lineEdits`) に置く。
/// 記録は、同じ id の区間が在り、その文が `edited` と同じ時だけ有効。合わない記録は無い物と扱い、
/// 次に書く時に取り除く (訳の覚えの `signature` と同じ考え方)
public struct LineEdit: Codable, Hashable, Sendable {
    /// 直した区間の id
    public var segmentID: UUID
    /// 聞き取った文 (利用者が最初に直す前の文。反映していた監査の直しが在れば、監査の前の文)
    public var heard: String
    /// 利用者が直した文 (整えた後の物)
    public var edited: String
    /// 直した時
    public var date: Date
    /// この直しで、学習した直しの台帳に 1 回分覚えさせた組 (覚えていなければ nil。この項目の無い古い記録も nil で読める)
    public var learned: AuditChange.Pair?

    public init(segmentID: UUID, heard: String, edited: String, date: Date = Date(), learned: AuditChange.Pair? = nil) {
        self.segmentID = segmentID
        self.heard = heard
        self.edited = edited
        self.date = date
        self.learned = learned
    }

    /// 直した文を整える: 改行とタブは空白 1 つに、ほかの制御文字は消す、続く空白は 1 つに、前後の空白を除く。
    /// 1 つだけの空白は、その字のまま残す (日本語の全角の空白を、半角に変えないように)
    public static func normalized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        // 今の空白の続き (1 つ目の字と、続いた数)
        var pending: Unicode.Scalar?
        var run = 0
        func flush() {
            if let space = pending {
                out.append(run > 1 ? " " : space)
            }
            pending = nil
            run = 0
        }
        for scalar in text.unicodeScalars {
            let s: Unicode.Scalar
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" {
                s = " "
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                s = scalar
            }
            if CharacterSet.whitespaces.contains(s) {
                if pending == nil { pending = s }
                run += 1
            } else {
                flush()
                out.append(s)
            }
        }
        flush()
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Transcript {
    /// 区間 id の、今も有効な直しの記録 (区間が在り、文が直した文と同じ物だけ)。無ければ nil
    public func lineEdit(forSegment id: UUID) -> LineEdit? {
        guard let edits = lineEdits, !edits.isEmpty,
              let edit = edits.last(where: { $0.segmentID == id }),
              let segment = segments.first(where: { $0.id == id }), segment.text == edit.edited else { return nil }
        return edit
    }

    /// 今も有効な直しの記録 (区間の id ごと)。記録が無ければ、区間を見ずに空を返す
    /// (結果の一覧の覚えておく所と、監査の結果を受け取る所が使う)
    public var validLineEdits: [UUID: LineEdit] {
        guard let edits = lineEdits, !edits.isEmpty else { return [:] }
        var latest: [UUID: LineEdit] = [:]
        for edit in edits { latest[edit.segmentID] = edit }
        var out: [UUID: LineEdit] = [:]
        for segment in segments {
            if let edit = latest[segment.id], edit.edited == segment.text { out[segment.id] = edit }
        }
        return out
    }

    /// 区間 id の文を、利用者の文 text に直す (整えてから)。何か変えたら true。
    /// 空の文・区間が無い・今の文と同じ時は、何もせず false。
    /// 聞き取った文は、最初に直した時の物を残す (反映していた監査の直しが在れば、監査の前の文)。
    /// その区間に当たる監査の直し・提案は、監査の結果から取り除く (利用者の直しが、監査の案より優先。
    /// 文は利用者の文で上書きするので、元には戻さない)。利用者の決定 (`userDecisions`) は変えない。
    /// 聞き取った文と同じに直した時は「元に戻した」のと同じ (記録を取り除く)。
    /// 文が変わったので、その区間を含む訳は消す (監査の直しを反映した時と同じ。訳し直すのは利用者)
    /// 覚えた組 (`LineEdit.learned`) は、前の記録の物をそのまま引き継ぐ
    @discardableResult
    public mutating func setLineText(_ text: String, forSegment id: UUID, date: Date = Date()) -> Bool {
        setLineText(text, forSegment: id, learned: .keep, date: date)
    }

    /// `setLineText(_:forSegment:date:)` と同じ。覚えた組を learned に置き換える (nil なら、覚えていない記録にする)
    @discardableResult
    public mutating func setLineText(_ text: String, forSegment id: UUID, learned: AuditChange.Pair?,
                                     date: Date = Date()) -> Bool {
        setLineText(text, forSegment: id, learned: .set(learned), date: date)
    }

    /// 覚えた組をどうするか (前の記録の物を引き継ぐ / 置き換える)
    enum LearnedChoice {
        case keep
        case set(AuditChange.Pair?)
    }

    private mutating func setLineText(_ text: String, forSegment id: UUID, learned choice: LearnedChoice, date: Date) -> Bool {
        let cleaned = LineEdit.normalized(text)
        guard !cleaned.isEmpty, let index = segments.firstIndex(where: { $0.id == id }) else { return false }
        let current = segments[index].text
        guard cleaned != LineEdit.normalized(current) else { return false }
        let heard: String
        let existing = lineEdit(forSegment: id)
        let learned: AuditChange.Pair?
        switch choice {
        case .keep: learned = existing?.learned
        case .set(let pair): learned = pair
        }
        if let existing {
            heard = existing.heard
        } else if let fix = audit?.changes.first(where: { $0.original.id == id && $0.kind == .fix && $0.isApplied }) {
            heard = fix.original.text
        } else {
            heard = current
        }
        // 監査の直し・提案を取り除く (反映済みでも、要確認でも、fix でも delete でも)
        if var report = audit, report.changes.contains(where: { $0.original.id == id }) {
            report.changes.removeAll { $0.original.id == id }
            audit = report
        }
        // 文を書き換える前に、その区間を含む訳を消す (文の続きとして含めていた訳も)
        invalidateTranslation(of: id)
        var edits = (lineEdits ?? []).filter { $0.segmentID != id }
        if cleaned == LineEdit.normalized(heard) {
            segments[index].text = heard
        } else {
            segments[index].text = cleaned
            edits.append(LineEdit(segmentID: id, heard: heard, edited: cleaned, date: date, learned: learned))
        }
        normalizeTranslationUnits()
        lineEdits = edits
        pruneLineEdits()
        return true
    }

    /// 直した文はそのままで、覚えた組だけを置き換える (直す画面で、文は変えずに「この直しを覚える」だけを変えた時)。
    /// 有効な直しが無い・同じ組の時は false
    @discardableResult
    public mutating func setLineLearned(_ learned: AuditChange.Pair?, forSegment id: UUID) -> Bool {
        guard var edit = lineEdit(forSegment: id), edit.learned != learned,
              var edits = lineEdits, let i = edits.lastIndex(where: { $0.segmentID == id }) else { return false }
        edit.learned = learned
        edits[i] = edit
        lineEdits = edits
        return true
    }

    /// 区間 id の直しを元に戻す (文を聞き取った文に戻し、記録を取り除く)。有効な直しが無ければ false
    @discardableResult
    public mutating func revertLineEdit(forSegment id: UUID) -> Bool {
        guard let edit = lineEdit(forSegment: id), let index = segments.firstIndex(where: { $0.id == id }) else { return false }
        invalidateTranslation(of: id)
        segments[index].text = edit.heard
        lineEdits = (lineEdits ?? []).filter { $0.segmentID != id }
        normalizeTranslationUnits()
        pruneLineEdits()
        return true
    }

    /// 今の文と合わなくなった記録を捨てる (記録が空になったら nil にする)
    public mutating func pruneLineEdits() {
        guard let edits = lineEdits else { return }
        let valid = validLineEdits
        let kept = edits.filter { valid[$0.segmentID] == $0 }
        lineEdits = kept.isEmpty ? nil : kept
    }
}

// MARK: 学習した直しの台帳に覚えさせる組

extension LineEdit {
    /// 組の語の長さの上限 (これより長い所を書き換えた時は、語の直しではなく、文の書き換えとみなす)
    public static let pairMaxLength = 40

    /// 聞き取った文と直した文から、「聞き間違えた語 → 正しい語」の組を切り出す。切り出せなければ nil。
    /// 1. 2 つの文を整え、同じなら nil。
    /// 2. 頭と尻の同じ字の並びを除いて、違う所を出す。
    /// 3. 違う所を、聞き取った文の語の切れ目まで左右に広げる (広げるのは 2 つの文に共通の字だけなので、
    ///    聞き取った文の中の wrong を right に置き換えると、直した文になる)。
    /// 4. 広げた後の wrong が 2 字に満たなければ、右隣の語 1 つ分まで広げる (右に無ければ左)。
    /// 5. 端の空白と句読点は、両方の端が同じ字の時だけ、両方から落とす。
    /// 6. どちらかが空・40 字を超える・同じ、の時は nil
    public static func suggestedPair(heard: String, edited: String) -> AuditChange.Pair? {
        guard let span = suggestedSpan(heard: heard, edited: edited) else { return nil }
        return span.pair
    }

    /// 切り出した組と、聞き取った文の中の場所 (字の数で数えた位置)。試験が、置き換えると直した文になる事を見るのに使う
    struct PairSpan {
        var pair: AuditChange.Pair
        /// 整えた聞き取った文の中の、wrong の場所
        var range: Range<Int>
    }

    static func suggestedSpan(heard: String, edited: String) -> PairSpan? {
        let h = normalized(heard), e = normalized(edited)
        guard h != e, !h.isEmpty, !e.isEmpty else { return nil }
        let H = Array(h), E = Array(e)
        var prefix = 0
        while prefix < H.count, prefix < E.count, H[prefix] == E[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(H.count, E.count) - prefix, H[H.count - 1 - suffix] == E[E.count - 1 - suffix] { suffix += 1 }
        // 聞き取った文の語の場所 (字の数で数えた、始まりと終わり)
        let words = wordRanges(h)
        var boundaries = Set<Int>([0, H.count])
        for w in words {
            boundaries.insert(w.lowerBound)
            boundaries.insert(w.upperBound)
        }
        // 聞き取った文の中の、違う所 [a, b)。広げた分 (left・right) は、直した文の側も同じだけ広げる
        var a = prefix
        var b = H.count - suffix
        // 語の切れ目に文を足しただけ・消しただけの直しは、語の聞き間違いではない (組にしない)
        if a == b && boundaries.contains(a) { return nil }
        if prefix == E.count - suffix && boundaries.contains(a) && boundaries.contains(b) { return nil }
        while !boundaries.contains(a) { a -= 1 }
        while !boundaries.contains(b) { b += 1 }
        if letterCount(String(H[a..<b])) < 2 {
            if let next = words.first(where: { $0.lowerBound >= b && $0.upperBound > b }) {
                b = next.upperBound
            } else if let previous = words.last(where: { $0.upperBound <= a && $0.lowerBound < a }) {
                a = previous.lowerBound
            }
        }
        var left = prefix - a
        var right = b - (H.count - suffix)
        var wrong = Array(H[a..<b])
        var fixed = Array(E[(prefix - left)..<(E.count - suffix + right)])
        // 端の空白と句読点は、両方の端が同じ字なら落とす (同じ字なので、置き換えると直した文になる事は変わらない)
        func isEdge(_ c: Character) -> Bool { c.isWhitespace || c.isPunctuation }
        while let w = wrong.first, let r = fixed.first, w == r, isEdge(w) {
            wrong.removeFirst()
            fixed.removeFirst()
            left -= 1
            a += 1
        }
        while let w = wrong.last, let r = fixed.last, w == r, isEdge(w) {
            wrong.removeLast()
            fixed.removeLast()
            right -= 1
            b -= 1
        }
        let w = String(wrong), r = String(fixed)
        guard !w.isEmpty, !r.isEmpty, w != r,
              w.trimmingCharacters(in: .whitespacesAndNewlines) == w, r.trimmingCharacters(in: .whitespacesAndNewlines) == r,
              wrong.count <= pairMaxLength, fixed.count <= pairMaxLength else { return nil }
        return PairSpan(pair: AuditChange.Pair(wrong: w, right: r), range: a..<b)
    }

    /// 空白と句読点を除いた字の数 (組の語が短すぎないかを見るのに使う。直す画面の「覚える」の初めの値も、これで決める)
    public static func letterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
    }

    /// 文の語の場所 (字の数で数えた範囲。Foundation の語の分け方。日本語も辞書で分ける)
    static func wordRanges(_ text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            out.append(start..<end)
        }
        return out
    }

    /// 台帳に何をするか: 取り消す組と、覚える組
    public struct LedgerUpdate: Equatable, Sendable {
        /// 前に 1 回分覚えさせた組 (取り消す。`CorrectionLedger.retract`)
        public var retract: AuditChange.Pair?
        /// 今回覚えさせる組 (`CorrectionLedger.record(… accepted: true)`)
        public var record: AuditChange.Pair?

        public init(retract: AuditChange.Pair? = nil, record: AuditChange.Pair? = nil) {
            self.retract = retract
            self.record = record
        }

        public var isEmpty: Bool { retract == nil && record == nil }
    }

    /// 前に覚えさせた組 old と、今回の組 new (覚えない時・直しを戻した時は nil) から、台帳に何をするかを決める。
    /// 同じ組なら何もしない (同じ行を直し直しても、回数が増えない)。違えば、old を取り消し、new を覚える
    public static func ledgerUpdate(old: AuditChange.Pair?, new: AuditChange.Pair?) -> LedgerUpdate {
        guard old != new else { return LedgerUpdate() }
        return LedgerUpdate(retract: old, record: new)
    }
}
