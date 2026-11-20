import Foundation

/// whisper.cpp 形式 (ggml) の Whisper モデル。
public struct WhisperModelSpec: Hashable, Identifiable, Sendable {
    /// `large-v3-turbo-q5_0` のような whisper.cpp のモデル名
    public let id: String
    /// 名前と説明の鍵 (英語)。読む時に、今の画面の言語で引く (言語を切り替えたら変わるように)
    let displayNameKey: String
    let summaryKey: String
    public let approxMB: Int
    public let recommended: Bool

    /// displayName と summary は鍵 (英語。表に無い名前は、そのまま出る)。アプリの一覧は models.json から作る
    public init(id: String, displayName: String, summary: String, approxMB: Int, recommended: Bool = false) {
        self.id = id
        self.displayNameKey = displayName
        self.summaryKey = summary
        self.approxMB = approxMB
        self.recommended = recommended
    }

    /// 画面に出す名前 (今の画面の言語)
    public var displayName: String { L10n.lookup(displayNameKey) }
    /// 画面に出す説明 (今の画面の言語)
    public var summary: String { L10n.lookup(summaryKey) }

    /// 保存するファイルの名前 (作り方は models.json の whisper.fileNameTemplate)
    /// (埋め込んだ一覧のテンプレートは、読む時に、印が合っている事を確かめてあるので、置き換えは必ずできる)
    public var fileName: String {
        ModelCatalogData.fill(ModelCatalogData.embedded.whisper.fileNameTemplate, [("id", id)])!
    }

    /// whisper.cpp 公式の配布元 (Hugging Face。作り方は models.json の whisper.downloadURLTemplate)
    public var downloadURL: URL {
        URL(string: ModelCatalogData.fill(ModelCatalogData.embedded.whisper.downloadURLTemplate, [("fileName", fileName)])!)!
    }
}

/// Whisper のモデルの一覧。中身は models.json (`ModelCatalogData.embedded`) から来る
public enum ModelCatalog {
    public static let defaultModelID = ModelCatalogData.embedded.whisper.defaultModelID

    public static let all: [WhisperModelSpec] = ModelCatalogData.embedded.whisper.models

    public static func spec(id: String) -> WhisperModelSpec? {
        all.first { $0.id == id }
    }

    /// 無音を飛ばすための VAD (Silero) モデル。約 0.9 MB。
    public static let vadFileName = ModelCatalogData.embedded.vad.fileName
    public static let vadURL = ModelCatalogData.embedded.vad.url
}

/// ダウンロードしたファイルが ggml 形式のモデルかを先頭バイトで確かめる。
public enum ModelFile {
    /// `ggml` のマジックナンバー (0x67676d6c をリトルエンディアンで格納したもの)
    static let ggmlMagic: [UInt8] = [0x6c, 0x6d, 0x67, 0x67]
    /// gguf 形式 (将来のモデル) のマジック
    static let ggufMagic: [UInt8] = Array("GGUF".utf8)

    public static func isValidModel(at url: URL, minimumBytes: Int64 = 100_000) -> Bool {
        // attributesOfItem はシンボリックリンク自身の情報を返すので、先にリンク先へたどる
        let url = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size >= minimumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        return bytes == ggmlMagic || bytes == ggufMagic
    }
}
