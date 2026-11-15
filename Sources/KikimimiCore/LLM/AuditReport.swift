import Foundation

/// 監査で見つけた 1 か所の直し (削除 or 修正)。元の区間をまるごと持つので、いつでも元に戻せる。
public struct AuditChange: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 区間を消す (繰り返し・実際には話していない文)
        case delete
        /// 区間の文を直す (聞き取りミス)
        case fix
    }

    public enum Origin: String, Codable, Sendable {
        /// 決まった規則で見つけた
        case rule
        /// ローカル LLM が見つけた
        case llm
        /// 学習した直し (利用者が前に決めた直し) を当てた
        case ledger
    }

    public var id: UUID
    public var kind: Kind
    public var origin: Origin
    /// 直す前の区間 (元に戻すときに使う)
    public var original: TranscriptSegment
    /// 直した文 (fix のとき)
    public var replacement: String?
    /// 理由 (画面に出す)
    public var reason: String
    /// 安全の基準を満たしたもの。満たさないものは自動では反映せず「要確認」として提案だけする
    public var isConfident: Bool
    /// いま本文に反映されているか
    public var isApplied: Bool
    /// 聞き間違えた語と正しい語 (fix のとき。利用者の決定を「学習した直し」として覚えるのに使う)
    public var wrong: String?
    public var right: String?
    /// この直しに入っている、学習した直しの組 (いくつかの語が 1 行に当たれば、すべて。LLM の直しとまとめたものにも入る)。
    /// 利用者が反映 / 元に戻すと決めたら、どの組にも同じ決定を覚える
    public var learned: [Pair]?
    /// 消した区間 (delete) のすぐ後ろにあった区間。元に戻すときに、同じ時刻の区間が並んでいても元の順に戻す
    public var nextID: UUID?

    public struct Pair: Codable, Hashable, Sendable {
        public var wrong: String
        public var right: String

        public init(wrong: String, right: String) {
            self.wrong = wrong
            self.right = right
        }
    }

    public init(id: UUID = UUID(), kind: Kind, origin: Origin, original: TranscriptSegment,
                replacement: String? = nil, reason: String, isConfident: Bool, isApplied: Bool = false,
                wrong: String? = nil, right: String? = nil, learned: [Pair]? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.original = original
        self.replacement = replacement
        self.reason = reason
        self.isConfident = isConfident
        self.isApplied = isApplied
        self.wrong = wrong
        self.right = right
        self.learned = learned
    }

    /// 利用者の決定を覚える組: 学習した直しの組と、LLM が出した組 (重なりは 1 つに)
    public var decisionPairs: [Pair] {
        var pairs = learned ?? []
        if let wrong, let right, !pairs.contains(Pair(wrong: wrong, right: right)) {
            pairs.append(Pair(wrong: wrong, right: right))
        }
        return pairs
    }
}

/// 監査の結果。
public struct AuditReport: Codable, Hashable, Sendable {
    public var changes: [AuditChange]
    /// 使った LLM の名前 (規則だけなら nil)
    public var model: String?
    /// 見直した区間の数
    public var reviewedCount: Int
    public var date: Date
    /// 利用者が自分で決めたこと (反映する / しない)。監査をやり直しても、同じ直しには同じ決定を当てる
    public var userDecisions: [String: Bool]?
    /// LLM が全部を見終える前の結果 (中止・失敗したときに、見終えた所までを反映したもの)
    public var isPartial: Bool?

    public init(changes: [AuditChange], model: String?, reviewedCount: Int, date: Date = Date(),
                userDecisions: [String: Bool]? = nil, isPartial: Bool? = nil) {
        self.changes = changes
        self.model = model
        self.reviewedCount = reviewedCount
        self.date = date
        self.userDecisions = userDecisions
        self.isPartial = isPartial
    }

    public var appliedFixes: Int { changes.filter { $0.isApplied && $0.kind == .fix }.count }
    public var appliedDeletes: Int { changes.filter { $0.isApplied && $0.kind == .delete }.count }
    /// 反映していない提案 (要確認)
    public var pendingSuggestions: Int { changes.filter { !$0.isApplied }.count }

    /// その区間に当たっている直し
    public func change(forSegment id: UUID) -> AuditChange? {
        changes.first { $0.original.id == id }
    }
}

extension AuditChange {
    /// 監査をやり直したときに「同じ直し」とみなすための印 (区間・種類・直した文)
    public var signature: String {
        "\(original.id.uuidString)|\(kind.rawValue)|\(replacement ?? "")"
    }
}

extension Transcript {
    /// 監査の結果を受け取り、自信のあるものだけ本文に反映する。前の監査の反映は先に元に戻す。
    /// 利用者が前の監査で決めたこと (反映する / しない) は、同じ直しに引き継ぐ。
    /// 結果として文が変わらなかった区間は、訳もそのまま残す。
    public mutating func adopt(_ report: AuditReport) {
        let before = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let decisions = audit?.userDecisions ?? [:]
        if let previous = audit {
            for change in previous.changes where change.isApplied {
                revert(change)
            }
        }
        var report = report
        report.userDecisions = decisions.isEmpty ? nil : decisions
        for i in report.changes.indices {
            let wanted = decisions[report.changes[i].signature] ?? report.changes[i].isConfident
            report.changes[i].isApplied = false
            if wanted, apply(report.changes[i]) {
                report.changes[i].isApplied = true
            }
        }
        // 文が前と同じに戻った区間は、前の訳 (と、文ごとの訳のまとまり) を戻す
        for i in segments.indices {
            guard let old = before[segments[i].id], old.text == segments[i].text,
                  segments[i].translation == nil, old.translation != nil else { continue }
            let covers = old.translationCovers ?? []
            let intact = covers.allSatisfy { id in
                guard let now = segments.first(where: { $0.id == id }), let was = before[id] else { return false }
                return now.text == was.text
            }
            if intact {
                segments[i].translation = old.translation
                segments[i].translationCovers = old.translationCovers
            }
        }
        normalizeTranslationUnits()
        audit = report
    }

    /// 1 つの直しを反映する / 元に戻す (利用者の決定として覚えておく)
    public mutating func setChange(_ id: UUID, applied: Bool) {
        guard var report = audit, let i = report.changes.firstIndex(where: { $0.id == id }) else { return }
        let change = report.changes[i]
        var decisions = report.userDecisions ?? [:]
        decisions[change.signature] = applied
        report.userDecisions = decisions
        if change.isApplied != applied {
            if applied {
                guard apply(change) else { return }
            } else {
                revert(change)
            }
            report.changes[i].isApplied = applied
        }
        audit = report
    }

    /// 監査で直す前の区間 (監査をやり直すときは、ここから見直す)。利用者の決定は変えない
    public var segmentsBeforeAudit: [TranscriptSegment] {
        var copy = self
        if let report = copy.audit {
            for change in report.changes where change.isApplied {
                copy.revert(change)
            }
        }
        return copy.segments
    }

    /// すべての直しを元に戻す (監査の結果は提案として残す)
    public mutating func revertAllChanges() {
        guard let report = audit else { return }
        for change in report.changes where change.isApplied {
            setChange(change.id, applied: false)
        }
    }

    /// 本文に反映する。対象の区間が見つからなければ false
    @discardableResult
    mutating func apply(_ change: AuditChange) -> Bool {
        guard let index = segments.firstIndex(where: { $0.id == change.original.id }) else { return false }
        switch change.kind {
        case .delete:
            // この区間を含む訳 (文ごとの訳) は、消した区間の分だけずれるので訳し直す
            invalidateTranslation(of: change.original.id)
            segments.removeAll { $0.id == change.original.id }
        case .fix:
            guard let text = change.replacement, !text.isEmpty else { return false }
            // 文が変わったので、訳は訳し直す (文の続きとして含めていた訳も)
            invalidateTranslation(of: change.original.id)
            segments[index].text = text
        }
        normalizeTranslationUnits()
        return true
    }

    mutating func revert(_ change: AuditChange) {
        switch change.kind {
        case .delete:
            guard !segments.contains(where: { $0.id == change.original.id }) else { return }
            // すぐ後ろにあった区間が残っていれば、その前に戻す (同じ時刻の区間が並んでいても、元の順になる)。
            // 無ければ、時刻で場所を決める
            let position = change.nextID.flatMap { next in segments.firstIndex { $0.id == next } }
                ?? segments.firstIndex { ($0.start, $0.end) > (change.original.start, change.original.end) }
                ?? segments.endIndex
            segments.insert(change.original, at: position)
        case .fix:
            guard let index = segments.firstIndex(where: { $0.id == change.original.id }) else { return }
            invalidateTranslation(of: change.original.id)
            segments[index].text = change.original.text
            // 1 区間だけの訳は、文が元に戻ればそのまま正しい。いくつかの区間にまたがる訳は、ほかの区間が
            // 変わっているかもしれないので戻さない (訳し直しにする)
            if (change.original.translationCovers ?? []).isEmpty {
                segments[index].translation = change.original.translation
            }
        }
        // 戻した区間が、あとから訳した文のまとまりの途中に入ったら、そのまとまりは訳し直し
        normalizeTranslationUnits()
    }
}
