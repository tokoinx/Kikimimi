import Foundation
import XCTest
@testable import KikimimiCore

/// リンクを検査する道具が読む URL の一覧 (tools/check-links/runtime-urls.txt) が、
/// アプリが本当に使う URL と合っているか。llama.cpp の版が、Package.swift と CI で揃っているか。
final class LinkListTests: XCTestCase {
    /// リポジトリの根 (このファイルから 3 つ上)
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let listPath = "tools/check-links/runtime-urls.txt"

    private static func readText(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// アプリが使う URL を、アプリと同じ関数・値から作る。並びは一覧と同じ
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

    func testRuntimeURLListMatchesTheCatalogs() throws {
        let text = try Self.readText(Self.listPath)
        // # で始まる行と空の行は注釈
        let listed = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let expected = Self.appURLs()
        guard listed != expected else { return }

        let missing = expected.filter { !listed.contains($0) }
        let extra = listed.filter { !expected.contains($0) }
        var message = "\(Self.listPath) does not match ModelCatalog / LLMCatalog. Fix \(Self.listPath)."
        if !missing.isEmpty {
            message += "\nMissing URLs (add to \(Self.listPath)):\n" + missing.map { "  " + $0 }.joined(separator: "\n")
        }
        if !extra.isEmpty {
            message += "\nExtra URLs (remove from \(Self.listPath)):\n" + extra.map { "  " + $0 }.joined(separator: "\n")
        }
        if missing.isEmpty && extra.isEmpty {
            message += "\nSame URLs, wrong order. Expected order:\n" + expected.map { "  " + $0 }.joined(separator: "\n")
        }
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
