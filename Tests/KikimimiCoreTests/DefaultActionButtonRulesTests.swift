import Foundation
import XCTest

/// Return キーで押せるボタン (`.keyboardShortcut(.defaultAction)` が付く Button) の action の書き方を、ソースの書き方で見る。
///
/// 決まり: action は、引数の無い関数を 1 つ呼ぶだけにする。通す形は `{ save() }` と `{ chat.cancelResearchOn() }` のような
/// `{ 名前() }`・`{ 何か.名前() }` だけ。複数の文・if・引数つきの呼び出し・値の代入は落とす。
///
/// なぜか: 行を直す画面 (LineEditSheet.swift) で、「保存」ボタンの action が、body の中で入力欄の字から作った let を
/// クロージャで掴んでいた時に、マウスで押すと正しく保存され、Return キーで押すと一部が保存されない食い違いが起きた。
/// action を `{ save() }` にして、save() の中で、押した時の @State から計算し直す形にすると、起きなくなった
/// (なぜ Return の時だけ古い値だったかは、突き止めていない)。引数なしに限るのは、引数が、body で作った値を渡す入口になるから。
///
/// 直し方: action の中身を、その型のメソッドに出し、押した時にメソッドの中で @State と model から読み直す。
/// どうしても引数なしにできない時は、exceptions に、ファイル名・ボタンの鍵・理由を載せる。
///
/// 書き方しか見ないので、次の形は見逃す: 引数なしの関数の中で、body が @State に書いておいた値を読む形・
/// onSubmit (入力欄で Return を押した時) で同じ事をする形・.defaultAction を別の名前の修飾子で包んで付ける形。
/// 注釈と文字列の中身は、TranscriptListRulesTests の SwiftCode で除いてから見る
final class DefaultActionButtonRulesTests: XCTestCase {
    static let reasonsAt = "See the notes at the top of DefaultActionButtonRulesTests.swift for the reasons"

    /// 決まりに合わなくてよいボタン (理由つき)。file は Sources/Kikimimi からの相対、key は Button の L("…") の鍵。今は無い
    static let exceptions: [(file: String, key: String, reason: String)] = []

    /// 今のコードに在る .defaultAction の数の下限 (走査が何も見ていない事に気づくため。2026-11-26 に数えて 6)
    static let minimumCount = 6

    func testDefaultActionButtonsOnlyCallOneFunctionWithoutArguments() throws {
        var sources: [(name: String, text: String)] = []
        for file in try SwiftCode.appFiles() {
            sources.append((file.name, try String(contentsOf: file.url, encoding: .utf8)))
        }
        XCTAssertEqual(DefaultActionScan.problems(in: sources, minimum: Self.minimumCount, exceptions: Self.exceptions), [],
                       "A button with .keyboardShortcut(.defaultAction) must have an action that only calls one function "
                           + "without arguments, like `{ save() }`. Move the work into a method of the view, and read the "
                           + "@State and model values inside that method when it is pressed. \(Self.reasonsAt)")
    }

    // MARK: 決まりそのものの見張り

    func testScanAcceptsOneCallWithoutArguments() {
        XCTAssertEqual(Self.problems("Button(L(\"Save\")) { save() }\n    .keyboardShortcut(.defaultAction)"), [])
        XCTAssertEqual(Self.problems("Button(L(\"Save\")) { model.save() }\n.disabled(x)\n.keyboardShortcut(.defaultAction)"), [])
        XCTAssertEqual(Self.problems("Button(L(\"Save\"), action: { save() })\n.keyboardShortcut(.defaultAction)"), [])
        XCTAssertEqual(Self.problems("Button { save() } label: { Text(\"a\") }\n.keyboardShortcut(.defaultAction)"), [])
    }

    func testScanRejectsOtherActions() {
        let rejected = [
            "Button(L(\"Save\")) { if ready { save() } }",
            "Button(L(\"Save\")) { save(draft) }",
            "Button(L(\"Save\")) {\n    let a = b\n    save()\n}",
            "Button(L(\"Save\")) { save(); close() }",
            "Button(L(\"Save\")) { done = true }",
            "Button(L(\"Save\"), action: save)"
        ]
        for code in rejected {
            let found = Self.problems(code + "\n.keyboardShortcut(.defaultAction)")
            XCTAssertEqual(found.count, 1, "should be rejected: \(code)")
            XCTAssertTrue(found.first?.hasPrefix("x.swift:") ?? false, "the message must name the file and line: \(found)")
        }
    }

    func testScanFailsWhenItCannotReadOrFindsNothing() {
        // Button が見つからない
        XCTAssertEqual(Self.problems("Text(\"a\")\n.keyboardShortcut(.defaultAction)").count, 1)
        // クロージャの終わりが分からない
        XCTAssertEqual(Self.problems("Button(L(\"Save\")) { save()\n.keyboardShortcut(.defaultAction)").count, 1)
        // 1 つも見つからない
        XCTAssertEqual(DefaultActionScan.problems(in: [("x.swift", "Button(L(\"Save\")) { save() }")], minimum: 1, exceptions: []).count, 1)
        // 例外の一覧に載せたボタンは通る
        let code = "Button(L(\"Go back\")) { if a { b() } }\n.keyboardShortcut(.defaultAction)"
        XCTAssertEqual(DefaultActionScan.problems(in: [("x.swift", code)], minimum: 1,
                                                  exceptions: [("x.swift", "Go back", "test")]), [])
    }

    private static func problems(_ code: String) -> [String] {
        DefaultActionScan.problems(in: [("x.swift", code)], minimum: 1, exceptions: [])
    }
}

/// .defaultAction の付く Button を探して、action の形を見る
enum DefaultActionScan {
    /// 見つけた 1 か所
    struct Found {
        let line: Int
        /// Button の L("…") の鍵 (取れない時は "")
        let key: String
        /// action の中身 (取れない時は nil)
        let action: String?
        /// 決まりに合わない・読めない時の理由
        let problem: String?
    }

    /// 決まりに合わない所の文 (無ければ空)。見つけた数が minimum より少ない時も、その文を返す
    static func problems(in sources: [(name: String, text: String)], minimum: Int,
                         exceptions: [(file: String, key: String, reason: String)]) -> [String] {
        var out: [String] = []
        var count = 0
        for source in sources {
            for found in scan(source.text) {
                count += 1
                guard let problem = found.problem else { continue }
                if exceptions.contains(where: { $0.file == source.name && $0.key == found.key }) { continue }
                out.append("\(source.name):\(found.line): \(problem)")
            }
        }
        if count < minimum {
            out.append("found only \(count) .keyboardShortcut(.defaultAction) (expected at least \(minimum); did the files move or the scan break?)")
        }
        return out
    }

    /// 1 つのファイルの文から、.defaultAction の所をすべて探す
    static func scan(_ text: String) -> [Found] {
        let code = SwiftCode(name: "", text: text).code
        let rawLines = text.components(separatedBy: "\n")
        let ns = code as NSString
        let u = Array(code.utf16)
        let shortcut = try! NSRegularExpression(pattern: #"\.keyboardShortcut\s*\(\s*\.defaultAction\b"#)
        let button = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])Button\s*[({]"#)
        let buttons = button.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        var found: [Found] = []
        for match in shortcut.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let at = match.range.location
            let line = lineNumber(ns, at)
            // いちばん近い、上の Button
            guard let start = buttons.last(where: { $0.location < at }) else {
                found.append(Found(line: line, key: "", action: nil, problem: "could not read: no Button( above .keyboardShortcut(.defaultAction)"))
                continue
            }
            let buttonLine = lineNumber(ns, start.location)
            let key = keyOf(rawLines, buttonLine)
            let where_ = "the Button at line \(buttonLine)" + (key.isEmpty ? "" : " (\"\(key)\")")
            guard let (action, end) = action(u, opener: start.location + start.length - 1) else {
                found.append(Found(line: line, key: key, action: nil, problem: "could not read the action of \(where_)"))
                continue
            }
            // Button の終わりから .keyboardShortcut までが、修飾子のつながりである事 (別の部品の物を拾っていない事)
            guard isModifierChain(u, from: end, to: at) else {
                found.append(Found(line: line, key: key, action: action,
                                   problem: "could not read: .keyboardShortcut(.defaultAction) does not seem to belong to \(where_)"))
                continue
            }
            let ok = action.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*\s*\(\s*\)$"#, options: .regularExpression) != nil
            found.append(Found(line: line, key: key, action: action,
                               problem: ok ? nil : "the action of \(where_) must only call one function without arguments, "
                                   + "like `{ save() }`; it is `{\(action)}`"))
        }
        return found
    }

    /// Button の action の中身と、Button の終わりの位置。opener は Button の後の ( か {
    private static func action(_ u: [UInt16], opener: Int) -> (String, Int)? {
        if u[opener] == brace {
            // Button { 動き } label: { … }
            guard let close = matching(u, opener) else { return nil }
            var end = close + 1
            let rest = skipSpaces(u, end)
            if hasWord(u, rest, "label") {
                var k = skipSpaces(u, rest + 5)
                guard k < u.count, u[k] == colon else { return nil }
                k = skipSpaces(u, k + 1)
                guard k < u.count, u[k] == brace, let labelClose = matching(u, k) else { return nil }
                end = labelClose + 1
            }
            return (text(u, opener + 1, close), end)
        }
        guard let closeParen = matching(u, opener) else { return nil }
        let after = skipSpaces(u, closeParen + 1)
        if after < u.count, u[after] == brace {
            // Button(…) { 動き }
            guard let close = matching(u, after) else { return nil }
            return (text(u, after + 1, close), close + 1)
        }
        // Button(…, action: { 動き })
        var depth = 0
        var i = opener
        while i < closeParen {
            let c = u[i]
            if c == paren || c == brace || c == bracket { depth += 1 }
            if c == closeP || c == closeB || c == closeK { depth -= 1 }
            if depth == 1, hasWord(u, i, "action"), i > 0, !isWordChar(u[i - 1]) {
                var k = skipSpaces(u, i + 6)
                guard k < u.count, u[k] == colon else { i += 1; continue }
                k = skipSpaces(u, k + 1)
                guard k < closeParen, u[k] == brace, let close = matching(u, k) else { return nil }
                return (text(u, k + 1, close), closeParen + 1)
            }
            i += 1
        }
        return nil
    }

    /// from から to までが、空白で始まり . の修飾子が続くだけか (かっこの数が合っているか)
    private static func isModifierChain(_ u: [UInt16], from: Int, to: Int) -> Bool {
        guard from <= to else { return false }
        let first = skipSpaces(u, from)
        guard first == to || (first < to && u[first] == dot) else { return false }
        var depth = 0
        for i in from..<to {
            let c = u[i]
            if c == paren || c == brace || c == bracket { depth += 1 }
            if c == closeP || c == closeB || c == closeK {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// 開きかっこ ( { [ の位置から、対になる閉じかっこの位置 (文字列の中身は除いてあるので、かっこだけを数える)
    private static func matching(_ u: [UInt16], _ open: Int) -> Int? {
        var depth = 0
        for i in open..<u.count {
            let c = u[i]
            if c == paren || c == brace || c == bracket { depth += 1 }
            if c == closeP || c == closeB || c == closeK {
                depth -= 1
                if depth == 0 { return u[open] == paren && c == closeP || u[open] == brace && c == closeB
                    || u[open] == bracket && c == closeK ? i : nil }
            }
        }
        return nil
    }

    /// 元の文の、その行の L("…") の鍵
    private static func keyOf(_ rawLines: [String], _ line: Int) -> String {
        guard line - 1 < rawLines.count else { return "" }
        let raw = rawLines[line - 1] as NSString
        let regex = try! NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)""#)
        guard let m = regex.firstMatch(in: raw as String, range: NSRange(location: 0, length: raw.length)) else { return "" }
        return raw.substring(with: m.range(at: 1))
    }

    private static func lineNumber(_ ns: NSString, _ location: Int) -> Int {
        ns.substring(to: location).components(separatedBy: "\n").count
    }

    private static func text(_ u: [UInt16], _ from: Int, _ to: Int) -> String {
        String(decoding: u[from..<to], as: UTF16.self)
    }

    private static func skipSpaces(_ u: [UInt16], _ from: Int) -> Int {
        var i = from
        while i < u.count, u[i] == 0x20 || u[i] == 0x0A || u[i] == 0x09 || u[i] == 0x0D { i += 1 }
        return i
    }

    private static func hasWord(_ u: [UInt16], _ at: Int, _ word: String) -> Bool {
        let w = Array(word.utf16)
        guard at + w.count <= u.count, Array(u[at..<(at + w.count)]) == w else { return false }
        return at + w.count == u.count || !isWordChar(u[at + w.count])
    }

    private static func isWordChar(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    private static let paren: UInt16 = 0x28
    private static let closeP: UInt16 = 0x29
    private static let brace: UInt16 = 0x7B
    private static let closeB: UInt16 = 0x7D
    private static let bracket: UInt16 = 0x5B
    private static let closeK: UInt16 = 0x5D
    private static let colon: UInt16 = 0x3A
    private static let dot: UInt16 = 0x2E
}
