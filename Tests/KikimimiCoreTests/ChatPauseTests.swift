import XCTest
@testable import KikimimiCore

/// チャットが答えている間に、監査・翻訳の進み具合の文を替えるか
final class ChatPauseTests: XCTestCase {
    func testOnlyAnsweringWithARunningPostTaskReplacesTheProgress() {
        let phases: [ChatPhase] = [.idle, .readingPages, .waitingForLLM, .answering]
        for phase in phases {
            XCTAssertEqual(ChatPause.replacesProgress(chatPhase: phase, postTaskRunning: true), phase == .answering, "\(phase)")
            XCTAssertFalse(ChatPause.replacesProgress(chatPhase: phase, postTaskRunning: false), "\(phase)")
        }
    }
}
