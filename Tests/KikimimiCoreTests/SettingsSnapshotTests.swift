import Foundation
import XCTest
@testable import KikimimiCore

/// 確認用の起動の、本物の設定の写しと元に戻す手順を見る。
/// 本物の設定には書かない (元に戻す所は、一時の領域で試し、終わりに消す)
final class SettingsSnapshotTests: XCTestCase {
    // MARK: 比べる所

    func testSameComparesPropertyListValues() {
        XCTAssertTrue(SettingsSnapshot.same("105 57 1200 800", "105 57 1200 800"))
        XCTAssertFalse(SettingsSnapshot.same("105 57 1200 800", "105 57 1200 807"))
        XCTAssertTrue(SettingsSnapshot.same(3, 3))
        XCTAssertTrue(SettingsSnapshot.same(true, true))
        XCTAssertFalse(SettingsSnapshot.same(1.5, 2.5))
        XCTAssertTrue(SettingsSnapshot.same(["a", "b"], ["a", "b"]))
        XCTAssertFalse(SettingsSnapshot.same(["a", "b"], ["b", "a"]))
        XCTAssertTrue(SettingsSnapshot.same(["x": [1, 2]], ["x": [1, 2]]))
        XCTAssertFalse(SettingsSnapshot.same(["x": [1, 2]], ["x": [1, 3]]))
        XCTAssertFalse(SettingsSnapshot.same("1", 1))
    }

    func testChangedKeysFindsChangedAddedAndRemoved() {
        let before: [String: Any] = [
            "NSWindow Frame main-AppWindow-1": "105 57 1200 800 0 0 1440 875 ",
            "keep": ["a": 1],
            "gone": 5,
            "useVAD": true
        ]
        let after: [String: Any] = [
            "NSWindow Frame main-AppWindow-1": "10 10 900 700 0 0 1440 875 ",
            "keep": ["a": 1],
            "NSWindow Frame chat": "0 0 400 500 0 0 1440 875 ",
            "useVAD": true
        ]
        XCTAssertEqual(SettingsSnapshot.changedKeys(before: before, after: after),
                       ["NSWindow Frame chat", "NSWindow Frame main-AppWindow-1", "gone"])
        XCTAssertEqual(SettingsSnapshot.changedKeys(before: before, after: before), [])
        XCTAssertEqual(SettingsSnapshot.changedKeys(before: [:], after: [:]), [])
    }

    // MARK: 出力の行

    func testReportLines() {
        XCTAssertEqual(SettingsSnapshot.reportLines(restored: []), ["REAL SETTINGS: unchanged"])
        XCTAssertEqual(SettingsSnapshot.reportLines(restored: [
            "NSWindow Frame main-AppWindow-1", "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
        ]), [
            "REAL SETTINGS: put back 2 keys the system wrote during the self-test: NSWindow Frame main-AppWindow-1,"
                + " NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
        ])
        XCTAssertEqual(SettingsSnapshot.reportLines(restored: ["NSWindow Frame chat"]),
                       ["REAL SETTINGS: put back 1 key the system wrote during the self-test: NSWindow Frame chat"])
        // アプリの設定の鍵は、別の行で大きく知らせる
        XCTAssertEqual(SettingsSnapshot.reportLines(restored: ["NSWindow Frame chat", "showNotes", "useVAD"]), [
            "REAL SETTINGS: put back 1 key the system wrote during the self-test: NSWindow Frame chat",
            "REAL SETTINGS: APP SETTINGS CHANGED DURING THE SELF-TEST (put back): showNotes, useVAD"
        ])
        XCTAssertEqual(SettingsSnapshot.reportLines(restored: ["useVAD"]),
                       ["REAL SETTINGS: APP SETTINGS CHANGED DURING THE SELF-TEST (put back): useVAD"])
    }

    func testReportLinesCutLongNamesAndLongLists() {
        let long = String(repeating: "x", count: 100)
        let line = SettingsSnapshot.reportLines(restored: [long])[0]
        XCTAssertTrue(line.hasSuffix(": " + String(repeating: "x", count: 80) + "..."), line)
        let many = (1...9).map { "k\($0)" }
        XCTAssertEqual(SettingsSnapshot.reportLines(restored: many),
                       ["REAL SETTINGS: put back 9 keys the system wrote during the self-test: k1, k2, k3, k4, k5, k6, and 3 more"])
    }

    func testInsertKeepsTheOKLineLast() {
        let report = ["REAL SETTINGS: unchanged"]
        XCTAssertEqual(SettingsSnapshot.insert(report, into: ["a", "UI LOAD OK"], before: "UI LOAD OK"),
                       ["a", "REAL SETTINGS: unchanged", "UI LOAD OK"])
        XCTAssertEqual(SettingsSnapshot.insert(report, into: ["a", "UI LOAD FAILED: x"], before: "UI LOAD OK"),
                       ["a", "UI LOAD FAILED: x", "REAL SETTINGS: unchanged"])
        XCTAssertEqual(SettingsSnapshot.insert([], into: ["a", "UI LOAD OK"], before: "UI LOAD OK"), ["a", "UI LOAD OK"])
    }

    // MARK: 元に戻す所 (一時の領域)

    /// 確認用の起動は、写しを取り、変わった鍵・増えた鍵・消えた鍵だけを元に戻す。触っていない鍵は、そのまま
    func testPutBackRestoresOnlyChangedKeys() throws {
        let name = "local.kikimimi.tests.settings-snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            SettingsWriter.clearSnapshotForTests()
        }
        defaults.set("105 57 1200 800 0 0 1440 875 ", forKey: "NSWindow Frame main-AppWindow-1")
        defaults.set(["a": 1], forKey: "keep")
        defaults.set(5, forKey: "gone")
        SettingsWriter.takeSnapshotForSelfTest(mode: .selfTest, defaults: defaults, domainName: name)
        // 確認のあいだに macOS が書いた事にする
        defaults.set("10 10 900 700 0 0 1440 875 ", forKey: "NSWindow Frame main-AppWindow-1")
        defaults.set("0 0 400 500 0 0 1440 875 ", forKey: "NSWindow Frame chat")
        defaults.removeObject(forKey: "gone")
        let restored = SettingsWriter.putBackAfterSelfTest(mode: .selfTest, defaults: defaults, domainName: name)
        XCTAssertEqual(restored, ["NSWindow Frame chat", "NSWindow Frame main-AppWindow-1", "gone"])
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame main-AppWindow-1"), "105 57 1200 800 0 0 1440 875 ")
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame chat"))
        XCTAssertEqual(defaults.integer(forKey: "gone"), 5)
        XCTAssertEqual(defaults.dictionary(forKey: "keep") as? [String: Int], ["a": 1])
        // 戻した後は、写しと同じ
        let now = defaults.persistentDomain(forName: name) ?? [:]
        XCTAssertEqual(SettingsWriter.putBackAfterSelfTest(mode: .selfTest, defaults: defaults, domainName: name), [])
        XCTAssertEqual(now.count, 3)
    }

    /// ふつうの起動・道具の起動では、写しを取らず、戻さない (呼ばれても何もしない)
    func testDoesNothingOutsideSelfTest() throws {
        let name = "local.kikimimi.tests.settings-snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            SettingsWriter.clearSnapshotForTests()
        }
        SettingsWriter.clearSnapshotForTests()
        defaults.set("a", forKey: "k")
        for mode in [LaunchMode.app, .tool] {
            SettingsWriter.takeSnapshotForSelfTest(mode: mode, defaults: defaults, domainName: name)
            defaults.set("b", forKey: "k")
            XCTAssertNil(SettingsWriter.putBackAfterSelfTest(mode: mode, defaults: defaults, domainName: name))
            XCTAssertEqual(defaults.string(forKey: "k"), "b")
        }
        // 写しが無ければ、確認用の起動でも戻さない
        XCTAssertNil(SettingsWriter.putBackAfterSelfTest(mode: .selfTest, defaults: defaults, domainName: name))
        XCTAssertEqual(defaults.string(forKey: "k"), "b")
    }
}
