import Foundation

/// 追加学習 (LoRA) 用のデータを、学習した直しの台帳から作る。
///
/// 監査役と評価役が実際に受け取るのと同じ形の問い (system / user) と、望ましい答え (assistant) の組にする。
/// - 利用者が「反映する」と決めた直し → 監査役は、その語を FIX として指摘する。評価役は、直した後を選ぶ
/// - 利用者が「元に戻す」と決めた直し → 監査役は、その行を指摘しない。評価役は、直す前を選ぶ
/// - 直す必要のなかった行 → 監査役は「END」だけを答える (直さないことも教える。これが無いと、何でも直したがるようになる)
///
/// 書き出したファイルは Mac の中だけで使う (`tools/finetune/finetune.py`)。
public enum FineTuneData {
    public struct Message: Codable, Hashable, Sendable {
        public var role: String
        public var content: String
    }

    /// 1 件の学習例 (mlx-lm の chat 形式: 1 行に 1 つの JSON)
    public struct Record: Codable, Hashable, Sendable {
        public var messages: [Message]

        init(system: String, user: String, assistant: String) {
            self.init(system: system, examples: [], user: user, assistant: assistant)
        }

        /// examples は、問いの前に置く手本のやりとり (user・assistant の順に並べる。アプリが LLM に送る会話と同じ並び)
        init(system: String, examples: [LLMExample], user: String, assistant: String) {
            var all = [Message(role: "system", content: system)]
            for example in examples {
                all.append(Message(role: "user", content: example.user))
                all.append(Message(role: "assistant", content: example.assistant))
            }
            all.append(Message(role: "user", content: user))
            all.append(Message(role: "assistant", content: assistant))
            messages = all
        }
    }

    /// 直す必要のなかった行 (文字起こしの中で、監査が何も指摘しなかった行)
    public struct CleanLine: Hashable, Sendable {
        public var text: String
        public var language: String?

        public init(text: String, language: String?) {
            self.text = text
            self.language = language
        }
    }

    /// いつも同じ並びになる乱数 (同じ台帳からは、同じデータを作る)
    struct Shuffler {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return bound > 0 ? Int((state >> 33) % UInt64(bound)) : 0
        }
    }

    /// 台帳と、直す必要のなかった行から、学習例を作る。variants は、1 つの直しを何通りの並びで見せるか
    public static func records(ledger: CorrectionLedger, cleanLines: [CleanLine], variants: Int = 3, seed: UInt64 = 1) -> [Record] {
        var random = Shuffler(state: seed)
        var records: [Record] = []
        let decided = ledger.corrections.filter { $0.isActive || $0.isBlocked }
        // 言語ごとの、直す必要のない行 (学習した誤りの語を含む行は除く)
        func clean(_ language: String?) -> [String] {
            cleanLines.filter { line in
                (line.language == nil || language == nil || line.language == language)
                    && !decided.contains { line.text.range(of: $0.wrong, options: .caseInsensitive) != nil }
            }.map(\.text)
        }
        /// その直しが当たる行: 覚えた例の行と、正しい語を含む行を誤りの語に戻したもの
        func erroneous(_ c: LearnedCorrection) -> [String] {
            var lines: [String] = []
            if let example = c.example, Auditor.applyFix(to: example, wrong: c.wrong, right: c.right) != nil {
                lines.append(example)
            }
            // 利用者が断った直しは、覚えた例の行だけを使う (正しい語を含む行を「誤りの語」に戻すと、本物の誤りを「直すな」と教えてしまう)
            guard c.isActive else { return lines }
            for line in cleanLines where c.language == nil || line.language == nil || line.language == c.language {
                guard lines.count < variants, let broken = Auditor.applyFix(to: line.text, wrong: c.right, right: c.wrong),
                      !lines.contains(broken), Auditor.applyFix(to: broken, wrong: c.wrong, right: c.right) != nil else { continue }
                lines.append(broken)
            }
            return lines
        }

        for correction in decided {
            let language = correction.language
            let system = Auditor.systemPrompt(language: language)
            let pool = clean(language)
            let targets = erroneous(correction)
            guard !targets.isEmpty else { continue }
            for variant in 0..<variants {
                let target = targets[variant % targets.count]
                // 3〜7 行のまとまりの中の、毎回ちがう位置に置く
                var lines: [String] = []
                let size = pool.isEmpty ? 1 : min(pool.count + 1, 3 + random.next(5))
                var used = Set<Int>()
                while lines.count < size - 1, used.count < pool.count {
                    let k = random.next(pool.count)
                    if used.insert(k).inserted { lines.append(pool[k]) }
                }
                let position = random.next(lines.count + 1)
                lines.insert(target, at: position)
                let answer = correction.isActive ? "[\(position + 1)] FIX \(correction.wrong) => \(correction.right)\nEND\n" : "END\n"
                records.append(Record(system: system, user: Auditor.userPrompt(lines: lines, context: [], glossary: nil),
                                      assistant: answer))
            }
            // 評価役: 並びを入れ替えた 2 つの問い
            for target in targets.prefix(2) {
                guard let fixed = Auditor.applyFix(to: target, wrong: correction.wrong, right: correction.right) else { continue }
                let judge = Auditor.judgeSystemPrompt(language: language)
                let question = "Which version of the line is correct?\n"
                records.append(Record(system: judge, user: question + "1: \(target)\n2: \(fixed)",
                                      assistant: correction.isActive ? "2" : "1"))
                records.append(Record(system: judge, user: question + "1: \(fixed)\n2: \(target)",
                                      assistant: correction.isActive ? "1" : "2"))
            }
        }

        // 直す必要のないまとまり (直しの例と同じくらいの数。最低 4 つ)
        let wanted = max(4, records.count / 3)
        for language in Set(cleanLines.map(\.language)).sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            let pool = clean(language)
            guard pool.count >= 3 else { continue }
            for _ in 0..<max(2, wanted * pool.count / max(1, cleanLines.count)) {
                var lines: [String] = []
                var used = Set<Int>()
                let size = min(pool.count, 3 + random.next(5))
                while lines.count < size {
                    let k = random.next(pool.count)
                    if used.insert(k).inserted { lines.append(pool[k]) }
                }
                records.append(Record(system: Auditor.systemPrompt(language: language),
                                      user: Auditor.userPrompt(lines: lines, context: [], glossary: nil), assistant: "END\n"))
            }
        }
        // 並びを混ぜる (同じ種類が固まらないように)
        for i in stride(from: records.count - 1, to: 0, by: -1) {
            records.swapAt(i, random.next(i + 1))
        }
        return records
    }

    // MARK: 翻訳の学習の例 (U7)

    /// 翻訳の学習の例と、訳す先ごとの数
    public struct TranslationTraining: Sendable {
        public var records: [Record]
        /// 訳す先ごとの学習の例の数 (1 行の例 + まとめた例)
        public var examplesByTarget: [String: Int]
        /// 訳す先ごとの、例に使った文の数
        public var sentencesByTarget: [String: Int]
        /// 取り分け (`heldOut`) なので使わなかった文の数
        public var heldOut: Int
    }

    /// まとめた例の行の数の並び (この順に繰り返して切る。乱数は使わない)
    static let translationChunkSizes = [2, 3, 4]

    /// 訳の記憶 (いくつでも。足し合わせる) から、翻訳の学習の例を作る。
    ///
    /// - 使うのは、取り分け (`heldOut`) でない文だけ。どれかの記憶で取り分けた文 (訳す先と、そろえた原文が同じ物) は、
    ///   ほかの記憶に在っても使わない (評価の問題に出る文を、学習に入れない)。同じ文が 2 つ在れば、先に在る方を使う
    /// - 指示文は、アプリが翻訳で実際に送る物と同じ: system は `Translator.systemPrompt(language:target:)`、
    ///   user は `Translator.userPrompt` (文脈・用語集なし。記憶の訳語の対のうち、その行に出る物だけを Terms に付ける)。
    ///   答えは `[1] 訳` を行の数だけ (1 行ごとに改行)
    /// - system と問いの間に、アプリと同じ手本のやりとり (`TranslationExamples.examples(for: 訳す先)`。
    ///   `Translator.checkedTranslateLines` が `LLMPrompt.examples` に入れる物) を、前の会話として置く。
    ///   学習の時と使う時で、モデルが見る会話を同じにするため (学習の対象は、最後の答えだけ。`tools/finetune/finetune.py`)
    /// - 1 つの文は、1 行の例に 1 回、まとめた例 (同じ訳す先・同じ原文の言語の文を、記憶の並びの順に 2〜4 行) に多くて 1 回
    /// - 原文の言語は、記憶の `sourceLanguage`。無ければ detector で決め、それでも分からなければ "en"
    public static func translationRecords(memories: [TranslationMemory],
                                          detector: LanguageDetector? = LLMEval.defaultLanguageDetector) -> TranslationTraining {
        struct Item {
            var source: String
            var translation: String
            var language: String
            var target: String
        }
        func key(_ e: RememberedTranslation) -> String {
            TranslationMemory.normalizedTarget(e.target) + "\u{1}" + TranslationMemory.normalizedSource(e.source)
        }
        let all = memories.flatMap(\.sentences)
        let heldOutKeys = Set(all.filter(\.heldOut).map(key))
        var seen = Set<String>()
        var items: [Item] = []
        var heldOut = 0
        for entry in all {
            let k = key(entry)
            if heldOutKeys.contains(k) {
                if seen.insert(k).inserted { heldOut += 1 }
                continue
            }
            // 1 行に収める (改行・続く空白を 1 つの空白に)
            let source = TermPair.cleaned(entry.source)
            let translation = TermPair.cleaned(entry.translation)
            guard !source.isEmpty, !translation.isEmpty, seen.insert(k).inserted else { continue }
            let language = entry.sourceLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? detector?(entry.source) ?? "en"
            items.append(Item(source: source, translation: translation, language: language,
                              target: TranslationMemory.normalizedTarget(entry.target)))
        }

        // 訳語の対は、全部の記憶を足した物から、訳す先ごとに引く (同じ原語は新しく決めた方。アプリの引き方と同じ)
        let merged = TranslationMemory(terms: memories.flatMap(\.terms))
        var termsByTarget: [String: [TermPair]] = [:]
        func terms(_ target: String) -> [TermPair] {
            if let cached = termsByTarget[target] { return cached }
            let pairs = merged.lookup(target: target).terms
            termsByTarget[target] = pairs
            return pairs
        }
        func record(_ group: [Item]) -> Record {
            let first = group[0]
            let lines = group.map(\.source)
            let used = TermPair.matching(terms(first.target), in: lines.joined(separator: "\n"))
            let answer = group.enumerated().map { "[\($0.offset + 1)] \($0.element.translation)\n" }.joined()
            return Record(system: Translator.systemPrompt(language: first.language, target: first.target),
                          examples: TranslationExamples.examples(for: first.target),
                          user: Translator.userPrompt(lines: lines, context: [], glossary: nil, terms: used),
                          assistant: answer)
        }

        // 同じ原文の言語・同じ訳す先の組に分ける (初めに出た順)
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for item in items {
            let g = item.language + "\u{1}" + item.target
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(item)
        }
        var records: [Record] = []
        var examples: [String: Int] = [:]
        var sentences: [String: Int] = [:]
        for g in order {
            guard let group = groups[g], let target = group.first?.target else { continue }
            // 1 行の例
            for item in group {
                records.append(record([item]))
            }
            examples[target, default: 0] += group.count
            sentences[target, default: 0] += group.count
            // まとめた例: 並びの順に 2, 3, 4, 2, 3, 4 … 行ずつ。最後に 1 行だけ余れば、前のまとまり (4 行未満の時) に足す
            var chunks: [[Item]] = []
            var start = 0
            var turn = 0
            while start < group.count {
                let size = translationChunkSizes[turn % translationChunkSizes.count]
                let end = min(group.count, start + size)
                let chunk = Array(group[start..<end])
                if chunk.count >= 2 {
                    chunks.append(chunk)
                } else if let last = chunks.indices.last, chunks[last].count < 4 {
                    chunks[last].append(contentsOf: chunk)
                }
                start = end
                turn += 1
            }
            for chunk in chunks {
                records.append(record(chunk))
            }
            examples[target, default: 0] += chunks.count
        }
        return TranslationTraining(records: records, examplesByTarget: examples, sentencesByTarget: sentences, heldOut: heldOut)
    }

    /// 1 行に 1 つの JSON (JSON Lines)
    public static func jsonl(_ records: [Record]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return records.compactMap { record in
            (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }
}
