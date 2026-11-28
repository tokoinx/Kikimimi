import XCTest
@testable import KikimimiCore

/// 一覧の終わりへ小刻みに追いつく決まり (TailCatchUp) の試験
final class TailCatchUpTests: XCTestCase {
    /// 増えた行の数の境目: 10 以下は 1 回で飛び、11 以上は小刻み
    func testAddedThreshold() {
        XCTAssertFalse(TailCatchUp.usesSteps(added: 10, distance: 10, enabledOnThisOS: true))
        XCTAssertTrue(TailCatchUp.usesSteps(added: 11, distance: 11, enabledOnThisOS: true))
        XCTAssertFalse(TailCatchUp.usesSteps(added: 1, distance: 1, enabledOnThisOS: true))
        XCTAssertTrue(TailCatchUp.usesSteps(added: 300, distance: 300, enabledOnThisOS: true))
    }

    /// 終わりまでの距離の境目: 600 までは小刻み、601 からは 1 回で飛ぶ
    func testDistanceThreshold() {
        XCTAssertTrue(TailCatchUp.usesSteps(added: 600, distance: 600, enabledOnThisOS: true))
        XCTAssertFalse(TailCatchUp.usesSteps(added: 601, distance: 601, enabledOnThisOS: true))
        XCTAssertFalse(TailCatchUp.isTooFar(reached: 100, lastIndex: 700))
        XCTAssertTrue(TailCatchUp.isTooFar(reached: 100, lastIndex: 701))
    }

    /// 使わない OS では、増えた数によらず使わない
    func testDisabledOnThisOS() {
        XCTAssertFalse(TailCatchUp.usesSteps(added: 300, distance: 300, enabledOnThisOS: false))
    }

    /// 8087 行に 300 行が増えた: 番号 8086 から、10 ずつ 30 回で、ちょうど終わりの番号 8386 に着く
    func testSequenceFor300RowsFrom8086() {
        let sequence = indices(from: 8086, lastIndex: 8386)
        XCTAssertEqual(sequence.count, 30)
        XCTAssertEqual(sequence.first, 8096)
        XCTAssertEqual(sequence.last, 8386)
        XCTAssertEqual(Set(zip(sequence, sequence.dropFirst()).map { $1 - $0 }), [10])
    }

    /// 10 の倍数でない数: 最後の 1 回は短く、終わりの番号を越えない
    func testSequenceForNonMultipleOfTen() {
        let sequence = indices(from: 0, lastIndex: 25)
        XCTAssertEqual(sequence, [10, 20, 25])
        XCTAssertNil(TailCatchUp.nextIndex(after: 25, lastIndex: 25))
        XCTAssertNil(TailCatchUp.nextIndex(after: 30, lastIndex: 25))
    }

    /// 動かしているあいだに終わりが延びた: 着いた所から、新しい終わりまで続ける
    func testEndExtendedWhileStepping() {
        var reached = 0
        var lastIndex = 30
        var sequence: [Int] = []
        while let next = TailCatchUp.nextIndex(after: reached, lastIndex: lastIndex) {
            sequence.append(next)
            reached = next
            // 2 回動かしたところで、15 行増えた
            if sequence.count == 2 { lastIndex += 15 }
        }
        XCTAssertEqual(sequence, [10, 20, 30, 40, 45])
    }

    /// 環境変数での切り替え: "1" は使う、"0" は使わない、ほかは OS のとおり
    func testSwitch() {
        XCTAssertTrue(TailCatchUp.isEnabled(osAtLeast15: true, override: nil))
        XCTAssertFalse(TailCatchUp.isEnabled(osAtLeast15: false, override: nil))
        XCTAssertTrue(TailCatchUp.isEnabled(osAtLeast15: false, override: "1"))
        XCTAssertFalse(TailCatchUp.isEnabled(osAtLeast15: true, override: "0"))
        XCTAssertTrue(TailCatchUp.isEnabled(osAtLeast15: true, override: "yes"))
        XCTAssertFalse(TailCatchUp.isEnabled(osAtLeast15: false, override: ""))
    }

    private func indices(from start: Int, lastIndex: Int) -> [Int] {
        var reached = start
        var sequence: [Int] = []
        while let next = TailCatchUp.nextIndex(after: reached, lastIndex: lastIndex) {
            sequence.append(next)
            reached = next
        }
        return sequence
    }
}
