import XCTest
@testable import KikimimiCore

/// 区間が届いた時刻のまとまりを数える関数 (ArrivalBursts) の試験
final class ArrivalBurstsTests: XCTestCase {
    func testEmpty() {
        XCTAssertEqual(ArrivalBursts.mostWithin(0.25, times: []), 0)
        XCTAssertEqual(ArrivalBursts.longestGap(times: []), 0)
        XCTAssertEqual(ArrivalBursts.longestGap(times: [3]), 0)
    }

    func testSlidingWindow() {
        // 0.0〜0.2 に 3 つ、1.0 に 1 つ、2.0〜2.4 に 5 つ (並びは崩してある)
        let times = [2.4, 0.0, 2.0, 0.1, 1.0, 2.1, 0.2, 2.2, 2.3]
        XCTAssertEqual(ArrivalBursts.mostWithin(0.25, times: times), 3)
        XCTAssertEqual(ArrivalBursts.mostWithin(0.5, times: times), 5)
        XCTAssertEqual(ArrivalBursts.mostWithin(1.0, times: times), 5)
        XCTAssertEqual(ArrivalBursts.mostWithin(3.0, times: times), 9)
        XCTAssertEqual(ArrivalBursts.longestGap(times: times), 1.0, accuracy: 1e-9)
    }

    func testWindowIsHalfOpen() {
        // ちょうど窓の幅だけ離れた 2 つは、同じ窓に入らない
        XCTAssertEqual(ArrivalBursts.mostWithin(0.5, times: [0, 0.5, 1.0]), 1)
        // 同じ時刻はすべて 1 つの窓に入る
        XCTAssertEqual(ArrivalBursts.mostWithin(0.25, times: [1, 1, 1, 1]), 4)
    }
}
