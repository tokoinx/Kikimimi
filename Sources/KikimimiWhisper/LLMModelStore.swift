import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
import KikimimiCore

/// 監査・翻訳用の LLM (GGUF) の置き場所と出し入れ。
///
/// 既定は `~/Library/Application Support/Kikimimi/Models/LLM`。一覧にあるモデルは `qwen3.5-4b.gguf` のような名前で、
/// 利用者が取り込んだ GGUF はそのままの名前で置く。
public struct LLMModelStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// whisper のモデル置き場の中の `LLM` フォルダ
    public init(models: ModelStore) {
        self.directory = models.directory.appendingPathComponent("LLM", isDirectory: true)
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for spec: LLMModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName)
    }

    public func url(forFile name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func isInstalled(_ spec: LLMModelSpec) -> Bool {
        GGUFFile.isGGUF(at: url(for: spec), minimumBytes: 50_000_000)
    }

    /// 一覧にない、取り込んだ GGUF のファイル名
    public func customFiles() -> [String] {
        let known = Set(LLMCatalog.all.map(\.fileName))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter {
            $0.lowercased().hasSuffix(".gguf") && !$0.hasPrefix(".") && !known.contains($0)
                && GGUFFile.isGGUF(at: url(forFile: $0))
        }.sorted()
    }

    public func delete(fileNamed name: String) throws {
        let u = url(forFile: name)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    public enum ImportError: LocalizedError {
        case notGGUF
        case multimodalProjector

        public var errorDescription: String? {
            switch self {
            case .notGGUF:
                return "GGUF 形式の LLM ではありません。llama.cpp で動く .gguf ファイルを選んでください。"
            case .multimodalProjector:
                return "これは画像を読むための補助ファイル (mmproj) です。本体の .gguf を選んでください。"
            }
        }
    }

    /// 手元の GGUF を取り込む。名前が一覧のモデルと同じなら、そのモデルとして扱う。戻り値は置いたファイル名
    @discardableResult
    public func importFile(from source: URL) throws -> String {
        guard GGUFFile.isGGUF(at: source) else { throw ImportError.notGGUF }
        let name = source.lastPathComponent
        guard !name.lowercased().contains("mmproj") else { throw ImportError.multimodalProjector }
        try ensureDirectory()
        let dest = url(forFile: name)
        let fm = FileManager.default
        if source.resolvingSymlinksInPath().standardizedFileURL.path
            == dest.resolvingSymlinksInPath().standardizedFileURL.path {
            return name
        }
        let tmp = directory.appendingPathComponent(".import-\(UUID().uuidString).part")
        do {
            try fm.copyItem(at: source, to: tmp)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            // 写している途中で失敗しても (空き容量不足など)、数 GB の書きかけを残さない
            try? fm.removeItem(at: tmp)
            throw error
        }
        return name
    }
}

/// Hugging Face から、取る GGUF の場所と大きさ・SHA-256 を調べる。
public enum HuggingFaceResolver {
    public struct Resolved: Sendable, Equatable {
        public let url: URL
        public let expectedSize: Int64?
        public let sha256: String?
    }

    public enum ResolveError: LocalizedError {
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "\(name) のファイルが配布元で見つかりませんでした。設定の「監査・翻訳」タブの「手元の GGUF を追加…」から取り込むこともできます。"
            }
        }
    }

    /// リポジトリのファイル一覧から選ぶ。一覧が取れなければ (繋がらない・混み合っている・一覧の API だけ止められている など)、
    /// 決めておいた名前で取りにいく (大きさ・SHA-256 は確かめない)
    public static func resolve(_ spec: LLMModelSpec, session: URLSession = .shared) async throws -> Resolved {
        var listed = false
        for repository in spec.repositories {
            try Task.checkCancellation()
            guard let treeURL = LLMModelSpec.treeURL(repository: repository) else { continue }
            var request = URLRequest(url: treeURL)
            request.setValue("Kikimimi/1.1", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let fetched: (Data, URLResponse)
            do {
                fetched = try await session.data(for: request)
            } catch {
                // 中止は「繋がらない」と区別して、そのまま止める (決めておいた名前での取得に進まない)
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                continue
            }
            guard let http = fetched.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let entries = try? JSONDecoder().decode([HFFileEntry].self, from: fetched.0) else { continue }
            listed = true
            guard let file = spec.pickFile(from: entries),
                  let url = LLMModelSpec.downloadURL(repository: repository, path: file.path) else { continue }
            return Resolved(url: url, expectedSize: file.fileSize, sha256: file.sha256)
        }
        if !listed, let first = spec.repositories.first,
           let url = LLMModelSpec.downloadURL(repository: first, path: spec.fallbackFileName) {
            return Resolved(url: url, expectedSize: nil, sha256: nil)
        }
        throw ResolveError.notFound(spec.displayName)
    }
}

/// ファイルの SHA-256 (16 進の小文字)。数 GB でもメモリを食わないよう、少しずつ読む
public enum FileHash {
    public static func sha256(of url: URL) -> String? {
        #if canImport(CryptoKit)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// 期待どおりのファイルか (GGUF であること、分かっていれば大きさと SHA-256 も)
    public static func validateDownload(at url: URL, expectedSize: Int64?, sha256: String?) -> Bool {
        guard GGUFFile.isGGUF(at: url, minimumBytes: 50_000_000) else { return false }
        if let expectedSize {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == expectedSize else { return false }
        }
        if let sha256, let actual = FileHash.sha256(of: url) {
            return actual == sha256.lowercased()
        }
        return true
    }
}
