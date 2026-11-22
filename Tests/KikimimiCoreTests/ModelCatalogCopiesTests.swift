import Foundation
import XCTest
@testable import KikimimiCore

/// モデルの一覧 (Sources/KikimimiCore/Catalog/models.json) の値を、手で写している所 (README の表・CI の URL・
/// 追加学習の道具のモデルの id) が、一覧と合っているか。ずれたら落ちる
final class ModelCatalogCopiesTests: XCTestCase {
    /// リポジトリの根 (このファイルから 3 つ上)
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func readText(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 正規表現に当たった所ごとに、1 つ目の組を集める
    private static func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: README のモデルの表

    /// 表の 1 行 (名前の列・大きさの列・メモリの列 (LLM の表だけ))
    private struct Row {
        let line: String
        let name: String
        let size: String
        let memory: String?
    }

    /// 見出しの行 (header で始まる行) の表を読む。区切りの行を飛ばし、| で始まる行が続く間だけ
    private static func table(_ text: String, header: String, path: String) throws -> [Row] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(header) }) else {
            XCTFail("\(path): the table starting with \"\(header)\" was not found")
            return []
        }
        var rows: [Row] = []
        for line in lines[(start + 2)...] {
            guard line.hasPrefix("|") else { break }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 先頭と終わりの | の外側は空の欄になる
            guard cells.count >= 5 else {
                XCTFail("\(path): a row of the table has too few columns: \(line)")
                continue
            }
            rows.append(Row(line: line, name: cells[1], size: cells[3], memory: cells.count >= 6 ? cells[4] : nil))
        }
        return rows
    }

    /// 文の中の数 (小数を含む) を、出た順に取り出す
    private static func numbers(_ text: String) throws -> [Double] {
        try captures(#"(\d+(?:\.\d+)?)"#, in: text).compactMap(Double.init)
    }

    /// 1 つのモデルの大きさの書き方: 1000 MB 未満は MB の数そのまま、それ以上は GB (1000 MB = 1 GB) で小数 1 桁
    private static func sizeMatches(_ cell: String, approxMB: Int) throws -> Bool {
        let values = try numbers(cell)
        guard values.count == 1 else { return false }
        if approxMB < 1000 {
            return cell.hasSuffix("MB") && Int(values[0]) == approxMB
        }
        let gb = (Double(approxMB) / 100).rounded() / 10
        return cell.hasSuffix("GB") && values[0] == gb
    }

    /// 1 から 10 の位で丸めた数 (まとめた行の「60〜540 MB」の書き方)
    private static func roundedToTen(_ value: Int) -> Int {
        Int((Double(value) / 10).rounded()) * 10
    }

    /// 名前の終わりの「 (…)」を外した物 (まとめた行は「Medium / Small / …」と、括弧の無い名前で書く)
    private static func baseName(_ name: String) -> String {
        guard let index = name.range(of: " (") else { return name }
        return String(name[..<index.lowerBound])
    }

    /// 表の行と、一覧のモデル (名前・大きさ) を突き合わせる。どのモデルも、ちょうど 1 つの行に出る事も見る。
    /// name は、その README の言語で出る名前 (日本語の README は、日本語の表の訳)
    private func assertTable(_ rows: [Row], path: String, models: [(id: String, name: String, approxMB: Int, memoryGB: Int?)]) throws {
        var seen: [String] = []
        for row in rows {
            let parts = row.name.components(separatedBy: " / ")
            if parts.count == 1 {
                // 1 つのモデルの行: 名前がそのまま同じ
                guard let model = models.first(where: { $0.name == row.name }) else {
                    XCTFail("\(path): no model in the catalog is shown as \"\(row.name)\": \(row.line)")
                    continue
                }
                seen.append(model.id)
                XCTAssertTrue(try Self.sizeMatches(row.size, approxMB: model.approxMB),
                              "\(path): the size of \(model.id) is \(model.approxMB) MB in the catalog: \(row.line)")
                if let memoryGB = model.memoryGB {
                    let memory = try Self.numbers(row.memory ?? "")
                    XCTAssertEqual(memory, [Double(memoryGB)],
                                   "\(path): the memory of \(model.id) is \(memoryGB) GB in the catalog: \(row.line)")
                }
            } else {
                // まとめた行: 名前は括弧を外した物。大きさは、最も小さい物〜最も大きい物 (10 の位で丸めた MB)
                var group: [(id: String, name: String, approxMB: Int, memoryGB: Int?)] = []
                for part in parts {
                    guard let model = models.first(where: { Self.baseName($0.name) == part }) else {
                        XCTFail("\(path): no model in the catalog is shown as \"\(part)\": \(row.line)")
                        continue
                    }
                    group.append(model)
                }
                seen += group.map(\.id)
                guard let low = group.map(\.approxMB).min(), let high = group.map(\.approxMB).max() else { continue }
                let values = try Self.numbers(row.size)
                XCTAssertTrue(row.size.hasSuffix("MB") && values == [Double(Self.roundedToTen(low)), Double(Self.roundedToTen(high))],
                              "\(path): the sizes of \(group.map(\.id)) are \(low)…\(high) MB in the catalog: \(row.line)")
            }
        }
        XCTAssertEqual(seen.count, Set(seen).count, "\(path): a model appears in more than one row: \(seen)")
        XCTAssertEqual(Set(seen), Set(models.map(\.id)), "\(path): the table and the catalog have different models")
    }

    /// README.md (日本語) と README.en.md (英語) の、Whisper の表と LLM の表
    func testReadmeModelTablesMatchTheCatalog() throws {
        let readmes: [(path: String, language: UILanguage, whisperHeader: String, llmHeader: String)] = [
            ("README.md", .ja, "| モデル | 向いている用途 | サイズ |", "| LLM | 向いている用途 | サイズ | メモリ |"),
            ("README.en.md", .en, "| Model | Best for | Size |", "| LLM | Best for | Size | Memory |"),
        ]
        for readme in readmes {
            let text = try Self.readText(readme.path)
            let whisper = ModelCatalog.all.map {
                (id: $0.id, name: L10n.text($0.displayNameKey, in: readme.language), approxMB: $0.approxMB, memoryGB: Int?.none)
            }
            let llm = LLMCatalog.all.map {
                (id: $0.id, name: L10n.text($0.displayNameKey, in: readme.language), approxMB: $0.approxMB,
                 memoryGB: Int?.some($0.recommendedMemoryGB))
            }
            try assertTable(Self.table(text, header: readme.whisperHeader, path: readme.path), path: readme.path, models: whisper)
            try assertTable(Self.table(text, header: readme.llmHeader, path: readme.path), path: readme.path, models: llm)
        }
    }

    // MARK: CI のモデルの URL

    /// CI (.github/workflows/build.yml・finetune.yml) が取ってくる Hugging Face の URL が、一覧から作れる URL と同じ。
    /// - Whisper の配布元 (whisper.downloadURLTemplate の前の所で始まる物) は、一覧のどれかのモデルの URL と同じ
    /// - VAD の配布元 (vad.url と同じリポジトリ) は、vad.url と同じ
    /// - ほかは LLM。一覧のモデルなら、その URL と同じ。一覧に無いモデル (CI だけが使う物) は、
    ///   llm.downloadURLTemplate の型 (リポジトリと .gguf のファイル) に合う事だけを見る
    /// - 保存する名前 (curl -o の最後の所) が、URL の最後の所と同じ (アプリは、その名前でモデルを探す)
    func testWorkflowModelURLsMatchTheCatalog() throws {
        let catalog = ModelCatalogData.embedded
        let whisperURLs = Set(ModelCatalog.all.map(\.downloadURL.absoluteString))
        let whisperPrefix = try XCTUnwrap(catalog.whisper.downloadURLTemplate.components(separatedBy: "{fileName}").first)
        let vadURL = ModelCatalog.vadURL.absoluteString
        let vadPrefix = vadURL.replacingOccurrences(of: ModelCatalog.vadURL.lastPathComponent, with: "")
        var llmURLs: Set<String> = []
        for model in LLMCatalog.all {
            for repository in model.repositories {
                if let url = LLMModelSpec.downloadURL(repository: repository, path: model.fallbackFileName) {
                    llmURLs.insert(url.absoluteString)
                }
            }
        }
        // llm.downloadURLTemplate を正規表現にする ({repository} は 所有者/名前、{path} は .gguf のファイル)
        let llmPattern = "^" + NSRegularExpression.escapedPattern(for: catalog.llm.downloadURLTemplate)
            .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{repository}"), with: #"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+"#)
            .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{path}"), with: #"[A-Za-z0-9._-]+\.gguf"#) + "$"
        let llmRegex = try NSRegularExpression(pattern: llmPattern)

        var checked = 0
        for path in [".github/workflows/build.yml", ".github/workflows/finetune.yml"] {
            let text = try Self.readText(path)
            for url in try Self.captures(#"(https://huggingface\.co/[^\s"'\\;]+)"#, in: text) {
                checked += 1
                if url.hasPrefix(whisperPrefix) {
                    XCTAssertTrue(whisperURLs.contains(url), "\(path): \(url) is not the URL of any whisper model in the catalog")
                } else if url.hasPrefix(vadPrefix) {
                    XCTAssertEqual(url, vadURL, "\(path): the VAD URL differs from vad.url in the catalog")
                } else if !llmURLs.contains(url) {
                    let range = NSRange(url.startIndex..., in: url)
                    XCTAssertNotNil(llmRegex.firstMatch(in: url, range: range),
                                    "\(path): \(url) is not in the catalog and does not fit llm.downloadURLTemplate (\(catalog.llm.downloadURLTemplate))")
                }
                // 保存する名前: curl -o <置き場>/<名前> \ の次の行が、この URL
                let pattern = #"-o\s+(\S+)\s*\\\s*\n\s*"# + NSRegularExpression.escapedPattern(for: url)
                if let saved = try Self.captures(pattern, in: text).first, url.hasPrefix(whisperPrefix) || url.hasPrefix(vadPrefix) {
                    XCTAssertEqual((saved as NSString).lastPathComponent, (url as NSString).lastPathComponent,
                                   "\(path): \(url) is saved as \(saved); the app looks for the catalog's file name")
                }
            }
        }
        // 3 つ (小さな Whisper・VAD・0.8B の LLM) より少なければ、読み方が合っていない
        XCTAssertGreaterThanOrEqual(checked, 3, "fewer Hugging Face URLs than expected were found in the workflows")
    }

    // MARK: 追加学習の道具のモデルの id

    /// tools/finetune/finetune.py の辞書 (MLX_MODELS・MEMORY_NEEDED) の鍵と、--model の既定が、一覧の LLM の id に在る
    func testFinetuneModelIDsAreInTheCatalog() throws {
        let path = "tools/finetune/finetune.py"
        let text = try Self.readText(path)
        let catalogIDs = Set(LLMCatalog.all.map(\.id))
        for name in ["MLX_MODELS", "MEMORY_NEEDED"] {
            let body = try XCTUnwrap(try Self.captures(name + #"\s*=\s*\{([^}]*)\}"#, in: text).first,
                                     "\(path): \(name) = { … } was not found")
            let ids = try Self.captures(#""([^"]+)"\s*:"#, in: body)
            XCTAssertFalse(ids.isEmpty, "\(path): no ids were read from \(name)")
            let unknown = ids.filter { !catalogIDs.contains($0) && !Self.ciOnlyModelIDs.contains($0) }
            XCTAssertEqual(unknown, [], "\(path): \(name) has ids that are not LLMs in the catalog"
                               + " (a model that only CI uses goes into ciOnlyModelIDs in this test)")
            // 一覧のどの LLM も学習できる
            let missing = catalogIDs.subtracting(ids).sorted()
            XCTAssertEqual(missing, [], "\(path): \(name) has no entry for these LLMs in the catalog")
        }
        let defaults = try Self.captures(#"add_argument\("--model", default="([^"]+)""#, in: text)
        XCTAssertEqual(defaults.count, 1, "\(path): the default of --model was not found")
        for id in defaults {
            XCTAssertTrue(catalogIDs.contains(id), "\(path): the default --model \(id) is not an LLM in the catalog")
        }
        // CI だけの id は、本当に CI の通しの確認が使っていて、一覧には無い (一覧に足したら、ここから外す)
        let workflowPath = ".github/workflows/finetune.yml"
        let workflow = try Self.readText(workflowPath)
        for id in Self.ciOnlyModelIDs.sorted() {
            XCTAssertTrue(workflow.contains("--model \(id)"), "\(workflowPath) does not use --model \(id); remove it from ciOnlyModelIDs")
            XCTAssertFalse(catalogIDs.contains(id), "\(id) is in the catalog now; remove it from ciOnlyModelIDs")
        }
    }

    /// 一覧に無いが、CI の通しの確認 (.github/workflows/finetune.yml) だけが使う LLM の id。
    /// 学習の道具 (tools/finetune/finetune.py) には在るが、アプリでは選べない (小さくて、CI の Mac でも学習できる物)
    private static let ciOnlyModelIDs: Set<String> = ["qwen3.5-0.8b"]
}
