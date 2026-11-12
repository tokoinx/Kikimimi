import Foundation
import XCTest
@testable import KikimimiCore

/// 文字起こしの途中の区間をまとめて渡す入れ物 (LiveSegmentBuffer) の試験
final class LiveSegmentBufferTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TranscriptSegment] = []
        func add(_ more: [TranscriptSegment]) {
            lock.lock()
            items += more
            lock.unlock()
        }
        var all: [TranscriptSegment] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private func seg(_ i: Int) -> TranscriptSegment {
        Self.seg(i)
    }

    private static func seg(_ i: Int) -> TranscriptSegment {
        TranscriptSegment(start: Double(i), end: Double(i) + 0.5, text: "s\(i)")
    }

    func testWakesOnceUntilTakenAndKeepsOrder() {
        let wakes = Counter()
        let buffer = LiveSegmentBuffer { _ in wakes.add() }
        let segments = (0..<5).map(seg)
        for s in segments { buffer.append(s) }
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(buffer.take(), LiveSegmentBuffer.Batch(segments: segments))
        XCTAssertNil(buffer.take())
        buffer.append(seg(5))
        XCTAssertEqual(wakes.count, 2)
        XCTAssertEqual(buffer.take()?.segments.map(\.text), ["s5"])
    }

    func testRestartDropsPendingAndResetsShownRows() {
        let buffer = LiveSegmentBuffer { _ in }
        var shown = [seg(0), seg(1)]
        buffer.append(seg(2))
        buffer.restart()
        buffer.append(seg(10))
        let batch = buffer.take()
        XCTAssertEqual(batch?.reset, true)
        batch?.apply(to: &shown)
        XCTAssertEqual(shown.map(\.text), ["s10"])
        // やり直しのあとに何も届かなくても、ここまでの区間は消える
        buffer.restart()
        buffer.take()?.apply(to: &shown)
        XCTAssertTrue(shown.isEmpty)
    }

    func testCloseReturnsRestAndRefusesLateSegments() {
        let wakes = Counter()
        let buffer = LiveSegmentBuffer { _ in wakes.add() }
        buffer.append(seg(0))
        buffer.append(seg(1))
        XCTAssertEqual(buffer.close()?.segments.map(\.text), ["s0", "s1"])
        buffer.append(seg(2))
        buffer.restart()
        XCTAssertEqual(wakes.count, 1)
        XCTAssertNil(buffer.take())
        XCTAssertNil(buffer.close())
    }

    func testAppendsFromManyThreadsAreAllDelivered() {
        let buffer = LiveSegmentBuffer { _ in }
        let collector = Collector()
        let finished = Counter()
        // 8 つのスレッドが届け、1 つのスレッド (アプリではメインスレッド) が受け取る
        DispatchQueue.concurrentPerform(iterations: 9) { worker in
            if worker == 8 {
                while finished.count < 8 {
                    if let batch = buffer.take() { collector.add(batch.segments) }
                }
                return
            }
            for i in 0..<250 {
                buffer.append(Self.seg(worker * 1000 + i))
            }
            finished.add()
        }
        if let rest = buffer.close() { collector.add(rest.segments) }
        let received = collector.all
        XCTAssertEqual(received.count, 2000)
        XCTAssertEqual(Set(received.map(\.text)).count, 2000)
        // 1 つのスレッドから届いた区間は、届いた順のまま
        for worker in 0..<8 {
            let mine = received.filter { Int($0.start) / 1000 == worker }.map(\.start)
            XCTAssertEqual(mine, mine.sorted())
        }
    }
}
