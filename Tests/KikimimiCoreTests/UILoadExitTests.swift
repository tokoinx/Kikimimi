import Foundation
import XCTest
@testable import KikimimiCore

/// 画面の重さの確認の終了コードの表 (UILoadExit) が、前の決め方と同じ答えを返し、手順書の表と合っているか。
final class UILoadExitTests: XCTestCase {
    /// リポジトリの根 (このファイルから 3 つ上)
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let skillPath = ".claude/skills/kikimimi-verify/SKILL.md"

    /// 1. 数が重ならず、集まりが {0,1,3,5,6,7,8,9}
    func testCodesAreDistinctAndKnown() {
        let codes = UILoadExit.allCases.map(\.rawValue)
        XCTAssertEqual(codes.count, Set(codes).count, "the same number is used twice: \(codes)")
        XCTAssertEqual(Set(codes), [0, 1, 3, 5, 6, 7, 8, 9])
        XCTAssertEqual(Set(UILoadExit.precedence).count, UILoadExit.precedence.count)
    }

    /// 前の UILoadSelfTest.run の式を、そのまま写した物 (library は library.failed || adapterMessageFailed)
    private static func oldCode(slow: Bool, lineFailed: Bool, library: Bool, practiceFailed: Bool,
                                chatFailed: Bool) -> Int32 {
        slow ? 5 : (lineFailed ? 6 : (library ? 7 : (practiceFailed ? 8 : (chatFailed ? 9 : 0))))
    }

    /// 2. precedence の 5 つの、32 通りの部分集合すべてで、decide が precedence で最も前の物 (空なら .ok) を返し、
    /// 前の式と同じ答えになる
    func testDecideMatchesPrecedenceAndTheOldExpression() {
        let order = UILoadExit.precedence
        XCTAssertEqual(order, [.slow, .line, .library, .practice, .chat])
        for mask in 0..<(1 << order.count) {
            let failed = Set(order.indices.filter { mask & (1 << $0) != 0 }.map { order[$0] })
            let expected = order.first { failed.contains($0) } ?? .ok
            let decided = UILoadExit.decide(failed: failed)
            XCTAssertEqual(decided, expected, "failed: \(failed)")
            let old = Self.oldCode(slow: failed.contains(.slow), lineFailed: failed.contains(.line),
                                   library: failed.contains(.library), practiceFailed: failed.contains(.practice),
                                   chatFailed: failed.contains(.chat))
            XCTAssertEqual(decided.rawValue, old, "failed: \(failed)")
        }
    }

    /// 3. 手順書の終了コードの表の数の集まりが、UILoadExit の数の集まりと同じ。「5 > 6 > … の順」の文も、precedence と合う
    func testSkillTableMatchesTheCodes() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent(Self.skillPath), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let header = "| 終了コード | 意味 | 出力に出る文 |"
        guard let start = lines.firstIndex(where: { $0.hasPrefix(header) }) else {
            return XCTFail("the exit code table was not found in \(Self.skillPath)")
        }
        // 見出しの次の区切りの行を飛ばし、表の行 (| で始まる) が続く間だけ読む
        var numbers: [Int32] = []
        for line in lines[(start + 2)...] {
            guard line.hasPrefix("|") else { break }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            guard cells.count > 1, let n = Int32(cells[1].trimmingCharacters(in: .whitespaces)) else {
                return XCTFail("a row of the exit code table does not start with a number: \(line)")
            }
            numbers.append(n)
        }
        XCTAssertEqual(numbers.count, Set(numbers).count, "the table has the same number twice: \(numbers)")
        XCTAssertEqual(Set(numbers), Set(UILoadExit.allCases.map(\.rawValue)),
                       "the table in \(Self.skillPath) and UILoadExit have different numbers")

        let order = UILoadExit.precedence.map { String($0.rawValue) }.joined(separator: " > ") + " の順"
        XCTAssertTrue(text.contains(order), "\(Self.skillPath) does not say \"\(order)\"")
    }
}
