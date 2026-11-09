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
/// 3. 評価役: LLM の直しを、直す前と後のどちらが正しいか、並びを入れ替えて 2 回たずね直す。
///
/// 自動で反映するのは、取り違えようのないものだけ (同じ文がすき間なく 2 度・評価役が 2 回とも認めた小さな直し)。
/// 意味が変わりうる直し (数字・否定) や、本当にくり返して話した可能性のあるものは「提案」として残し、利用者が選ぶ。
public enum Auditor {
    // MARK: 規則

    /// 前の区間を何個まで見るか、どれだけ時間が空いていたら比べないか
    static let lookBack = 3
    static let maximumGap: TimeInterval = 10
    /// 同じ文の 2 度目を自動で消すのは、この長さ (比較用キーの文字数) 以上の文が、この秒数以内のすき間で続いたときだけ。
    /// 「よろしくお願いいたします」を何人かが順に言う、などの本当のくり返しは提案どまりにする
    static let confidentRepeatLength = 16
    static let confidentRepeatGap: TimeInterval = 1.0

    /// 句読点も含めた比較用の文 (「…木曜日です。」と「…木曜日ですか？」を区別する)
    static func punctuatedKey(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 規則で見つかる繰り返しと、定番の誤認識
    public static func findRepeats(_ segments: [TranscriptSegment]) -> [AuditChange] {
        let keys = segments.map { TextSimilarity.key($0.text) }
        let stockPhrases = Set(HallucinationFilter.phrases.map(TextSimilarity.key))
        var flagged = Set<Int>()
        var changes: [AuditChange] = []
        for i in segments.indices {
            // 無音や音楽のところで Whisper が出しがちな定番の文 (実際にそう話すこともあるので提案どまり)
            if stockPhrases.contains(keys[i]) {
                changes.append(AuditChange(kind: .delete, origin: .rule, original: segments[i],
                                           reason: "無音や音楽のところで出やすい定番の誤認識の可能性", isConfident: false))
                flagged.insert(i)
                continue
            }
            guard i > 0 else { continue }
            let ki = keys[i]
            guard ki.count >= 8 else { continue }
            var j = i - 1
            var looked = 0
            while j >= 0, looked < lookBack {
                defer { j -= 1 }
                if flagged.contains(j) { continue }
                looked += 1
                let gap = segments[i].start - segments[j].end
                guard gap <= maximumGap else { break }
                let kj = keys[j]
                guard !kj.isEmpty else { continue }
                let when = TimeFormat.short(segments[j].start)
                let finding: (reason: String, confident: Bool)?
                if ki == kj {
                    // 句読点まで同じ文が、すき間なく続く: 同じ音声を 2 度読んだもの。
                    // 句読点が違う (「〜です。」「〜ですか？」) ものは、聞き返しなど本当の発話なので見送る
                    if punctuatedKey(segments[i].text) != punctuatedKey(segments[j].text) {
                        finding = nil
                    } else {
                        // すぐ前の区間との比べっこのときだけ (あいだに「OK」などが入ったくり返しは本当の発話かもしれない)
                        let adjacent = (j + 1..<i).allSatisfy { flagged.contains($0) }
                        let confident = adjacent && ki.count >= confidentRepeatLength && gap <= confidentRepeatGap
                        finding = ("直前と同じ文の繰り返し (\(when))" + (confident ? "" : "。本当にくり返して話した可能性もあるため要確認"),
                                   confident)
                    }
                } else if min(ki.count, kj.count) >= 15, TextSimilarity.isNearDuplicate(ki, kj, minimumRatio: 0.85) {
                    // 言い直し (「月曜に」→「火曜に」) のこともあるので、自動では消さない
                    finding = ("直前とほぼ同じ文の繰り返し (\(when))。言い直しの可能性もあるため要確認", false)
                } else if ki.count >= 10, kj.contains(ki) {
                    finding = ("直前の文の一部の繰り返し (\(when))。要確認", false)
                } else {
                    finding = nil
                }
                if let finding {
                    changes.append(AuditChange(kind: .delete, origin: .rule, original: segments[i],
                                               reason: finding.reason, isConfident: finding.confident))
                    flagged.insert(i)
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

    /// 否定の言い方 (足されたり消されたりすると、意味が逆になる)
    static let negationWords: Set<String> = ["not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "cannot"]
    static let japaneseNegations = ["ない", "ません", "なかった", "ず", "ぬ", "無い"]
    static let wordSeparators = CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted

    static func negationCount(_ text: String) -> Int {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lower.components(separatedBy: wordSeparators)
        let english = words.filter { negationWords.contains($0) || $0.hasSuffix("n't") }.count
        let japanese = japaneseNegations.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
        return english + japanese
    }

    /// 数を表す言葉 (英語)。「fifteen → fifty」のような聞き間違いは、音声を聞かない LLM には決められない
    static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "trillion", "dozen", "half", "quarter", "double", "triple",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "once", "twice", "percent",
    ]

    static func numberWordsIn(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: wordSeparators).filter { numberWords.contains($0) }
    }

    /// 自動では反映せず、確かめてもらうべき直しか (意味が変わりうる)。理由を返す
    static func meaningRisk(original: String, fixed: String, wrong: String, right: String) -> String? {
        if original.filter(\.isNumber) != fixed.filter(\.isNumber) || numberWordsIn(original) != numberWordsIn(fixed) {
            return "数字が変わる直し"
        }
        if negationCount(original) != negationCount(fixed) { return "否定の有無が変わる直し" }
        let kw = TextSimilarity.key(wrong), kr = TextSimilarity.key(right)
        if kr.contains(kw) || kw.contains(kr) { return "語を足す・削るだけの直し" }
        if kr.count * 2 < kw.count { return "語を大きく削る直し" }
        // かなを漢字にする直し (こうせい → 構成 / 校正 / 厚生…) は、同じ音の候補から当て推量で選ぶことになる
        if !Script.hasHan(wrong) && Script.hasHan(right) { return "漢字が新しく入る直し" }
        return nil
    }

    /// 削除してよい裏付けがあるか: 近く (10 秒以内) に、同じかほぼ同じ文が「残る」形である。
    /// keep は消さずに残る区間 (同じ答えが消そうとしている区間は裏付けにしない)
    static func deletionIsBacked(_ index: Int, in segments: [TranscriptSegment], keep: (Int) -> Bool) -> Bool {
        let target = segments[index]
        let k = TextSimilarity.key(target.text)
        guard k.count >= 8 else { return false }
        return segments.indices.contains { j in
            guard j != index, keep(j), abs(segments[j].start - target.start) <= maximumGap else { return false }
            let kj = TextSimilarity.key(segments[j].text)
            guard kj.count >= 8 else { return false }
            return kj == k || TextSimilarity.isNearDuplicate(kj, k, minimumRatio: 0.85)
        }
    }

    /// 書き換えすぎ (聞き取りミスの指摘ではなく、文の手直し) とみなす、直し (FIX) の数か。
    /// 小さなまとまり (短い録音・最後の端数) では割合で、大きなまとまりでは数と割合で見る
    static func isTooMany(_ count: Int, of lines: Int) -> Bool {
        if lines < 10 { return count >= 2 && Double(count) >= Double(lines) * 0.5 }
        return count >= 4 && Double(count) > Double(lines) * 0.4
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

    /// 語の一部になる文字 (漢字・かなを除く): 英字・キリル文字・ハングルなど、空白で語を区切る文字と数字。
    /// 漢字・かなは除くので、「Roblocksを」の「を」の前は語の切れ目になる
    static let wordCharacter = "[[\\p{L}\\p{N}'’]--[\\p{Han}\\p{Hiragana}\\p{Katakana}]]"

    /// 直す語の前後に付ける「切れ目」の条件
    static func boundaries(for wrong: String) -> (leading: String, trailing: String) {
        func isSpacedLetter(_ c: Character) -> Bool {
            (c.isLetter || c == "'" || c == "’") && !c.unicodeScalars.contains { Script.isUnspacedCJK($0) }
        }
        var leading = "", trailing = ""
        if let first = wrong.first {
            if first.isNumber {
                // 「115」の中の「15」や「1,500」の中の「500」は直さない
                leading = "(?<!\\p{N})(?<!\\p{N}[.,])"
            } else if isSpacedLetter(first) {
                leading = "(?<!\(wordCharacter))"
            }
        }
        if let last = wrong.last {
            if last.isNumber {
                trailing = "(?!\\p{N})(?![.,]\\p{N})"
            } else if isSpacedLetter(last) {
                trailing = "(?!\(wordCharacter))"
            }
        }
        return (leading, trailing)
    }

    /// 行の中の「聞き間違えた語」を「正しい語」に置き換える (最初の 1 か所だけ)。行に見つからなければ nil。
    /// 語や数は切れ目で合わせる (「can」を直すつもりで「scan」の中を、「15」を直すつもりで「115」の中を変えない)
    static func applyFix(to text: String, wrong: String, right: String) -> String? {
        guard TextSimilarity.key(wrong) != TextSimilarity.key(right) else { return nil }
        let (leading, trailing) = boundaries(for: wrong)
        let pattern = leading + NSRegularExpression.escapedPattern(for: wrong) + trailing
        for options: NSRegularExpression.Options in [[], [.caseInsensitive]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let ns = NSString(string: text)
            guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { continue }
            var replacement = right
            // 大文字小文字を無視して見つけた語が大文字で始まっていれば (文の頭など)、直した語もそろえる
            if !options.isEmpty, let first = ns.substring(with: match.range).first, first.isUppercase,
               let r = replacement.first, r.isLowercase {
                replacement = r.uppercased() + replacement.dropFirst()
            }
            return ns.replacingCharacters(in: match.range, with: replacement)
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

    /// LLM で見直す。onChunk には、まとまりごとの結果を渡す (途中で止めても、見終えた所までを使えるように)
    public static func review(_ segments: [TranscriptSegment], language: String?, options: AuditOptions,
                              generator: any TextGenerating, shouldCancel: () -> Bool,
                              onProgress: (_ done: Int, _ total: Int) -> Void,
                              onChunk: (_ changes: [AuditChange]) -> Void = { _ in }) throws -> [AuditChange] {
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
            let actions = parse(output, count: chunk.count).sorted(by: { $0.key < $1.key })
            // 同じ答えが消そうとしている区間は、ほかの削除の裏付けにしない (2 つの写しが互いを裏付けて両方消えるのを防ぐ)
            let deleting = Set(actions.compactMap { item -> Int? in
                if case .delete = item.value { return chunk[item.key - 1] }
                return nil
            })
            var found: [AuditChange] = []
            for (n, action) in actions {
                let index = chunk[n - 1]
                let segment = segments[index]
                switch action {
                case .delete(let note):
                    // 理由に別の行の文を書いている: 番号の取り違え (4B で実際にあった)。使わない
                    if noteQuotesAnotherLine(note, target: index, chunk: chunk, lines: lines) { continue }
                    let backed = deletionIsBacked(index, in: segments, keep: { !deleting.contains($0) })
                    // LLM の削除は提案どまり: 自動で消してよい「すき間なく同じ文が 2 度」は規則が先に消している。
                    // 規則が残したもの (聞き返し・間をあけたくり返し) を、LLM の判断で消さない
                    found.append(AuditChange(kind: .delete, origin: .llm, original: segment,
                                             reason: deletionReason(note, backed: backed), isConfident: false))
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
                    let risk = meaningRisk(original: segment.text, fixed: fixed, wrong: wrong, right: right)
                    let confident = assessment.confident && !wholesale && risk == nil && votes == 2
                    let note: String
                    if confident {
                        note = ""
                    } else if let risk {
                        note = " (\(risk)のため要確認)"
                    } else if votes < 2 {
                        note = " (評価役の判断が割れたため要確認)"
                    } else {
                        note = " (直す量が多いため要確認)"
                    }
                    found.append(AuditChange(kind: .fix, origin: .llm, original: segment, replacement: fixed,
                                             reason: "聞き取りミス: 「\(wrong)」→「\(right)」" + note,
                                             isConfident: confident))
                }
            }
            // 半分近くの行を直したがる答えは、聞き取りミスの指摘ではなく書き換え。すべて提案どまりにする
            if isTooMany(found.filter { $0.kind == .fix }.count, of: chunk.count) {
                for k in found.indices { found[k].isConfident = false }
            }
            changes += found
            onChunk(found)
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

    /// 削除の理由に、対象とは別の行の文がそのまま書かれているか
    static func noteQuotesAnotherLine(_ note: String, target: Int, chunk: [Int], lines: [String]) -> Bool {
        let noteKey = TextSimilarity.key(note)
        guard noteKey.count >= 8 else { return false }
        let targetKey = TextSimilarity.key(lines[target])
        if targetKey.contains(noteKey) || noteKey.contains(targetKey) { return false }
        return chunk.contains { other in
            guard other != target else { return false }
            let otherKey = TextSimilarity.key(lines[other])
            return otherKey.count >= 8 && (noteKey.contains(otherKey) || otherKey.contains(noteKey))
        }
    }

    static func deletionReason(_ note: String, backed: Bool) -> String {
        let lower = note.lowercased()
        let kind = lower.contains("dup") || lower.contains("repeat") || note.contains("繰り返") || note.contains("重複")
            ? "繰り返し" : "実際には話していない文の可能性"
        return backed ? "\(kind) (近くに同じ文があります。要確認)" : "\(kind) (裏付けが弱いため要確認)"
    }

    /// 規則 → LLM の順に見直し、1 区間 1 件にまとめた結果を返す。generator が nil なら規則だけ。
    /// onPartial には、規則の結果と、LLM が見終えたまとまりまでの結果を渡す (途中で止めたり失敗したりしても、そこまでを使える)
    public static func audit(_ segments: [TranscriptSegment], language: String?, options: AuditOptions = AuditOptions(),
                             generator: (any TextGenerating)?, modelName: String?,
                             shouldCancel: () -> Bool,
                             onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
                             onPartial: (AuditReport) -> Void = { _ in }) throws -> AuditReport {
        let ruleChanges = findRepeats(segments)
        let ruled = Set(ruleChanges.map(\.original.id))
        let removed = Set(ruleChanges.filter(\.isConfident).map(\.original.id))
        let order = Dictionary(segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func report(_ llmChanges: [AuditChange], model: String?) -> AuditReport {
            // 規則の指摘がある区間は規則を優先する (理由がはっきりしているため)
            var all = ruleChanges + llmChanges.filter { !ruled.contains($0.original.id) }
            all.sort { (order[$0.original.id] ?? 0) < (order[$1.original.id] ?? 0) }
            return AuditReport(changes: all, model: model, reviewedCount: segments.count)
        }
        onPartial(report([], model: nil))
        guard let generator else { return report([], model: nil) }
        let rest = segments.filter { !removed.contains($0.id) }
        var soFar: [AuditChange] = []
        let llmChanges = try review(rest, language: language, options: options, generator: generator,
                                    shouldCancel: shouldCancel, onProgress: onProgress) { chunk in
            soFar += chunk
            onPartial(report(soFar, model: modelName))
        }
        return report(llmChanges, model: modelName)
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
