import Foundation

/// 監査・翻訳に使うローカル LLM (GGUF 形式)。
public struct LLMModelSpec: Hashable, Identifiable, Sendable {
    /// 保存名にも使う ID (`qwen3.5-4b` など)
    public let id: String
    /// 名前と説明の鍵 (英語)。読む時に、今の画面の言語で引く (言語を切り替えたら変わるように)
    let displayNameKey: String
    let summaryKey: String
    public let approxMB: Int
    /// 快適に動かすのに必要なメモリ (GB)
    public let recommendedMemoryGB: Int
    /// 配布元 (Hugging Face のリポジトリ)。上から順に試す
    public let repositories: [String]
    /// 一覧を取れないときに使う、最初のリポジトリの中のファイル名
    public let fallbackFileName: String
    /// 選ぶ量子化の優先順
    public let quantizations: [String]
    public let license: String
    public let recommended: Bool

    public init(id: String, displayName: String, summary: String, approxMB: Int, recommendedMemoryGB: Int,
                repositories: [String], fallbackFileName: String,
                quantizations: [String] = LLMCatalog.defaultQuantizations,
                license: String, recommended: Bool = false) {
        self.id = id
        self.displayNameKey = displayName
        self.summaryKey = summary
        self.approxMB = approxMB
        self.recommendedMemoryGB = recommendedMemoryGB
        self.repositories = repositories
        self.fallbackFileName = fallbackFileName
        self.quantizations = quantizations
        self.license = license
        self.recommended = recommended
    }

    /// 画面に出す名前 (今の画面の言語。init の displayName は鍵。表に無い名前は、そのまま出る)
    public var displayName: String { L10n.lookup(displayNameKey) }
    /// 画面に出す説明 (今の画面の言語)
    public var summary: String { L10n.lookup(summaryKey) }

    /// Mac に保存するときの名前
    public var fileName: String { "\(id).gguf" }

    /// ファイル一覧 (Hugging Face の tree API。作り方は models.json の llm.treeURLTemplate)
    public static func treeURL(repository: String) -> URL? {
        ModelCatalogData.fill(ModelCatalogData.embedded.llm.treeURLTemplate, [("repository", repository)])
            .flatMap { URL(string: $0) }
    }

    /// ファイルの取得元 (作り方は models.json の llm.downloadURLTemplate。path は、/ で区切った所ごとに % で書き換える)
    public static func downloadURL(repository: String, path: String) -> URL? {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return ModelCatalogData.fill(ModelCatalogData.embedded.llm.downloadURLTemplate,
                                     [("repository", repository), ("path", encoded)])
            .flatMap { URL(string: $0) }
    }

    /// リポジトリのファイル一覧から、取る GGUF を選ぶ (量子化の優先順。画像用の mmproj と分割ファイルは除く)
    public func pickFile(from entries: [HFFileEntry]) -> HFFileEntry? {
        let ggufs = entries.filter {
            let name = $0.path.lowercased()
            return $0.type == "file" && name.hasSuffix(".gguf") && !name.contains("mmproj")
        }
        for quant in quantizations {
            let q = quant.lowercased()
            let matches = ggufs.filter {
                let base = ($0.path.lowercased() as NSString).lastPathComponent
                return base.hasSuffix("-\(q).gguf") || base.hasSuffix(".\(q).gguf") || base.hasSuffix("_\(q).gguf")
            }
            // フォルダの外にあるもの、名前の短いものを優先する
            if let best = matches.min(by: {
                ($0.path.contains("/") ? 1 : 0, $0.path.count) < ($1.path.contains("/") ? 1 : 0, $1.path.count)
            }) {
                return best
            }
        }
        return nil
    }
}

/// Hugging Face の tree API (`/api/models/{repo}/tree/main`) の 1 件
public struct HFFileEntry: Decodable, Hashable, Sendable {
    public struct LFS: Decodable, Hashable, Sendable {
        /// ファイルの SHA-256
        public let oid: String?
        public let size: Int64?
    }

    public let type: String
    public let path: String
    public let size: Int64?
    public let lfs: LFS?

    public init(type: String, path: String, size: Int64?, lfs: LFS?) {
        self.type = type
        self.path = path
        self.size = size
        self.lfs = lfs
    }

    /// ファイルの大きさ (LFS の値を優先)
    public var fileSize: Int64? { lfs?.size ?? size }

    /// SHA-256 (16 進 64 文字のときだけ)
    public var sha256: String? {
        guard let oid = lfs?.oid?.lowercased(), oid.count == 64,
              oid.allSatisfy({ $0.isHexDigit }) else { return nil }
        return oid
    }
}

/// LLM の一覧。中身は models.json (`ModelCatalogData.embedded`) から来る
public enum LLMCatalog {
    public static let defaultModelID = ModelCatalogData.embedded.llm.defaultModelID

    /// 量子化の既定の優先順 (models.json の llm.defaultQuantizations。モデルに書いていない時に使う)
    public static let defaultQuantizations: [String] = ModelCatalogData.embedded.llm.defaultQuantizations

    public static let all: [LLMModelSpec] = ModelCatalogData.embedded.llm.models

    public static func spec(id: String) -> LLMModelSpec? {
        all.first { $0.id == id }
    }
}

/// GGUF ファイルかを先頭バイトで確かめる (whisper の ggml 形式とは区別する)
public enum GGUFFile {
    public static func isGGUF(at url: URL, minimumBytes: Int64 = 1_000_000) -> Bool {
        let url = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size >= minimumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return [UInt8](head) == ModelFile.ggufMagic
    }

    /// GGUF の先頭にある項目のうち、文字列のもの (general.type・general.architecture・general.name など) を読む。
    /// ファイルの先頭 limit バイトだけを見る (語彙の一覧のような大きな配列に行き当たったら、そこでやめる)
    public static func stringMetadata(at url: URL, limit: Int = 262_144) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url.resolvingSymlinksInPath()) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return [:] }
        return stringMetadata(in: [UInt8](data))
    }

    static func stringMetadata(in bytes: [UInt8]) -> [String: String] {
        var offset = 0
        func integer(_ size: Int) -> UInt64? {
            guard offset + size <= bytes.count else { return nil }
            var value: UInt64 = 0
            for k in 0..<size { value |= UInt64(bytes[offset + k]) << UInt64(8 * k) }
            offset += size
            return value
        }
        func string() -> String? {
            guard let length = integer(8), length <= 1_000_000, offset + Int(length) <= bytes.count else { return nil }
            defer { offset += Int(length) }
            return String(decoding: bytes[offset..<(offset + Int(length))], as: UTF8.self)
        }
        // 値の型ごとの大きさ (GGUF v2 / v3): 0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 i32, 6 f32, 7 bool, 8 string, 9 array, 10 u64, 11 i64, 12 f64
        let sizes: [UInt64: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        guard bytes.count >= 24, Array(bytes[0..<4]) == ModelFile.ggufMagic else { return [:] }
        offset = 4
        guard let version = integer(4), version >= 2, integer(8) != nil, let count = integer(8) else { return [:] }
        var out: [String: String] = [:]
        for _ in 0..<min(count, 4096) {
            guard let key = string(), let type = integer(4) else { break }
            if type == 8 {
                guard let value = string() else { break }
                out[key] = value
            } else if let size = sizes[type] {
                guard offset + size <= bytes.count else { break }
                offset += size
            } else if type == 9 {
                // 配列: 数値の配列は読み飛ばす。文字列の配列 (語彙など) は大きいので、そこでやめる
                guard let element = integer(4), let length = integer(8), let size = sizes[element],
                      length <= UInt64(bytes.count), offset + Int(length) * size <= bytes.count else { break }
                offset += Int(length) * size
            } else {
                break
            }
        }
        return out
    }
}
