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

/// 翻訳役: 日本語以外の区間を、ローカル LLM で日本語に訳す。
///
/// Whisper の区間は文の途中で切れることが多い。区間ごとに訳すと、日本語の語順のせいで訳が隣の区間にずれる
/// (本物の Qwen3.5 4B で起きた) ので、続いている区間を文ごとにまとめて 1 行として訳す。
/// 行には番号を付けて数行ずつ訳し、出力は文法で「同じ番号・同じ行数」に縛る。読めなかった行は 1 行ずつ訳し直す。
public enum Translator {
    /// 1 文としてまとめる区間の数と長さの上限、区間のすき間 (これより空いていたら別の文)
    static let maxSegmentsPerSentence = 4
    static let maxCharactersPerSentence = 400
    static let maxGapInSentence: TimeInterval = 1.5

    /// 訳す必要がある区間か。「日本語＋英語」で日本語 (日) とわかっている区間は、かなが無くても (「Ruth先生」など) 訳さない
    static func needsTranslation(_ segment: TranscriptSegment, transcriptLanguage: String?) -> Bool {
        segment.language != "ja"
            && Script.needsTranslation(segment.text, transcriptLanguage: segment.language ?? transcriptLanguage)
    }

    /// 訳す必要があり、まだ訳がない区間の位置 (ほかの区間の訳に含まれているものは除く)
    public static func pendingIndices(_ segments: [TranscriptSegment], language: String?) -> [Int] {
        var covered = Set<UUID>()
        for s in segments where s.translation != nil {
            covered.formUnion(s.translationCovers ?? [])
        }
        return segments.indices.filter {
            segments[$0].translation == nil && !covered.contains(segments[$0].id)
                && needsTranslation(segments[$0], transcriptLanguage: language)
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

    static func systemPrompt(language: String?) -> String {
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

    /// 手本のやりとり。小さなモデル (Qwen3.5 4B など) は指示だけだと訳文が中国語に流れることがあり、
    /// 日本語の手本を 1 回見せると日本語で答える (あいさつの行は特に流れやすいので、手本にも入れておく)
    public static let examples = [
        LLMExample(
            user: """
            Lines to translate:
            [1] Hi everyone, thanks for joining us today.
            [2] Let's take a look at the results.
            [3] It costs about 20 dollars.
            """,
            assistant: """
            [1] みなさん、今日はお集まりいただきありがとうございます。
            [2] では、結果を見てみましょう。
            [3] 費用は約 20 ドルです。

            """
        ),
    ]

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

    /// 訳として受け取ってよいか (延々と続く・空のもの・中国語になったものは捨てる)
    static func isPlausible(_ translation: String, source: String) -> Bool {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !Script.containsNonJapaneseHan(t) else { return false }
        return t.count <= source.count * 4 + 40
    }

    /// まだ訳していない区間を、文ごとに訳す。1 まとまり訳すごとに onChunk を呼ぶ (done / total は区間の数)。
    /// 戻り値は、最後まで訳せなかった区間の数。
    @discardableResult
    public static func translate(_ segments: [TranscriptSegment], language: String?, options: TranslationOptions = TranslationOptions(),
                                 generator: any TextGenerating, shouldCancel: () -> Bool,
                                 onChunk: (_ results: [TranslationResult], _ done: Int, _ total: Int) -> Void) throws -> Int {
        let pending = pendingIndices(segments, language: language)
        // 「日本語＋英語」では、訳す区間に付いた言語 (いちばん多いもの) を原文の言語としてプロンプトに書く
        let source = sourceLanguage(of: pending.map { segments[$0] }) ?? language
        let units = sentenceUnits(pending, in: segments)
        let sources = units.map { unit in Transcript.join(unit.map { segments[$0].text }) }
        let chunks = LLMChunker.chunks(Array(units.indices), cost: { generator.tokenCount(sources[$0]) + 4 },
                                       maxLines: options.maxLinesPerChunk, maxCost: options.maxTokensPerChunk)
        let system = systemPrompt(language: source)
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
                                             system: system, options: options, generator: generator,
                                             shouldCancel: shouldCancel)
            // 読めなかった行は 1 行ずつ訳し直す
            if chunk.count > 1 {
                for k in chunk.indices where results[k] == nil {
                    if shouldCancel() { throw LLMError.cancelled }
                    results[k] = try translateLines([sources[chunk[k]]], context: Array(context), language: source,
                                                    system: system, options: options, generator: generator,
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
                               system: String, options: TranslationOptions, generator: any TextGenerating,
                               shouldCancel: () -> Bool) throws -> [String?] {
        let user = userPrompt(lines: lines, context: context, glossary: options.glossary)
        let sourceTokens = lines.reduce(0) { $0 + generator.tokenCount($1) }
        let exampleTokens = examples.reduce(0) { $0 + generator.tokenCount($1.user) + generator.tokenCount($1.assistant) + 16 }
        let promptTokens = generator.tokenCount(system) + generator.tokenCount(user) + exampleTokens + 32
        let budget = min(generator.contextLength - promptTokens - 8, 32 + sourceTokens * 4 + lines.count * 12)
        guard budget > 8 else { return lines.map { _ in nil } }
        let longest = lines.map(\.utf8.count).max() ?? 0
        let output = try generator.generate(
            LLMPrompt(system: system, user: user, grammar: GBNF.numberedLines(count: lines.count), maxTokens: budget,
                      maxLineBytes: longest * 3 + 120, examples: examples, japaneseOnly: true),
            shouldCancel: shouldCancel
        )
        let parsed = parse(output, count: lines.count)
        return lines.indices.map { k in
            guard let t = parsed[k + 1], isPlausible(t, source: lines[k]) else { return nil }
            return t
        }
    }
}

extension Transcript {
    /// 訳を 1 つ置く。訳したあいだに監査で文が変わっていた区間 (sources と違う) には置かない
    @discardableResult
    public mutating func apply(_ result: TranslationResult, sources: [UUID: String]) -> Bool {
        let ids = [result.head] + result.covers
        guard ids.allSatisfy({ id in segments.first { $0.id == id }?.text == sources[id] }),
              let index = segments.firstIndex(where: { $0.id == result.head }) else { return false }
        // まとめた区間が、いまも訳の区間のすぐ後ろに順に並んでいるときだけ (訳しているあいだに削除を元に戻した、など)
        let following = segments.dropFirst(index + 1).prefix(result.covers.count)
        guard following.count == result.covers.count, zip(following, result.covers).allSatisfy({ $0.id == $1 }) else { return false }
        segments[index].translation = result.text
        segments[index].translationCovers = result.covers.isEmpty ? nil : result.covers
        for i in following.indices { segments[i].translation = nil }
        return true
    }
}
