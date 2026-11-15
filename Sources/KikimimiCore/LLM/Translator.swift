import Foundation

/// 翻訳の設定
public struct TranslationOptions: Sendable {
    /// 固有名詞などの正しい表記 (設定の「語彙のヒント」)
    public var glossary: String?
    /// 1 度に訳す行の数と、その長さの上限 (トークン数)
    public var maxLinesPerChunk: Int
    public var maxTokensPerChunk: Int
    /// 文脈として見せる、直前の訳済みの行の数
    public var contextLines: Int

    public init(glossary: String? = nil, maxLinesPerChunk: Int = 10, maxTokensPerChunk: Int = 500, contextLines: Int = 3) {
        self.glossary = glossary
        self.maxLinesPerChunk = maxLinesPerChunk
        self.maxTokensPerChunk = maxTokensPerChunk
        self.contextLines = contextLines
    }
}

/// 1 つの訳 (文ごと)。head の区間に訳を置き、covers の区間はその訳に含める
public struct TranslationResult: Sendable, Hashable {
    public var head: UUID
    public var covers: [UUID]
    public var text: String
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

    static func userPrompt(lines: [String], context: [(source: String, translation: String)], glossary: String?) -> String {
        var parts: [String] = []
        if let g = glossary?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            parts.append("Glossary (keep exactly as written): \(g)")
        }
        if !context.isEmpty {
            parts.append("Previous lines, already translated (context only, do not output):\n"
                + context.map { "\($0.source) => \($0.translation)" }.joined(separator: "\n"))
        }
        parts.append("Lines to translate:\n" + lines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
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
    @discardableResult
    public static func translate(_ segments: [TranscriptSegment], language: String?, target: String = "ja",
                                 options: TranslationOptions = TranslationOptions(),
                                 only: Set<UUID>? = nil,
                                 generator: any TextGenerating, shouldCancel: () -> Bool,
                                 onChunk: (_ results: [TranslationResult], _ done: Int, _ total: Int) -> Void) throws -> Int {
        var units = sentenceUnits(pendingIndices(segments, language: language, target: target), in: segments)
        if let only {
            units = units.filter { unit in unit.contains { only.contains(segments[$0].id) } }
        }
        let pending = units.flatMap { $0 }
        // 「日本語＋英語」では、訳す区間に付いた言語 (いちばん多いもの) を原文の言語としてプロンプトに書く
        let source = sourceLanguage(of: pending.map { segments[$0] }) ?? language
        let sources = units.map { unit in Transcript.join(unit.map { segments[$0].text }) }
        let chunks = LLMChunker.chunks(Array(units.indices), cost: { generator.tokenCount(sources[$0]) + 4 },
                                       maxLines: options.maxLinesPerChunk, maxCost: options.maxTokensPerChunk)
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
        var failed = 0
        var done = 0
        onChunk([], 0, pending.count)
        for chunk in chunks {
            if shouldCancel() { throw LLMError.cancelled }
            let first = units[chunk[0]][0]
            let context = known.filter { $0.position < first }.suffix(options.contextLines)
                .map { (source: $0.source, translation: $0.translation) }
            var results = try translateLines(chunk.map { sources[$0] }, context: Array(context), language: source,
                                             target: target, system: system, options: options, generator: generator,
                                             shouldCancel: shouldCancel)
            // 読めなかった行は 1 行ずつ訳し直す
            if chunk.count > 1 {
                for k in chunk.indices where results[k] == nil {
                    if shouldCancel() { throw LLMError.cancelled }
                    results[k] = try translateLines([sources[chunk[k]]], context: Array(context), language: source,
                                                    target: target, system: system, options: options, generator: generator,
                                                    shouldCancel: shouldCancel)[0]
                }
            }
            var batch: [TranslationResult] = []
            for (k, u) in chunk.enumerated() {
                let unit = units[u]
                if let t = results[k] {
                    batch.append(TranslationResult(head: segments[unit[0]].id, covers: unit.dropFirst().map { segments[$0].id }, text: t))
                    known.append((unit[0], sources[u], t))
                } else {
                    failed += unit.count
                }
                done += unit.count
            }
            known.sort { $0.position < $1.position }
            onChunk(batch, done, pending.count)
        }
        return failed
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
        let user = userPrompt(lines: lines, context: context, glossary: options.glossary)
        let shots = TranslationExamples.examples(for: target)
        let sourceTokens = lines.reduce(0) { $0 + generator.tokenCount($1) }
        let exampleTokens = shots.reduce(0) { $0 + generator.tokenCount($1.user) + generator.tokenCount($1.assistant) + 16 }
        let promptTokens = generator.tokenCount(system) + generator.tokenCount(user) + exampleTokens + 32
        let budget = min(generator.contextLength - promptTokens - 8, 32 + sourceTokens * 4 + lines.count * 12)
        guard budget > 8 else { return lines.map { _ in nil } }
        let longest = lines.map(\.utf8.count).max() ?? 0
        let output = try generator.generate(
            LLMPrompt(system: system, user: user, grammar: GBNF.numberedLines(count: lines.count), maxTokens: budget,
                      maxLineBytes: longest * 3 + 120, examples: shots, japaneseOnly: target == "ja"),
            shouldCancel: shouldCancel
        )
        let parsed = parse(output, count: lines.count)
        return lines.indices.map { k in
            guard let t = parsed[k + 1], isPlausible(t, source: lines[k], target: target) else { return nil }
            return t
        }
    }
}

extension Transcript {
    /// 訳を 1 つ置く。訳したあいだに監査で文が変わっていた区間 (sources と違う) には置かない。
    /// 訳した言語 (`translationLanguage`) は、ここでは変えない (訳した後に、呼ぶ側が `translationModel` と並べて入れる)。
    /// 利用者が直した訳 (今も合う "edited" の覚え) のまとまりに当たる区間を含む訳も置かない: 翻訳の途中に利用者が直した訳が、
    /// 後から届いた機械の訳や、翻訳の終わりにもう 1 度置く訳 (AppModel) で、機械の訳に戻らないように。
    /// 利用者が自分で訳し直しを選んだ時は、呼ぶ側が先に覚えを捨てる (`dropUserTranslations(touching:)`・`removeAllTranslations()`)
    @discardableResult
    public mutating func apply(_ result: TranslationResult, sources: [UUID: String]) -> Bool {
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
        return true
    }
}
