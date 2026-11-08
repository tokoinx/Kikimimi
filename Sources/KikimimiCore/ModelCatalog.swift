import Foundation

/// whisper.cpp 形式 (ggml) の Whisper モデル。
public struct WhisperModelSpec: Hashable, Identifiable, Sendable {
    /// `large-v3-turbo-q5_0` のような whisper.cpp のモデル名
    public let id: String
    public let displayName: String
    public let summary: String
    public let approxMB: Int
    public let recommended: Bool

    public init(id: String, displayName: String, summary: String, approxMB: Int, recommended: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.approxMB = approxMB
        self.recommended = recommended
    }

    public var fileName: String { "ggml-\(id).bin" }

    /// whisper.cpp 公式の配布元 (Hugging Face)
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

public enum ModelCatalog {
    public static let defaultModelID = "large-v3-turbo-q5_0"

    public static let all: [WhisperModelSpec] = [
        WhisperModelSpec(id: "large-v3-turbo-q5_0", displayName: "Large v3 Turbo (軽量版)",
                         summary: "日本語の精度と速度のバランスが最も良い。迷ったらこれ。", approxMB: 574, recommended: true),
        WhisperModelSpec(id: "large-v3-turbo", displayName: "Large v3 Turbo",
                         summary: "軽量版より少しだけ高精度。メモリに余裕がある Mac 向け。", approxMB: 1620),
        WhisperModelSpec(id: "large-v3-q5_0", displayName: "Large v3 (軽量版)",
                         summary: "最高精度クラス。Turbo の数倍遅い。", approxMB: 1080),
        WhisperModelSpec(id: "medium-q5_0", displayName: "Medium (軽量版)",
                         summary: "中くらいの精度と速度。", approxMB: 539),
        WhisperModelSpec(id: "small-q5_1", displayName: "Small (軽量版)",
                         summary: "速いが日本語の精度は控えめ。", approxMB: 190),
        WhisperModelSpec(id: "base-q5_1", displayName: "Base (軽量版)",
                         summary: "とても速い。動作確認向け。", approxMB: 60),
        WhisperModelSpec(id: "tiny", displayName: "Tiny",
                         summary: "最小。精度は低い。", approxMB: 78),
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
