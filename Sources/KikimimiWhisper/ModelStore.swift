import Foundation
import KikimimiCore

/// モデルファイルの置き場所と出し入れ。
///
/// 既定は `~/Library/Application Support/Kikimimi/Models`。
/// 環境変数 `KIKIMIMI_MODELS_DIR` で変更できる (テスト用)。
public struct ModelStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment["KIKIMIMI_MODELS_DIR"], !env.isEmpty {
            self.directory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("Kikimimi/Models", isDirectory: true)
        }
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for model: WhisperModelSpec) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    public var vadURL: URL {
        directory.appendingPathComponent(ModelCatalog.vadFileName)
    }

    public func isInstalled(_ model: WhisperModelSpec) -> Bool {
        ModelFile.isValidModel(at: url(for: model), minimumBytes: 10_000_000)
    }

    public var isVADInstalled: Bool {
        ModelFile.isValidModel(at: vadURL, minimumBytes: 100_000)
    }

    /// ディスク上のサイズ (未取得なら nil)
    public func installedSize(_ model: WhisperModelSpec) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: model).path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    public func delete(_ model: WhisperModelSpec) throws {
        let u = url(for: model)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    public enum ImportError: LocalizedError {
        case notAModel
        case unknownName(String)

        public var errorDescription: String? {
            switch self {
            case .notAModel: return "whisper.cpp 形式 (ggml) のモデルファイルではありません。"
            case .unknownName(let name):
                return "「\(name)」は一覧にない名前です。ggml-large-v3-turbo-q5_0.bin のような公式の名前のモデルか、無音検出用の \(ModelCatalog.vadFileName) を選んでください。"
            }
        }
    }

    /// 取り込んだファイルの種類
    public enum ImportedFile: Equatable, Sendable {
        case model(WhisperModelSpec)
        case vad
    }

    /// 手元の .bin を取り込む (Hugging Face に繋がらない環境向け)。音声認識モデルと VAD モデルのどちらも受け付ける。
    @discardableResult
    public func importFile(from source: URL) throws -> ImportedFile {
        guard ModelFile.isValidModel(at: source) else { throw ImportError.notAModel }
        let name = source.lastPathComponent
        let dest: URL
        let result: ImportedFile
        if name == ModelCatalog.vadFileName {
            dest = vadURL
            result = .vad
        } else if let spec = ModelCatalog.all.first(where: { $0.fileName == name }) {
            dest = url(for: spec)
            result = .model(spec)
        } else {
            throw ImportError.unknownName(name)
        }
        try ensureDirectory()
        let fm = FileManager.default
        // 選んだファイルがすでに置き場所にある: 何もしない (先に消すと、選んだファイルごと消えてしまう)
        if source.resolvingSymlinksInPath().standardizedFileURL.path
            == dest.resolvingSymlinksInPath().standardizedFileURL.path {
            return result
        }
        // 同じフォルダの一時ファイルへ写してから差し替える (途中で失敗しても元のファイルは残る。
        // 大文字小文字だけ違う同一ファイルのように、上の判定をすり抜けた場合も安全)
        let tmp = directory.appendingPathComponent(".import-\(UUID().uuidString).part")
        try fm.copyItem(at: source, to: tmp)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return result
    }
}
