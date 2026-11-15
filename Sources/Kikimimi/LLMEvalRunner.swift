import Foundation
import KikimimiCore
import KikimimiLLM

/// `Kikimimi --eval-llm <model.gguf> --set <場面.json> [--set …] [--adapter <lora.gguf>] [--ledger <台帳.json>]
///          [--rules-only] [--cpu] [--report <結果.json>] [--baseline <前の結果.json>]`
///
/// 評価ハーネス: 決まった場面 (聞き間違いを含む短い文字起こしと正解) で監査役・翻訳役を動かし、成績を数える。
/// モデル・学習した直し・追加学習の差分 (LoRA) を変えたときに、同じ物差しで比べるために使う。
/// `--baseline` を付けると前の結果と比べ、悪くなっていれば終了コード 3 を返す (差分を使う前の関門)。
enum LLMEvalRunner {
    struct Report: Codable {
        var model: String
        var adapter: String?
        var ledgerEntries: Int
        var sets: [String]
        var audit: AuditEvalScore
        /// 翻訳の全体の合計
        var translation: TranslationEvalScore
        /// 翻訳の、訳す先ごとの成績 (鍵は言語のコード)
        var translationByTarget: [String: TranslationEvalScore]
        var details: [String]

        init(model: String, adapter: String?, ledgerEntries: Int, sets: [String], audit: AuditEvalScore,
             translation: TranslationEvalScore, translationByTarget: [String: TranslationEvalScore], details: [String]) {
            self.model = model
            self.adapter = adapter
            self.ledgerEntries = ledgerEntries
            self.sets = sets
            self.audit = audit
            self.translation = translation
            self.translationByTarget = translationByTarget
            self.details = details
        }

        private enum CodingKeys: String, CodingKey {
            case model, adapter, ledgerEntries, sets, audit, translation, translationByTarget, details
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            adapter = try c.decodeIfPresent(String.self, forKey: .adapter)
            ledgerEntries = try c.decodeIfPresent(Int.self, forKey: .ledgerEntries) ?? 0
            sets = try c.decodeIfPresent([String].self, forKey: .sets) ?? []
            audit = try c.decode(AuditEvalScore.self, forKey: .audit)
            translation = try c.decodeIfPresent(TranslationEvalScore.self, forKey: .translation) ?? TranslationEvalScore()
            details = try c.decodeIfPresent([String].self, forKey: .details) ?? []
            if let byTarget = try c.decodeIfPresent([String: TranslationEvalScore].self, forKey: .translationByTarget) {
                translationByTarget = byTarget
            } else {
                // 訳す先ごとの成績が無い古い結果は、日本語へ訳す場合だけを採点していた
                translationByTarget = translation.lines > 0 ? ["ja": translation] : [:]
            }
        }
    }

    static func run(arguments args: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func values(_ name: String) -> [String] {
            args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
        }
        let rulesOnly = args.contains("--rules-only")
        let modelPath = value("--eval-llm") ?? ""
        let setPaths = values("--set")
        guard !setPaths.isEmpty, rulesOnly || FileManager.default.fileExists(atPath: modelPath) else {
            log("usage: Kikimimi --eval-llm <model.gguf> --set <cases.json> [--set …] [--adapter <lora.gguf>] [--ledger <ledger.json>]"
                + " [--rules-only] [--cpu] [--report <out.json>] [--baseline <earlier report.json>]")
            return 2
        }
        do {
            var audit: [AuditEvalCase] = []
            var translation: [TranslationEvalCase] = []
            for path in setPaths {
                let set = try JSONDecoder().decode(LLMEvalSet.self, from: Data(contentsOf: URL(fileURLWithPath: expand(path))))
                audit += set.audit
                translation += set.translation
            }
            let ledger = value("--ledger").map { CorrectionLedger.load(from: URL(fileURLWithPath: expand($0))) }
            let adapter = value("--adapter").map(expand)
            var report = Report(model: rulesOnly ? "(rules only)" : (modelPath as NSString).lastPathComponent,
                                adapter: adapter.map { ($0 as NSString).lastPathComponent },
                                ledgerEntries: ledger?.corrections.count ?? 0,
                                sets: setPaths.map { ($0 as NSString).lastPathComponent },
                                audit: AuditEvalScore(), translation: TranslationEvalScore(), translationByTarget: [:], details: [])
            var engine: LlamaEngine?
            if !rulesOnly {
                let started = Date()
                engine = try LlamaEngine(modelPath: modelPath,
                                         options: LlamaOptions(gpuLayers: args.contains("--cpu") ? 0 : -1, adapterPath: adapter))
                log(String(format: "loaded %@%@ in %.1f s", engine?.modelDescription ?? "",
                           adapter.map { " + adapter " + ($0 as NSString).lastPathComponent } ?? "", Date().timeIntervalSince(started)))
            }
            log("cases: \(audit.count) audit, \(translation.count) translation; learned corrections: \(report.ledgerEntries)")
            let audited = try LLMEval.runAudit(audit, generator: engine, modelName: engine?.modelDescription, ledger: ledger,
                                               onCase: { done, total in
                                                   if done % 5 == 0 || done == total { log("  audit \(done)/\(total)") }
                                               })
            report.audit = audited.score
            report.details = audited.details
            if let engine {
                let translated = try LLMEval.runTranslation(translation, generator: engine, ledger: ledger,
                                                            onCase: { done, total in log("  translation \(done)/\(total)") })
                report.translation = translated.score
                report.translationByTarget = translated.byTarget
                report.details += translated.details
            }
            for line in report.details { log("  " + line) }
            log(report.audit.summary)
            if engine != nil {
                log(report.translation.summary)
                if !report.translationByTarget.isEmpty {
                    for line in LLMEval.translationTable(report.translationByTarget) { log("  " + line) }
                }
            }
            if let path = value("--report") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: expand(path)), options: .atomic)
                log("report: \(path)")
            }
            if let path = value("--baseline") {
                let before = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: expand(path))))
                return compare(report, with: before) ? 0 : 3
            }
            return 0
        } catch {
            log("EVAL FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    /// 前の結果と比べる。害が増えた・正しく直せた数が減った・訳す先のどれかで訳の点検が悪くなったら false
    static func compare(_ now: Report, with before: Report) -> Bool {
        func delta(_ name: String, _ a: Int, _ b: Int) -> String { "\(name) \(b) -> \(a) (\(a >= b ? "+" : "")\(a - b))" }
        let found = now.audit.fixedAutomatically + now.audit.fixedBySuggestion
        let foundBefore = before.audit.fixedAutomatically + before.audit.fixedBySuggestion
        log("compared with \(before.model)\(before.adapter.map { " + " + $0 } ?? ""):")
        log("  " + delta("fixed automatically", now.audit.fixedAutomatically, before.audit.fixedAutomatically)
            + ", " + delta("fixed incl. suggestions", found, foundBefore))
        log("  " + delta("harmed", now.audit.harmed, before.audit.harmed)
            + ", " + delta("wrong fixes", now.audit.wrongFixes, before.audit.wrongFixes)
            + ", " + delta("false suggestions", now.audit.falseSuggestions, before.audit.falseSuggestions))
        // 翻訳は、訳す先ごとに比べる (前の結果に無い訳す先は比べない)
        for target in now.translationByTarget.keys.sorted() {
            guard let a = now.translationByTarget[target], let b = before.translationByTarget[target] else { continue }
            let points = [b.chrF, a.chrF].map { $0.map { String(format: "%.2f", $0) } ?? "-" }
            log("  \(target): " + delta("translated", a.translated, b.translated)
                + ", " + delta("in the target language", a.inTarget, b.inTarget)
                + ", " + delta("numbers kept", a.numbersKept, b.numbersKept)
                + ", " + delta("terms kept", a.termsKept, b.termsKept)
                + ", " + delta("copied", a.copied, b.copied)
                + ", " + delta("repeated", a.repeated, b.repeated)
                + ", chrF \(points[0]) -> \(points[1])")
        }
        let regressions = LLMEval.translationRegressions(now.translationByTarget, baseline: before.translationByTarget)
        for line in regressions { log("  worse: " + line) }
        let worse = now.audit.harmed + now.audit.wrongFixes > before.audit.harmed + before.audit.wrongFixes
            || found < foundBefore
            || !regressions.isEmpty
        log(worse ? "RESULT: WORSE than the baseline (do not use this change)" : "RESULT: not worse than the baseline")
        return !worse
    }

    private static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
