import Foundation
import XCTest
@testable import KikimimiCore

/// 書き取りの答え合わせ (DictationCheck) の試験
final class DictationCheckTests: XCTestCase {
    private typealias P = DictationCheck.Piece

    private func check(_ typed: String, _ expected: String) -> DictationCheck.Result {
        DictationCheck.check(typed: typed, expected: expected)
    }

    func testPerfectMatchIgnoresCaseAndPunctuation() {
        let r = check("have you ever been to   london", "Have you ever been to London?")
        XCTAssertEqual(r.pieces, ["Have", "you", "ever", "been", "to", "London"].map { P.correct($0) })
        XCTAssertTrue(r.isPerfect)
        XCTAssertEqual(r.correctCount, 6)
        XCTAssertEqual(r.expectedCount, 6)
        XCTAssertEqual(r.accuracy, 1)
        XCTAssertEqual(r.mode, .words)
        XCTAssertTrue(check("\"Well,\" she said... ", "well she said").isPerfect)
    }

    func testOneSubstitution() {
        let r = check("I want to the store", "I went to the store.")
        XCTAssertEqual(r.pieces, [.correct("I"), .wrong(expected: "went", typed: "want"), .correct("to"), .correct("the"),
                                  .correct("store")])
        XCTAssertFalse(r.isPerfect)
        XCTAssertEqual(r.correctCount, 4)
        XCTAssertEqual(r.accuracy, 0.8, accuracy: 1e-9)
    }

    func testMissingWords() {
        let expected = "she sells sea shells"
        let table: [(typed: String, pieces: [P])] = [
            ("sells sea shells", [.missing("she"), .correct("sells"), .correct("sea"), .correct("shells")]),
            ("she sea shells", [.correct("she"), .missing("sells"), .correct("sea"), .correct("shells")]),
            ("she sells sea", [.correct("she"), .correct("sells"), .correct("sea"), .missing("shells")])
        ]
        for row in table {
            let r = check(row.typed, expected)
            XCTAssertEqual(r.pieces, row.pieces, row.typed)
            XCTAssertEqual(r.correctCount, 3)
            XCTAssertEqual(r.expectedCount, 4)
            XCTAssertEqual(r.accuracy, 0.75, accuracy: 1e-9)
        }
    }

    func testExtraWord() {
        let r = check("it is a very good idea", "It is a good idea.")
        XCTAssertEqual(r.pieces, [.correct("It"), .correct("is"), .correct("a"), .extra("very"), .correct("good"),
                                  .correct("idea")])
        XCTAssertEqual(r.correctCount, 5)
        XCTAssertEqual(r.expectedCount, 5)
        XCTAssertEqual(r.extraCount, 1)
        XCTAssertFalse(r.isPerfect)
        XCTAssertEqual(r.accuracy, 5.0 / 6.0, accuracy: 1e-9)
    }

    func testSeveralErrors() {
        let r = check("so I thing we should going now please", "So I think we should go now.")
        XCTAssertEqual(r.pieces, [.correct("So"), .correct("I"), .wrong(expected: "think", typed: "thing"), .correct("we"),
                                  .correct("should"), .wrong(expected: "go", typed: "going"), .correct("now"),
                                  .extra("please")])
        XCTAssertEqual(r.correctCount, 5)
        XCTAssertEqual(r.expectedCount, 7)
        let s = check("we go", "Then we will go home")
        XCTAssertEqual(s.pieces, [.missing("Then"), .correct("we"), .missing("will"), .correct("go"), .missing("home")])
    }

    func testApostrophes() {
        XCTAssertTrue(check("don't", "Don’t").isPerfect)
        XCTAssertTrue(check("I‘m here", "I'm here.").isPerfect)
        XCTAssertEqual(check("dont", "don't").pieces, [.wrong(expected: "don't", typed: "dont")])
        XCTAssertEqual(DictationCheck.tokens("I don't know, 'really'."), ["I", "don't", "know", "really"])
        XCTAssertTrue(check("the students books", "the students' books").isPerfect)
    }

    func testNumbersAreComparedAsTyped() {
        XCTAssertEqual(check("three cats", "3 cats").pieces, [.wrong(expected: "3", typed: "three"), .correct("cats")])
        XCTAssertTrue(check("it costs 3.50", "It costs $3.50.").isPerfect)
    }

    func testHyphenRule() {
        XCTAssertEqual(check("well known", "a well-known song").pieces,
                       [.missing("a"), .correct("well"), .correct("known"), .missing("song")])
        XCTAssertTrue(check("a well known song", "a well-known song").isPerfect)
        XCTAssertTrue(check("a well-known song", "a well known song").isPerfect)
        XCTAssertTrue(check("a well–known song", "a well-known song").isPerfect)
        XCTAssertEqual(check("a wellknown song", "a well-known song").pieces,
                       [.correct("a"), .wrong(expected: "well", typed: "wellknown"), .missing("known"), .correct("song")])
        XCTAssertEqual(check("a well-known song", "a well-known song").expectedCount, 4)
        // ハイフンだけの語は数えない
        XCTAssertEqual(DictationCheck.tokens("wait - what"), ["wait", "what"])
    }

    func testEmptyTyped() {
        let r = check("", "Good morning, everyone.")
        XCTAssertEqual(r.pieces, [.missing("Good"), .missing("morning"), .missing("everyone")])
        XCTAssertEqual(r.correctCount, 0)
        XCTAssertEqual(r.expectedCount, 3)
        XCTAssertEqual(r.accuracy, 0)
        XCTAssertFalse(r.isPerfect)
    }

    func testEmptyExpected() {
        let none = check("", "")
        XCTAssertEqual(none.pieces, [])
        XCTAssertTrue(none.isPerfect)
        XCTAssertEqual(none.accuracy, 1)
        let typed = check("hello there", "  ")
        XCTAssertEqual(typed.pieces, [.extra("hello"), .extra("there")])
        XCTAssertEqual(typed.accuracy, 0)
        XCTAssertFalse(typed.isPerfect)
    }

    func testPunctuationOnly() {
        let r = check("?!", "... —")
        XCTAssertEqual(r.pieces, [])
        XCTAssertTrue(r.isPerfect)
        XCTAssertEqual(check("...", "Yes.").pieces, [.missing("Yes")])
    }

    func testLongLineIsFast() {
        let words = (0..<300).map { "word\($0 % 37)" }
        let expected = words.joined(separator: " ")
        var typedWords = words
        typedWords.remove(at: 150)
        typedWords[10] = "oops"
        typedWords.insert("extra", at: 200)
        let began = Date()
        let r = check(typedWords.joined(separator: " "), expected)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
        XCTAssertEqual(r.expectedCount, 300)
        XCTAssertEqual(r.correctCount, 298)
        XCTAssertEqual(r.extraCount, 1)
    }

    func testJapaneseFallsBackToCharacters() {
        let r = check("今日は いい天気。", "今日はいい天気ですね。")
        XCTAssertEqual(r.mode, .characters)
        XCTAssertEqual(r.pieces, ["今", "日", "は", "い", "い", "天", "気"].map { P.correct($0) } + [.missing("で"),
                                                                                                    .missing("す"),
                                                                                                    .missing("ね")])
        XCTAssertEqual(r.expectedCount, 10)
        XCTAssertEqual(r.correctCount, 7)
        XCTAssertTrue(check("今日はいい天気ですね", "今日は、いい天気ですね!").isPerfect)
        XCTAssertEqual(check("今日は", "今日は").mode, .characters)
        XCTAssertEqual(check("", "日本").pieces, [.missing("日"), .missing("本")])
        // 英字が入っていれば語ごと
        XCTAssertEqual(DictationCheck.mode(for: "今日は Apple の日"), .words)
        XCTAssertEqual(DictationCheck.mode(for: ""), .words)
        XCTAssertEqual(DictationCheck.mode(for: "2024"), .words)
    }

    func testFullWidthLatin() {
        XCTAssertTrue(check("ＯＫ", "OK").isPerfect)
    }
}
