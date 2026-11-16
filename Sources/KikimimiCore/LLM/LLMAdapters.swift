import Foundation

/// 追加学習の差分 (LoRA) の種類。監査用と翻訳用を分けて持つ。
///
/// 分ける理由: 監査 (聞き間違いの直し) を学習した差分を翻訳にも使うと、訳が崩れる事が在った
/// (固有名詞「Roblox Studio」が「ロブス・スタジオ」になった。README の「既知の制限」)。
/// そこで、翻訳には、翻訳を学習した差分だけを使う
public enum AdapterKind: String, CaseIterable, Sendable {
    /// 監査役 (と評価役) に渡す差分。置き場は `<key>.lora.gguf` (前からの名前のまま)
    case audit
    /// 翻訳 (全体・行・訳し直し) に渡す差分。置き場は `<key>.translation.lora.gguf`
    case translation

    /// ファイルの名前の終わり。`tools/finetune/finetune.py --install` が置く名前と同じ
    public var fileSuffix: String {
        switch self {
        case .audit: return ".lora.gguf"
        case .translation: return ".translation.lora.gguf"
        }
    }
}

/// 差分のファイルの置き場 (`LLM/Adapters`) での、置く・外す・在るかの確かめ。
/// 中身の検査 (差分の GGUF か・モデルの種類と大きさが合うか) は、呼ぶ側 (`LLMModelStore.importAdapter`) が先に行う
public struct AdapterFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 差分のファイル。key は、一覧のモデルの ID (`qwen3.5-2b`) か、取り込んだ GGUF の名前 (拡張子なし)
    public func url(forModelKey key: String, kind: AdapterKind) -> URL {
        let safe = key.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return directory.appendingPathComponent(String(safe) + kind.fileSuffix)
    }

    /// 差分が入っているか (GGUF の印が在り、小さすぎない)
    public func has(forModelKey key: String, kind: AdapterKind) -> Bool {
        GGUFFile.isGGUF(at: url(forModelKey: key, kind: kind), minimumBytes: 1_000)
    }

    /// source を、その種類の置き場に写す (前の差分は入れ替える)。写す途中で失敗しても、前の差分は残る
    public func install(from source: URL, forModelKey key: String, kind: AdapterKind) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = url(forModelKey: key, kind: kind)
        if source.resolvingSymlinksInPath().standardizedFileURL.path == dest.resolvingSymlinksInPath().standardizedFileURL.path {
            return
        }
        let tmp = directory.appendingPathComponent(".import-\(UUID().uuidString).part")
        do {
            try fm.copyItem(at: source, to: tmp)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// その種類の差分だけを外す (ほかの種類の差分は残す)
    public func remove(forModelKey key: String, kind: AdapterKind) throws {
        let url = url(forModelKey: key, kind: kind)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 仕事 (kind) に渡す差分の場所。使う設定 (enabled) が入で、その種類の差分が入っている時だけ。
    /// ほかの種類の差分で代わりにしない (翻訳用が無い時に、監査用を翻訳に渡さない)
    public static func activePath(for kind: AdapterKind, enabled: Bool, installed: Set<AdapterKind>,
                                  url: (AdapterKind) -> URL) -> String? {
        enabled && installed.contains(kind) ? url(kind).path : nil
    }
}
