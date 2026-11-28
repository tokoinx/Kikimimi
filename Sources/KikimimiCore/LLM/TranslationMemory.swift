import Foundation

/// 訳の記憶の 1 件: 利用者が直した、1 文の訳。
///
/// 入るのは利用者が直した訳だけ (機械の訳は入れない)。次の翻訳で同じ文に出た時は、LLM を呼ばずにこの訳を置く
/// (`TranslationMemoryLookup`)。
public struct RememberedTranslation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 原文 (前後の空白を外した物。比べる時は `TranslationMemory.normalizedSource(_:)` でそろえる)
    public var source: String
    /// 原文の言語 (わかっていれば)
    public var sourceLanguage: String?
    /// 訳す先の言語のコード
    public var target: String
    /// 利用者の訳
    public var translation: String
    /// 直す前の機械の訳 (無ければ nil)
    public var machine: String?
    /// 機械の訳を作った LLM の名前 (わかっていれば)
    public var model: String?
    /// 評価用に取り分けた 1 件 (学習と手本には使わない。同じ文にそのまま戻す再利用には使う)。入れる時に、そろえた原文から決める
    public var heldOut: Bool
    public var updated: Date

    public init(id: UUID = UUID(), source: String, sourceLanguage: String? = nil, target: String, translation: String,
                machine: String? = nil, model: String? = nil, heldOut: Bool = false, updated: Date = Date()) {
        self.id = id
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.target = target
        self.translation = translation
        self.machine = machine
        self.model = model
        self.heldOut = heldOut
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, source, sourceLanguage, target, translation, machine, model, heldOut, updated
    }

    /// 欠けている項目は補って読む (原文・訳す先・訳は無いと読めない)
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        translation = try c.decode(String.self, forKey: .translation)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        sourceLanguage = try? c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        machine = try? c.decodeIfPresent(String.self, forKey: .machine)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        heldOut = (try? c.decodeIfPresent(Bool.self, forKey: .heldOut))
            ?? TranslationMemory.isHeldOut(TranslationMemory.normalizedSource(source))
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? Date()
    }
}

/// 訳の記憶 (利用者の Mac の中だけに保存する。`translation-memory.json`)。
///
/// 監査の台帳 (`CorrectionLedger`、`learned-corrections.json`) とは別のファイル。読み書きの作りは台帳と同じ:
/// 壊れた 1 件は飛ばし、読めないファイルは別の名前でよけ、書く時は原子的に書く。
/// 形は `{ "version": 1, "sentences": [...], "terms": [...], "gate": [...] }`。`terms`・`gate` の無い古いファイルも読める。
/// 知らない項目は読み飛ばす
public struct TranslationMemory: Codable, Hashable, Sendable {
    public var version: Int
    public var sentences: [RememberedTranslation]
    /// 訳語の対 (利用者が決めた「この語は、こう訳す」)。訳す先の言語ごとに持つ
    public var terms: [TermPair]
    /// 訳の関門の検査ごとの、利用者の判定の数 (検査 × 訳す先ごとに 1 件)。`suppressedChecks(target:)` が使う
    public var gate: [GateCount]

    /// 保存するファイルの名前 (学習した直しの台帳と同じフォルダに置く)
    public static let fileName = "translation-memory.json"

    public init(sentences: [RememberedTranslation] = [], terms: [TermPair] = [], gate: [GateCount] = []) {
        self.version = 1
        self.sentences = sentences
        self.terms = terms
        self.gate = gate
    }

    enum CodingKeys: String, CodingKey {
        case version, sentences, terms, gate
    }

    /// 読めない 1 件があっても、ほかは読む (その 1 件だけを飛ばす)。原文・訳が空の物も飛ばす
    public init(from decoder: any Decoder) throws {
        struct Entry: Decodable {
            var value: RememberedTranslation?
            init(from decoder: any Decoder) throws {
                value = try? RememberedTranslation(from: decoder)
            }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        sentences = (try c.decodeIfPresent([Entry].self, forKey: .sentences) ?? []).compactMap(\.value)
            .filter { !Self.normalizedSource($0.source).isEmpty && !$0.translation.isEmpty }
        // 訳語の対も、壊れた 1 件だけを飛ばす (原語・訳語・訳す先が空の物も飛ばす)
        struct TermEntry: Decodable {
            var value: TermPair?
            init(from decoder: any Decoder) throws {
                value = try? TermPair(from: decoder)
            }
        }
        terms = ((try? c.decodeIfPresent([TermEntry].self, forKey: .terms)) ?? []).compactMap { $0.value }
            .filter { !$0.source.isEmpty && !$0.translation.isEmpty && !$0.target.isEmpty }
        // 検査の判定の数も、壊れた 1 件だけを飛ばす (検査・訳す先が空の物も飛ばす)
        struct GateEntry: Decodable {
            var value: GateCount?
            init(from decoder: any Decoder) throws {
                value = try? GateCount(from: decoder)
            }
        }
        gate = ((try? c.decodeIfPresent([GateEntry].self, forKey: .gate)) ?? []).compactMap { $0.value }
            .filter { !$0.check.isEmpty && !$0.target.isEmpty }
    }

    /// 覚えた文が無いか (訳語の対は数えない。対も無いかは `hasNothing`)
    public var isEmpty: Bool { sentences.isEmpty }

    /// 覚えた文も、訳語の対も無いか (検査の判定の数は数えない)
    public var hasNothing: Bool { sentences.isEmpty && terms.isEmpty }

    // MARK: そろえる

    /// 比べるための原文: NFKC にし、続く空白 (改行・全角の空白も) を 1 つの空白にし、前後の空白を外す
    public static func normalizedSource(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 訳す先の言語のコードをそろえる (小文字。前後の空白を外す)
    static func normalizedTarget(_ target: String) -> String {
        target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 評価用に取り分けるか (5 件に 1 件)。そろえた原文の UTF-8 の FNV-1a (64 ビット) で決める
    /// (Swift の `Hasher` は起動ごとに値が変わるので使わない)
    public static func isHeldOut(_ normalizedSource: String) -> Bool {
        stableHash(normalizedSource) % 5 == 0
    }

    /// 決まった計算のハッシュ (FNV-1a 64 ビット)。同じ文なら、どの Mac・どの起動でも同じ値
    public static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    func index(source: String, target: String) -> Int? {
        let s = Self.normalizedSource(source)
        let t = Self.normalizedTarget(target)
        return sentences.firstIndex { Self.normalizedSource($0.source) == s && Self.normalizedTarget($0.target) == t }
    }

    // MARK: 入れる・外す

    /// 利用者が直した訳を入れる。原文 (そろえた物)・訳す先が同じ物が在れば書き換え、無ければ足す。
    /// 入れた (書き換えた) 1 件を返す。原文・訳が空なら nil (何も変えない)
    @discardableResult
    public mutating func remember(source: String, sourceLanguage: String?, target: String, translation: String,
                                  machine: String?, model: String?, date: Date = Date()) -> RememberedTranslation? {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalizedSource(s)
        guard !key.isEmpty, !t.isEmpty else { return nil }
        let held = Self.isHeldOut(key)
        if let i = index(source: s, target: target) {
            sentences[i].source = s
            sentences[i].sourceLanguage = sourceLanguage ?? sentences[i].sourceLanguage
            sentences[i].translation = t
            // 直す前の機械の訳は、初めに入れた時の物を残す (無かった時だけ、今の物にする)
            sentences[i].machine = sentences[i].machine ?? machine
            sentences[i].model = sentences[i].model ?? model
            sentences[i].heldOut = held
            sentences[i].updated = date
            return sentences[i]
        }
        let entry = RememberedTranslation(source: s, sourceLanguage: sourceLanguage, target: Self.normalizedTarget(target),
                                          translation: t, machine: machine, model: model, heldOut: held, updated: date)
        sentences.append(entry)
        return entry
    }

    /// 同じ原文・訳す先の 1 件 (無ければ nil)
    public func entry(source: String, target: String) -> RememberedTranslation? {
        index(source: source, target: target).map { sentences[$0] }
    }

    /// 同じ原文・訳す先の 1 件を消す (利用者が「機械の訳に戻す」を押した時)。消したら true
    @discardableResult
    public mutating func forget(source: String, target: String) -> Bool {
        guard let i = index(source: source, target: target) else { return false }
        sentences.remove(at: i)
        return true
    }

    public mutating func remove(_ id: UUID) {
        sentences.removeAll { $0.id == id }
    }

    // MARK: 訳語の対 (U5)

    /// 訳語の対を足す。原語 (大文字と小文字を区別せずに比べる)・訳す先が同じ物が在れば訳語を書き換え、無ければ足す。
    /// 足した (書き換えた) 1 件を返す。原語・訳語・訳す先のどれかが空なら nil (何も変えない)
    @discardableResult
    public mutating func setTerm(source: String, translation: String, target: String, date: Date = Date()) -> TermPair? {
        let s = TermPair.cleaned(source)
        let t = TermPair.cleaned(translation)
        let g = Self.normalizedTarget(target)
        guard !s.isEmpty, !t.isEmpty, !g.isEmpty else { return nil }
        if let i = terms.firstIndex(where: { $0.matches(source: s, target: g) }) {
            terms[i].source = s
            terms[i].translation = t
            terms[i].updated = date
            return terms[i]
        }
        let pair = TermPair(source: s, translation: t, target: g, updated: date)
        terms.append(pair)
        return pair
    }

    /// 訳語の対を 1 件消す
    public mutating func removeTerm(_ id: UUID) {
        terms.removeAll { $0.id == id }
    }

    /// 訳語の対の一覧 (訳す先 target を渡すと、その言語の物だけ)。訳す先・原語の順
    public func termList(target: String? = nil) -> [TermPair] {
        let g = target.map(Self.normalizedTarget)
        return terms.filter { g == nil || Self.normalizedTarget($0.target) == g }
            .sorted { ($0.target, $0.source.lowercased()) < ($1.target, $1.source.lowercased()) }
    }

    // MARK: 関門が、利用者の判定から学ぶ (U6)

    /// 検査を止めるかを決める、判定の数の下限。これより少ない時は決めない (数回の判定では、たまたまの偏りと見分けられない)
    public static let gateMinimumJudgements = 5
    /// 検査を止める「誤りの印」の割合の下限。判定のうち、この割合以上が「この訳でよい」(印が誤り) だった検査は、
    /// その言語では役に立っていないと見て止める (5 回のうち 4 回以上が誤りの印、など)
    public static let gateFalseAlarmRatio = 0.8

    func gateIndex(check: String, target: String) -> Int? {
        let t = Self.normalizedTarget(target)
        return gate.firstIndex { $0.check == check && Self.normalizedTarget($0.target) == t }
    }

    /// 印の付いた訳への利用者の判定を数える。flags の検査のうち、止めてよい検査 (`TranslationGate.learnable`) の 1 つずつに、
    /// confirmed (「この訳でよい」= 検査の誤り) と edited (直した = 検査が当たった) を足す (負の数で引く。0 より下げない)。
    /// 数を変えたら true
    @discardableResult
    public mutating func countGate(flags: [String], target: String, confirmed: Int = 0, edited: Int = 0,
                                   date: Date = Date()) -> Bool {
        let t = Self.normalizedTarget(target)
        guard !t.isEmpty, confirmed != 0 || edited != 0 else { return false }
        var changed = false
        for check in Set(flags) where TranslationGate.learnable.contains(check) {
            if let i = gateIndex(check: check, target: t) {
                gate[i].confirmed = max(0, gate[i].confirmed + confirmed)
                gate[i].edited = max(0, gate[i].edited + edited)
                gate[i].updated = date
                changed = true
            } else if confirmed > 0 || edited > 0 {
                gate.append(GateCount(check: check, target: t, confirmed: max(0, confirmed), edited: max(0, edited),
                                      updated: date))
                changed = true
            }
        }
        return changed
    }

    /// 判定の数から、検査を止めるか (数が `gateMinimumJudgements` 以上で、「この訳でよい」の割合が `gateFalseAlarmRatio` 以上)。
    /// 重い印の検査は止めない
    public static func isSuppressed(_ count: GateCount) -> Bool {
        let total = count.confirmed + count.edited
        guard TranslationGate.learnable.contains(count.check), total >= gateMinimumJudgements else { return false }
        return Double(count.confirmed) / Double(total) >= gateFalseAlarmRatio
    }

    /// 訳す先 target で止める検査 (印を出さない検査)
    public func suppressedChecks(target: String) -> Set<String> {
        let t = Self.normalizedTarget(target)
        return Set(gate.filter { Self.normalizedTarget($0.target) == t && Self.isSuppressed($0) }.map(\.check))
    }

    /// 止めている検査の一覧 (設定の画面に出す)。訳す先・検査の順 (検査は `TranslationGate.all` の順)
    public var suppressedGate: [GateCount] {
        gate.filter(Self.isSuppressed).sorted { a, b in
            if a.target != b.target { return a.target < b.target }
            return (TranslationGate.all.firstIndex(of: a.check) ?? 99) < (TranslationGate.all.firstIndex(of: b.check) ?? 99)
        }
    }

    /// 検査 check × 訳す先 target の数を 0 に戻す (その 1 件を消す。設定の「元に戻す」)。戻したら true
    @discardableResult
    public mutating func resetGate(check: String, target: String) -> Bool {
        guard let i = gateIndex(check: check, target: target) else { return false }
        gate.remove(at: i)
        return true
    }

    // MARK: 評価の問題にする (U6)

    /// 取り分けた直し (`heldOut`) だけを、翻訳の評価の問題にする。1 件 = 1 場面 (行は原文 1 つ、人の訳は直した訳)。
    /// id は記憶の id から決まる ("memory-<訳す先>-<id の頭 8 字>")。並びは訳す先・原文の順。
    /// 原文の言語は、記憶の `sourceLanguage`。無ければ detector で決め、それでも分からなければ "en"
    public func evaluationCases(detector: LanguageDetector? = LLMEval.defaultLanguageDetector) -> [TranslationEvalCase] {
        sentences.filter(\.heldOut)
            .sorted { ($0.target, $0.source) < ($1.target, $1.source) }
            .map { entry in
                let target = Self.normalizedTarget(entry.target)
                let short = String(entry.id.uuidString.lowercased().prefix(8))
                let language = entry.sourceLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? detector?(entry.source) ?? "en"
                return TranslationEvalCase(id: "memory-\(target)-\(short)", language: language,
                                           lines: [entry.source], target: target, references: [entry.translation],
                                           domain: "memory")
            }
    }

    // MARK: 保存

    public static func load(from url: URL) -> TranslationMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let memory = try? JSONInput.decode(TranslationMemory.self, from: data, with: decoder) else { return TranslationMemory() }
        return memory
    }

    /// アプリが起動のときに読む。ファイルがあるのに読めないとき (壊れた・手で書き換えて形が崩れた) は、
    /// 空の記憶で上書きしてしまわないよう、そのファイルを別の名前でとっておき、その場所を返す
    public static func loadKeepingUnreadable(from url: URL, date: Date = Date()) -> (memory: TranslationMemory, setAside: URL?) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return (TranslationMemory(), nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let memory = try? JSONInput.decode(TranslationMemory.self, from: data, with: decoder) { return (memory, nil) }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("translation-memory.unreadable-\(stamp.string(from: date)).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return (TranslationMemory(), aside)
        } catch {
            // 動かせなければ、そのまま (次に保存するときに上書きされる。読めない中身なので、失うものは同じ)
            return (TranslationMemory(), nil)
        }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: 次の翻訳で使う (U2)

/// 次の翻訳で同じ文に使う、訳す先 1 つ分の記憶の写し。
///
/// 値なので、LLM のスレッドへそのまま渡せる (`AppModel` の記憶を、訳している間に引き直さない)。
/// 取り分けた 1 件 (`heldOut`) も入れる: 取り分けは「学習と手本に使わない」ための印で、
/// 利用者が直した同じ文に、その訳をそのまま戻す事までは止めない
public struct TranslationMemoryLookup: Hashable, Sendable {
    /// 引く原文の重さの下限 (`TranslationGate.weight`。漢字・かな・ハングルは 2 と数える)。
    /// これより短い文 (「Yes.」「はい。」など) は引かない: 短い文は、場面で訳が変わるため
    /// (ある場面で直した「Yes.」の訳を、ほかの場面の「Yes.」に置くと、かえって合わない事が多い)
    /// 値は、訳の関門の「短い文」と 1 つにまとめてある (`TranslationGate.shortSentenceWeight`)
    public static let minimumSourceWeight = TranslationGate.shortSentenceWeight

    /// 訳す先の言語のコード (そろえた物)
    public let target: String
    /// そろえた原文 → 利用者の訳
    let translations: [String: String]
    /// この訳す先の訳語の対 (原文に出る物だけを指示文と関門に使う: `terms(in:)`)
    public let terms: [TermPair]
    /// この訳す先で止める検査 (利用者の判定から学んだ物。`TranslationMemory.suppressedChecks(target:)`)。
    /// 翻訳は、覚えに残す印から、この検査の印を外す (訳し直しの引き金は、外す前の印で決める)
    public let suppressedChecks: Set<String>
    /// 似た文の手本の候補 (取り分けでない文だけ。そろえた原文の順)。
    /// 使うのは `TranslationOptions.memoryExamples` が 1 以上の時だけ (`MemoryExampleIndex`)
    public let examples: [MemoryExample]

    public init(target: String, sentences: [RememberedTranslation], terms: [TermPair] = [],
                suppressedChecks: Set<String> = []) {
        let t = TranslationMemory.normalizedTarget(target)
        self.target = t
        self.suppressedChecks = suppressedChecks.intersection(TranslationGate.learnable)
        var map: [String: String] = [:]
        // 手本に使えるか (取り分けでないか)。同じ文の新しい方で決める
        var usable: [String: Bool] = [:]
        // 同じ文が 2 つ在れば、新しく直した方を使う
        for entry in sentences.sorted(by: { $0.updated < $1.updated })
        where TranslationMemory.normalizedTarget(entry.target) == t {
            let key = TranslationMemory.normalizedSource(entry.source)
            let value = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key] = value
            usable[key] = !entry.heldOut
        }
        translations = map
        examples = map.keys.sorted().compactMap { key in
            guard usable[key] == true, let value = map[key] else { return nil }
            return MemoryExample(source: key, translation: TermPair.cleaned(value))
        }
        // 同じ原語が 2 つ在れば、新しく決めた方を使う
        var seen = Set<String>()
        var pairs: [TermPair] = []
        for pair in terms.sorted(by: { $0.updated > $1.updated })
        where TranslationMemory.normalizedTarget(pair.target) == t && !pair.source.isEmpty && !pair.translation.isEmpty {
            guard seen.insert(pair.source.lowercased()).inserted else { continue }
            pairs.append(pair)
        }
        self.terms = pairs
    }

    /// 引ける文の数
    public var count: Int { translations.count }
    /// 引ける文が無いか (訳語の対は数えない)
    public var isEmpty: Bool { translations.isEmpty }

    /// 原文 text に出る訳語の対 (`TermPair.matching` の決まり。長い語を先に、`TermPair.maxPerPrompt` 組まで)
    public func terms(in text: String) -> [TermPair] {
        TermPair.matching(terms, in: text)
    }

    /// 原文に合う利用者の訳。短い文・記憶に無い文は nil
    public func translation(for source: String) -> String? {
        let key = TranslationMemory.normalizedSource(source)
        guard TranslationGate.weight(key) >= Self.minimumSourceWeight else { return nil }
        return translations[key]
    }
}

extension TranslationMemory {
    /// 訳す先 target の記憶の写し (次の翻訳に渡す。覚えた文・訳語の対・止める検査)
    public func lookup(target: String) -> TranslationMemoryLookup {
        TranslationMemoryLookup(target: target, sentences: sentences, terms: terms,
                                suppressedChecks: suppressedChecks(target: target))
    }

    /// 次の翻訳に渡す写し。reuse (設定「覚えた訳を、次の翻訳に使う」) が切なら、覚えた文も訳語の対も渡さない。
    /// 止める検査は、reuse に関わらず渡す (記憶の入・切とは別の働き)。
    /// 訳す先 target の文も対も止める検査も無ければ nil
    public func lookup(target: String, reuse: Bool) -> TranslationMemoryLookup? {
        let suppressed = suppressedChecks(target: target)
        guard reuse, !hasNothing else {
            return suppressed.isEmpty ? nil
                : TranslationMemoryLookup(target: target, sentences: [], terms: [], suppressedChecks: suppressed)
        }
        let lookup = lookup(target: target)
        return lookup.isEmpty && lookup.terms.isEmpty && lookup.suppressedChecks.isEmpty ? nil : lookup
    }
}

/// 訳の関門の検査 1 つ × 訳す先 1 つの、利用者の判定の数 (`TranslationMemory.gate`)。
///
/// 印の付いた機械の訳に、利用者が「この訳でよい」とした数 (検査の誤り) と、直した数 (検査が当たった) を持つ。
/// 数がたまると、誤りの多い検査を、その訳す先では止める (`TranslationMemory.isSuppressed(_:)`)
public struct GateCount: Codable, Hashable, Sendable {
    /// 検査の符号 (`TranslationGate` の number・language など)
    public var check: String
    /// 訳す先の言語のコード (そろえた物)
    public var target: String
    /// 「この訳でよい」とした数
    public var confirmed: Int
    /// 直した数
    public var edited: Int
    public var updated: Date

    public init(check: String, target: String, confirmed: Int = 0, edited: Int = 0, updated: Date = Date()) {
        self.check = check
        self.target = target
        self.confirmed = confirmed
        self.edited = edited
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case check, target, confirmed, edited, updated
    }

    /// 欠けている項目は補って読む (検査・訳す先は無いと読めない)。負の数は 0 と読む
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        check = try c.decode(String.self, forKey: .check)
        target = TranslationMemory.normalizedTarget(try c.decode(String.self, forKey: .target))
        confirmed = max(0, (try? c.decodeIfPresent(Int.self, forKey: .confirmed)) ?? 0)
        edited = max(0, (try? c.decodeIfPresent(Int.self, forKey: .edited)) ?? 0)
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? Date()
    }
}

// MARK: 訳語の対 (U5)

/// 訳語の対 1 つ: 利用者が決めた「原文のこの語は、いつもこう訳す」(例: "dashboard" → 「管理画面」)。
///
/// 訳す先の言語ごとに持つ。次の翻訳で、原文にこの語が出る行を送る時だけ、指示文に `X => Y` と書く
/// (`Translator.userPrompt`)。訳に訳語が無ければ、関門が `term` の印を付ける (印だけ。訳し直さない)
public struct TermPair: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 原文の語
    public var source: String
    /// 訳語
    public var translation: String
    /// 訳す先の言語のコード (そろえた物)
    public var target: String
    public var updated: Date

    /// 1 回の指示文に入れる対の数の上限 (長い語から)。指示文が長くなりすぎて、小さな LLM が行の訳を落とさないように
    public static let maxPerPrompt = 8

    public init(id: UUID = UUID(), source: String, translation: String, target: String, updated: Date = Date()) {
        self.id = id
        self.source = source
        self.translation = translation
        self.target = target
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, source, translation, target, updated
    }

    /// 欠けている項目は補って読む (原語・訳語・訳す先は無いと読めない)
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = Self.cleaned(try c.decode(String.self, forKey: .source))
        translation = Self.cleaned(try c.decode(String.self, forKey: .translation))
        target = TranslationMemory.normalizedTarget(try c.decode(String.self, forKey: .target))
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? Date()
    }

    /// 語をそろえる: 改行を空白にし、続く空白を 1 つにし、前後の空白を外す (指示文の 1 行に収めるため)
    static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 原語 (大文字と小文字は区別しない)・訳す先が同じか
    func matches(source: String, target: String) -> Bool {
        self.source.lowercased() == source.lowercased()
            && TranslationMemory.normalizedTarget(self.target) == TranslationMemory.normalizedTarget(target)
    }

    // MARK: 原文に出るか

    /// 対の中から、原文 text に出る物を返す (長い語を先に、limit 組まで。同じ原語は 1 つ)。
    /// 当て方は `occurs(_:in:)`
    public static func matching(_ pairs: [TermPair], in text: String, limit: Int = maxPerPrompt) -> [TermPair] {
        guard !pairs.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [TermPair] = []
        // 長い語を先に (同じ長さなら、渡された順)
        let ordered = pairs.enumerated().sorted { a, b in
            a.element.source.count != b.element.source.count ? a.element.source.count > b.element.source.count
                : a.offset < b.offset
        }.map(\.element)
        for pair in ordered where !pair.source.isEmpty && !pair.translation.isEmpty {
            guard out.count < limit else { break }
            guard !seen.contains(pair.source.lowercased()), occurs(pair.source, in: text) else { continue }
            seen.insert(pair.source.lowercased())
            out.append(pair)
        }
        return out
    }

    /// 原文の語 term が text に出るか (大文字と小文字は区別しない)。
    /// 漢字・かな・ハングル・タイ文字を含む語は、含むかどうかだけで見る (語の間に空白を置かない書き方なので)。
    /// ほかの語 (ラテン文字・キリル文字など) は、語の切れ目で当てる: 当たった所の前と後ろが文字でない事
    /// ("car" は "career" にも "scar" にも当たらない)
    public static func occurs(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        if hasUnspacedLetters(term) { return text.range(of: term, options: .caseInsensitive) != nil }
        var start = text.startIndex
        while start < text.endIndex,
              let r = text.range(of: term, options: .caseInsensitive, range: start..<text.endIndex) {
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : nil
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            start = text.index(after: r.lowerBound)
        }
        return false
    }

    /// 文字 (letters) か。nil (文の端) は文字でない
    static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// 語の間に空白を置かない文字 (漢字・かな・ハングル・タイ文字) を含むか
    static func hasUnspacedLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v)
                || (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
                || (0x0E00...0x0E7F).contains(v)
        }
    }

    // MARK: 訳に訳語が在るか

    /// 訳語の当て方を緩める長さ: 訳語がこの字数以上の時は、頭の `keptPrefixRatio` (切り上げ) が訳に在ればよい。
    /// ロシア語・ドイツ語・韓国語などは、文の中で語の終わりが変わる (格・助詞: "панель" → "панели"、
    /// "Verwaltungsbereich" → "Verwaltungsbereichs") ので、そのまま含むかで見ると、正しい訳にも印が付きすぎる
    public static let looseMatchMinimumLength = 5
    /// 訳語の頭の、訳に在ればよい割合 (75%。語の終わりの変わる所は、ふつう最後の 1〜2 字)
    public static let keptPrefixRatio = 0.75
    /// そのまま含むかで見る訳す先: 語の形が変わらない、語の間に空白を置かない言語 (頭だけで当てると、別の語にも当たりやすい)
    public static let exactMatchTargets: Set<String> = ["ja", "zh", "th"]

    /// 訳 text に訳語 translation が在るか (大文字と小文字は区別しない)。
    /// 訳語が `looseMatchMinimumLength` 字以上で、訳す先が `exactMatchTargets` でない時は、頭の 75% (切り上げ) が在ればよい
    public static func kept(_ translation: String, in text: String, target: String) -> Bool {
        let y = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !y.isEmpty else { return true }
        let t = TranslationTarget.normalized(target)
        let needle: String
        if y.count >= looseMatchMinimumLength, !exactMatchTargets.contains(t) {
            let n = Int((Double(y.count) * keptPrefixRatio).rounded(.up))
            needle = String(y.prefix(n))
        } else {
            needle = y
        }
        return text.range(of: needle, options: .caseInsensitive) != nil
    }

    /// 理由の文に出す並び ("X → Y")。原語と訳語が同じ (大文字と小文字を除いて) なら、訳語だけ
    var label: String {
        source.lowercased() == translation.lowercased() ? translation : source + " → " + translation
    }
}

// MARK: 似た文を手本にする (実験。既定は切)

/// 手本の候補 1 件: 覚えた文 (取り分けでない物) の、そろえた原文と利用者の訳 (空白をそろえた物)
public struct MemoryExample: Hashable, Sendable {
    public let source: String
    public let translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

/// 送る行に似た、記憶の文を選ぶ (`TranslationOptions.memoryExamples` が 1 以上の時だけ作る)。
///
/// 1 回の翻訳 (`Translator.translateSummarizing`) で 1 度だけ作り、送るまとまりごとに `select(for:limit:)` で選ぶ。
/// 似ているかの点は、原文どうしの chrF (字の n-gram の一致、0〜100)。chrF は β = 2 で再現率を重く見るので、
/// 片方の向きだけで測ると、長い文 (参照の側なら短い文) が高く出やすい。手本の向きで偏らないように、
/// 両方の向きの点の平均 (対称の点) を使う。
/// 記憶が大きくても遅くならないように、先に字の 3-gram の集合の重なり (Dice 係数) で粗く絞り、
/// 上位 `shortlist` 件にだけ、Dice 係数のいちばん高かった行との chrF を付ける
/// (行のどれか 1 つに対する点を、その文の点とする。chrF を全部の行と付けると、行の数だけ遅くなる)
public struct MemoryExampleIndex: Sendable {
    /// 手本に使う点の下限 (対称の chrF)。初めに置いた値で、測って決めた値ではない
    public static let minimumScore = 30.0
    /// 長い手本は使わない (原文か訳が、この字数を超える物は外す。指示文を伸ばしすぎないため)
    public static let maximumCharacters = 200
    /// 粗く絞った後に chrF を付ける件数の上限
    public static let shortlist = 24

    struct Candidate: Sendable {
        var example: MemoryExample
        /// 字の 3-gram (小さい順に並べ、重なりを数えやすくした物)
        var grams: [UInt64]
    }

    let candidates: [Candidate]

    /// 候補を作る。excluding (そろえた原文) に在る文は使わない: 今の翻訳の原文と同じ文
    /// (U2 の再利用でもう訳が置かれる文・評価で抜く文。答えを見て訳す事になる)
    public init(_ examples: [MemoryExample], excluding: Set<String>) {
        candidates = examples.compactMap { e in
            guard !excluding.contains(e.source), e.source.count <= Self.maximumCharacters,
                  e.translation.count <= Self.maximumCharacters, !e.translation.isEmpty else { return nil }
            let grams = Self.trigrams(e.source)
            guard !grams.isEmpty else { return nil }
            return Candidate(example: e, grams: grams)
        }
    }

    /// 手本に使える候補の数
    public var count: Int { candidates.count }

    /// 字の 3-gram の集合 (空白を除いたコードポイントの並びから。chrF と同じ数え方)。重なりを数えやすいよう、小さい順に並べて返す
    static func trigrams(_ text: String) -> [UInt64] {
        let s: [UInt32] = text.unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value)
        guard s.count >= 3 else { return [] }
        var out = Set<UInt64>()
        for i in 0...(s.count - 3) {
            out.insert(UInt64(s[i]) << 42 | UInt64(s[i + 1]) << 21 | UInt64(s[i + 2]))
        }
        return out.sorted()
    }

    /// 小さい順に並べた 2 つの集合の、重なりの数
    static func sharedCount(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var i = 0, j = 0, shared = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                shared += 1
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return shared
    }

    /// 2 つの文の対称の点 (両方の向きの chrF の平均)
    public static func similarity(_ a: String, _ b: String) -> Double {
        (ChrF.sentence(hypothesis: a, reference: b) + ChrF.sentence(hypothesis: b, reference: a)) / 2
    }

    /// 送る行 lines に似た手本を、多くて limit 件選ぶ (点の高い順)。
    /// 候補の点は、行のどれか 1 つに対する、いちばん高い点。`minimumScore` に届かない物は使わない
    public func select(for lines: [String], limit: Int) -> [MemoryExample] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        let sent = lines.map { TranslationMemory.normalizedSource($0) }.filter { !$0.isEmpty }
        let sentGrams = sent.map(Self.trigrams)
        guard sentGrams.contains(where: { !$0.isEmpty }) else { return [] }
        // 粗く絞る: 3-gram の集合の Dice 係数 (行ごとの最大と、その行)
        var rough: [(index: Int, dice: Double, line: Int)] = []
        for (i, c) in candidates.enumerated() {
            var best = 0.0, bestLine = 0
            for (k, g) in sentGrams.enumerated() where !g.isEmpty {
                let shared = Self.sharedCount(g, c.grams)
                guard shared > 0 else { continue }
                let dice = 2 * Double(shared) / Double(g.count + c.grams.count)
                if dice > best {
                    best = dice
                    bestLine = k
                }
            }
            if best > 0 { rough.append((i, best, bestLine)) }
        }
        rough.sort { $0.dice != $1.dice ? $0.dice > $1.dice : $0.index < $1.index }
        // 点を付ける (Dice 係数のいちばん高かった行との、対称の chrF)
        var scored: [(index: Int, score: Double)] = []
        for r in rough.prefix(Self.shortlist) {
            let score = Self.similarity(sent[r.line], candidates[r.index].example.source)
            if score >= Self.minimumScore { scored.append((r.index, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { candidates[$0.index].example }
    }
}
