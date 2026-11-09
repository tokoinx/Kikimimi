import Foundation

/// 監査・翻訳に使うローカル LLM (GGUF 形式)。
public struct LLMModelSpec: Hashable, Identifiable, Sendable {
    /// 保存名にも使う ID (`qwen3.5-4b` など)
    public let id: String
    public let displayName: String
    public let summary: String
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
                quantizations: [String] = ["Q4_K_M", "Q4_K_S", "IQ4_XS", "UD-Q4_K_XL", "Q5_K_M", "Q8_0"],
                license: String, recommended: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.approxMB = approxMB
        self.recommendedMemoryGB = recommendedMemoryGB
        self.repositories = repositories
        self.fallbackFileName = fallbackFileName
        self.quantizations = quantizations
        self.license = license
        self.recommended = recommended
    }

    /// Mac に保存するときの名前
    public var fileName: String { "\(id).gguf" }

    /// ファイル一覧 (Hugging Face の tree API)
    public static func treeURL(repository: String) -> URL? {
        URL(string: "https://huggingface.co/api/models/\(repository)/tree/main")
    }

    /// ファイルの取得元
    public static func downloadURL(repository: String, path: String) -> URL? {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repository)/resolve/main/\(encoded)")
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

public enum LLMCatalog {
    public static let defaultModelID = "qwen3.5-4b"

    public static let all: [LLMModelSpec] = [
        LLMModelSpec(
            id: "qwen3.5-4b", displayName: "Qwen3.5 4B",
            summary: "監査と翻訳のバランスが良い。迷ったらこれ。メモリ 8 GB の Mac でも動く。",
            approxMB: 2780, recommendedMemoryGB: 8,
            repositories: ["bartowski/Qwen_Qwen3.5-4B-GGUF", "unsloth/Qwen3.5-4B-GGUF"],
            fallbackFileName: "Qwen_Qwen3.5-4B-Q4_K_M.gguf",
            license: "Apache-2.0", recommended: true),
        LLMModelSpec(
            id: "qwen3.5-2b", displayName: "Qwen3.5 2B (軽量)",
            summary: "速くて軽い。精度は 4B より控えめ。",
            approxMB: 1310, recommendedMemoryGB: 8,
            repositories: ["unsloth/Qwen3.5-2B-GGUF", "bartowski/Qwen_Qwen3.5-2B-GGUF"],
            fallbackFileName: "Qwen3.5-2B-Q4_K_M.gguf",
            license: "Apache-2.0"),
        LLMModelSpec(
            id: "qwen3.5-9b", displayName: "Qwen3.5 9B (高精度)",
            summary: "いちばん賢いが遅い。メモリ 16 GB 以上の Mac 向け。",
            approxMB: 6170, recommendedMemoryGB: 16,
            repositories: ["bartowski/Qwen_Qwen3.5-9B-GGUF", "unsloth/Qwen3.5-9B-GGUF"],
            fallbackFileName: "Qwen_Qwen3.5-9B-Q4_K_M.gguf",
            license: "Apache-2.0"),
    ]

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
}
