import Foundation
import KikimimiCore

/// `Kikimimi --export-training <出力.jsonl> [--ledger <台帳.json>] [--clean <行.txt>] [--language <ja|en>]`
///
/// 学習した直しの台帳から、追加学習 (LoRA) 用のデータを書き出す (`tools/finetune/finetune.py` が読む)。
/// `--clean` は、直す必要のない行を 1 行ずつ書いたテキスト (文字起こしを「テキスト」で書き出したものなど)。
/// 画面からは、設定の「監査・翻訳」の「学習用のデータを書き出す…」で同じものを書き出せる。
enum TrainingExport {
    /// 台帳の既定の場所 (アプリが保存しているもの)
    static var defaultLedgerURL: URL {
        if let env = ProcessInfo.processInfo.environment["KIKIMIMI_MODELS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env).deletingLastPathComponent().appendingPathComponent("learned-corrections.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Kikimimi/learned-corrections.json")
    }

    static func run(arguments args: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return (args[i + 1] as NSString).expandingTildeInPath
        }
        guard let output = value("--export-training") else {
            log("usage: Kikimimi --export-training <out.jsonl> [--ledger <ledger.json>] [--clean <lines.txt>] [--language <ja|en>]")
            return 2
        }
        let ledgerURL = value("--ledger").map { URL(fileURLWithPath: $0) } ?? defaultLedgerURL
        let ledger = CorrectionLedger.load(from: ledgerURL)
        var clean: [FineTuneData.CleanLine] = []
        if let path = value("--clean") {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                log("✗ \(path) を読めません")
                return 1
            }
            let language = args.firstIndex(of: "--language").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            clean = cleanLines(from: text, language: language)
        }
        do {
            let count = try write(ledger: ledger, cleanLines: clean, to: URL(fileURLWithPath: output))
            log("ledger: \(ledgerURL.path) (\(ledger.corrections.count) corrections), clean lines: \(clean.count)")
            log("✓ \(output): \(count) examples")
            return count > 0 ? 0 : 1
        } catch {
            log("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// テキストを、直す必要のない行にする (空の行と、[mm:ss] の時刻の印を除く)
    static func cleanLines(from text: String, language: String?) -> [FineTuneData.CleanLine] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                line = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
            // 言語が決まっていなければ、文字から決める (かな・漢字があれば日本語)
            return line.count >= 4 ? FineTuneData.CleanLine(text: line, language: language ?? (Script.isJapanese(line) ? "ja" : "en")) : nil
        }
    }

    /// 書き出して、学習例の数を返す
    @discardableResult
    static func write(ledger: CorrectionLedger, cleanLines: [FineTuneData.CleanLine], to url: URL) throws -> Int {
        let records = FineTuneData.records(ledger: ledger, cleanLines: cleanLines)
        try FineTuneData.jsonl(records).write(to: url, atomically: true, encoding: .utf8)
        return records.count
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
