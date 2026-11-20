import Foundation

/// モデルの一覧 (Whisper・VAD・LLM) のデータ。元は同じ場所の `models.json` (ただ 1 つの元)。
/// アプリには、台本 (`Scripts/generate-model-catalog.py`) が作った `ModelCatalogGenerated.swift` として埋め込む。
/// `ModelCatalog`・`LLMCatalog` は、ここから一覧を作る。
///
/// 将来、一覧を外から差し替える時の入口は `decode(_:)` (受けた `Data` を読み、中身を確かめる)。
/// 埋め込んだ物も、同じ入口を通して読む。
///
/// LLM の大きさは Hugging Face の一覧 (2026-11) の Q4_K_M の値。リポジトリは書いた順に試す
/// (unsloth の方が少し小さいので先に書く)。
public struct ModelCatalogData: Sendable, Equatable {
    public struct Whisper: Sendable, Equatable {
        /// 保存するファイルの名前の作り方 (`{id}` を置き換える)
        public let fileNameTemplate: String
        /// 取得元の作り方 (`{fileName}` を置き換える)
        public let downloadURLTemplate: String
        public let defaultModelID: String
        public let models: [WhisperModelSpec]
    }

    public struct VAD: Sendable, Equatable {
        public let fileName: String
        public let url: URL
    }

    public struct LLM: Sendable, Equatable {
        /// ファイル一覧 (tree API) の作り方 (`{repository}` を置き換える)
        public let treeURLTemplate: String
        /// ファイルの取得元の作り方 (`{repository}` と `{path}` を置き換える)
        public let downloadURLTemplate: String
        public let defaultModelID: String
        /// 量子化の優先順 (モデルに書いていない時に使う)
        public let defaultQuantizations: [String]
        public let models: [LLMModelSpec]
    }

    public let whisper: Whisper
    public let vad: VAD
    public let llm: LLM

    /// 一覧が読めない・おかしい時の理由 (英語)
    public struct InvalidCatalog: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: 読む

    /// JSON を読み、中身を確かめて、一覧を作る。おかしな所が 1 つでも在れば、理由を付けて断る
    public static func decode(_ data: Data) throws -> ModelCatalogData {
        let raw: RawCatalog
        do {
            raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        } catch {
            throw InvalidCatalog("the model catalog is not in the expected JSON form: \(error)")
        }
        return try build(raw)
    }

    /// アプリに埋め込んだ一覧。初めて使う時に 1 度だけ読む。
    /// 読めない時は止まる (試験が通ったビルドでは起きない。空の一覧で続けると、`ModelCatalog.all[0]` などが壊れる)
    public static let embedded: ModelCatalogData = {
        do {
            return try decode(Data(embeddedJSON.utf8))
        } catch {
            fatalError("Kikimimi: the built-in model catalog (Catalog/models.json) could not be read: \(error)")
        }
    }()

    /// 訳す鍵 (`displayNameKey` と `summaryKey`)。画面の文の試験 (L10nTests) が、表と突き合わせる
    let translationKeys: [String]
    /// 訳さない生の名前 (`displayName`)。画面の文の試験が、日本語が入っていない事を見る
    let untranslatedNames: [String]

    // MARK: 置き換え

    /// テンプレートの `{名前}` を、そのまま置き換える (Python の check_links.py も同じやり方)。
    /// テンプレートに、渡した名前のほかの `{` `}` (知らない印・閉じていない印) が在れば nil
    static func fill(_ template: String, _ values: [(String, String)]) -> String? {
        var rest = template
        for (name, _) in values { rest = rest.replacingOccurrences(of: "{\(name)}", with: "") }
        guard !rest.contains("{"), !rest.contains("}") else { return nil }
        var out = template
        for (name, value) in values {
            out = out.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return out
    }

    /// https で、ホストの在る URL だけを受ける
    static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

// MARK: - JSON の形

/// JSON の形そのもの (確かめる前)
private struct RawCatalog: Decodable {
    struct Whisper: Decodable {
        let fileNameTemplate: String
        let downloadURLTemplate: String
        let defaultModelID: String
        let models: [Model]
        struct Model: Decodable {
            let id: String
            /// 訳す鍵 (英語)。訳さない名前なら displayName。どちらか一方を書く
            let displayNameKey: String?
            let displayName: String?
            let summaryKey: String
            let approxMB: Int
        }
    }

    struct VAD: Decodable {
        let fileName: String
        let url: String
    }

    struct LLM: Decodable {
        let treeURLTemplate: String
        let downloadURLTemplate: String
        let defaultModelID: String
        let defaultQuantizations: [String]
        let models: [Model]
        struct Model: Decodable {
            let id: String
            let displayNameKey: String?
            let displayName: String?
            let summaryKey: String
            let approxMB: Int
            let recommendedMemoryGB: Int
            let repositories: [String]
            let fallbackFileName: String
            /// 既定 (defaultQuantizations) と違う時だけ書く
            let quantizations: [String]?
            let license: String
        }
    }

    let whisper: Whisper
    let vad: VAD
    let llm: LLM
}

// MARK: - 確かめて作る

extension ModelCatalogData {
    /// 文が空でない・前後に空白が無い
    private static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines) == text
    }

    /// id に使える形 (空でない・空白と / が無い)
    private static func isSafeID(_ id: String) -> Bool {
        isPlain(id) && !id.contains("/") && !id.contains(where: { $0.isWhitespace })
    }

    /// 表示名の鍵か生の名前の、どちらか一方だけが書いてある事を確かめ、鍵として持つ文を返す
    private static func nameKey(_ section: String, _ id: String, key: String?, name: String?) throws -> String {
        switch (key, name) {
        case let (key?, nil):
            guard isPlain(key) else { throw InvalidCatalog("\(section) model \"\(id)\": displayNameKey is empty or has extra spaces") }
            return key
        case let (nil, name?):
            guard isPlain(name) else { throw InvalidCatalog("\(section) model \"\(id)\": displayName is empty or has extra spaces") }
            return name
        case (nil, nil):
            throw InvalidCatalog("\(section) model \"\(id)\": write displayNameKey (a key to translate) or displayName (a name not translated)")
        case (_?, _?):
            throw InvalidCatalog("\(section) model \"\(id)\": write only one of displayNameKey and displayName")
        }
    }

    /// id の重なりと、既定の id が一覧に在る事を見る
    private static func checkIDs(_ section: String, _ ids: [String], defaultID: String) throws {
        guard !ids.isEmpty else { throw InvalidCatalog("\(section): the model list is empty") }
        var seen: Set<String> = []
        for id in ids {
            guard isSafeID(id) else { throw InvalidCatalog("\(section): bad model id \"\(id)\" (empty, or has spaces or /)") }
            guard seen.insert(id).inserted else { throw InvalidCatalog("\(section): the model id \"\(id)\" is listed twice") }
        }
        guard ids.contains(defaultID) else {
            throw InvalidCatalog("\(section): defaultModelID \"\(defaultID)\" is not in the model list")
        }
    }

    /// テンプレートに、要る印が全部在る事を見る
    private static func checkTemplate(_ section: String, _ field: String, _ template: String, needs names: [String]) throws {
        for name in names where !template.contains("{\(name)}") {
            throw InvalidCatalog("\(section).\(field) has no {\(name)} placeholder: \(template)")
        }
    }

    fileprivate static func build(_ raw: RawCatalog) throws -> ModelCatalogData {
        // Whisper
        let w = raw.whisper
        try checkTemplate("whisper", "fileNameTemplate", w.fileNameTemplate, needs: ["id"])
        try checkTemplate("whisper", "downloadURLTemplate", w.downloadURLTemplate, needs: ["fileName"])
        try checkIDs("whisper", w.models.map(\.id), defaultID: w.defaultModelID)
        var whisperModels: [WhisperModelSpec] = []
        for m in w.models {
            let key = try nameKey("whisper", m.id, key: m.displayNameKey, name: m.displayName)
            guard isPlain(m.summaryKey) else { throw InvalidCatalog("whisper model \"\(m.id)\": summaryKey is empty or has extra spaces") }
            guard m.approxMB > 0 else { throw InvalidCatalog("whisper model \"\(m.id)\": approxMB must be more than 0") }
            guard let fileName = fill(w.fileNameTemplate, [("id", m.id)]), isSafeID(fileName) else {
                throw InvalidCatalog("whisper model \"\(m.id)\": fileNameTemplate gives a bad file name: \(w.fileNameTemplate)")
            }
            guard let url = fill(w.downloadURLTemplate, [("fileName", fileName)]), httpsURL(url) != nil else {
                throw InvalidCatalog("whisper model \"\(m.id)\": downloadURLTemplate does not give an https URL: \(w.downloadURLTemplate)")
            }
            whisperModels.append(WhisperModelSpec(id: m.id, displayName: key, summary: m.summaryKey, approxMB: m.approxMB,
                                                  recommended: m.id == w.defaultModelID))
        }

        // VAD
        guard let vadURL = httpsURL(raw.vad.url) else { throw InvalidCatalog("vad.url is not an https URL: \(raw.vad.url)") }
        guard isSafeID(raw.vad.fileName), vadURL.lastPathComponent == raw.vad.fileName else {
            throw InvalidCatalog("vad.fileName \"\(raw.vad.fileName)\" must be the last part of vad.url")
        }

        // LLM
        let l = raw.llm
        try checkTemplate("llm", "treeURLTemplate", l.treeURLTemplate, needs: ["repository"])
        try checkTemplate("llm", "downloadURLTemplate", l.downloadURLTemplate, needs: ["repository", "path"])
        try checkIDs("llm", l.models.map(\.id), defaultID: l.defaultModelID)
        guard !l.defaultQuantizations.isEmpty, l.defaultQuantizations.allSatisfy(isPlain) else {
            throw InvalidCatalog("llm.defaultQuantizations is empty or has an empty name")
        }
        var llmModels: [LLMModelSpec] = []
        for m in l.models {
            let section = "llm model \"\(m.id)\""
            // 手元の GGUF は "file:…" の id で表すので、一覧の id には使わない
            guard !m.id.hasPrefix("file:") else { throw InvalidCatalog("\(section): ids starting with file: are for local files") }
            let key = try nameKey("llm", m.id, key: m.displayNameKey, name: m.displayName)
            guard isPlain(m.summaryKey) else { throw InvalidCatalog("\(section): summaryKey is empty or has extra spaces") }
            guard m.approxMB > 0, m.recommendedMemoryGB > 0 else {
                throw InvalidCatalog("\(section): approxMB and recommendedMemoryGB must be more than 0")
            }
            guard !m.repositories.isEmpty else { throw InvalidCatalog("\(section): repositories is empty") }
            for repository in m.repositories {
                guard isPlain(repository), !repository.contains(where: { $0.isWhitespace }) else {
                    throw InvalidCatalog("\(section): bad repository \"\(repository)\"")
                }
                guard let tree = fill(l.treeURLTemplate, [("repository", repository)]), httpsURL(tree) != nil else {
                    throw InvalidCatalog("\(section): treeURLTemplate does not give an https URL for \(repository)")
                }
                guard let file = fill(l.downloadURLTemplate, [("repository", repository), ("path", m.fallbackFileName)]),
                      httpsURL(file) != nil else {
                    throw InvalidCatalog("\(section): downloadURLTemplate does not give an https URL for \(repository)")
                }
            }
            guard isPlain(m.fallbackFileName) else { throw InvalidCatalog("\(section): fallbackFileName is empty") }
            guard isPlain(m.license) else { throw InvalidCatalog("\(section): license is empty") }
            let quantizations = m.quantizations ?? l.defaultQuantizations
            guard !quantizations.isEmpty, quantizations.allSatisfy(isPlain) else {
                throw InvalidCatalog("\(section): quantizations is empty or has an empty name")
            }
            llmModels.append(LLMModelSpec(id: m.id, displayName: key, summary: m.summaryKey, approxMB: m.approxMB,
                                          recommendedMemoryGB: m.recommendedMemoryGB, repositories: m.repositories,
                                          fallbackFileName: m.fallbackFileName, quantizations: quantizations,
                                          license: m.license, recommended: m.id == l.defaultModelID))
        }

        let names = w.models.map { ($0.displayNameKey, $0.displayName, $0.summaryKey) }
            + l.models.map { ($0.displayNameKey, $0.displayName, $0.summaryKey) }
        return ModelCatalogData(
            whisper: Whisper(fileNameTemplate: w.fileNameTemplate, downloadURLTemplate: w.downloadURLTemplate,
                             defaultModelID: w.defaultModelID, models: whisperModels),
            vad: VAD(fileName: raw.vad.fileName, url: vadURL),
            llm: LLM(treeURLTemplate: l.treeURLTemplate, downloadURLTemplate: l.downloadURLTemplate,
                     defaultModelID: l.defaultModelID, defaultQuantizations: l.defaultQuantizations, models: llmModels),
            translationKeys: names.flatMap { [$0.0, $0.2].compactMap { $0 } },
            untranslatedNames: names.compactMap { $0.1 })
    }
}
