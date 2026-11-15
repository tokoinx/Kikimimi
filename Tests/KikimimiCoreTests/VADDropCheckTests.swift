import XCTest
@testable import KikimimiCore

/// 「無音を飛ばす機能 (VAD) が、大事な音まで飛ばしたらしい」の決め方
final class VADDropCheckTests: XCTestCase {
    /// 正弦波 (振幅 amplitude) の seconds 秒ぶん
    private func tone(_ seconds: Double, rate: Int, amplitude: Float = 0.3, frequency: Double = 220) -> [Float] {
        let n = Int(seconds * Double(rate))
        return (0..<n).map { i in amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / Double(rate))) }
    }

    private func silence(_ seconds: Double, rate: Int) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    func testContinuousToneWithOneShortSegmentLooksDropped() {
        // 歌のように、ずっと音が鳴っているのに、結果が 1 区間 (8〜12.5 秒) だけ
        let rate = 16_000
        let samples = tone(150, rate: rate)
        XCTAssertTrue(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: [8.0...12.5]))
        let a = VADDropCheck.assess(samples: samples, sampleRate: rate, segments: [8.0...12.5])
        XCTAssertEqual(a.totalSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(a.keptSeconds, 4.5, accuracy: 0.001)
    }

    func testSpeechWithPausesMatchingSegmentsIsNotDropped() {
        // 「2 秒の音 + 3 秒の無音」のくり返し。区間は音の所に合っている (講演の間)
        let rate = 8_000
        var samples: [Float] = []
        var segments: [ClosedRange<Double>] = []
        for k in 0..<12 {
            let start = Double(k) * 5
            samples += tone(2, rate: rate)
            samples += silence(3, rate: rate)
            segments.append(start...(start + 2))
        }
        XCTAssertFalse(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: segments))
    }

    func testWholeAudioCoveredIsNotDropped() {
        let rate = 8_000
        let samples = tone(60, rate: rate)
        XCTAssertFalse(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: [0.0...60.0]))
    }

    func testShortAudioIsNotChecked() {
        let rate = 16_000
        let samples = tone(15, rate: rate)
        XCTAssertFalse(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: []))
    }

    func testNearSilenceWithoutSegmentsIsNotDropped() {
        // 全体がほぼ無音 (振幅 0.0005) で、区間なし
        let rate = 8_000
        let samples = tone(60, rate: rate, amplitude: 0.0005)
        XCTAssertFalse(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: []))
    }

    func testContinuousToneWithoutSegmentsLooksDropped() {
        let rate = 8_000
        let samples = tone(60, rate: rate)
        XCTAssertTrue(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: []))
    }

    func testLongSilenceWithShortTalkIsNotDropped() {
        // 60 分の無音に、5 分の音と区間 (長い配列になるので、サンプルレートを下げて作る)
        let rate = 1_000
        let samples = silence(3600, rate: rate) + tone(300, rate: rate, frequency: 100)
        XCTAssertFalse(VADDropCheck.looksDropped(samples: samples, sampleRate: rate, segments: [3600.0...3900.0]))
    }

    func testLetterCountIgnoresWhitespaceAndRetryNeedsMoreLetters() {
        let first = [TranscriptSegment(start: 0, end: 1, text: "あい う"), TranscriptSegment(start: 1, end: 2, text: " ab ")]
        XCTAssertEqual(VADDropCheck.letterCount(of: first), 5)
        let same = [TranscriptSegment(start: 0, end: 1, text: "あいうab")]
        let more = [TranscriptSegment(start: 0, end: 1, text: "あいうえおか")]
        XCTAssertFalse(VADDropCheck.prefersRetry(first: first, retry: same), "the same count keeps the first result")
        XCTAssertTrue(VADDropCheck.prefersRetry(first: first, retry: more))
        XCTAssertFalse(VADDropCheck.prefersRetry(first: more, retry: first))
    }
}
