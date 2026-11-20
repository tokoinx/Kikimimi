import Foundation
import XCTest
@testable import KikimimiCore

/// モデルの一覧のデータ (Sources/KikimimiCore/Catalog/models.json) と、それを読む所 (ModelCatalogData)
final class ModelCatalogDataTests: XCTestCase {
    /// リポジトリの根 (このファイルから 3 つ上)
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let jsonPath = "Sources/KikimimiCore/Catalog/models.json"

    private static func jsonData() throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(jsonPath))
    }

    // MARK: 埋め込んだ物

    /// アプリに埋め込んだ文 (ModelCatalogGenerated.swift) が、models.json と同じ
    func testGeneratedSwiftMatchesTheJSON() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent(Self.jsonPath), encoding: .utf8)
        // 複数行の文字列は、閉じの前の改行を含まない。台本は、改行で終わらない JSON に改行を足して入れる
        let embedded = ModelCatalogData.embeddedJSON + "\n"
        let expected = file.hasSuffix("\n") ? file : file + "\n"
        XCTAssertTrue(embedded == expected,
                      "Sources/KikimimiCore/Catalog/ModelCatalogGenerated.swift is out of date with \(Self.jsonPath)."
                      + " Run: /usr/bin/python3 Scripts/generate-model-catalog.py")
    }

    /// 埋め込んだ一覧と、ファイルから読んだ一覧が同じ (どちらも同じ入口 decode を通る)
    func testEmbeddedCatalogEqualsTheFile() throws {
        XCTAssertEqual(ModelCatalogData.embedded, try ModelCatalogData.decode(Self.jsonData()))
        XCTAssertEqual(ModelCatalog.all, ModelCatalogData.embedded.whisper.models)
        XCTAssertEqual(LLMCatalog.all, ModelCatalogData.embedded.llm.models)
    }

    /// 一覧の形: 数・id の重なりなし・既定が在り、推奨はそれ 1 つ・URL は https
    func testCatalogShape() throws {
        XCTAssertEqual(ModelCatalog.all.count, 7)
        XCTAssertEqual(LLMCatalog.all.count, 3)
        for ids in [ModelCatalog.all.map(\.id), LLMCatalog.all.map(\.id)] {
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids: \(ids)")
        }
        XCTAssertNotNil(ModelCatalog.spec(id: ModelCatalog.defaultModelID))
        XCTAssertNotNil(LLMCatalog.spec(id: LLMCatalog.defaultModelID))
        XCTAssertEqual(ModelCatalog.all.filter(\.recommended).map(\.id), [ModelCatalog.defaultModelID])
        XCTAssertEqual(LLMCatalog.all.filter(\.recommended).map(\.id), [LLMCatalog.defaultModelID])

        for model in ModelCatalog.all {
            XCTAssertEqual(model.downloadURL.scheme, "https", model.id)
            XCTAssertEqual(model.downloadURL.lastPathComponent, model.fileName, model.id)
            XCTAssertGreaterThan(model.approxMB, 0, model.id)
        }
        XCTAssertEqual(ModelCatalog.vadURL.scheme, "https")
        XCTAssertEqual(ModelCatalog.vadURL.lastPathComponent, ModelCatalog.vadFileName)
        XCTAssertFalse(LLMCatalog.defaultQuantizations.isEmpty)
        for model in LLMCatalog.all {
            XCTAssertFalse(model.repositories.isEmpty, model.id)
            XCTAssertFalse(model.quantizations.isEmpty, model.id)
            XCTAssertFalse(model.license.isEmpty, model.id)
            XCTAssertTrue(model.fallbackFileName.hasSuffix(".gguf"), model.id)
            XCTAssertGreaterThan(model.recommendedMemoryGB, 0, model.id)
            for repository in model.repositories {
                XCTAssertEqual(LLMModelSpec.treeURL(repository: repository)?.scheme, "https", repository)
                XCTAssertEqual(LLMModelSpec.downloadURL(repository: repository, path: model.fallbackFileName)?.scheme, "https", repository)
            }
        }
    }

    /// 書いていない quantizations は、既定の並びになる (init の既定も同じ並び)
    func testQuantizationsDefaultToTheCatalogDefault() throws {
        let spec = LLMModelSpec(id: "x", displayName: "X", summary: "Y", approxMB: 1, recommendedMemoryGB: 1,
                                repositories: ["a/b"], fallbackFileName: "x.gguf", license: "MIT")
        XCTAssertEqual(spec.quantizations, LLMCatalog.defaultQuantizations)
        var json = try Self.object()
        var llm = json["llm"] as! [String: Any]
        var models = llm["models"] as! [[String: Any]]
        models[0]["quantizations"] = ["Q8_0"]
        llm["models"] = models
        json["llm"] = llm
        let catalog = try ModelCatalogData.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(catalog.llm.models[0].quantizations, ["Q8_0"])
        XCTAssertEqual(catalog.llm.models[1].quantizations, catalog.llm.defaultQuantizations)
    }

    // MARK: 壊れた一覧を断る

    private static func object() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonData()) as? [String: Any])
    }

    /// JSON の 1 つの区分 (whisper・vad・llm) を書き換えて読み、断られる事と、理由の文を見る
    private func assertRejected(_ section: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line,
                                _ change: (inout [String: Any]) -> Void) throws {
        var json = try Self.object()
        var part = try XCTUnwrap(json[section] as? [String: Any], file: file, line: line)
        change(&part)
        json[section] = part
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try ModelCatalogData.decode(data), file: file, line: line) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains(expected), "expected “\(expected)” in: \(text)", file: file, line: line)
        }
    }

    /// 区分の models の、n 番目の項目を書き換える
    private static func changeModel(_ part: inout [String: Any], _ index: Int, _ change: (inout [String: Any]) -> Void) {
        var models = part["models"] as! [[String: Any]]
        change(&models[index])
        part["models"] = models
    }

    func testDecodeRejectsBrokenCatalogs() throws {
        // 読めない JSON・形の違う JSON
        XCTAssertThrowsError(try ModelCatalogData.decode(Data("{".utf8)))
        XCTAssertThrowsError(try ModelCatalogData.decode(Data("{}".utf8)))

        // id の重なり・既定が無い・空の一覧・おかしな id
        try assertRejected("whisper", "listed twice") { Self.changeModel(&$0, 1) { $0["id"] = "tiny" } }
        try assertRejected("llm", "listed twice") { Self.changeModel(&$0, 2) { $0["id"] = "qwen3.5-4b" } }
        try assertRejected("whisper", "defaultModelID") { $0["defaultModelID"] = "nope" }
        try assertRejected("llm", "defaultModelID") { $0["defaultModelID"] = "nope" }
        try assertRejected("whisper", "empty") { $0["models"] = [[String: Any]]() }
        try assertRejected("whisper", "bad model id") { Self.changeModel(&$0, 0) { $0["id"] = "a/b" } }
        try assertRejected("llm", "file:") { part in
            Self.changeModel(&part, 0) { $0["id"] = "file:x" }
            part["defaultModelID"] = "file:x"
        }

        // テンプレート: 要る印が無い・知らない印・https でない
        try assertRejected("whisper", "{fileName}") { $0["downloadURLTemplate"] = "https://example.com/model.bin" }
        try assertRejected("whisper", "{id}") { $0["fileNameTemplate"] = "model.bin" }
        try assertRejected("llm", "{repository}") { $0["treeURLTemplate"] = "https://huggingface.co/api/models/tree/main" }
        try assertRejected("llm", "{path}") { $0["downloadURLTemplate"] = "https://huggingface.co/{repository}/resolve/main/" }
        try assertRejected("whisper", "https") { $0["downloadURLTemplate"] = "https://example.com/{fileName}/{other}" }
        try assertRejected("whisper", "https") { $0["downloadURLTemplate"] = "http://example.com/{fileName}" }
        try assertRejected("llm", "https") { $0["treeURLTemplate"] = "http://example.com/{repository}" }
        try assertRejected("vad", "https") { $0["url"] = "http://example.com/ggml-silero-v6.2.0.bin" }
        try assertRejected("vad", "last part") { $0["fileName"] = "other.bin" }

        // 名前: 鍵か生の名前の、どちらか一方だけ。説明は要る
        try assertRejected("whisper", "only one") { Self.changeModel(&$0, 0) { $0["displayName"] = "X" } }
        try assertRejected("llm", "write displayNameKey") { Self.changeModel(&$0, 0) { $0["displayName"] = nil } }
        try assertRejected("whisper", "summaryKey") { Self.changeModel(&$0, 0) { $0["summaryKey"] = "" } }
        try assertRejected("whisper", "summaryKey") { Self.changeModel(&$0, 0) { $0["summaryKey"] = nil } }

        // 数・リポジトリ・量子化
        try assertRejected("whisper", "approxMB") { Self.changeModel(&$0, 0) { $0["approxMB"] = 0 } }
        try assertRejected("llm", "recommendedMemoryGB") { Self.changeModel(&$0, 0) { $0["recommendedMemoryGB"] = 0 } }
        try assertRejected("llm", "repositories is empty") { Self.changeModel(&$0, 0) { $0["repositories"] = [String]() } }
        try assertRejected("llm", "bad repository") { Self.changeModel(&$0, 0) { $0["repositories"] = ["a b/c"] } }
        try assertRejected("llm", "defaultQuantizations") { $0["defaultQuantizations"] = [String]() }
        try assertRejected("llm", "quantizations") { Self.changeModel(&$0, 0) { $0["quantizations"] = [String]() } }
        try assertRejected("llm", "license") { Self.changeModel(&$0, 0) { $0["license"] = "" } }
    }

    // MARK: 画面の文の検査が、JSON を読む所

    func testSourceScanReadsTheCatalog() throws {
        var scan = SourceScan()
        try scan.collectCatalog("models.json", Self.jsonData())
        // 訳す鍵は集まり、訳さない名前 (displayName) は鍵にならない
        XCTAssertTrue(scan.keys.contains("Large v3 Turbo (light)"))
        XCTAssertTrue(scan.keys.contains("Smallest. Low accuracy."))
        XCTAssertFalse(scan.keys.contains("Tiny"))
        XCTAssertFalse(scan.keys.contains("Qwen3.5 4B"))
        XCTAssertEqual(scan.japaneseLiterals, [])

        // 訳さない名前に日本語が入っていれば数える
        var json = try Self.object()
        var whisper = json["whisper"] as! [String: Any]
        Self.changeModel(&whisper, 6) { $0["displayName"] = "極小" }
        json["whisper"] = whisper
        var bad = SourceScan()
        try bad.collectCatalog("models.json", JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(bad.japaneseLiterals.count, 1, "\(bad.japaneseLiterals)")
    }
}
