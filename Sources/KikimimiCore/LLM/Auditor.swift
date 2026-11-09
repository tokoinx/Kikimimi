import Foundation

/// 監査の設定
public struct AuditOptions: Sendable {
    /// 固有名詞などの正しい表記 (設定の「語彙のヒント」)
    public var glossary: String?
    /// LLM に 1 度に見せる区間の数と、その長さの上限 (トークン数)
    public var maxLinesPerChunk: Int
    public var maxTokensPerChunk: Int

    public init(glossary: String? = nil, maxLinesPerChunk: Int = 20, maxTokensPerChunk: Int = 900) {
        self.glossary = glossary
        self.maxLinesPerChunk = maxLinesPerChunk
        self.maxTokensPerChunk = maxTokensPerChunk
    }
}

/// 監査役: 文字起こしの「繰り返し」と「聞き取りミス」を見つけて直す。
///
/// 1. 規則: すぐ前と同じ (またはほぼ同じ) 文がもう一度出ている区間を見つける。
/// 2. ローカル LLM: 文脈から見て明らかな聞き間違い (同音の別の語・固有名詞の崩れ) と、
///    実際には話していない文 (無音のところの定番フレーズなど) を見つける。
///
/// LLM の指摘はそのまま信じず、安全の基準 (直す量が少ない・言語が変わらない・繰り返しの裏付けがある) を
/// 満たしたものだけを自動で反映する。満たさないものは「要確認」の提案として残し、利用者が選べるようにする。
public enum Auditor {
    // MARK: 規則

    /// 前の区間を何個まで見るか、どれだけ時間が空いていたら比べないか
    static let lookBack = 3
    static let maximumGap: TimeInterval = 10

    /// 規則で見つかる繰り返しと、定番の誤認識
    public static func findRepeats(_ segments: [TranscriptSegment]) -> [AuditChange] {
        let keys = segments.map { TextSimilarity.key($0.text) }
        let stockPhrases = Set(HallucinationFilter.phrases.map(TextSimilarity.key))
        var deleted = Set<Int>()
        var changes: [AuditChange] = []
        for i in segments.indices {
            // 無音や音楽のところで Whisper が出しがちな定番の文 (実際にそう話すこともあるので提案どまり)
            if stockPhrases.contains(keys[i]) {
                changes.append(AuditChange(kind: .delete, origin: .rule, original: segments[i],
                                           reason: "無音や音楽のところで出やすい定番の誤認識の可能性", isConfident: false))
                deleted.insert(i)
                continue
            }
            guard i > 0 else { continue }
            let ki = keys[i]
            guard ki.count >= 8 else { continue }
            var j = i - 1
            var looked = 0
            while j >= 0, looked < lookBack {
                defer { j -= 1 }
                if deleted.contains(j) { continue }
                looked += 1
                guard segments[i].start - segments[j].end <= maximumGap else { break }
                let kj = keys[j]
                guard !kj.isEmpty else { continue }
                // 時間が重なる・すぐ続く: 同じ音声を 2 度読んだ可能性が高い
                let adjacent = segments[i].start <= segments[j].end + 1.0
                let finding: (reason: String, confident: Bool)?
                if ki == kj {
                    finding = ("直前と同じ文の繰り返し (\(TimeFormat.short(segments[j].start)))", ki.count >= 12)
                } else if min(ki.count, kj.count) >= 15, TextSimilarity.isNearDuplicate(ki, kj, minimumRatio: 0.85) {
                    finding = ("直前とほぼ同じ文の繰り返し (\(TimeFormat.short(segments[j].start)))", adjacent)
                } else if ki.count >= 10, kj.contains(ki) {
                    finding = ("直前の文の一部の繰り返し (\(TimeFormat.short(segments[j].start)))", adjacent)
                } else {
                    finding = nil
                }
                if let finding {
                    changes.append(AuditChange(kind: .delete, origin: .rule, original: segments[i],
                                               reason: finding.reason, isConfident: finding.confident))
                    deleted.insert(i)
                    break
                }
            }
        }
        return changes
    }

    // MARK: 安全の基準

    /// 聞き取りミスの直しとして小さいか (言い換え・要約・翻訳ではないか)
    static func fixAssessment(original: String, replacement: String,
                              language: String?) -> (keep: Bool, confident: Bool) {
        let ko = Array(TextSimilarity.key(original)), kr = Array(TextSimilarity.key(replacement))
        guard !kr.isEmpty, ko != kr else { return (false, false) }
        // 言語が変わる直し (翻訳) は受け付けない
        if Script.isJapanese(original, transcriptLanguage: language)
            != Script.isJapanese(replacement, transcriptLanguage: language) {
            return (false, false)
        }
        let distance = TextSimilarity.distance(ko, kr)
        let longest = max(ko.count, kr.count)
        let ratio = Double(kr.count) / Double(max(1, ko.count))
        // 半分以上が変わる直しは、聞き取りミスではなく書き換え
        guard Double(distance) <= Double(longest) * 0.5 else { return (false, false) }
        let allowed = min(20, max(2, Int((Double(ko.count) * 0.3).rounded(.up))))
        let confident = distance <= allowed && (0.7...1.4).contains(ratio)
        return (true, confident)
    }

    /// 削除してよい裏付けがあるか (近くに同じような文がある / 定番の誤認識)
    static func deletionIsBacked(_ index: Int, in segments: [TranscriptSegment]) -> Bool {
        let target = segments[index]
        let k = TextSimilarity.key(target.text)
        if HallucinationFilter.phrases.contains(where: { TextSimilarity.key($0) == k }) { return true }
        guard k.count >= 4 else { return false }
        let near = segments.indices.filter { $0 != index && abs(segments[$0].start - target.start) <= 30 }
        return near.contains { j in
            let kj = TextSimilarity.key(segments[j].text)
            guard !kj.isEmpty else { return false }
            return kj == k || (k.count >= 6 && kj.contains(k)) || TextSimilarity.isNearDuplicate(kj, k, minimumRatio: 0.8)
        }
    }

    // MARK: LLM

    enum Action: Equatable {
        case delete(String)
        /// 聞き間違えた語 → 正しい語 (行ぜんたいは書き直させない)
        case fix(wrong: String, right: String)
    }

    /// LLM の答えを読む (番号は 1 始まり)。同じ番号が何度も出たら最初のものを使う
    static func parse(_ output: String, count: Int) -> [Int: Action] {
        var actions: [Int: Action] = [:]
        for raw in completeLines(of: output) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let n = Int(line[line.index(after: line.startIndex)..<close]), (1...count).contains(n),
                  actions[n] == nil else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("DEL") {
                let note = rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
                actions[n] = .delete(note)
            } else if rest.hasPrefix("FIX") {
                let parts = rest.dropFirst(3).components(separatedBy: "=>")
                guard parts.count == 2 else { continue }
                let wrong = parts[0].trimmingCharacters(in: .whitespaces)
                let right = parts[1].trimmingCharacters(in: .whitespaces)
                if !wrong.isEmpty, !right.isEmpty { actions[n] = .fix(wrong: wrong, right: right) }
            }
        }
        return actions
    }

    /// 行の中の「聞き間違えた語」を「正しい語」に置き換える。行に見つからなければ nil (思い込みの直しは使わない)
    static func applyFix(to text: String, wrong: String, right: String) -> String? {
        guard TextSimilarity.key(wrong) != TextSimilarity.key(right) else { return nil }
        if text.contains(wrong) {
            return text.replacingOccurrences(of: wrong, with: right)
        }
        if let range = text.range(of: wrong, options: [.caseInsensitive, .widthInsensitive]) {
            return text.replacingCharacters(in: range, with: right)
        }
        return nil
    }

    static func systemPrompt(language: String?) -> String {
        let lang = Script.englishName(for: language)
        return """
        You are a careful proofreader of automatic speech recognition (ASR) transcripts. \
        The transcript is mostly in \(lang). Each numbered line is one subtitle segment.
        Report only clear recognition errors:
        - FIX: a word or name was misheard (a similar-sounding wrong word, a broken proper noun, a word that makes no sense in context). \
        Write only the wrong words as they appear in the line and the correct words, like "[3] FIX whirled => world". \
        Keep the speaker's language. Never translate or rephrase, never add or remove particles, endings or small words, \
        and never fix punctuation, grammar or style.
        - DEL: the line is not real speech: a duplicate of a nearby line created by the recognizer, \
        or a typical hallucination such as "Thank you for watching." during silence or music.
        Skip every line that is fine. Most lines are fine. If you are not sure, skip the line.
        List the problems in line order, then write "END". If nothing is wrong, write only "END".
        """
    }

    static func userPrompt(lines: [String], context: [String], glossary: String?) -> String {
        var parts: [String] = []
        if let g = glossary?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            parts.append("Correct spellings of names and terms in this recording: \(g)")
        }
        if !context.isEmpty {
            parts.append("Earlier lines (context only, do not judge):\n" + context.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("Lines to check:\n" + lines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// LLM で見直す。規則で消す区間は先に除いてから見せる。
    public static func review(_ segments: [TranscriptSegment], language: String?, options: AuditOptions,
                              generator: any TextGenerating, shouldCancel: () -> Bool,
                              onProgress: (_ done: Int, _ total: Int) -> Void) throws -> [AuditChange] {
        let lines = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidates = lines.indices.filter { !TextSimilarity.key(lines[$0]).isEmpty }
        let chunks = LLMChunker.chunks(candidates,
                                       cost: { generator.tokenCount(lines[$0]) + 4 },
                                       maxLines: options.maxLinesPerChunk,
                                       maxCost: options.maxTokensPerChunk)
        let system = systemPrompt(language: language)
        var changes: [AuditChange] = []
        onProgress(0, chunks.count)
        for (done, chunk) in chunks.enumerated() {
            if shouldCancel() { throw LLMError.cancelled }
            let contextStart = max(0, (chunk.first ?? 0) - 2)
            let context = Array(lines[contextStart..<(chunk.first ?? 0)])
            let user = userPrompt(lines: chunk.map { lines[$0] }, context: context, glossary: options.glossary)
            let promptTokens = generator.tokenCount(system) + generator.tokenCount(user) + 32
            // 答えは問題のある行だけの短い指摘 (1 行あたり十数トークン)
            let budget = min(generator.contextLength - promptTokens - 8, 48 + chunk.count * 32)
            guard budget > 16 else { continue }
            let longest = chunk.map { lines[$0].utf8.count }.max() ?? 0
            let output = try generator.generate(
                LLMPrompt(system: system, user: user, grammar: GBNF.auditActions(count: chunk.count), maxTokens: budget,
                          maxLineBytes: longest * 2 + 80),
                shouldCancel: shouldCancel
            )
            var found: [AuditChange] = []
            for (n, action) in parse(output, count: chunk.count).sorted(by: { $0.key < $1.key }) {
                let index = chunk[n - 1]
                let segment = segments[index]
                switch action {
                case .delete(let note):
                    let backed = deletionIsBacked(index, in: segments)
                    found.append(AuditChange(kind: .delete, origin: .llm, original: segment,
                                             reason: deletionReason(note, backed: backed), isConfident: backed))
                case .fix(let wrong, let right):
                    // 指摘された語が行に無い・何も変わらない直しは使わない
                    guard let fixed = applyFix(to: segment.text, wrong: wrong, right: right) else { continue }
                    let assessment = fixAssessment(original: segment.text, replacement: fixed, language: language)
                    guard assessment.keep else { continue }
                    // 評価役: 直す前と後のどちらが正しいかを、もう一度たずねる。どちらの並びでも直す前を選んだら捨てる
                    let votes = try judgeVotes(original: segment.text, proposed: fixed,
                                               context: Array(lines[max(0, index - 2)..<index]), language: language,
                                               generator: generator, shouldCancel: shouldCancel)
                    guard votes > 0 else { continue }
                    // 行の大部分を差し替える直しは、聞き取りミスではなく書き換えの疑い
                    let wholesale = TextSimilarity.key(wrong).count > TextSimilarity.key(segment.text).count * 6 / 10
                    // 語を足すだけ・削るだけの直し (助詞や語尾など) は、聞き間違いより文の手直しに近い
                    let affixOnly = TextSimilarity.key(right).contains(TextSimilarity.key(wrong))
                        || TextSimilarity.key(wrong).contains(TextSimilarity.key(right))
                    let confident = assessment.confident && !wholesale && !affixOnly && votes == 2
                    let note: String
                    if confident {
                        note = ""
                    } else if votes < 2 {
                        note = " (評価役の判断が割れたため要確認)"
                    } else if affixOnly {
                        note = " (語を足す・削るだけの直しのため要確認)"
                    } else {
                        note = " (直す量が多いため要確認)"
                    }
                    found.append(AuditChange(kind: .fix, origin: .llm, original: segment, replacement: fixed,
                                             reason: "聞き取りミス: 「\(wrong)」→「\(right)」" + note,
                                             isConfident: confident))
                }
            }
            // 半分近くを直したがる答えは、聞き取りミスの指摘ではなく書き換え。すべて提案どまりにする
            if found.count >= 4 && Double(found.count) > Double(chunk.count) * 0.4 {
                for k in found.indices { found[k].isConfident = false }
            }
            changes += found
            onProgress(done + 1, chunks.count)
        }
        return changes
    }

    // MARK: 評価役

    static func judgeSystemPrompt(language: String?) -> String {
        let lang = Script.englishName(for: language)
        return """
        You check corrections of an automatic speech recognition (ASR) transcript in \(lang). \
        Two versions of one line are shown. Choose the one that is more likely to be what the speaker actually said: \
        natural, correct \(lang) that fits the context. Answer with the number only.
        """
    }

    /// 評価役: 直す前と直した後のどちらが正しいかを、並びを入れ替えて 2 回たずねる。直した後を選んだ回数 (0〜2) を返す
    /// (小さなモデルは「1 番目を選びがち」などの癖があるので、2 回とも選ばれたときだけ信じる)
    static func judgeVotes(original: String, proposed: String, context: [String], language: String?,
                           generator: any TextGenerating, shouldCancel: () -> Bool) throws -> Int {
        let system = judgeSystemPrompt(language: language)
        let contextText = context.isEmpty ? "" : "Context (the lines just before):\n" + context.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        func ask(_ first: String, _ second: String) throws -> String {
            let user = contextText + "Which version of the line is correct?\n1: \(first)\n2: \(second)"
            return try generator.generate(LLMPrompt(system: system, user: user, grammar: GBNF.choice, maxTokens: 2),
                                          shouldCancel: shouldCancel).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var votes = 0
        if try ask(original, proposed) == "2" { votes += 1 }
        if try ask(proposed, original) == "1" { votes += 1 }
        return votes
    }

    static func deletionReason(_ note: String, backed: Bool) -> String {
        let lower = note.lowercased()
        let kind = lower.contains("dup") || lower.contains("repeat") || note.contains("繰り返") || note.contains("重複")
            ? "繰り返し" : "実際には話していない文の可能性"
        return backed ? kind : "\(kind) (裏付けが弱いため要確認)"
    }

    /// 規則 → LLM の順に見直し、1 区間 1 件にまとめた結果を返す。generator が nil なら規則だけ。
    public static func audit(_ segments: [TranscriptSegment], language: String?, options: AuditOptions = AuditOptions(),
                             generator: (any TextGenerating)?, modelName: String?,
                             shouldCancel: () -> Bool,
                             onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) throws -> AuditReport {
        let ruleChanges = findRepeats(segments)
        let removed = Set(ruleChanges.filter(\.isConfident).map(\.original.id))
        var changes = ruleChanges
        if let generator {
            let rest = segments.filter { !removed.contains($0.id) }
            let llmChanges = try review(rest, language: language, options: options, generator: generator,
                                        shouldCancel: shouldCancel, onProgress: onProgress)
            // 規則の指摘がある区間は規則を優先する (理由がはっきりしているため)
            let ruled = Set(ruleChanges.map(\.original.id))
            changes += llmChanges.filter { !ruled.contains($0.original.id) }
        }
        let order = Dictionary(segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        changes.sort { (order[$0.original.id] ?? 0) < (order[$1.original.id] ?? 0) }
        return AuditReport(changes: changes, model: generator == nil ? nil : modelName, reviewedCount: segments.count)
    }
}

/// LLM に渡すために、区間を「行数」と「長さ」の上限に収まるまとまりに分ける。
public enum LLMChunker {
    public static func chunks(_ indices: [Int], cost: (Int) -> Int, maxLines: Int, maxCost: Int) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        var currentCost = 0
        for index in indices {
            let c = max(1, cost(index))
            if !current.isEmpty && (current.count >= maxLines || currentCost + c > maxCost) {
                result.append(current)
                current = []
                currentCost = 0
            }
            current.append(index)
            currentCost += c
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
