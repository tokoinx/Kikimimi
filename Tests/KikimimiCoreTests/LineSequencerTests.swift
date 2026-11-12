import Foundation
import XCTest
@testable import KikimimiCore

/// 練習で次にすることを決める所 (LineSequencer) と、前後の行を探す所 (LineNeighbors) の試験
final class LineSequencerTests: XCTestCase {
    /// 5 行: 始まりは 0, 3, 6, 9, 12 秒、長さはどれも 2 秒
    private let lines: [PracticeLine] = (0..<5).map { i in
        PracticeLine(id: UUID(), start: Double(i) * 3, end: Double(i) * 3 + 2)
    }

    private func sequencer(_ settings: PracticeSettings = PracticeSettings()) -> LineSequencer {
        LineSequencer(lines: lines, settings: settings)
    }

    private func token(_ action: LineSequencer.Action, file: StaticString = #filePath, line: UInt = #line) -> Int {
        switch action {
        case .play(_, let t), .wait(_, let t): return t
        default:
            XCTFail("no token in \(action)", file: file, line: line)
            return -1
        }
    }

    private func playedLine(_ action: LineSequencer.Action) -> PracticeLine? {
        if case .play(let l, _) = action { return l }
        return nil
    }

    /// 再生の係のまねをして、止まるまで (または limit 回まで) 進める。返すのは指示の種類の並び
    private func run(_ s: inout LineSequencer, from first: LineSequencer.Action, limit: Int = 50) -> [String] {
        var trace: [String] = []
        var action = first
        for _ in 0..<limit {
            switch action {
            case .play(let l, let t):
                trace.append("play \(lines.firstIndex(of: l).map(String.init) ?? "?")")
                action = s.lineFinished(l.id, token: t)
            case .wait(let seconds, let t):
                trace.append("wait \(seconds)")
                action = s.waitFinished(token: t)
            case .stop:
                trace.append("stop")
                return trace
            case .nothing:
                trace.append("nothing")
                return trace
            }
        }
        return trace
    }

    // MARK: 繰り返し

    func testRepeatCounts() {
        let table: [(count: Int, expected: [String])] = [
            (1, ["play 1", "stop"]),
            (2, ["play 1", "play 1", "stop"]),
            (3, ["play 1", "play 1", "play 1", "stop"]),
            (5, ["play 1", "play 1", "play 1", "play 1", "play 1", "stop"])
        ]
        for row in table {
            var s = sequencer(PracticeSettings(repeatCount: row.count))
            let first = s.start(lines[1].id)
            XCTAssertEqual(run(&s, from: first), row.expected, "repeat \(row.count)")
            XCTAssertFalse(s.isActive)
            XCTAssertEqual(s.currentID, lines[1].id)
        }
    }

    func testRepeatUntilStopped() {
        var s = sequencer(PracticeSettings(repeatCount: PracticeSettings.untilStopped))
        let first = s.start(lines[2].id)
        let trace = run(&s, from: first, limit: 20)
        XCTAssertEqual(trace, Array(repeating: "play 2", count: 20))
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.playsDone, 20)
    }

    // MARK: 間

    func testGapOffHasNoWait() {
        var s = sequencer(PracticeSettings(repeatCount: 2, gap: .off))
        let first = s.start(lines[0].id)
        XCTAssertEqual(run(&s, from: first), ["play 0", "play 0", "stop"])
    }

    func testGapLineLengthWaitsBeforeEachFollowingPlay() {
        var s = sequencer(PracticeSettings(repeatCount: 3, gap: .lineLength))
        let first = s.start(lines[0].id)
        // 最後の 1 回のあとは、流すものがないので待たずに止める
        XCTAssertEqual(run(&s, from: first), ["play 0", "wait 2.0", "play 0", "wait 2.0", "play 0", "stop"])
    }

    func testGapExactActions() {
        var s = sequencer(PracticeSettings(repeatCount: 2, gap: .lineLength))
        let a = s.start(lines[1].id)
        XCTAssertEqual(a, .play(lines[1], token: 1))
        XCTAssertEqual(s.phase, .playing)
        let b = s.lineFinished(lines[1].id, token: 1)
        XCTAssertEqual(b, .wait(2.0, token: 2))
        XCTAssertEqual(s.phase, .waiting)
        XCTAssertEqual(s.waitFinished(token: 2), .play(lines[1], token: 3))
        XCTAssertEqual(s.lineFinished(lines[1].id, token: 3), .stop)
        XCTAssertEqual(s.phase, .idle)
    }

    func testGapLength() {
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 2, rate: 1), 2)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 2, rate: 0.5), 4)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 2.5, rate: 1.25), 2, accuracy: 1e-9)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 0.3, rate: 1), 1)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 20, rate: 1), 15)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 0, rate: 1), 1)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: 4, rate: 0), 4)
        XCTAssertEqual(PracticeSettings.lineLengthGap(duration: .nan, rate: 1), 1)
        XCTAssertEqual(PracticeSettings(gap: .off).gapSeconds(lineDuration: 5), 0)
        XCTAssertEqual(PracticeSettings(rate: 0.5, gap: .lineLength).gapSeconds(lineDuration: 5), 10)
    }

    func testGapUsesRate() {
        var s = sequencer(PracticeSettings(rate: 0.5, repeatCount: 2, gap: .lineLength))
        let first = s.start(lines[0].id)
        XCTAssertEqual(run(&s, from: first), ["play 0", "wait 4.0", "play 0", "stop"])
    }

    // MARK: 自動で次へ

    func testAutoAdvance() {
        let table: [(start: Int, advance: Bool, gap: PracticeSettings.Gap, repeats: Int, expected: [String])] = [
            (2, false, .off, 1, ["play 2", "stop"]),
            (2, true, .off, 1, ["play 2", "play 3", "play 4", "stop"]),
            (4, false, .off, 1, ["play 4", "stop"]),
            (4, true, .off, 1, ["play 4", "stop"]),
            (3, true, .off, 2, ["play 3", "play 3", "play 4", "play 4", "stop"]),
            (3, true, .lineLength, 1, ["play 3", "wait 2.0", "play 4", "stop"]),
            (4, true, .lineLength, 1, ["play 4", "stop"]),
            (3, true, .lineLength, 2, ["play 3", "wait 2.0", "play 3", "wait 2.0", "play 4", "wait 2.0", "play 4", "stop"])
        ]
        for row in table {
            var s = sequencer(PracticeSettings(repeatCount: row.repeats, gap: row.gap, autoAdvance: row.advance))
            let first = s.start(lines[row.start].id)
            XCTAssertEqual(run(&s, from: first), row.expected, "\(row)")
        }
    }

    func testAutoAdvanceSkipsLinesWithoutLength() {
        var custom = lines
        custom[2].end = custom[2].start
        var s = LineSequencer(lines: custom, settings: PracticeSettings(autoAdvance: true))
        var action = s.start(custom[1].id)
        action = s.lineFinished(custom[1].id, token: token(action))
        XCTAssertEqual(playedLine(action), custom[3])
    }

    // MARK: 止める と 遅れて届いた知らせ

    func testStopDuringPlayIgnoresStaleCallbacks() {
        var s = sequencer(PracticeSettings(repeatCount: 3, autoAdvance: true))
        let a = s.start(lines[1].id)
        s.stop()
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(a)), .nothing)
        XCTAssertEqual(s.waitFinished(token: token(a)), .nothing)
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.currentID, lines[1].id)
    }

    func testStopDuringWaitIgnoresStaleCallbacks() {
        var s = sequencer(PracticeSettings(repeatCount: 2, gap: .lineLength))
        let a = s.start(lines[1].id)
        let w = s.lineFinished(lines[1].id, token: token(a))
        XCTAssertEqual(s.phase, .waiting)
        s.stop()
        XCTAssertEqual(s.waitFinished(token: token(w)), .nothing)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(a)), .nothing)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(w)), .nothing)
        XCTAssertEqual(s.phase, .idle)
    }

    func testSwitchingLinesIgnoresTheOldLine() {
        var s = sequencer(PracticeSettings(repeatCount: 2))
        let a = s.start(lines[1].id)
        let b = s.start(lines[3].id)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(a)), .nothing)
        XCTAssertEqual(s.lineFinished(lines[3].id, token: token(a)), .nothing)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(b)), .nothing)
        // 新しい行の知らせは効く
        XCTAssertEqual(playedLine(s.lineFinished(lines[3].id, token: token(b))), lines[3])
    }

    func testDuplicateCallbackIsIgnored() {
        var s = sequencer(PracticeSettings(repeatCount: 2))
        let a = s.start(lines[0].id)
        _ = s.lineFinished(lines[0].id, token: token(a))
        XCTAssertEqual(s.lineFinished(lines[0].id, token: token(a)), .nothing)
        XCTAssertEqual(s.playsDone, 1)
    }

    func testWaitFinishedWhilePlayingIsIgnored() {
        var s = sequencer()
        let a = s.start(lines[0].id)
        XCTAssertEqual(s.waitFinished(token: token(a)), .nothing)
        XCTAssertEqual(s.phase, .playing)
    }

    // MARK: キー

    func testKeysWithoutCurrentLine() {
        var s = sequencer()
        XCTAssertEqual(playedLine(s.next()), lines[0])
        s.reset()
        XCTAssertEqual(playedLine(s.previous()), lines[0])
        s.reset()
        XCTAssertEqual(playedLine(s.replay()), lines[0])
        s.reset()
        // 再生の位置の行から
        XCTAssertEqual(playedLine(s.next(from: lines[2].id)), lines[3])
        s.reset()
        XCTAssertEqual(playedLine(s.previous(from: lines[2].id)), lines[1])
        s.reset()
        XCTAssertEqual(playedLine(s.replay(from: lines[2].id)), lines[2])
        s.reset()
        // 知らない位置は、ないとみなす
        XCTAssertEqual(playedLine(s.next(from: UUID())), lines[0])
    }

    func testKeysFromFirstMiddleAndLast() {
        let table: [(from: Int, next: Int?, previous: Int?)] = [
            (0, 1, nil),
            (2, 3, 1),
            (4, nil, 3)
        ]
        for row in table {
            var s = sequencer()
            _ = s.start(lines[row.from].id)
            var n = s
            let nextAction = n.next()
            XCTAssertEqual(nextAction, row.next.map { .play(lines[$0], token: 2) } ?? .nothing, "next from \(row.from)")
            var p = s
            let previousAction = p.previous()
            XCTAssertEqual(previousAction, row.previous.map { .play(lines[$0], token: 2) } ?? .nothing,
                           "previous from \(row.from)")
            var r = s
            XCTAssertEqual(r.replay(), .play(lines[row.from], token: 2), "replay \(row.from)")
        }
    }

    func testKeyAtTheEndKeepsPlaying() {
        var s = sequencer()
        let a = s.start(lines[4].id)
        XCTAssertEqual(s.next(), .nothing)
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.lineFinished(lines[4].id, token: token(a)), .stop)
    }

    func testKeysUseCurrentLineOverPosition() {
        var s = sequencer()
        _ = s.start(lines[1].id)
        s.stop()
        XCTAssertEqual(playedLine(s.next(from: lines[3].id)), lines[2])
    }

    func testKeysRestartThePlayCount() {
        var s = sequencer(PracticeSettings(repeatCount: 2))
        let a = s.start(lines[1].id)
        let b = s.lineFinished(lines[1].id, token: token(a))
        XCTAssertEqual(playedLine(b), lines[1])
        XCTAssertEqual(s.playsDone, 1)
        let c = s.next()
        XCTAssertEqual(playedLine(c), lines[2])
        XCTAssertEqual(s.playsDone, 0)
        XCTAssertEqual(run(&s, from: c), ["play 2", "play 2", "stop"])
        // replay も数え直す
        let d = s.replay()
        XCTAssertEqual(run(&s, from: d), ["play 2", "play 2", "stop"])
    }

    func testKeySkipsLinesWithoutLength() {
        var custom = lines
        custom[2].end = custom[2].start - 1
        var s = LineSequencer(lines: custom)
        _ = s.start(custom[1].id)
        XCTAssertEqual(playedLine(s.next()), custom[3])
        XCTAssertEqual(playedLine(s.previous()), custom[1])
        XCTAssertEqual(s.start(custom[2].id), .nothing)
        XCTAssertEqual(s.replay(from: custom[2].id), .play(custom[1], token: 4))
        var t = LineSequencer(lines: custom)
        XCTAssertEqual(t.replay(from: custom[2].id), .nothing)
    }

    // MARK: 設定が変わった

    func testSettingsChangedDuringPlay() {
        var s = sequencer(PracticeSettings(repeatCount: 3))
        let a = s.start(lines[1].id)
        let b = s.lineFinished(lines[1].id, token: token(a))
        XCTAssertEqual(playedLine(b), lines[1])
        s.update(settings: PracticeSettings(repeatCount: 1, gap: .lineLength, autoAdvance: true))
        // 回数はもう足りたので次の行へ。新しい間が先に入る
        XCTAssertEqual(run(&s, from: b), ["play 1", "wait 2.0", "play 2", "wait 2.0", "play 3", "wait 2.0", "play 4", "stop"])
    }

    func testSettingsChangedDuringWait() {
        var s = sequencer(PracticeSettings(gap: .lineLength, autoAdvance: true))
        let a = s.start(lines[1].id)
        let w = s.lineFinished(lines[1].id, token: token(a))
        XCTAssertEqual(w, .wait(2.0, token: 2))
        s.update(settings: PracticeSettings(gap: .lineLength, autoAdvance: false))
        XCTAssertEqual(s.waitFinished(token: token(w)), .stop)
    }

    func testSettingsAreNormalized() {
        var s = sequencer(PracticeSettings())
        var odd = PracticeSettings()
        odd.rate = 0.7
        odd.repeatCount = 4
        s.update(settings: odd)
        XCTAssertEqual(s.settings.rate, 0.75)
        XCTAssertEqual(s.settings.repeatCount, 3)
    }

    // MARK: 行が変わった

    func testLinesGrowDuringSequence() {
        var s = LineSequencer(lines: Array(lines.prefix(2)), settings: PracticeSettings(autoAdvance: true))
        let a = s.start(lines[1].id)
        XCTAssertEqual(s.update(lines: Array(lines.prefix(3))), .nothing)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(a)), .play(lines[2], token: 2))
    }

    func testCurrentLineRemovedDuringPlay() {
        var s = sequencer(PracticeSettings(repeatCount: 2))
        let a = s.start(lines[1].id)
        var rest = lines
        rest.remove(at: 1)
        XCTAssertEqual(s.update(lines: rest), .stop)
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.currentID)
        XCTAssertEqual(s.lineFinished(lines[1].id, token: token(a)), .nothing)
    }

    func testCurrentLineRemovedDuringWait() {
        var s = sequencer(PracticeSettings(repeatCount: 2, gap: .lineLength))
        let a = s.start(lines[1].id)
        let w = s.lineFinished(lines[1].id, token: token(a))
        XCTAssertEqual(s.update(lines: [lines[0]]), .stop)
        XCTAssertEqual(s.waitFinished(token: token(w)), .nothing)
    }

    func testCurrentLineRemovedWhileIdle() {
        var s = sequencer()
        _ = s.start(lines[1].id)
        s.stop()
        XCTAssertEqual(s.update(lines: [lines[0]]), .nothing)
        XCTAssertNil(s.currentID)
    }

    func testCurrentLineLosesItsLength() {
        var s = sequencer()
        _ = s.start(lines[1].id)
        var changed = lines
        changed[1].end = changed[1].start
        XCTAssertEqual(s.update(lines: changed), .stop)
    }

    // MARK: 変な入力

    func testUnknownIdsAndEmptyLines() {
        var s = sequencer()
        XCTAssertEqual(s.start(UUID()), .nothing)
        XCTAssertEqual(s.lineFinished(UUID(), token: 0), .nothing)
        XCTAssertEqual(s.waitFinished(token: 0), .nothing)
        var empty = LineSequencer()
        XCTAssertEqual(empty.next(), .nothing)
        XCTAssertEqual(empty.previous(), .nothing)
        XCTAssertEqual(empty.replay(from: UUID()), .nothing)
        XCTAssertEqual(empty.start(UUID()), .nothing)
        let a = s.start(lines[0].id)
        XCTAssertEqual(s.lineFinished(UUID(), token: token(a)), .nothing)
        XCTAssertTrue(s.isActive)
    }

    func testStartIgnoresBadLineAndKeepsSequence() {
        var custom = lines
        custom[3] = PracticeLine(id: custom[3].id, start: 5, end: .nan)
        var s = LineSequencer(lines: custom, settings: PracticeSettings(repeatCount: 2))
        let a = s.start(custom[0].id)
        XCTAssertEqual(s.start(custom[3].id), .nothing)
        XCTAssertEqual(playedLine(s.lineFinished(custom[0].id, token: token(a))), custom[0])
    }

    // MARK: LineNeighbors

    func testNeighbors() {
        let ids = [1, 2, 3]
        XCTAssertNil(LineNeighbors.previous(of: 1, in: ids))
        XCTAssertEqual(LineNeighbors.previous(of: 2, in: ids), 1)
        XCTAssertEqual(LineNeighbors.next(of: 2, in: ids), 3)
        XCTAssertNil(LineNeighbors.next(of: 3, in: ids))
        XCTAssertNil(LineNeighbors.next(of: 9, in: ids))
        XCTAssertNil(LineNeighbors.previous(of: 9, in: [Int]()))
    }

    func testLineAtTime() {
        let table: [(t: TimeInterval, index: Int?)] = [
            (-1, nil), (0, 0), (1.9, 0), (2.5, 0), (3, 1), (8.9, 2), (12, 4), (100, 4)
        ]
        for row in table {
            XCTAssertEqual(LineNeighbors.index(at: row.t, in: lines), row.index, "t = \(row.t)")
        }
        XCTAssertNil(LineNeighbors.index(at: 5, in: [PracticeLine]()))
        XCTAssertNil(LineNeighbors.index(at: .nan, in: lines))
        let segments = [TranscriptSegment(start: 1, end: 2, text: "a"), TranscriptSegment(start: 1, end: 3, text: "b"),
                        TranscriptSegment(start: 4, end: 5, text: "c")]
        XCTAssertNil(LineNeighbors.index(at: 0.5, in: segments))
        XCTAssertEqual(LineNeighbors.index(at: 1, in: segments), 1)
        XCTAssertEqual(LineNeighbors.index(at: 4.5, in: segments), 2)
        // 一部分 (位置が 0 から始まらない) でも
        let slice = lines[2...]
        XCTAssertNil(LineNeighbors.index(at: 5, in: slice) { $0.start })
        XCTAssertEqual(LineNeighbors.index(at: 10, in: slice) { $0.start }, 3)
    }

    func testLineAtTimeIsFastForManyLines() {
        let many = (0..<100_000).map { PracticeLine(id: UUID(), start: Double($0), end: Double($0) + 0.5) }
        for t in stride(from: 0.0, to: 100_000, by: 997) {
            XCTAssertEqual(LineNeighbors.index(at: t + 0.7, in: many), Int(t))
        }
    }
}
