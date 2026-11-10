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
            messages = [Message(role: "system", content: system), Message(role: "user", content: user),
                        Message(role: "assistant", content: assistant)]
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

    /// 1 行に 1 つの JSON (JSON Lines)
    public static func jsonl(_ records: [Record]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return records.compactMap { record in
            (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }
}
