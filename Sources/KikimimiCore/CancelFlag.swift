import Foundation

/// スレッドをまたいで「中止してほしい」を伝えるフラグ。
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func set() {
        lock.lock(); value = true; lock.unlock()
    }
}
