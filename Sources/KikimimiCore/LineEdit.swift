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

    public init(segmentID: UUID, heard: String, edited: String, date: Date = Date()) {
        self.segmentID = segmentID
        self.heard = heard
        self.edited = edited
        self.date = date
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
    @discardableResult
    public mutating func setLineText(_ text: String, forSegment id: UUID, date: Date = Date()) -> Bool {
        let cleaned = LineEdit.normalized(text)
        guard !cleaned.isEmpty, let index = segments.firstIndex(where: { $0.id == id }) else { return false }
        let current = segments[index].text
        guard cleaned != LineEdit.normalized(current) else { return false }
        let heard: String
        if let existing = lineEdit(forSegment: id) {
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
            edits.append(LineEdit(segmentID: id, heard: heard, edited: cleaned, date: date))
        }
        normalizeTranslationUnits()
        lineEdits = edits
        pruneLineEdits()
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
