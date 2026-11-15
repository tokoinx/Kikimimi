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
/// 形は `{ "version": 1, "sentences": [...] }`。後で訳語の対 (`terms`) を足すので、知らない項目は読み飛ばす
public struct TranslationMemory: Codable, Hashable, Sendable {
    public var version: Int
    public var sentences: [RememberedTranslation]

    /// 保存するファイルの名前 (学習した直しの台帳と同じフォルダに置く)
    public static let fileName = "translation-memory.json"

    public init(sentences: [RememberedTranslation] = []) {
        self.version = 1
        self.sentences = sentences
    }

    enum CodingKeys: String, CodingKey {
        case version, sentences
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
    }

    public var isEmpty: Bool { sentences.isEmpty }

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

    // MARK: 保存

    public static func load(from url: URL) -> TranslationMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let memory = try? decoder.decode(TranslationMemory.self, from: data) else { return TranslationMemory() }
        return memory
    }

    /// アプリが起動のときに読む。ファイルがあるのに読めないとき (壊れた・手で書き換えて形が崩れた) は、
    /// 空の記憶で上書きしてしまわないよう、そのファイルを別の名前でとっておき、その場所を返す
    public static func loadKeepingUnreadable(from url: URL, date: Date = Date()) -> (memory: TranslationMemory, setAside: URL?) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return (TranslationMemory(), nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let memory = try? decoder.decode(TranslationMemory.self, from: data) { return (memory, nil) }
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

    public init(target: String, sentences: [RememberedTranslation]) {
        let t = TranslationMemory.normalizedTarget(target)
        self.target = t
        var map: [String: String] = [:]
        // 同じ文が 2 つ在れば、新しく直した方を使う
        for entry in sentences.sorted(by: { $0.updated < $1.updated })
        where TranslationMemory.normalizedTarget(entry.target) == t {
            let key = TranslationMemory.normalizedSource(entry.source)
            let value = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key] = value
        }
        translations = map
    }

    /// 引ける文の数
    public var count: Int { translations.count }
    public var isEmpty: Bool { translations.isEmpty }

    /// 原文に合う利用者の訳。短い文・記憶に無い文は nil
    public func translation(for source: String) -> String? {
        let key = TranslationMemory.normalizedSource(source)
        guard TranslationGate.weight(key) >= Self.minimumSourceWeight else { return nil }
        return translations[key]
    }
}

extension TranslationMemory {
    /// 訳す先 target の記憶の写し (次の翻訳に渡す)
    public func lookup(target: String) -> TranslationMemoryLookup {
        TranslationMemoryLookup(target: target, sentences: sentences)
    }
}
