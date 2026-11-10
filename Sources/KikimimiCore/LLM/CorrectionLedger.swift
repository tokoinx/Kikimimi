import Foundation

/// 学習した直し 1 件: 「この聞き間違いは、こう直す」(または「この直しは、しない」)。
///
/// 監査の一覧で利用者が直しを「反映する / 元に戻す」と決めるたびに、その語の組を数える。設定の画面で利用者が自分で書くこともできる。
public struct LearnedCorrection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 聞き間違えた語 (行に出てきたとおり)
    public var wrong: String
    /// 正しい語
    public var right: String
    /// その行の言語 (わかっていれば。nil はどの言語の行にも当てる)
    public var language: String?
    /// 利用者が「反映する」と決めた回数
    public var accepted: Int
    /// 利用者が「元に戻す」と決めた回数
    public var rejected: Int
    /// 設定の画面で、利用者が自分で書いたもの (回数に関係なく当てる)
    public var taught: Bool
    /// 直す前の行の例 (手本と、追加学習のデータに使う)
    public var example: String?
    public var updated: Date

    public init(id: UUID = UUID(), wrong: String, right: String, language: String? = nil, accepted: Int = 0,
                rejected: Int = 0, taught: Bool = false, example: String? = nil, updated: Date = Date()) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.language = language
        self.accepted = accepted
        self.rejected = rejected
        self.taught = taught
        self.example = example
        self.updated = updated
    }

    /// 次からは自動で当てる: 利用者が自分で書いたもの、または「反映する」が「元に戻す」より多いもの
    public var isActive: Bool { taught || accepted > rejected }
    /// この直しは、もう提案しない: 「元に戻す」のほうが多いもの
    public var isBlocked: Bool { !taught && rejected > accepted }
}

/// 学習した直しの台帳 (利用者の Mac の中だけに保存する)。
///
/// 小さなローカル LLM は、同じ固有名詞を毎回聞き間違いとして見つけられるとは限らず、利用者が一度断った直しをまた出すこともある。
/// そこで、利用者の決定を LLM の外に覚えておき、
/// - 「反映する」と決めた直しは、次からは LLM に聞く前に規則として当てる (一覧に出るので、いつでも元に戻せる)
/// - 「元に戻す」と決めた直しは、LLM がまた出してきても捨てる
/// - 正しい語は、語彙のヒントに足す (文字起こしの段階で、その表記が出やすくなる)
/// - 追加学習 (LoRA) のデータとして書き出せる
public struct CorrectionLedger: Codable, Hashable, Sendable {
    public var version: Int
    public var corrections: [LearnedCorrection]

    public init(corrections: [LearnedCorrection] = []) {
        self.version = 1
        self.corrections = corrections
    }

    public var isEmpty: Bool { corrections.isEmpty }
    public var active: [LearnedCorrection] { corrections.filter(\.isActive) }

    // MARK: 覚える

    /// 語をそろえる (前後の空白を除く)。空の語・同じ語の組は覚えない
    static func normalized(_ wrong: String, _ right: String) -> (wrong: String, right: String)? {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty, w != r, w.count <= 80, r.count <= 80,
              !w.contains("\n"), !r.contains("\n") else { return nil }
        return (w, r)
    }

    /// 同じ組とみなす印 (英字の大文字小文字は区別しない)
    static func key(_ wrong: String, _ right: String) -> String {
        wrong.lowercased() + "\u{1}" + right.lowercased()
    }

    func index(wrong: String, right: String) -> Int? {
        let k = Self.key(wrong, right)
        return corrections.firstIndex { Self.key($0.wrong, $0.right) == k }
    }

    /// 利用者の決定を 1 回分覚える (監査の一覧で、直しを反映した / 元に戻した)
    public mutating func record(wrong: String, right: String, language: String?, example: String?, accepted: Bool,
                                date: Date = Date()) {
        guard let pair = Self.normalized(wrong, right) else { return }
        if let i = index(wrong: pair.wrong, right: pair.right) {
            if accepted { corrections[i].accepted += 1 } else { corrections[i].rejected += 1 }
            corrections[i].updated = date
            if corrections[i].example == nil { corrections[i].example = example }
            // 言語が食い違う行でも決定されたら、どの言語の行にも当てる
            if corrections[i].language != language { corrections[i].language = nil }
        } else {
            corrections.append(LearnedCorrection(wrong: pair.wrong, right: pair.right, language: language,
                                                 accepted: accepted ? 1 : 0, rejected: accepted ? 0 : 1,
                                                 example: example, updated: date))
        }
    }

    /// 利用者が設定の画面で書いた直し (いつも当てる)。同じ組があれば、それを「いつも当てる」にする
    public mutating func teach(wrong: String, right: String, language: String? = nil, date: Date = Date()) -> Bool {
        guard let pair = Self.normalized(wrong, right) else { return false }
        if let i = index(wrong: pair.wrong, right: pair.right) {
            corrections[i].taught = true
            corrections[i].updated = date
        } else {
            corrections.append(LearnedCorrection(wrong: pair.wrong, right: pair.right, language: language,
                                                 taught: true, updated: date))
        }
        return true
    }

    public mutating func remove(_ id: UUID) {
        corrections.removeAll { $0.id == id }
    }

    // MARK: 使う

    /// LLM が出した直しを捨てるか (利用者が、同じ直しを元に戻したことがある)
    public func blocks(wrong: String, right: String) -> Bool {
        guard let pair = Self.normalized(wrong, right), let i = index(wrong: pair.wrong, right: pair.right) else { return false }
        return corrections[i].isBlocked
    }

    /// 学習した直しを、LLM に聞く前に規則として当てる。1 区間に 1 件 (いくつかの語が当たれば、まとめて 1 件)。
    /// 行の言語が決まっている直しは、その言語の行にだけ当てる。長い語から先に当てる
    public func fixes(for segments: [TranscriptSegment], language: String?) -> [AuditChange] {
        let rules = active.sorted {
            $0.wrong.count != $1.wrong.count ? $0.wrong.count > $1.wrong.count : $0.updated > $1.updated
        }
        guard !rules.isEmpty else { return [] }
        var changes: [AuditChange] = []
        for segment in segments {
            let lineLanguage = segment.language ?? language
            var text = segment.text
            var applied: [LearnedCorrection] = []
            for rule in rules {
                if let own = rule.language, let lineLanguage, own != lineLanguage { continue }
                // 正しい語がもう入っている行は、そのまま (「AI」→「AI model」のように、正しい語が誤りの語を含む組を重ねて当てない。
                // 正しい語と誤りの語の両方がある行は、言い分けているのかもしれない)。
                // 大文字小文字・記号だけが違う組 (「T-pie」→「TPIE」「roblox」→「Roblox」) は、表記まで同じものがあるときだけ
                let surface = TextSimilarity.key(rule.wrong) == TextSimilarity.key(rule.right)
                if surface ? text.contains(rule.right) : text.range(of: rule.right, options: .caseInsensitive) != nil { continue }
                var count = 0
                while count < 8, let fixed = Auditor.applyFix(to: text, wrong: rule.wrong, right: rule.right, surfaceOnly: true),
                      fixed != text {
                    text = fixed
                    count += 1
                    if rule.right.range(of: rule.wrong, options: .caseInsensitive) != nil { break }
                }
                if count > 0 { applied.append(rule) }
            }
            guard !applied.isEmpty, text != segment.text else { continue }
            // 「日本語＋英語」: 行の言語が文字の上で変わる直しは当てない
            if let own = segment.language, Script.spokenLanguage(of: text, among: ["ja", "en"], fallback: own) != own { continue }
            let pairs = applied.map { "「\($0.wrong)」→「\($0.right)」" }.joined(separator: "、")
            changes.append(AuditChange(kind: .fix, origin: .ledger, original: segment, replacement: text,
                                       reason: "学習した直し: \(pairs)", isConfident: true,
                                       wrong: applied[0].wrong, right: applied[0].right))
        }
        return changes
    }

    /// 語彙のヒントに足す語 (正しい語。新しい順に limit 個まで、全体で maxLength 文字まで)
    public func glossaryTerms(limit: Int = 24, maxLength: Int = 240) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        var length = 0
        for correction in active.sorted(by: { $0.updated > $1.updated }) {
            let term = correction.right
            guard seen.insert(term.lowercased()).inserted else { continue }
            guard terms.count < limit, length + term.count + 2 <= maxLength else { break }
            terms.append(term)
            length += term.count + 2
        }
        return terms
    }

    /// 語彙のヒント (設定で利用者が書いたもの) に、学習した語を足す。もう入っている語は足さない
    public func glossary(adding hint: String?) -> String? {
        let base = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = base.lowercased()
        let extra = glossaryTerms().filter { !lower.contains($0.lowercased()) }
        if extra.isEmpty { return base.isEmpty ? nil : base }
        return base.isEmpty ? extra.joined(separator: ", ") : base + ", " + extra.joined(separator: ", ")
    }

    // MARK: 保存

    public static func load(from url: URL) -> CorrectionLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let ledger = try? decoder.decode(CorrectionLedger.self, from: data) else { return CorrectionLedger() }
        return ledger
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private enum CodingKeys: String, CodingKey { case version, corrections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        corrections = try container.decodeIfPresent([LearnedCorrection].self, forKey: .corrections) ?? []
    }
}
