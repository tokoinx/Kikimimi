import XCTest
@testable import KikimimiCore

/// チャットの対訳の札の「前の値」(「もうこの値」になるか) の決め方
final class ChatProposalBeforeTests: XCTestCase {
    /// 結果での見え方 (設定 || 行の「訳」の印)。結果が無ければ nil
    private func shown(setting: Bool, mark: Bool?) -> Bool? {
        mark.map { setting || $0 }
    }

    /// 全部の組: 設定の入切 × 結果の印 (在る・無い・結果なし) × 頼まれた入切
    func testAllCombinations() {
        // (設定, 印 (nil = 結果なし), 頼まれた値) → 前の値
        let cases: [(Bool, Bool?, Bool, Bool)] = [
            (false, nil, true, false),
            (false, nil, false, false),
            (true, nil, true, true),
            (true, nil, false, true),
            (false, false, true, false),
            (false, false, false, false),
            (false, true, true, false),   // 印で見えていても、設定が切なら「切 → 入」
            (false, true, false, true),   // 見えているので「入 → 切」
            (true, false, true, true),
            (true, false, false, true),
            (true, true, true, true),
            (true, true, false, true)
        ]
        for (setting, mark, requested, expected) in cases {
            let before = ChatProposalBefore.bilingual(setting: setting, shownForResult: shown(setting: setting, mark: mark),
                                                      requested: requested)
            XCTAssertEqual(before, expected, "setting \(setting) mark \(String(describing: mark)) requested \(requested)")
        }
    }

    /// 直す前の決め方 (いつも画面の見え方) だと「もうこの値」になる組が、今は札を出す
    func testSettingOffWithLineMarkAndOnRequestedIsNotAlreadySet() {
        let shownNow = shown(setting: false, mark: true)
        let oldBefore = shownNow ?? false
        XCTAssertTrue(oldBefore == true, "直す前の決め方では、もうこの値になっていた")
        let before = ChatProposalBefore.bilingual(setting: false, shownForResult: shownNow, requested: true)
        XCTAssertFalse(before == true, "札は「もうこの値」にならない")
    }
}
