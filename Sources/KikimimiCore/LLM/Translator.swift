import Foundation

/// 翻訳の設定
public struct TranslationOptions: Sendable {
    /// 固有名詞などの正しい表記 (設定の「語彙のヒント」)
    public var glossary: String?
    /// 1 度に訳す区間の数と、その長さの上限 (トークン数)
    public var maxLinesPerChunk: Int
    public var maxTokensPerChunk: Int
    /// 文脈として見せる、直前の訳済みの区間の数
    public var contextLines: Int

    public init(glossary: String? = nil, maxLinesPerChunk: Int = 12, maxTokensPerChunk: Int = 500, contextLines: Int = 3) {
        self.glossary = glossary
        self.maxLinesPerChunk = maxLinesPerChunk
        self.maxTokensPerChunk = maxTokensPerChunk
        self.contextLines = contextLines
    }
}

/// 翻訳役: 日本語以外の区間を、ローカル LLM で日本語に訳す。
///
/// 区間ごとに番号を付けて数行ずつまとめて訳し、出力は文法で「同じ番号・同じ行数」に縛る
/// (訳が隣の区間にずれたり、まとめられたりしない)。読めなかった行は 1 行ずつ訳し直す。
public enum Translator {
    /// 訳す必要があり、まだ訳がない区間の位置
    public static func pendingIndices(_ segments: [TranscriptSegment], language: String?) -> [Int] {
        segments.indices.filter {
            segments[$0].translation == nil && Script.needsTranslation(segments[$0].text, transcriptLanguage: language)
        }
    }

    static func systemPrompt(language: String?) -> String {
        let lang = Script.englishName(for: language)
        return """
        You are an expert subtitle translator. Translate each numbered line of a speech transcript \
        from \(lang) into natural, easy-to-read Japanese.
        - Write Japanese only (kana and kanji). Never write Chinese.
        - Output exactly one line for each input line, in the same order, starting with the same number, like "[3] 訳文".
        - Translate every line separately. Never merge, split, skip or reorder lines, even when a sentence continues on the next line.
        - Translate the meaning faithfully. Keep numbers and units accurate.
        - Keep every name and term from the glossary exactly as written, in the same letters (do not turn them into katakana). \
        Write other well-known names in their usual Japanese form.
        - If a line is already Japanese, copy it unchanged.
        - Output only the translations, with no notes.
        """
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

    /// 訳として受け取ってよいか (延々と続く・空のものは捨てる)
    static func isPlausible(_ translation: String, source: String) -> Bool {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.count <= source.count * 4 + 40
    }

    /// まだ訳していない区間を訳す。1 まとまり訳すごとに onChunk (区間 ID → 訳) を呼ぶ。
    /// 戻り値は、最後まで訳せなかった区間の数。
    @discardableResult
    public static func translate(_ segments: [TranscriptSegment], language: String?, options: TranslationOptions = TranslationOptions(),
                                 generator: any TextGenerating, shouldCancel: () -> Bool,
                                 onChunk: (_ translations: [UUID: String], _ done: Int, _ total: Int) -> Void) throws -> Int {
        let lines = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pending = pendingIndices(segments, language: language)
        let chunks = LLMChunker.chunks(pending, cost: { generator.tokenCount(lines[$0]) + 4 },
                                       maxLines: options.maxLinesPerChunk, maxCost: options.maxTokensPerChunk)
        let system = systemPrompt(language: language)
        // 文脈用に、訳しながら訳を覚えておく (最初から訳がある区間も使う)
        var known: [Int: String] = [:]
        for i in segments.indices {
            if let t = segments[i].translation { known[i] = t }
        }
        var failed = 0
        onChunk([:], 0, pending.count)
        var done = 0
        for chunk in chunks {
            if shouldCancel() { throw LLMError.cancelled }
            let first = chunk[0]
            let context = (max(0, first - options.contextLines)..<first).compactMap { i -> (source: String, translation: String)? in
                guard let t = known[i] else { return nil }
                return (lines[i], t)
            }
            var results = try translateLines(chunk.map { lines[$0] }, context: context, language: language,
                                             system: system, options: options, generator: generator,
                                             shouldCancel: shouldCancel)
            // 読めなかった行は 1 行ずつ訳し直す
            if chunk.count > 1 {
                for k in chunk.indices where results[k] == nil {
                    if shouldCancel() { throw LLMError.cancelled }
                    results[k] = try translateLines([lines[chunk[k]]], context: context, language: language,
                                                    system: system, options: options, generator: generator,
                                                    shouldCancel: shouldCancel)[0]
                }
            }
            var batch: [UUID: String] = [:]
            for (k, index) in chunk.enumerated() {
                if let t = results[k] {
                    batch[segments[index].id] = t
                    known[index] = t
                } else {
                    failed += 1
                }
            }
            done += chunk.count
            onChunk(batch, done, pending.count)
        }
        return failed
    }

    /// 数行をまとめて訳す。読めなかった行は nil
    static func translateLines(_ lines: [String], context: [(source: String, translation: String)], language: String?,
                               system: String, options: TranslationOptions, generator: any TextGenerating,
                               shouldCancel: () -> Bool) throws -> [String?] {
        let user = userPrompt(lines: lines, context: context, glossary: options.glossary)
        let sourceTokens = lines.reduce(0) { $0 + generator.tokenCount($1) }
        let promptTokens = generator.tokenCount(system) + generator.tokenCount(user) + 32
        let budget = min(generator.contextLength - promptTokens - 8, 32 + sourceTokens * 4 + lines.count * 12)
        guard budget > 8 else { return lines.map { _ in nil } }
        let longest = lines.map(\.utf8.count).max() ?? 0
        let output = try generator.generate(
            LLMPrompt(system: system, user: user, grammar: GBNF.numberedLines(count: lines.count), maxTokens: budget,
                      maxLineBytes: longest * 3 + 120),
            shouldCancel: shouldCancel
        )
        let parsed = parse(output, count: lines.count)
        return lines.indices.map { k in
            guard let t = parsed[k + 1], isPlausible(t, source: lines[k]) else { return nil }
            return t
        }
    }
}
