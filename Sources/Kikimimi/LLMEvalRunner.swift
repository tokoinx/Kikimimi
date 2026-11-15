import Foundation
import KikimimiCore
import KikimimiLLM

/// `Kikimimi --eval-llm <model.gguf> --set <場面.json> [--set …] [--adapter <lora.gguf>] [--ledger <台帳.json>]
///          [--rules-only] [--cpu] [--no-split-retry] [--no-terms] [--report <結果.json>] [--baseline <前の結果.json>]`
/// `Kikimimi --eval-llm none --rescore <結果.json> [--report <結果.json>] [--baseline <前の結果.json>]`
///
/// 評価ハーネス: 決まった場面 (聞き間違いを含む短い文字起こしと正解) で監査役・翻訳役を動かし、成績を数える。
/// モデル・学習した直し・追加学習の差分 (LoRA) を変えたときに、同じ物差しで比べるために使う。
/// `--baseline` を付けると前の結果と比べ、悪くなっていれば終了コード 3 を返す (差分を使う前の関門)。
/// 結果には、翻訳の問題ごとの LLM の訳そのもの (`translationOutputs`) を残す。`--rescore` は、それを今の採点の決まりで
/// 採点し直す (LLM は使わない。採点の決まりを直した時に、測り直さずに済む)
/// `Kikimimi --eval-llm none --gate <問題.json か 結果.json> [--gate …] [--report <出力.json>]` は、訳の関門
/// (`TranslationGate`) を LLM なしで測る (問題なら人の訳と壊した訳に、結果なら残した LLM の訳に掛ける)
/// `--no-split-retry` は、訳の後ろが抜けた時の、文に分けた訳し直し (`TranslationOptions.splitRetry`) を切る (入・切を比べる)
/// `--no-terms` は、問題の訳語の対 (`terms`) を翻訳に渡さずに訳す (採点は対で行う。渡した時と `termsKept` を比べる)
enum LLMEvalRunner {
    /// 結果の JSON (中身と、古い結果の読み方・採点し直しは KikimimiCore の `LLMEvalReport`)
    typealias Report = LLMEvalReport

    private static func load(_ path: String) throws -> Report {
        try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: expand(path))))
    }

    private static func write(_ report: Report, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: expand(path)), options: .atomic)
        log("report: \(path)")
    }

    /// `--rescore`: 残した訳を、今の採点の決まりで採点し直す (LLM は使わない)
    private static func rescore(_ path: String, report reportPath: String?, baseline: Report?) -> Int32 {
        let old: Report
        do {
            old = try load(path)
        } catch {
            log("RESCORE FAILED: could not read \(path): \(error.localizedDescription)")
            return 1
        }
        guard let report = old.rescored(from: (path as NSString).lastPathComponent) else {
            log("RESCORE FAILED: \(path) has no translationOutputs (the LLM translations were not saved in this report). "
                + "Run --eval-llm again with this version to save them.")
            return 2
        }
        for line in report.details { log("  " + line) }
        log("rescored \(report.translationOutputs?.count ?? 0) translation cases from \(path)")
        log(report.translation.summary)
        for line in LLMEval.translationTable(report.translationByTarget) { log("  " + line) }
        do {
            if let reportPath { try write(report, to: reportPath) }
        } catch {
            log("RESCORE FAILED: \(error.localizedDescription)")
            return 1
        }
        if let baseline { return compare(report, with: baseline) ? 0 : 3 }
        return 0
    }

    /// `--gate`: 訳の関門 (`TranslationGate`) を LLM なしで測る。問題のファイルなら人の訳 (と壊した訳) に、
    /// 結果のファイルなら残した LLM の訳に、関門を掛ける (中身は KikimimiCore の `TranslationGateEval`)
    private static func gate(_ paths: [String], report reportPath: String?) -> Int32 {
        var report = TranslationGateReport()
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: expand(path)))
            } catch {
                log("GATE FAILED: could not read \(path): \(error.localizedDescription)")
                return 1
            }
            // 結果のファイル (model と audit が在る) か、問題のファイルか
            if let old = try? JSONDecoder().decode(Report.self, from: data) {
                guard let outputs = old.translationOutputs else {
                    log("GATE FAILED: \(path) has no translationOutputs (the LLM translations were not saved in this report)")
                    return 1
                }
                let result = TranslationGateEval.checkOutputs(outputs, file: name)
                for (target, stats) in result.byTarget { report.outputs[target, default: TranslationGateEval.OutputStats()].add(stats) }
                report.examples += result.examples
                log("\(name): \(outputs.count) translation cases (LLM translations), \(result.examples.count) flagged units")
            } else {
                let set: LLMEvalSet
                do {
                    set = try JSONDecoder().decode(LLMEvalSet.self, from: data)
                } catch {
                    log("GATE FAILED: \(path) is neither a report nor a set: \(error.localizedDescription)")
                    return 1
                }
                guard !set.translation.isEmpty else {
                    log("\(name): no translation cases, skipped")
                    continue
                }
                let result = TranslationGateEval.checkReferences(set, file: name)
                for (target, stats) in result.byTarget {
                    report.references[target, default: TranslationGateEval.ReferenceStats()].add(stats)
                }
                report.examples += result.examples
                log("\(name): \(set.translation.count) translation cases (references)")
            }
            report.files.append(name)
        }
        for e in report.examples {
            log("  [\(e.file) \(e.id) \(e.lines.map { "\($0 + 1)" }.joined(separator: ","))] \(e.kind) \(e.flags.joined(separator: ","))"
                + (e.detail.map { " (\($0))" } ?? "") + ": \(e.source) => \(e.translation ?? "(none)")")
        }
        if !report.references.isEmpty {
            log("gate on references (flags = false alarms on human translations; +name = caught/tried on broken translations):")
            for line in TranslationGateEval.referenceTable(report.references) { log("  " + line) }
        }
        if !report.outputs.isEmpty {
            log("gate on LLM translations (chrF of flagged / unflagged units, units with a reference in brackets):")
            for line in TranslationGateEval.outputTable(report.outputs) { log("  " + line) }
        }
        if let reportPath {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: expand(reportPath)), options: .atomic)
                log("report: \(reportPath)")
            } catch {
                log("GATE FAILED: \(error.localizedDescription)")
                return 1
            }
        }
        return 0
    }

    static func run(arguments args: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func values(_ name: String) -> [String] {
            args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
        }
        let gatePaths = values("--gate")
        if !gatePaths.isEmpty {
            return gate(gatePaths, report: value("--report"))
        }
        let rulesOnly = args.contains("--rules-only")
        let modelPath = value("--eval-llm") ?? ""
        let setPaths = values("--set")
        // 前の結果は、何かを書く前に読んでおく (--report と同じファイルでも、上書きする前の値と比べる)
        var baseline: Report?
        if let path = value("--baseline") {
            do {
                baseline = try load(path)
            } catch {
                log("EVAL FAILED: could not read the baseline \(path): \(error.localizedDescription)")
                return 1
            }
        }
        if let path = value("--rescore") {
            return rescore(path, report: value("--report"), baseline: baseline)
        }
        guard !setPaths.isEmpty, rulesOnly || FileManager.default.fileExists(atPath: modelPath) else {
            log("usage: Kikimimi --eval-llm <model.gguf> --set <cases.json> [--set …] [--adapter <lora.gguf>] [--ledger <ledger.json>]"
                + " [--rules-only] [--cpu] [--no-split-retry] [--no-terms] [--report <out.json>] [--baseline <earlier report.json>]")
            log("       Kikimimi --eval-llm none --rescore <report.json> [--report <out.json>] [--baseline <earlier report.json>]")
            log("       Kikimimi --eval-llm none --gate <cases.json or report.json> [--gate …] [--report <out.json>]")
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
                let splitRetry = !args.contains("--no-split-retry")
                if !splitRetry { log("split retry: off (--no-split-retry)") }
                let useTerms = !args.contains("--no-terms")
                if !useTerms { log("terms: not given to the translator (--no-terms)") }
                let translated = try LLMEval.runTranslation(translation, generator: engine, ledger: ledger,
                                                            splitRetry: splitRetry, useTerms: useTerms,
                                                            onCase: { done, total in log("  translation \(done)/\(total)") })
                report.translation = translated.score
                report.translationByTarget = translated.byTarget
                report.details += translated.details
                report.translationOutputs = translated.outputs
            }
            for line in report.details { log("  " + line) }
            log(report.audit.summary)
            if engine != nil {
                log(report.translation.summary)
                if !report.translationByTarget.isEmpty {
                    for line in LLMEval.translationTable(report.translationByTarget) { log("  " + line) }
                }
            }
            if let path = value("--report") { try write(report, to: path) }
            if let baseline { return compare(report, with: baseline) ? 0 : 3 }
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
