import Foundation
import KikimimiCore

/// ライブラリ (保存した結果) の読み書きを、裏の 1 本の列 (シリアルキュー) で、頼まれた順に行う。
/// メインスレッドは、結果の写し (SavedDocument は値) を作って渡すだけにする
/// (数千行の文字起こしを JSON にするのは、メインスレッドでは行わない)
final class LibraryWriter: Sendable {
    let store: LibraryStore
    private let queue = DispatchQueue(label: "local.kikimimi.library", qos: .utility)

    init(store: LibraryStore) {
        self.store = store
    }

    /// 列の最後に積む (すぐに戻る)
    func async(_ work: @escaping @Sendable (LibraryStore) -> Void) {
        let store = store
        queue.async { work(store) }
    }

    /// 列の最後に積み、終わるまで待つ (メインスレッドは止めない)
    func run<T: Sendable>(_ work: @escaping @Sendable (LibraryStore) throws -> T) async -> Result<T, Error> {
        let store = store
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
            queue.async {
                continuation.resume(returning: Result { try work(store) })
            }
        }
    }

    /// それまでに積んだものが、すべて書き終わるまで待つ (終了の前・確認用)
    func flush() {
        queue.sync {}
    }

    /// ゴミ箱に入れる。入れられなければ消す
    static func trash(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        #if os(macOS)
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        #endif
        try FileManager.default.removeItem(at: url)
    }
}
