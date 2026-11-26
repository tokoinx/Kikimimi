import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// 翻訳の設定
public struct TranslationOptions: Sendable {
    /// 固有名詞などの正しい表記 (設定の「語彙のヒント」)
    public var glossary: String?
    /// 1 度に訳す行の数と、その長さの上限 (トークン数)
    public var maxLinesPerChunk: Int
    public var maxTokensPerChunk: Int
    /// 文脈として見せる、直前の訳済みの行の数
    public var contextLines: Int
    /// 訳の後ろが抜けた (関門の `short` の印が付いた) 訳を、文に分けて 1 回だけ訳し直すか (既定は入)。
    /// 評価で入・切を比べるための口 (`--eval-llm … --no-split-retry`)
    public var splitRetry: Bool
    /// 訳の記憶の中の似た文を、手本として指示文に足す件数の上限 (実験。既定は 0 = 切)。
    /// 0 の時は、指示文も訳も、この口を足す前と 1 字も変わらない。評価の `--eval-llm … --memory … --examples N` で入にする
    public var memoryExamples: Int

    public init(glossary: String? = nil, maxLinesPerChunk: Int = 10, maxTokensPerChunk: Int = 500, contextLines: Int = 3,
                splitRetry: Bool = true, memoryExamples: Int = 0) {
        self.glossary = glossary
        self.maxLinesPerChunk = maxLinesPerChunk
        self.maxTokensPerChunk = maxTokensPerChunk
        self.contextLines = contextLines
        self.splitRetry = splitRetry
        self.memoryExamples = memoryExamples
    }
}

/// 1 つの訳 (文ごと)。head の区間に訳を置き、covers の区間はその訳に含める
public struct TranslationResult: Sendable, Hashable {
    public var head: UUID
    public var covers: [UUID]
    public var text: String
    /// 訳の記憶 (前に利用者が直した同じ文の訳) から、LLM を呼ばずに置いた訳。
    /// 置く時に、覚え (`TranslationNote`、出どころ "memory") を残す (`Transcript.apply(_:sources:)`)
    public var fromMemory: Bool = false
    /// 訳の関門 (`TranslationGate`) の印の符号。空でなければ、置く時に覚え (出どころ "llm") を残す。
    /// text が空の結果は「訳せなかった理由」だけを運ぶ (`TranslationRunSummary.rejected`。訳は置かない)
    public var flags: [String] = []
    /// 印の説明 (消えた数など。`TranslationGate.Finding.detail`)
    public var detail: String? = nil

    public init(head: UUID, covers: [UUID], text: String, fromMemory: Bool = false, flags: [String] = [],
                detail: String? = nil) {
        self.head = head
        self.covers = covers
        self.text = text
        self.fromMemory = fromMemory
        self.flags = flags
        self.detail = detail
    }

    /// 訳せなかった理由だけを運ぶ結果か (訳は置かず、理由の覚えだけを残す)
    public var isRejection: Bool { text.isEmpty }
}

/// 1 回の翻訳で、どれだけを記憶から置き、どれだけを LLM に送ったか (行 = 文のまとまり 1 つ)
public struct TranslationRunSummary: Sendable, Hashable {
    /// 最後まで訳せなかった区間の数 (`Translator.translate` の戻り値と同じ)
    public var failed: Int
    /// 記憶に当たった行の数 (LLM に送らずに、記憶の訳を置いた)
    public var fromMemory: Int
    /// LLM に送った行の数 (読めずに 1 行ずつ送り直した分は数えない)
    public var sentToLLM: Int
    /// LLM の訳のうち、訳の関門の印が付いた行の数 (訳は置いた。「要確認」)
    public var flagged: Int
    /// LLM の訳を受け取らなかった行の理由 (text が空で、flags に理由の符号。訳せなかった行の覚えにする)。
    /// onChunk には渡さない (訳の結果だけを受け取る今の呼び手を変えないため)。呼ぶ側が、終わりに `Transcript.apply` で置く
    public var rejected: [TranslationResult]
    /// 訳の後ろが抜けて (`short`)、文に分けて訳し直したまとまりの数
    public var retried: Int
    /// そのうち、訳し直した訳に入れ替えたまとまりの数
    public var retryFixed: Int
    /// 訳し直しで増えた LLM の呼び出しの数と、送った行 (文のかけら) の数 (sentToLLM には足さない)
    public var retryCalls: Int
    public var retryLines: Int
    /// 似た文の手本を 1 件以上足した LLM の呼び出しの数 (`TranslationOptions.memoryExamples` が 0 の時は、いつも 0)
    public var examplesUsed: Int

    public init(failed: Int = 0, fromMemory: Int = 0, sentToLLM: Int = 0, flagged: Int = 0,
                rejected: [TranslationResult] = [], retried: Int = 0, retryFixed: Int = 0, retryCalls: Int = 0,
                retryLines: Int = 0, examplesUsed: Int = 0) {
        self.failed = failed
        self.fromMemory = fromMemory
        self.sentToLLM = sentToLLM
        self.flagged = flagged
        self.rejected = rejected
        self.retried = retried
        self.retryFixed = retryFixed
        self.retryCalls = retryCalls
        self.retryLines = retryLines
        self.examplesUsed = examplesUsed
    }
}

/// 翻訳役: 訳す先の言語 (target。既定は日本語) でない区間を、ローカル LLM でその言語に訳す。
///
/// Whisper の区間は文の途中で切れることが多い。区間ごとに訳すと、日本語の語順のせいで訳が隣の区間にずれる
/// (本物の Qwen3.5 4B で起きた) ので、続いている区間を文ごとにまとめて 1 行として訳す。
/// 行には番号を付けて数行ずつ訳し、出力は文法で「同じ番号・同じ行数」に縛る。読めなかった行は 1 行ずつ訳し直す。
public enum Translator {
    /// 1 文としてまとめる区間の数と長さの上限、区間のすき間 (これより空いていたら別の文)
    static let maxSegmentsPerSentence = 4
    static let maxCharactersPerSentence = 400
    static let maxGapInSentence: TimeInterval = 1.5

    /// 訳す必要がある区間か (決め方は `Script.needsTranslation(_:segmentLanguage:transcriptLanguage:target:)`)
    static func needsTranslation(_ segment: TranscriptSegment, transcriptLanguage: String?, target: String = "ja") -> Bool {
        Script.needsTranslation(segment.text, segmentLanguage: segment.language, transcriptLanguage: transcriptLanguage,
                                target: target)
    }

    /// 訳す必要があり、まだ訳がない区間の位置 (ほかの区間の訳に含まれているものは除く)
    public static func pendingIndices(_ segments: [TranscriptSegment], language: String?, target: String = "ja") -> [Int] {
        var covered = Set<UUID>()
        for s in segments where s.translation != nil {
            covered.formUnion(s.translationCovers ?? [])
        }
        return segments.indices.filter {
            segments[$0].translation == nil && !covered.contains(segments[$0].id)
                && needsTranslation(segments[$0], transcriptLanguage: language, target: target)
        }
    }

    /// 文の終わりか (句点・疑問符・感嘆符、またはそのあとに閉じかっこ・引用符)
    static func endsSentence(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, "\"'”’)）」』]".contains(last) {
            trimmed.removeLast()
        }
        guard let last = trimmed.last else { return true }
        return ".?!。？！…♪".contains(last)
    }

    /// 訳す区間を、文ごとのまとまりに分ける (位置の並び)
    static func sentenceUnits(_ pending: [Int], in segments: [TranscriptSegment]) -> [[Int]] {
        var units: [[Int]] = []
        var current: [Int] = []
        var characters = 0
        for index in pending {
            if let last = current.last {
                let continues = index == last + 1
                    && segments[index].start - segments[last].end <= maxGapInSentence
                    && !endsSentence(segments[last].text)
                    && current.count < maxSegmentsPerSentence
                    && characters + segments[index].text.count <= maxCharactersPerSentence
                if !continues {
                    units.append(current)
                    current = []
                    characters = 0
                }
            }
            current.append(index)
            characters += segments[index].text.count
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// その区間を含む「1 文」の区間の id (文の頭から順に)。訳す必要がない・もう訳がある (ほかの区間の訳に含まれる) なら空。
    /// 「翻訳」でまとめて訳すときと同じまとめ方なので、1 文だけ訳しても「翻訳」と同じ訳になる
    public static func unitIDs(containing id: UUID, in segments: [TranscriptSegment], language: String?,
                               target: String = "ja") -> [UUID] {
        let pending = pendingIndices(segments, language: language, target: target)
        guard let unit = sentenceUnits(pending, in: segments).first(where: { $0.contains { segments[$0].id == id } }) else {
            return []
        }
        return unit.map { segments[$0].id }
    }

    /// 訳し直す区間の訳を外した区間の並び (その区間を含む訳は、文ごと外す)。訳し直しで文の区切りを決め直すのに使う
    public static func clearingTranslations(of ids: Set<UUID>, in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out = segments
        for i in out.indices where ids.contains(out[i].id) || (out[i].translationCovers ?? []).contains(where: ids.contains) {
            out[i].translation = nil
            out[i].translationCovers = nil
        }
        return out
    }

    /// その区間を含む訳のまとまりの区間の id (訳のある区間と、その訳に含めた区間)。訳が無ければ、その区間だけ
    public static func translationGroupIDs(of id: UUID, in segments: [TranscriptSegment]) -> [UUID] {
        guard let head = segments.first(where: { s in
            s.translation != nil && (s.id == id || (s.translationCovers ?? []).contains(id))
        }) else { return [id] }
        return [head.id] + (head.translationCovers ?? [])
    }

    /// 訳し直す (右クリックの「この文を訳し直す」) ときに訳す区間の id (文の頭から順に)。
    /// 前の訳でまとめていた区間は、いまの文の区切りで何文になっていても全部含める
    /// (監査の直しで文の途中が文の終わりになっていると、押した区間の文だけ訳し直すと残りの区間の訳が無くなる)
    public static func redoUnitIDs(containing id: UUID, in segments: [TranscriptSegment], language: String?,
                                   target: String = "ja") -> [UUID] {
        let cleared = clearingTranslations(of: [id], in: segments)
        var out: [UUID] = []
        for member in translationGroupIDs(of: id, in: segments) where !out.contains(member) {
            for u in unitIDs(containing: member, in: cleared, language: language, target: target) where !out.contains(u) {
                out.append(u)
            }
        }
        return out
    }

    /// 指示文。訳す先が日本語の時は、これまでの文と一字も変えない (日本語だけの注意 (かな・漢字・カタカナ) が在る)
    static func systemPrompt(language: String?, target: String = "ja") -> String {
        guard target == "ja" else { return otherSystemPrompt(from: sourceLanguageName(for: language), target: target) }
        let lang = Script.englishName(for: language)
        return """
        You are an expert subtitle translator. Translate each numbered line of a speech transcript \
        from \(lang) into natural, easy-to-read Japanese.
        - Write Japanese only (kana and kanji). Never write Chinese.
        - Output exactly one line for each input line, in the same order, starting with the same number, like "[3] 訳文".
        - Each line is one sentence or a part of one. Translate every line on its own line. Never merge, split, skip or reorder lines.
        - Translate the meaning faithfully. Keep numbers and units accurate.
        - Keep every name and term from the glossary exactly as written, in the same letters (do not turn them into katakana). \
        Write other well-known names in their usual Japanese form.
        - If a line is already Japanese, copy it unchanged.
        - Output only the translations, with no notes.
        """
    }

    /// 日本語のほかの言語へ訳す時の指示文に書く、原文の言語の名前。原文が日本語なら "Japanese"、
    /// ほかは `Script.englishName(for:)` (監査の指示文と同じ名前。ja だけは、監査では「the original language」のまま)
    static func sourceLanguageName(for language: String?) -> String {
        language?.lowercased() == "ja" ? "Japanese" : Script.englishName(for: language)
    }

    /// 日本語のほかの言語へ訳す時の指示文 (出力の形の例は、手本に任せる)
    static func otherSystemPrompt(from lang: String, target: String) -> String {
        let name = TranslationTarget.englishName(for: target)
        var only = "- Write \(name) only."
        switch target {
        case "zh": only += " Use Simplified Chinese characters."
        case "pt": only += " Use Brazilian Portuguese."
        default: break
        }
        return """
        You are an expert subtitle translator. Translate each numbered line of a speech transcript \
        from \(lang) into natural, easy-to-read \(name).
        \(only)
        - Output exactly one line for each input line, in the same order, starting with the same number in square brackets.
        - Each line is one sentence or a part of one. Translate every line on its own line. Never merge, split, skip or reorder lines.
        - Translate the meaning faithfully. Keep numbers and units accurate.
        - Keep every name and term from the glossary exactly as written, in the same letters. \
        Write other well-known names in their usual \(name) form.
        - If a line is already \(name), copy it unchanged.
        - Output only the translations, with no notes.
        """
    }

    /// 日本語へ訳す時の手本のやりとり (`examples(for: "ja")` と同じ)
    public static let examples = TranslationExamples.examples(for: "ja")

    /// 訳す先の言語の手本のやりとり (中身は `TranslationExamples`)
    public static func examples(for target: String) -> [LLMExample] {
        TranslationExamples.examples(for: target)
    }

    /// 指示文の user の部分。terms (訳語の対) は、この 1 回に送る行に出る物だけを渡す (`checkedTranslateLines`)。
    /// terms が空の時は、対を入れる前の指示文と 1 字も変わらない (評価の前後を比べるため)。
    /// examples (記憶の似た文の手本) も同じく、空の時は手本を入れる前の指示文と 1 字も変わらない。
    /// 手本は、訳語の対の後・直前の行の前に置く
    static func userPrompt(lines: [String], context: [(source: String, translation: String)], glossary: String?,
                           terms: [TermPair] = [], examples: [MemoryExample] = []) -> String {
        var parts: [String] = []
        if let g = glossaryText(glossary, without: terms) {
            parts.append("Glossary (keep exactly as written): \(g)")
        }
        if !terms.isEmpty {
            parts.append("Terms (always translate the left as the right):\n"
                + terms.map { "\($0.source) => \($0.translation)" }.joined(separator: "\n"))
        }
        if !examples.isEmpty {
            parts.append("Examples of earlier translations (same style):\n"
                + examples.map { "\($0.source) => \($0.translation)" }.joined(separator: "\n"))
        }
        if !context.isEmpty {
            parts.append("Previous lines, already translated (context only, do not output):\n"
                + context.map { "\($0.source) => \($0.translation)" }.joined(separator: "\n"))
        }
        parts.append("Lines to translate:\n" + lines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// 指示文に書く用語集 (空なら nil)。訳語の対の原語と同じ語 (大文字と小文字は区別しない) は外す:
    /// 用語集は「そのまま書く」語、対は「訳語に訳す」語で、両方に在ると指示が食い違うため。
    /// 外す語が無い時は、用語集の文をそのまま返す (区切りを書き直さない)。外す時は、「,」「、」・改行で分けて「, 」でつなぎ直す
    static func glossaryText(_ glossary: String?, without terms: [TermPair]) -> String? {
        guard let g = glossary?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return nil }
        guard !terms.isEmpty else { return g }
        let drop = Set(terms.map { $0.source.lowercased() })
        let items = g.split(whereSeparator: { $0 == "," || $0 == "、" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard items.contains(where: { drop.contains($0.lowercased()) }) else { return g }
        let kept = items.filter { !drop.contains($0.lowercased()) }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// 答えを読む (番号は 1 始まり)
    static func parse(_ output: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        for raw in completeLines(of: output) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let n = Int(line[line.index(after: line.startIndex)..<close]), (1...count).contains(n),
                  result[n] == nil else { continue }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result[n] = text }
        }
        return result
    }

    /// 訳として受け取ってよいか (延々と続く・空のもの・ほかの言語になったものは捨てる)
    /// 中の検査は `isTooLong` と `hasWrongScript` (訳の関門 `TranslationGate` も、同じ 2 つを使う)
    static func isPlausible(_ translation: String, source: String, target: String = "ja") -> Bool {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return !isTooLong(t, source: source, target: target) && !hasWrongScript(t, source: source, target: target)
    }

    /// 訳が長すぎるか (延々と続いた訳)。translation は、前後の空白を外した物
    static func isTooLong(_ translation: String, source: String, target: String = "ja") -> Bool {
        if target == "ja" { return translation.count > source.count * 4 + 40 }
        return translation.count > source.count * 6 + 60
    }

    /// 訳の文字の種類が、訳す先の言語に合わないか。translation は、前後の空白を外した物
    static func hasWrongScript(_ translation: String, source: String, target: String = "ja") -> Bool {
        let t = translation
        switch target {
        case "ja":
            // 日本語: 中国語になったものを捨てる (これまでと同じ)
            return Script.containsNonJapaneseHan(t)
        case "ko", "ru", "th":
            // その言語の文字が 1 つも無い訳は捨てる。ただし、原文をそのまま写したもの (名前だけの行など) は受け取る。
            // 写したかは、文字と数字だけで比べる (「NVIDIA.」を「NVIDIA」と写した時のように、句読点だけ違っても写し)
            let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return Script.hasLetters(s) && !Script.hasLetters(t, of: target) && lettersAndDigits(t) != lettersAndDigits(s)
        case "zh":
            // 簡体字の訳に、かなが入っていたら日本語に流れている (中黒「・」と長音「ー」は、かなと数えない)
            return Script.hasKanaLetters(t)
        default:
            // ラテン文字の言語は、文字の種類を見ない (原文と同じ文字なので、見分けられない)
            return false
        }
    }

    /// 文字と数字だけを残した文 (句読点・記号・空白を外す)。訳が原文の写しかを見るのに使う
    static func lettersAndDigits(_ text: String) -> String {
        let kept = CharacterSet.letters.union(.decimalDigits)
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { kept.contains($0) }))
    }

    /// まだ訳していない区間を、文ごとに訳す。1 まとまり訳すごとに onChunk を呼ぶ (done / total は区間の数)。
    /// only を渡すと、その区間を含む文だけを訳す (行ごとの「訳」。文のまとめ方は全体を訳すときと同じ)。
    /// 戻り値は、最後まで訳せなかった区間の数。
    /// memory を渡すと、記憶に在る文は LLM に送らずに記憶の訳を置く (`translateSummarizing` を見る)
    @discardableResult
    public static func translate(_ segments: [TranscriptSegment], language: String?, target: String = "ja",
                                 options: TranslationOptions = TranslationOptions(),
                                 only: Set<UUID>? = nil,
                                 memory: TranslationMemoryLookup? = nil,
                                 generator: any TextGenerating, shouldCancel: () -> Bool,
                                 onChunk: (_ results: [TranslationResult], _ done: Int, _ total: Int) -> Void) throws -> Int {
        try translateSummarizing(segments, language: language, target: target, options: options, only: only,
                                 memory: memory, generator: generator, shouldCancel: shouldCancel,
                                 onChunk: onChunk).failed
    }

    /// 訳の記憶だけで、訳すべき文が全部埋まるか (true なら、LLM を読み込まずに `translateSummarizing` を
    /// generator: nil で呼べる)。訳す文が 1 つも無い時は false (いつもどおりに進める)
    public static func memoryCoversAll(_ segments: [TranscriptSegment], language: String?, target: String = "ja",
                                       only: Set<UUID>? = nil, memory: TranslationMemoryLookup?,
                                       memoryExcluding: Set<UUID> = []) -> Bool {
        guard let memory, !memory.isEmpty else { return false }
        let units = pendingUnits(segments, language: language, target: target, only: only)
        guard !units.isEmpty else { return false }
        return units.allSatisfy { unit in
            rememberedTranslation(for: unit, in: segments, target: target, memory: memory,
                                  excluding: memoryExcluding) != nil
        }
    }

    /// 訳す文のまとまり (only を渡すと、その区間を含む文だけ)
    static func pendingUnits(_ segments: [TranscriptSegment], language: String?, target: String,
                             only: Set<UUID>?) -> [[Int]] {
        var units = sentenceUnits(pendingIndices(segments, language: language, target: target), in: segments)
        if let only {
            units = units.filter { unit in unit.contains { only.contains(segments[$0].id) } }
        }
        return units
    }

    /// 文のまとまり unit に当たる記憶の訳 (無い・短い・訳す先が違う・除く区間を含む時は nil)。
    /// まとまりの原文は、訳を置いた後の `Transcript.translationSource(ofHead:)` と同じ作り方 (区間の文をつなぐ)
    static func rememberedTranslation(for unit: [Int], in segments: [TranscriptSegment], target: String,
                                      memory: TranslationMemoryLookup, excluding: Set<UUID>) -> String? {
        guard memory.target == TranslationMemory.normalizedTarget(target),
              !unit.contains(where: { excluding.contains(segments[$0].id) }) else { return nil }
        return memory.translation(for: Transcript.join(unit.map { segments[$0].text }))
    }

    /// `translate` と同じく訳し、記憶に当たった行と LLM に送った行の数も返す。
    ///
    /// memory を渡すと、文のまとまりごとに、その原文 (`TranslationMemory.normalizedSource` でそろえた物) を引き、
    /// 当たったまとまりは LLM に送らずに記憶の訳を置く (`TranslationResult.fromMemory`)。残りだけを、今までどおり数行ずつ送る。
    /// 当たった文も、後ろの行の文脈 (直前の訳済みの行) には入れる。
    /// memoryExcluding の区間を含むまとまりは、記憶を引かない (利用者が自分で押した「この文を訳し直す」)。
    /// generator が nil の時は、LLM に送る行を訳せなかった行と数える (記憶だけで埋まる時に、LLM を読み込まずに呼ぶため)
    public static func translateSummarizing(_ segments: [TranscriptSegment], language: String?, target: String = "ja",
                                            options: TranslationOptions = TranslationOptions(),
                                            only: Set<UUID>? = nil,
                                            memory: TranslationMemoryLookup? = nil,
                                            memoryExcluding: Set<UUID> = [],
                                            generator: (any TextGenerating)?, shouldCancel: () -> Bool,
                                            onChunk: (_ results: [TranslationResult], _ done: Int, _ total: Int) -> Void)
        throws -> TranslationRunSummary {
        let units = pendingUnits(segments, language: language, target: target, only: only)
        let pending = units.flatMap { $0 }
        // 「日本語＋英語」では、訳す区間に付いた言語 (いちばん多いもの) を原文の言語としてプロンプトに書く
        let source = sourceLanguage(of: pending.map { segments[$0] }) ?? language
        let sources = units.map { unit in Transcript.join(unit.map { segments[$0].text }) }
        // 記憶に当たったまとまり (まとまりの位置 → 記憶の訳)
        var remembered: [Int: String] = [:]
        if let memory, !memory.isEmpty {
            for u in units.indices {
                if let t = rememberedTranslation(for: units[u], in: segments, target: target, memory: memory,
                                                 excluding: memoryExcluding) {
                    remembered[u] = t
                }
            }
        }
        // 訳語の対 (訳す先が同じ写しの物だけ)。送る行・関門には、その原文に出る物だけを使う
        let termPairs = memory.map { $0.target == TranslationMemory.normalizedTarget(target) ? $0.terms : [] } ?? []
        // 利用者の判定から学んで止める検査 (訳す先が同じ写しの物だけ)。外すのは覚えに残す印だけで、
        // 訳し直しの引き金 (short) は、外す前の関門の判定で決める
        let suppressed = memory.map { $0.target == TranslationMemory.normalizedTarget(target) ? $0.suppressedChecks : [] } ?? []
        func unitTerms(_ u: Int) -> [(source: String, translation: String)] {
            TermPair.matching(termPairs, in: sources[u]).map { (source: $0.source, translation: $0.translation) }
        }
        let toLLM = units.indices.filter { remembered[$0] == nil }
        var summary = TranslationRunSummary(fromMemory: remembered.count)
        // 似た文の手本 (実験。既定は切)。訳す先が同じ写しの、取り分けでない文だけ。今の翻訳の原文と同じ文
        // (区間の文・まとまりの文。U2 の再利用で訳が置かれる文と、評価で抜く文 memoryExcluding を含む) は使わない
        let exampleIndex: MemoryExampleIndex?
        if options.memoryExamples > 0, let memory, memory.target == TranslationMemory.normalizedTarget(target),
           !memory.examples.isEmpty {
            let same = Set((segments.map(\.text) + sources).map { TranslationMemory.normalizedSource($0) })
            exampleIndex = MemoryExampleIndex(memory.examples, excluding: same)
        } else {
            exampleIndex = nil
        }
        func similarExamples(_ lines: [String]) -> [MemoryExample] {
            guard let exampleIndex else { return [] }
            let chosen = exampleIndex.select(for: lines, limit: options.memoryExamples)
            if !chosen.isEmpty { summary.examplesUsed += 1 }
            return chosen
        }
        let chunks: [[Int]]
        if let generator {
            chunks = LLMChunker.chunks(toLLM, cost: { generator.tokenCount(sources[$0]) + 4 },
                                       maxLines: options.maxLinesPerChunk, maxCost: options.maxTokensPerChunk)
        } else {
            chunks = []
            summary.failed = toLLM.reduce(0) { $0 + units[$1].count }
        }
        let system = systemPrompt(language: source, target: target)
        // 文脈用に、訳しながら訳を覚えておく (最初から訳がある区間も使う)
        var known: [(position: Int, source: String, translation: String)] = segments.indices.compactMap { i in
            guard let t = segments[i].translation else { return nil }
            // いくつかの区間をまとめた訳は、原文もまとめた文と組にする (断片と文全体の訳を組にしない)
            let covers = Set(segments[i].translationCovers ?? [])
            let source = covers.isEmpty ? segments[i].text
                : Transcript.join([segments[i].text] + segments.filter { covers.contains($0.id) }.map(\.text))
            return (i, source, t)
        }
        var done = 0
        onChunk([], 0, pending.count)
        // 記憶に当たった文を先に置く (LLM に送る文の文脈にも入れる)
        if !remembered.isEmpty {
            if shouldCancel() { throw LLMError.cancelled }
            var batch: [TranslationResult] = []
            for u in units.indices {
                guard let t = remembered[u] else { continue }
                let unit = units[u]
                batch.append(TranslationResult(head: segments[unit[0]].id, covers: unit.dropFirst().map { segments[$0].id },
                                               text: t, fromMemory: true))
                known.append((unit[0], sources[u], t))
                done += unit.count
            }
            known.sort { $0.position < $1.position }
            onChunk(batch, done, pending.count)
        }
        // generator が無い時は、chunks は空 (LLM に送る行は、上で訳せなかった行と数えてある)
        // 訳の関門の写しの検査に使う、原文の言語 (まとまりの先頭の区間の言語。無ければ全体の言語)
        func unitLanguage(_ u: Int) -> String? { segments[units[u][0]].language ?? source }
        for chunk in chunks {
            guard let generator else { break }
            if shouldCancel() { throw LLMError.cancelled }
            summary.sentToLLM += chunk.count
            let first = units[chunk[0]][0]
            let context = known.filter { $0.position < first }.suffix(options.contextLines)
                .map { (source: $0.source, translation: $0.translation) }
            var results = try checkedTranslateLines(chunk.map { sources[$0] }, context: Array(context), language: source,
                                                    target: target, system: system, options: options, terms: termPairs,
                                                    examples: similarExamples(chunk.map { sources[$0] }),
                                                    generator: generator, shouldCancel: shouldCancel)
            // 読めなかった行は 1 行ずつ訳し直す (理由は、最後に試した時の物)
            if chunk.count > 1 {
                for k in chunk.indices where results[k].text == nil {
                    if shouldCancel() { throw LLMError.cancelled }
                    results[k] = try checkedTranslateLines([sources[chunk[k]]], context: Array(context), language: source,
                                                           target: target, system: system, options: options,
                                                           terms: termPairs, examples: similarExamples([sources[chunk[k]]]),
                                                           generator: generator, shouldCancel: shouldCancel)[0]
                }
            }
            var batch: [TranslationResult] = []
            for (k, u) in chunk.enumerated() {
                let unit = units[u]
                let head = segments[unit[0]].id
                let covers = unit.dropFirst().map { segments[$0].id }
                if var t = results[k].text {
                    // 通った訳は、関門に掛けて印を付ける。訳の後ろが抜けた (short) 時だけ、文に分けて 1 回訳し直す
                    var finding = TranslationGate.assess(source: sources[u], translation: t, sourceLanguage: unitLanguage(u),
                                                         target: target, terms: unitTerms(u))
                    if options.splitRetry, finding.flags.contains(TranslationGate.short) {
                        if shouldCancel() { throw LLMError.cancelled }
                        // 文脈は、このまとまりの前の物 (同じまとまりの初めの訳と同じ決め方)
                        let before = known.filter { $0.position < unit[0] }.sorted { $0.position < $1.position }
                            .suffix(options.contextLines).map { (source: $0.source, translation: $0.translation) }
                        if let retry = try splitRetry(source: sources[u], sourceLanguage: unitLanguage(u),
                                                      promptLanguage: source, target: target, system: system,
                                                      context: Array(before), options: options, terms: termPairs,
                                                      generator: generator, shouldCancel: shouldCancel) {
                            summary.retried += 1
                            summary.retryCalls += retry.calls
                            summary.retryLines += retry.lines
                            if let fixed = retry.text {
                                t = fixed
                                finding = retry.finding
                                summary.retryFixed += 1
                            }
                        }
                    }
                    if !suppressed.isEmpty { finding = finding.removing(suppressed) }
                    if !finding.flags.isEmpty { summary.flagged += 1 }
                    batch.append(TranslationResult(head: head, covers: covers, text: t, flags: finding.flags,
                                                   detail: finding.detail))
                    known.append((unit[0], sources[u], t))
                } else {
                    summary.failed += unit.count
                    // 訳せなかった理由を残す (まとまりの先頭の区間に。訳が後から入れば、覚えは合わなくなって消える)
                    summary.rejected.append(TranslationResult(head: head, covers: [], text: "", flags: results[k].rejection))
                }
                done += unit.count
            }
            known.sort { $0.position < $1.position }
            onChunk(batch, done, pending.count)
        }
        return summary
    }

    // MARK: 訳の後ろが抜けた時の、文に分けた訳し直し

    /// 文に分けて訳し直す時、1 行に送る原文の重さ (`TranslationGate.weight`) の下限。
    /// これより軽いかけら (「Oh yeah.」など) は、前の文 (前が無ければ次の文) にまとめる
    static let splitRetryMinimumPieceWeight = 12

    /// 文に分けた訳し直しの結果
    struct SplitRetry {
        /// つないだ訳 (採る条件に合わなかった時は nil。初めの訳を残す)
        var text: String?
        /// つないだ訳を関門に掛けた結果 (text が nil の時は使わない)
        var finding: TranslationGate.Finding
        /// 増えた LLM の呼び出しの数と、送った行の数
        var calls: Int
        var lines: Int
    }

    /// 原文を文に分けて、文 1 つを番号つきの 1 行として送り直し、訳を原文の順につなぐ。
    /// 文が 2 つ以上に分かれない時は、送らずに nil を返す。
    /// つないだ訳を関門に掛け、重い印が無く `short` が消えた時だけ text を返す。
    /// かけらの 1 つでも訳せなかった (受け取れなかった・返らなかった) 時は、text は nil
    static func splitRetry(source: String, sourceLanguage: String?, promptLanguage: String?, target: String,
                           system: String, context: [(source: String, translation: String)],
                           options: TranslationOptions, terms: [TermPair] = [], generator: any TextGenerating,
                           shouldCancel: () -> Bool) throws -> SplitRetry? {
        let pieces = sentencePieces(source, language: sourceLanguage)
        guard pieces.count >= 2 else { return nil }
        // 初めの訳と同じ決め方で、数行ずつに分ける (行の数と長さの上限)
        let chunks = LLMChunker.chunks(Array(pieces.indices), cost: { generator.tokenCount(pieces[$0]) + 4 },
                                       maxLines: options.maxLinesPerChunk, maxCost: options.maxTokensPerChunk)
        var texts: [String?] = []
        for chunk in chunks {
            if shouldCancel() { throw LLMError.cancelled }
            // かけらにも、そのかけらに出る訳語の対を渡す (checkedTranslateLines が、送る行に出る物だけを選ぶ)。
            // 似た文の手本は渡さない (訳し直しの指示を伸ばさない)
            let outcomes = try checkedTranslateLines(chunk.map { pieces[$0] }, context: context, language: promptLanguage,
                                                     target: target, system: system, options: options, terms: terms,
                                                     generator: generator, shouldCancel: shouldCancel)
            texts += outcomes.map(\.text)
        }
        var result = SplitRetry(text: nil, finding: TranslationGate.Finding(), calls: chunks.count, lines: pieces.count)
        let parts = texts.compactMap { $0 }
        guard parts.count == pieces.count else { return result }
        let joined = joinTranslations(parts, target: target)
        let finding = TranslationGate.assess(source: source, translation: joined, sourceLanguage: sourceLanguage,
                                             target: target,
                                             terms: TermPair.matching(terms, in: source)
                                                .map { (source: $0.source, translation: $0.translation) })
        guard !finding.isSevere, !finding.flags.contains(TranslationGate.short) else { return result }
        result.text = joined
        result.finding = finding
        return result
    }

    /// 文ごとの訳をつなぐ。訳す先が ja・zh の時は間に何も入れない。ほかは空白 1 つ
    /// (タイ語は、語の間は詰めるが、文の間には空白を置く書き方なので、空白でつなぐ)
    static func joinTranslations(_ parts: [String], target: String) -> String {
        let separator = ["ja", "zh"].contains(TranslationTarget.normalized(target)) ? "" : " "
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    /// 訳し直しに送る文のかけら。split で文に分け、重さが minimumWeight に届かないかけらは前の文にまとめる
    /// (先頭のかけらは、次の文にまとめる。全部が軽ければ 1 つ)。まとめる時のつなぎ方は `Transcript.join`
    static func sentencePieces(_ text: String, language: String?,
                               minimumWeight: Int = splitRetryMinimumPieceWeight,
                               split: (String, String?) -> [String] = splitSentences) -> [String] {
        var out: [String] = []
        var lead: [String] = []
        for raw in split(text, language) {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if TranslationGate.weight(piece) < minimumWeight {
                if let last = out.popLast() {
                    out.append(Transcript.join([last, piece]))
                } else {
                    lead.append(piece)
                }
            } else {
                out.append(Transcript.join(lead + [piece]))
                lead = []
            }
        }
        if !lead.isEmpty { out.append(Transcript.join(lead)) }
        return out
    }

    /// 文に分ける (NaturalLanguage の `NLTokenizer`。原文の言語が分かる時は、その言語として分ける)。
    /// `NLTokenizer` が 1 つしか返さない時、字の過半がタイ・ラオ・ビルマ・クメールの字なら、空白の所で分ける
    /// (これらの言葉は、文の終わりの印を書かず、空白で文や句を区切るので、`NLTokenizer` では全体が 1 つになる)。
    /// 言語の印には頼らず、字で決める (言語が分からない時も同じ)。ほかの字の文は、空白が在っても分けない。
    /// NaturalLanguage の無い環境では、分けない
    static func splitSentences(_ text: String, language: String?) -> [String] {
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let language, !language.isEmpty {
            tokenizer.setLanguage(NLLanguage(rawValue: language.lowercased() == "zh" ? "zh-Hans" : language))
        }
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(String(text[range]))
            return true
        }
        // 分けない時の返し方は、前と同じにする (`NLTokenizer` が返した 1 つを、そのまま返す)
        if out.count <= 1, let pieces = splitAtSpacesIfUnspacedScript(text) { return pieces }
        return out.isEmpty ? [text] : out
        #else
        return [text]
        #endif
    }

    /// 字 (letter) の過半がタイ・ラオ・ビルマ・クメールの字で、空白が在る時に、空白の連なりの所で分ける。
    /// 空白は前のかけらの尻に付ける (`NLTokenizer` と同じ。つなぐと元の字に戻る)。
    /// 先頭の空白は、初めのかけらに含める。条件に合わない時と、分かれない時は nil
    static func splitAtSpacesIfUnspacedScript(_ text: String) -> [String]? {
        var letters = 0
        var southeastAsian = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if Script.isUnspacedSoutheastAsian(scalar) { southeastAsian += 1 }
        }
        guard letters > 0, southeastAsian * 2 > letters else { return nil }
        // 字のかたまり (Character) ごとに見るので、結合する印の前では切らない
        var out: [String] = []
        var current = ""
        var afterSpace = false
        var seenNonSpace = false
        for ch in text {
            if ch.isWhitespace {
                if seenNonSpace { afterSpace = true }
            } else {
                if afterSpace {
                    out.append(current)
                    current = ""
                    afterSpace = false
                }
                seenNonSpace = true
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out.count >= 2 ? out : nil
    }

    /// 区間に付いた言語のうち、いちばん多いもの (区間に言語が無ければ nil。同じ数なら先に出てきたもの)
    static func sourceLanguage(of segments: [TranscriptSegment]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in segments {
            guard let l = s.language else { continue }
            if counts[l] == nil { order.append(l) }
            counts[l, default: 0] += 1
        }
        var best: String? = nil
        for l in order where best.map({ (counts[l] ?? 0) > (counts[$0] ?? 0) }) ?? true { best = l }
        return best
    }

    /// 数行をまとめて訳す。読めなかった行は nil
    static func translateLines(_ lines: [String], context: [(source: String, translation: String)], language: String?,
                               target: String = "ja", system: String, options: TranslationOptions,
                               generator: any TextGenerating, shouldCancel: () -> Bool) throws -> [String?] {
        try checkedTranslateLines(lines, context: context, language: language, target: target, system: system,
                                  options: options, generator: generator, shouldCancel: shouldCancel).map(\.text)
    }

    /// 1 行の訳の受け取りの結果: 受け取った訳、または受け取らなかった理由の符号 (`TranslationGate` の
    /// failed・script・long。`isPlausible` が落とす範囲と同じ)
    struct LineOutcome {
        var text: String?
        var rejection: [String]
    }

    /// 受け取らなかった理由の符号 (受け取れる訳なら空)。中の検査は `isPlausible` と同じ
    static func rejectionFlags(_ translation: String?, source: String, target: String) -> [String] {
        let t = (translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [TranslationGate.failed] }
        var flags: [String] = []
        if hasWrongScript(t, source: source, target: target) { flags.append(TranslationGate.script) }
        if isTooLong(t, source: source, target: target) { flags.append(TranslationGate.long) }
        return flags
    }

    /// `translateLines` と同じく訳し、受け取らなかった行には理由を付けて返す
    static func checkedTranslateLines(_ lines: [String], context: [(source: String, translation: String)],
                                      language: String?, target: String = "ja", system: String,
                                      options: TranslationOptions, terms: [TermPair] = [], examples: [MemoryExample] = [],
                                      generator: any TextGenerating, shouldCancel: () -> Bool) throws -> [LineOutcome] {
        // 訳語の対は、この 1 回に送る行に出る物だけ (無ければ、指示文は対を入れる前と同じ)。
        // 出力の上限 (budget) は、下で指示文の長さを数えて決めるので、対・手本で指示文が伸びた分も引かれる
        // (上限の 2 つ目の式は送る行の長さだけで決まるので、指示文が伸びても、文脈の長さが足りる限り変わらない)
        let used = TermPair.matching(terms, in: lines.joined(separator: "\n"))
        let user = userPrompt(lines: lines, context: context, glossary: options.glossary, terms: used, examples: examples)
        let shots = TranslationExamples.examples(for: target)
        let sourceTokens = lines.reduce(0) { $0 + generator.tokenCount($1) }
        let exampleTokens = shots.reduce(0) { $0 + generator.tokenCount($1.user) + generator.tokenCount($1.assistant) + 16 }
        let promptTokens = generator.tokenCount(system) + generator.tokenCount(user) + exampleTokens + 32
        let budget = min(generator.contextLength - promptTokens - 8, 32 + sourceTokens * 4 + lines.count * 12)
        guard budget > 8 else { return lines.map { _ in LineOutcome(text: nil, rejection: [TranslationGate.failed]) } }
        let longest = lines.map(\.utf8.count).max() ?? 0
        let output = try generator.generate(
            LLMPrompt(system: system, user: user, grammar: GBNF.numberedLines(count: lines.count), maxTokens: budget,
                      maxLineBytes: longest * 3 + 120, examples: shots, japaneseOnly: target == "ja"),
            shouldCancel: shouldCancel
        )
        let parsed = parse(output, count: lines.count)
        return lines.indices.map { k in
            let t = parsed[k + 1]
            if let t, isPlausible(t, source: lines[k], target: target) { return LineOutcome(text: t, rejection: []) }
            // isPlausible が落とした訳は、必ず理由が 1 つ以上付く (付かなければ、訳が返らなかった物とする)
            let flags = rejectionFlags(t, source: lines[k], target: target)
            return LineOutcome(text: nil, rejection: flags.isEmpty ? [TranslationGate.failed] : flags)
        }
    }
}

extension Transcript {
    /// 訳を 1 つ置く。訳したあいだに監査で文が変わっていた区間 (sources と違う) には置かない。
    /// 訳した言語 (`translationLanguage`) は、ここでは変えない (訳した後に、呼ぶ側が `translationModel` と並べて入れる)。
    /// 利用者が直した訳 (今も合う "edited" の覚え) のまとまりに当たる区間を含む訳も置かない: 翻訳の途中に利用者が直した訳が、
    /// 後から届いた機械の訳や、翻訳の終わりにもう 1 度置く訳 (AppModel) で、機械の訳に戻らないように。
    /// 利用者が自分で訳し直しを選んだ時は、呼ぶ側が先に覚えを捨てる (`dropUserTranslations(touching:)`・`removeAllTranslations()`)
    ///
    /// text が空の結果 (`TranslationResult.isRejection`) は、訳を置かずに「訳せなかった理由」の覚えだけを残す
    /// (区間に訳がまだ無く、文が訳した時と同じ時だけ)
    @discardableResult
    public mutating func apply(_ result: TranslationResult, sources: [UUID: String]) -> Bool {
        if result.isRejection { return recordRejection(result, sources: sources) }
        let ids = [result.head] + result.covers
        if translationReview?.isEmpty == false {
            let protected = userTranslatedIDs
            if ids.contains(where: protected.contains) { return false }
        }
        guard ids.allSatisfy({ id in segments.first { $0.id == id }?.text == sources[id] }),
              let index = segments.firstIndex(where: { $0.id == result.head }) else { return false }
        // まとめた区間が、いまも訳の区間のすぐ後ろに順に並んでいるときだけ (訳しているあいだに削除を元に戻した、など)
        let following = segments.dropFirst(index + 1).prefix(result.covers.count)
        guard following.count == result.covers.count, zip(following, result.covers).allSatisfy({ $0.id == $1 }) else { return false }
        segments[index].translation = result.text
        segments[index].translationCovers = result.covers.isEmpty ? nil : result.covers
        for i in following.indices {
            segments[i].translation = nil
            segments[i].translationCovers = nil
        }
        // 訳の出どころの覚え: 記憶から置いた訳には "memory"、関門の印が付いた機械の訳には "llm" (印と説明つき) を残す。
        // 印の無い機械の訳を置いた時は、このまとまりの古い覚えを捨てる
        // (ここまで来たのは、守る "edited" の覚えが無いまとまりだけ。覚えが無い結果は、覚えを見ずに済ませる)
        let flagged = !result.fromMemory && !result.flags.isEmpty
        if result.fromMemory || flagged || translationReview?.isEmpty == false {
            let signature = Self.reviewSignature(source: translationSource(at: index), translation: result.text)
            // 同じ訳をもう 1 度置いた時 (翻訳の終わりに、もう 1 度置く) は、利用者の「この訳でよい」を残す
            let kept = flagged ? translationReview?.last { $0.head == result.head && $0.signature == signature && $0.isConfirmed }
                : nil
            var notes = (translationReview ?? []).filter { !ids.contains($0.head) }
            if let kept {
                notes.append(kept)
            } else if result.fromMemory {
                notes.append(TranslationNote(head: result.head, signature: signature, origin: TranslationNote.memory))
            } else if flagged {
                notes.append(TranslationNote(head: result.head, signature: signature, flags: result.flags,
                                             detail: result.detail, origin: TranslationNote.llm))
            }
            translationReview = notes.isEmpty ? nil : notes
        }
        return true
    }

    /// 訳せなかった理由の覚えを残す (訳は置かない)。区間に訳がまだ無い (ほかの訳にも含まれていない) 時、
    /// 文が訳した時と同じ時だけ。残したら true
    mutating func recordRejection(_ result: TranslationResult, sources: [UUID: String]) -> Bool {
        guard !result.flags.isEmpty,
              let index = segments.firstIndex(where: { $0.id == result.head }),
              segments[index].text == sources[result.head],
              segments[index].translation == nil,
              !segments.contains(where: { ($0.translationCovers ?? []).contains(result.head) }) else { return false }
        var notes = (translationReview ?? []).filter { $0.head != result.head }
        notes.append(TranslationNote(head: result.head,
                                     signature: Self.reviewSignature(source: translationSource(at: index), translation: ""),
                                     flags: result.flags, detail: result.detail, origin: TranslationNote.llm))
        translationReview = notes
        return true
    }
}
