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

    /// displayName と summary は鍵 (英語)。`LKey` で印を付けて渡す (訳の無い名前は、そのまま出る)
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

    public var fileName: String { "ggml-\(id).bin" }

    /// whisper.cpp 公式の配布元 (Hugging Face)
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

public enum ModelCatalog {
    public static let defaultModelID = "large-v3-turbo-q5_0"

    public static let all: [WhisperModelSpec] = [
        WhisperModelSpec(id: "large-v3-turbo-q5_0", displayName: LKey("Large v3 Turbo (light)"),
                         summary: LKey("Best balance of Japanese accuracy and speed. Pick this if unsure."), approxMB: 574, recommended: true),
        WhisperModelSpec(id: "large-v3-turbo", displayName: "Large v3 Turbo",
                         summary: LKey("Slightly more accurate than the light version. For Macs with plenty of memory."), approxMB: 1620),
        WhisperModelSpec(id: "large-v3-q5_0", displayName: LKey("Large v3 (light)"),
                         summary: LKey("Top accuracy. Several times slower than Turbo."), approxMB: 1080),
        WhisperModelSpec(id: "medium-q5_0", displayName: LKey("Medium (light)"),
                         summary: LKey("Medium accuracy and speed."), approxMB: 539),
        WhisperModelSpec(id: "small-q5_1", displayName: LKey("Small (light)"),
                         summary: LKey("Fast, but less accurate for Japanese."), approxMB: 190),
        WhisperModelSpec(id: "base-q5_1", displayName: LKey("Base (light)"),
                         summary: LKey("Very fast. For testing."), approxMB: 60),
        WhisperModelSpec(id: "tiny", displayName: "Tiny",
                         summary: LKey("Smallest. Low accuracy."), approxMB: 78),
    ]

    public static func spec(id: String) -> WhisperModelSpec? {
        all.first { $0.id == id }
    }

    /// 無音を飛ばすための VAD (Silero) モデル。約 0.9 MB。
    public static let vadFileName = "ggml-silero-v6.2.0.bin"
    public static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!
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
