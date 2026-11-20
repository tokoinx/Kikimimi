import Foundation
import XCTest
@testable import KikimimiCore

/// リンクを検査する道具 (tools/check-links/check_links.py) が models.json から作る URL が、
/// アプリが本当に使う URL と合っているか。llama.cpp の版が、Package.swift と CI で揃っているか。
final class LinkListTests: XCTestCase {
    /// リポジトリの根 (このファイルから 3 つ上)
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let catalogPath = "Sources/KikimimiCore/Catalog/models.json"

    private static func readText(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// アプリが使う URL を、アプリと同じ関数・値から作る。並びは check_links.py と同じ
    /// (Whisper → VAD → LLM の tree API (モデルの順 × リポジトリの順))
    private static func appURLs() -> [String] {
        var urls: [String] = ModelCatalog.all.map { $0.downloadURL.absoluteString }
        urls.append(ModelCatalog.vadURL.absoluteString)
        for model in LLMCatalog.all {
            for repository in model.repositories {
                // 作れない URL は、印の文字で残して食い違いとして出す
                urls.append(LLMModelSpec.treeURL(repository: repository)?.absoluteString ?? "(invalid URL for \(repository))")
            }
        }
        return urls
    }

    /// check_links.py と同じやり方で、models.json のテンプレートの {名前} を、そのまま置き換えて作る
    /// (アプリの読み込み (ModelCatalogData) を通さず、JSON を素のまま読む)
    private static func urlsLikeTheLinkChecker() throws -> [String] {
        let data = try Data(contentsOf: root.appendingPathComponent(catalogPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let whisper = try XCTUnwrap(json["whisper"] as? [String: Any])
        let vad = try XCTUnwrap(json["vad"] as? [String: Any])
        let llm = try XCTUnwrap(json["llm"] as? [String: Any])
        let fileNameTemplate = try XCTUnwrap(whisper["fileNameTemplate"] as? String)
        let whisperTemplate = try XCTUnwrap(whisper["downloadURLTemplate"] as? String)
        let treeTemplate = try XCTUnwrap(llm["treeURLTemplate"] as? String)
        var urls: [String] = []
        for model in try XCTUnwrap(whisper["models"] as? [[String: Any]]) {
            let id = try XCTUnwrap(model["id"] as? String)
            let fileName = fileNameTemplate.replacingOccurrences(of: "{id}", with: id)
            urls.append(whisperTemplate.replacingOccurrences(of: "{fileName}", with: fileName))
        }
        urls.append(try XCTUnwrap(vad["url"] as? String))
        for model in try XCTUnwrap(llm["models"] as? [[String: Any]]) {
            for repository in try XCTUnwrap(model["repositories"] as? [String]) {
                urls.append(treeTemplate.replacingOccurrences(of: "{repository}", with: repository))
            }
        }
        return urls
    }

    func testLinkCheckerBuildsTheSameURLsAsTheApp() throws {
        let checker = try Self.urlsLikeTheLinkChecker()
        let app = Self.appURLs()
        XCTAssertEqual(checker.count, ModelCatalog.all.count + 1 + LLMCatalog.all.reduce(0) { $0 + $1.repositories.count })
        guard checker != app else { return }
        var message = "The URLs built from \(Self.catalogPath) by plain {name} replacement (as tools/check-links/check_links.py does)"
            + " differ from the URLs the app builds (ModelCatalog / LLMModelSpec). Make the Swift code and check_links.py build URLs the same way."
        message += "\nLink checker:\n" + checker.map { "  " + $0 }.joined(separator: "\n")
        message += "\nApp:\n" + app.map { "  " + $0 }.joined(separator: "\n")
        XCTFail(message)
    }

    // MARK: llama.cpp の版

    /// 文から、正規表現の 1 つ目の組を取り出す。無ければ nil
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    func testLlamaVersionMatchesBetweenPackageAndCI() throws {
        let package = try Self.readText("Package.swift")
        let workflow = try Self.readText(".github/workflows/build.yml")

        // Package.swift: releases/download/bNNNNN/llama-bNNNNN-xcframework.zip (2 つの bNNNNN が同じ事も見る)
        let releaseTag = Self.firstCapture(#"ggml-org/llama\.cpp/releases/download/(b\d+)/llama-b\d+-xcframework\.zip"#, in: package)
        let zipTag = Self.firstCapture(#"ggml-org/llama\.cpp/releases/download/b\d+/llama-(b\d+)-xcframework\.zip"#, in: package)
        // build.yml: raw.githubusercontent.com/ggml-org/llama.cpp/<タグ>/models/ggml-vocab-qwen2.gguf
        let ciTag = Self.firstCapture(#"raw\.githubusercontent\.com/ggml-org/llama\.cpp/([^/\s]+)/models/ggml-vocab-qwen2\.gguf"#, in: workflow)

        guard let releaseTag, let zipTag else {
            XCTFail("Could not read the llama.cpp xcframework version (releases/download/bNNNNN/llama-bNNNNN-xcframework.zip) in Package.swift")
            return
        }
        guard let ciTag else {
            XCTFail("Could not read the llama.cpp tag (raw.githubusercontent.com/ggml-org/llama.cpp/<tag>/models/ggml-vocab-qwen2.gguf) in .github/workflows/build.yml")
            return
        }
        XCTAssertEqual(releaseTag, zipTag, "Package.swift: the release tag and the zip name of llama.cpp differ")
        XCTAssertEqual(releaseTag, ciTag, "llama.cpp version differs: Package.swift uses \(releaseTag), .github/workflows/build.yml uses \(ciTag). Make them the same.")
    }
}
