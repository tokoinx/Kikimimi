import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KikimimiCore

public enum DownloadError: LocalizedError {
    case http(Int)
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "ダウンロードに失敗しました (HTTP \(code))。"
        case .invalidFile: return "ダウンロードしたファイルがモデルではありませんでした。ネットワークの設定 (フィルタやプロキシ) を確認してください。"
        }
    }
}

/// 大きなファイルを進捗つきでダウンロードする。
///
/// 一時ファイルに落としてから検証し、問題なければ目的の場所へ移す。途中で止まっても壊れたモデルは残らない。
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ fraction: Double, _ received: Int64, _ total: Int64) -> Void
    public typealias Validator = @Sendable (URL) -> Bool

    private let destination: URL
    private let onProgress: Progress
    private let validate: Validator
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var finishError: Error?
    private let lock = NSLock()

    private init(destination: URL, validate: @escaping Validator, onProgress: @escaping Progress) {
        self.destination = destination
        self.validate = validate
        self.onProgress = onProgress
    }

    /// `url` を `destination` にダウンロードする。キャンセルされたら途中で止める。
    public static func download(from url: URL,
                                to destination: URL,
                                validate: @escaping Validator = { ModelFile.isValidModel(at: $0) },
                                onProgress: @escaping Progress = { _, _, _ in }) async throws {
        let downloader = ModelDownloader(destination: destination, validate: validate, onProgress: onProgress)
        try await downloader.run(url)
    }

    private func run(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 6 * 60 * 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                lock.lock()
                self.continuation = cont
                self.session = session
                lock.unlock()
                var request = URLRequest(url: url)
                request.setValue("Kikimimi/1.0", forHTTPHeaderField: "User-Agent")
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            self.lock.lock()
            let session = self.session
            self.lock.unlock()
            session?.invalidateAndCancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress(min(1, fraction), totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // この関数を抜けると location は消されるので、ここで検証して移動まで済ませる
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finishError = DownloadError.http(http.statusCode)
            return
        }
        guard validate(location) else {
            finishError = DownloadError.invalidFile
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            finishError = error
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        lock.lock()
        let cont = continuation
        continuation = nil
        self.session = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else if let finishError {
            cont?.resume(throwing: finishError)
        } else {
            cont?.resume()
        }
    }
}
