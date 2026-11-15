import Foundation
import XCTest
@testable import KikimimiCore

/// 書き取りの結果の並べ方 (DictationDisplay) の試験
final class DictationDisplayTests: XCTestCase {
    func testWordsWithWrongMissingExtra() {
        let result = DictationCheck.check(typed: "I has a red dog today", expected: "I have a big red dog.")
        let spans = DictationDisplay.spans(result)
        let text = spans.map(\.text).joined()
        XCTAssertEqual(text, "I has have a [big] red dog today")
        XCTAssertEqual(spans.filter { $0.style == .typedWrong }.map(\.text), ["has", "today"])
        XCTAssertEqual(spans.filter { $0.style == .expected }.map(\.text), ["have"])
        XCTAssertEqual(spans.filter { $0.style == .missing }.map(\.text), ["[big]"])
        XCTAssertEqual(DictationDisplay.summary(result), "4 / 6 語")
    }

    func testPerfect() {
        let result = DictationCheck.check(typed: "hello world", expected: "Hello, world!")
        XCTAssertEqual(DictationDisplay.spans(result).map(\.text).joined(), "Hello world")
        XCTAssertEqual(DictationDisplay.summary(result), "全部合っています")
    }

    func testCharactersHaveNoSpaces() {
        let result = DictationCheck.check(typed: "こんにちわ", expected: "こんにちは。")
        XCTAssertEqual(result.mode, .characters)
        XCTAssertEqual(DictationDisplay.spans(result).map(\.text).joined(), "こんにちわは")
        XCTAssertEqual(DictationDisplay.summary(result), "4 / 5 字")
    }

    func testEmptyTypedShowsAllMissing() {
        let result = DictationCheck.check(typed: "", expected: "Good morning")
        XCTAssertEqual(DictationDisplay.spans(result).map(\.text).joined(), "[Good] [morning]")
        XCTAssertEqual(DictationDisplay.summary(result), "0 / 2 語")
    }
}
