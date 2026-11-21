import Foundation
import XCTest

/// 結果の一覧 (数千行) の 4 つの決まり (CLAUDE.md の「結果の一覧」) を、ソースの書き方で見る。
/// 注釈と文字列の中身は除いてから見る (文字列に埋め込んだ式 \( … ) は、式として残す)。
/// 走査は書き方しか見ないので、次の形は見逃す: 一覧の body が、別のファイルの関数や部品を通して状態を読む・
/// 禁じた語と違う名前 (別名の変数など) で読む・呼ぶ側が TranscriptListView を変数に入れてから .id を付けずに置く。
/// 破った時の重さそのものは、アプリの確認 (--selftest-ui-load 3000) が測る
final class TranscriptListRulesTests: XCTestCase {
    static let reasonsAt = "See CLAUDE.md (section \"結果の一覧\") and the notes in TranscriptListView.swift for the reasons"

    // MARK: 決まり 1: GeometryReader の中の ScrollView + LazyVStack。大きさは外から決める

    func testRule1ListIsALazyStackSizedFromOutside() throws {
        let code = try SwiftCode.read(SwiftCode.listFile)
        let geometry = code.firstRange(of: #"\bGeometryReader\b"#)
        let scroll = code.firstRange(of: #"\bScrollView\s*\{"#)
        XCTAssertNotNil(geometry, "Rule 1: TranscriptListView.swift must put the list in a GeometryReader. \(Self.reasonsAt)")
        XCTAssertNotNil(scroll, "Rule 1: TranscriptListView.swift must use `ScrollView {`. \(Self.reasonsAt)")
        if let geometry, let scroll {
            XCTAssertLessThan(geometry.location, scroll.location,
                              "Rule 1: the ScrollView must be inside the GeometryReader (GeometryReader comes first). \(Self.reasonsAt)")
        }
        XCTAssertNotNil(code.firstRange(of: #"\bLazyVStack\s*\("#),
                        "Rule 1: the rows must be in a LazyVStack (not VStack or List). \(Self.reasonsAt)")
        XCTAssertNotNil(code.firstRange(of: #"\.frame\(\s*width:\s*geometry\.size\.width\s*,\s*height:\s*geometry\.size\.height\s*\)"#),
                        "Rule 1: the ScrollView must be sized from outside with "
                            + "`.frame(width: geometry.size.width, height: geometry.size.height)`. \(Self.reasonsAt)")
        XCTAssertEqual(code.lines(matching: #"\bList\s*[({]"#), [],
                       "Rule 1: do not use SwiftUI's List for the result list (it was slow with thousands of rows). \(Self.reasonsAt)")
    }

    // MARK: 決まり 2: 結果ごとに .id(job.id) で作り直す。行には .id() を付けない

    func testRule2ListIsRebuiltPerJobAndRowsHaveNoID() throws {
        var calls: [String] = []
        var missing: [String] = []
        for file in try SwiftCode.appFiles() {
            let code = try SwiftCode.read(file)
            for call in code.calls(of: "TranscriptListView") {
                calls.append("\(file.name):\(call.line)")
                if !call.after.hasMatch(#"^\s*\.id\(\s*job\.id\s*\)"#) { missing.append("\(file.name):\(call.line)") }
            }
        }
        XCTAssertFalse(calls.isEmpty, "Rule 2: found no place that makes a TranscriptListView (did the scan break?)")
        XCTAssertEqual(missing, [],
                       "Rule 2: every TranscriptListView(…) must be followed by `.id(job.id)` (one new list per result). \(Self.reasonsAt)")
        let list = try SwiftCode.read(SwiftCode.listFile)
        XCTAssertEqual(list.lines(matching: #"\.id\s*\("#), [],
                       "Rule 2: TranscriptListView.swift must not use .id(…) (no .id() on the rows). \(Self.reasonsAt)")
        let detail = try SwiftCode.read(SwiftCode.detailFile)
        XCTAssertEqual(detail.lines(matching: #"\.id\s*\("#).count, 1,
                       "Rule 2: TranscriptDetailView.swift must have exactly one .id(…) (the `.id(job.id)` on the list); "
                           + "found at lines \(detail.lines(matching: #"\.id\s*\("#)). The row views there must not use .id(). \(Self.reasonsAt)")
    }

    // MARK: 決まり 3: HSplitView・VSplitView で包まない

    /// HSplitView・VSplitView を使ってよいファイル (理由つき)。パスは Sources/Kikimimi からの相対。今は無い
    static let splitViewAllowed: [(path: String, reason: String)] = []

    func testRule3NoSplitViews() throws {
        var found: [String] = []
        for file in try SwiftCode.appFiles() where !Self.splitViewAllowed.contains(where: { $0.path == file.name }) {
            let code = try SwiftCode.read(file)
            found += code.lines(matching: #"\b(HSplitView|VSplitView)\b"#).map { "\(file.name):\($0)" }
        }
        XCTAssertEqual(found, [],
                       "Rule 3: do not wrap the result list in HSplitView or VSplitView (the split view measures the list, "
                           + "and the LazyVStack then builds every row). This test forbids them in all of Sources/Kikimimi, "
                           + "which is wider than the rule: if one is needed somewhere that does not wrap the list, "
                           + "add that file to TranscriptListRulesTests.splitViewAllowed with the reason. \(Self.reasonsAt)")
    }

    // MARK: 決まり 4: 一覧の body は、よく変わる状態を読まない

    /// TranscriptListView.swift に書かない語 (よく変わる状態を読む形)。注釈と文字列の外で見る
    static let forbidden: [(pattern: String, what: String)] = [
        // 再生 (PlayerController の見張られる値)
        (#"\bmodel\s*\.\s*player\b"#, "playback (model.player)"),
        (#"\bplayer\s*\."#, "playback (player.…)"),
        (#"\bPlayerController\b"#, "playback (PlayerController)"),
        (#"\bcurrentTime\b"#, "playback position (currentTime)"),
        (#"\bisPlaying\b"#, "playback (isPlaying)"),
        (#"\bplayingLineID\b"#, "playback (playingLineID)"),
        // 練習 (PracticeController と、行ごとの小さな入れ物)
        (#"\bmodel\s*\.\s*practice\b"#, "practice (model.practice)"),
        (#"\bpractice\s*\."#, "practice (practice.…)"),
        (#"\bPracticeController\b"#, "practice (PracticeController)"),
        (#"\b(activeLineID|currentLineID|isWaiting|scrollRequest|hideMode|showsDictation)\b"#, "practice state"),
        (#"\b(RowReveal|RevealCell|DictationState)\b"#, "practice state (revealed lines, dictation)"),
        // メモ (Job.notes と、メモの欄の幅・出すか)
        (#"\.\s*notes\b"#, "notes (job.notes)"),
        (#"\b(notesSaved|notesRevision|notesSpace|NotesSpace|notesWidth|showNotes)\b"#, "notes state"),
        // 追いかけるか (ListFollow.isOn)
        (#"\.\s*isOn\b"#, "follow state (ListFollow.isOn)"),
        // 行の色 (RowHighlight の中・RowTintCell)
        (#"\bhighlight\s*\.\s*\w"#, "row tint (highlight.…)"),
        (#"\bRowTintCell\b"#, "row tint (RowTintCell)"),
        (#"\.\s*tint\b"#, "row tint (.tint)"),
        (#"\b(playingID|currentID)\b"#, "row tint (RowHighlight state)")
    ]
    /// 一覧の body が AppModel から読んでよい物 (行が変わる時だけ変わる・めったに変わらない値)
    static let modelAllowed: Set<String> = ["canPlayLines", "showTimestamps", "searchText"]
    /// TranscriptListView.swift に置いてよい型 (よく変わる状態を見る部品は TranscriptListSupport.swift に置く)
    static let listFileTypes: Set<String> = ["TranscriptListView", "TranscriptRows"]

    func testRule4ListBodyDoesNotReadChangingState() throws {
        let code = try SwiftCode.read(SwiftCode.listFile)
        var found: [String] = []
        for (pattern, what) in Self.forbidden {
            found += code.lines(matching: pattern).map { "line \($0): \(what)" }
        }
        XCTAssertEqual(found, [],
                       "Rule 4: the list body (all of TranscriptListView.swift) must not read often-changing state "
                           + "(playback position, practice, notes, follow, row tint). Read it in a component in "
                           + "TranscriptListSupport.swift instead. \(Self.reasonsAt)")
        let modelReads = Set(code.captures(of: #"\bmodel\s*\.\s*(\w+)"#))
        XCTAssertEqual(modelReads.subtracting(Self.modelAllowed).sorted(), [],
                       "Rule 4: the list body reads AppModel values that are not in TranscriptListRulesTests.modelAllowed. "
                           + "Read often-changing values in a component in TranscriptListSupport.swift; add a value to the list "
                           + "only if it changes no more often than the rows do. \(Self.reasonsAt)")
        let types = Set(code.captures(of: #"\b(?:struct|class|enum|actor|extension)\s+(\w+)"#))
        XCTAssertEqual(types, Self.listFileTypes,
                       "Rule 4: TranscriptListView.swift must hold only TranscriptListView and TranscriptRows (this test reads "
                           + "the whole file as the list body). Put other components in TranscriptListSupport.swift. \(Self.reasonsAt)")
    }

    // MARK: 走査の道具そのもの

    func testScannerRemovesCommentsAndStrings() {
        let code = SwiftCode(name: "x.swift", text: """
            let a = "model.player \\(model.practice.x) \\" .isOn" // HSplitView
            /* List { /* nested */ .id( */ let b = #"VSplitView "x" \\(y)"#
            let c = \"\"\"
                LazyVStack(
                \"\"\"
            f(TranscriptListView(job: (1, 2)).id(job.id))
            """)
        XCTAssertEqual(code.lines(matching: #"HSplitView|VSplitView|\bList\b|LazyVStack|\.isOn"#), [])
        XCTAssertEqual(code.lines(matching: #"model\.player"#), [])
        XCTAssertEqual(code.lines(matching: #"model\.practice"#), [1])
        XCTAssertEqual(code.lines(matching: #"\.id\("#), [6])
        let calls = code.calls(of: "TranscriptListView")
        XCTAssertEqual(calls.map { $0.line }, [6])
        XCTAssertTrue(calls.first?.after.hasMatch(#"^\s*\.id\(\s*job\.id\s*\)"#) ?? false)
    }
}

/// Swift のソースから、注釈と文字列の中身を除いた文 (行の数は元のまま)
struct SwiftCode {
    let name: String
    /// 注釈と文字列の中身を除いた文
    let code: String

    init(name: String, text: String) {
        self.name = name
        code = Self.strip(text)
    }

    struct File {
        /// Sources/Kikimimi からの相対のパス
        let name: String
        let url: URL
    }

    static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Kikimimi")
    static let listFile = File(name: "Views/TranscriptListView.swift",
                               url: appRoot.appendingPathComponent("Views/TranscriptListView.swift"))
    static let detailFile = File(name: "Views/TranscriptDetailView.swift",
                                 url: appRoot.appendingPathComponent("Views/TranscriptDetailView.swift"))

    static func read(_ file: File) throws -> SwiftCode {
        SwiftCode(name: file.name, text: try String(contentsOf: file.url, encoding: .utf8))
    }

    /// Sources/Kikimimi の下の .swift のすべて
    static func appFiles() throws -> [File] {
        guard let walker = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [File] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(File(name: String(url.path.dropFirst(appRoot.path.count + 1)), url: url))
        }
        guard !files.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return files.sorted { $0.name < $1.name }
    }

    // MARK: 探す

    /// 型にはまる所の最初の位置
    func firstRange(of pattern: String) -> NSRange? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = code as NSString
        return regex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length))?.range
    }

    /// 型にはまる所の行の番号 (1 から。同じ行は 1 度だけ)
    func lines(matching pattern: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = code as NSString
        var found: [Int] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let line = lineNumber(match.range.location)
            if found.last != line { found.append(line) }
        }
        return found
    }

    /// 型の 1 つ目の組が取った文字列のすべて
    func captures(of pattern: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// name( で始まる呼び出しの、行の番号と、閉じかっこの後の文
    func calls(of name: String) -> [(line: Int, after: String)] {
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#)
        let ns = code as NSString
        let utf16 = Array(code.utf16)
        var found: [(line: Int, after: String)] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            // 開きかっこから、対になる閉じかっこを探す (文字列の中身は除いてあるので、かっこだけを数える)
            var depth = 0
            var end = utf16.count
            for i in (match.range.location + match.range.length - 1)..<utf16.count {
                if utf16[i] == 0x28 { depth += 1 }
                if utf16[i] == 0x29 {
                    depth -= 1
                    if depth == 0 { end = i + 1; break }
                }
            }
            found.append((lineNumber(match.range.location), ns.substring(from: min(end, ns.length))))
        }
        return found
    }

    private func lineNumber(_ location: Int) -> Int {
        (code as NSString).substring(to: location).components(separatedBy: "\n").count
    }

    // MARK: 除く

    /// 注釈 (// と、入れ子にできる /* */) と、文字列の中身 ("…"・\"\"\"…\"\"\"・#"…"#) を除く。
    /// 文字列に埋め込んだ式 \( … ) は式として残す。改行は残すので、行の番号は元と同じ
    static func strip(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        scanCode(chars, &i, &out, untilParen: false)
        return out
    }

    /// 文を写す。untilParen のときは、対になる閉じかっこ (埋め込んだ式の終わり) で止まる (かっこは写さない)
    private static func scanCode(_ c: [Character], _ i: inout Int, _ out: inout String, untilParen: Bool) {
        var depth = 0
        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if ch == "/" && next == "/" {
                while i < c.count && c[i] != "\n" { i += 1 }
                continue
            }
            if ch == "/" && next == "*" {
                var level = 0
                while i < c.count {
                    if c[i] == "/" && i + 1 < c.count && c[i + 1] == "*" {
                        level += 1
                        i += 2
                    } else if c[i] == "*" && i + 1 < c.count && c[i + 1] == "/" {
                        level -= 1
                        i += 2
                        if level == 0 { break }
                    } else {
                        if c[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                }
                out.append(" ")
                continue
            }
            if ch == "\"" || ch == "#" {
                var hashes = 0
                var j = i
                while j < c.count && c[j] == "#" { hashes += 1; j += 1 }
                if j < c.count && c[j] == "\"" {
                    i = j
                    scanString(c, &i, &out, hashes: hashes)
                    continue
                }
            }
            if untilParen {
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    if depth == 0 { i += 1; return }
                    depth -= 1
                }
            }
            out.append(ch)
            i += 1
        }
    }

    /// 文字列を "" に置き換える (埋め込んだ式と改行は残す)。i は始めの " を指している
    private static func scanString(_ c: [Character], _ i: inout Int, _ out: inout String, hashes: Int) {
        let multi = i + 2 < c.count && c[i + 1] == "\"" && c[i + 2] == "\""
        i += multi ? 3 : 1
        out.append("\"")
        let closing = Array(String(repeating: "\"", count: multi ? 3 : 1) + String(repeating: "#", count: hashes))
        func at(_ k: Int, _ s: [Character]) -> Bool {
            k + s.count <= c.count && Array(c[k..<(k + s.count)]) == s
        }
        let escape = Array("\\" + String(repeating: "#", count: hashes))
        while i < c.count {
            if at(i, closing) {
                i += closing.count
                out.append("\"")
                return
            }
            if at(i, escape) {
                i += escape.count
                if i < c.count && c[i] == "(" {
                    i += 1
                    out.append("\\(")
                    scanCode(c, &i, &out, untilParen: true)
                    out.append(")")
                } else if i < c.count {
                    if c[i] == "\n" { out.append("\n") }
                    i += 1
                }
                continue
            }
            if c[i] == "\n" { out.append("\n") }
            i += 1
        }
    }
}

private extension String {
    func hasMatch(_ pattern: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) != nil
    }
}
