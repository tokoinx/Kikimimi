import Foundation
import UniformTypeIdentifiers

/// 読み込める (文字起こしできる) ファイルかどうかの決め方。
/// 「開く」の画面が許す形式は、どれも音声 (.audio) か動画 (.movie) に合う型なので、ここでも同じ決め方にする
public enum MediaImport {
    /// 音声か動画に合う型なら true
    public static func isImportable(_ type: UTType) -> Bool {
        type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    /// 拡張子から型を決めて見る (大文字・小文字は問わない。空・知らない拡張子は false)
    public static func isImportable(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return isImportable(type)
    }

    /// 落とした物を、読み込む物と読み込まない物に分ける (どちらも落とした順のまま)。
    /// ファイルの URL でない物とフォルダは、読み込まない側に入れる。
    /// ファイルは、ファイルの持つ型で見る。型が取れなければ、拡張子で見る
    public static func split(_ urls: [URL]) -> (accepted: [URL], rejected: [URL]) {
        var accepted: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            if isImportableFile(url) {
                accepted.append(url)
            } else {
                rejected.append(url)
            }
        }
        return (accepted, rejected)
    }

    private static func isImportableFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return false
        }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return isImportable(type)
        }
        return isImportable(fileExtension: url.pathExtension)
    }
}
