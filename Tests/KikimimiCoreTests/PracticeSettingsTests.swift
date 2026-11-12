import Foundation
import XCTest
@testable import KikimimiCore

/// 練習の設定 (PracticeSettings) の試験: 候補への直し方と、保存・読み込み
final class PracticeSettingsTests: XCTestCase {
    func testDefaults() {
        let s = PracticeSettings()
        XCTAssertEqual(s.rate, 1.0)
        XCTAssertEqual(s.repeatCount, 1)
        XCTAssertEqual(s.gap, .off)
        XCTAssertFalse(s.autoAdvance)
        XCTAssertEqual(s.hide, .nothing)
        XCTAssertFalse(s.repeatsUntilStopped)
    }

    func testNearestRate() {
        let table: [(Double, Double)] = [
            (1.0, 1.0), (0.5, 0.5), (0.1, 0.5), (0.55, 0.5), (0.56, 0.6), (0.7, 0.75), (0.8, 0.75), (0.81, 0.85),
            (0.95, 1.0), (1.1, 1.0), (1.2, 1.25), (3, 1.25), (-2, 0.5), (.nan, 1.0), (.infinity, 1.0)
        ]
        for (value, expected) in table {
            XCTAssertEqual(PracticeSettings.nearestRate(value), expected, "\(value)")
        }
    }

    func testNearestRepeatCount() {
        let table: [(Int, Int)] = [(0, 0), (1, 1), (2, 2), (3, 3), (4, 3), (5, 5), (9, 5), (-3, 1)]
        for (value, expected) in table {
            XCTAssertEqual(PracticeSettings.nearestRepeatCount(value), expected, "\(value)")
        }
        XCTAssertTrue(PracticeSettings(repeatCount: 0).repeatsUntilStopped)
    }

    func testInitAndNormalized() {
        XCTAssertEqual(PracticeSettings(rate: 0.7, repeatCount: 4).rate, 0.75)
        var s = PracticeSettings()
        s.rate = 1.3
        s.repeatCount = 7
        let n = s.normalized()
        XCTAssertEqual(n.rate, 1.25)
        XCTAssertEqual(n.repeatCount, 5)
    }

    func testJSONRoundTrip() throws {
        let s = PracticeSettings(rate: 0.6, repeatCount: 0, gap: .lineLength, autoAdvance: true, hide: .sourceAndTranslation)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(PracticeSettings.self, from: data), s)
        XCTAssertEqual(PracticeSettings.load(jsonString: s.jsonString()), s)
        XCTAssertEqual(s.jsonString(),
                       #"{"autoAdvance":true,"gap":"lineLength","hide":"sourceAndTranslation","rate":0.6,"repeatCount":0}"#)
    }

    func testDecodingToleratesMissingAndUnknownValues() {
        XCTAssertEqual(PracticeSettings.load(jsonString: "{}"), PracticeSettings())
        XCTAssertEqual(PracticeSettings.load(jsonString: #"{"rate":0.5}"#), PracticeSettings(rate: 0.5))
        let odd = #"{"rate":"fast","repeatCount":4,"gap":"forever","autoAdvance":"yes","hide":"everything","extra":1}"#
        XCTAssertEqual(PracticeSettings.load(jsonString: odd), PracticeSettings(repeatCount: 3))
        XCTAssertEqual(PracticeSettings.load(jsonString: #"{"rate":0.9,"hide":"source"}"#),
                       PracticeSettings(rate: 0.85, hide: .source))
        XCTAssertEqual(PracticeSettings.load(jsonString: #"{"rate":1}"#).rate, 1.0)
    }

    func testLoadingBrokenText() {
        XCTAssertEqual(PracticeSettings.load(jsonString: nil), PracticeSettings())
        XCTAssertEqual(PracticeSettings.load(jsonString: ""), PracticeSettings())
        XCTAssertEqual(PracticeSettings.load(jsonString: "not json"), PracticeSettings())
        XCTAssertEqual(PracticeSettings.load(jsonString: "[1, 2]"), PracticeSettings())
    }
}
