import AppKit
import Foundation
import KikimimiLLM
import KikimimiWhisper

/// 起動の記録 (`~/Library/Logs/Kikimimi/launch.log`)。「起動しない」ときに、どこまで進んだかを後から見られるようにする
/// (`make doctor` が末尾を表示する)。
enum LaunchLog {
    static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Kikimimi/launch.log")
    }

    /// 版・ビルド番号・組み立てたときのコミット
    static var versionLine: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let commit = bundle.object(forInfoDictionaryKey: "KikimimiCommit") as? String ?? "unknown commit"
        return "Kikimimi \(version) (\(build), \(commit))"
    }

    static var environmentLine: String {
        let info = ProcessInfo.processInfo
        return "macOS \(info.operatingSystemVersionString), memory \(info.physicalMemory / 1_073_741_824) GB,"
            + " bundle \(Bundle.main.bundlePath)"
    }

    static var whisperInfo: String { WhisperContext.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines) }
    static var llamaInfo: String { LlamaEngine.systemInfo.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 同じアプリの、ほかに動いているもの (プロセス番号)。`open` は、動いているものがあると新しく起動しない
    static func otherInstances() -> [Int32] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .map(\.processIdentifier).filter { $0 != me }
    }

    /// 1 行を書き足す (失敗しても何もしない。大きくなりすぎたら作り直す)
    static func note(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? manager.removeItem(at: url)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
