import XCTest
@testable import KikimimiCore

// でたらめな入力を、たくさん入れてみる試験 (モンキーテスト) の見本。
//
// ねらい: 人が思いつく例だけでなく、「ふつうは来ない値」(とても大きい数・空・壊れた文・長い文) を
// 機械に作らせて、落ちる所・止まる所・行って戻らない所を見つける。
//
// 新しい試験を足す時は、下の 3 つの形のどれかをまねる (どれも `monkey(…, make:, check:)` を呼ぶだけ):
//   形 1「落ちない」        どんな入力でも、関数が戻ってくる (落ちると、試験の実行ごと止まる)
//   形 2「行って戻る」      書いて読むと、元と同じになる
//   形 3「時間の内に終わる」 入力が長くても、決めた秒数の内に戻ってくる
//
// 失敗の読み方:
//   - 決まりが破れた時: 失敗の文に、試験の名前・種 (seed)・回の番号・入力が出る。
//   - 落ちた時 (実行ごと止まる): 最後に試していた入力が、一時フォルダの `kikimimi-monkey-last.txt` に残る
//     (場所は `MonkeyTrail.url`。`cat "$TMPDIR/kikimimi-monkey-last.txt"`)。
//   - 同じ入力をもう 1 度作る: `KIKIMIMI_MONKEY_SEED=<種> swift test --filter MonkeyTests/<試験の名前>`
//   - 手元で長く回す (ゲリラ的に試す時): `KIKIMIMI_MONKEY_ROUNDS=5000 swift test --filter MonkeyTests`
//
// 決まり: 乱数は、必ず `Monkey` (種を決めた乱数) から取る。`Int.random(in:)` をそのまま使うと、
// 失敗した入力を、もう 1 度作れない。

// MARK: - 道具 (ほかの試験からも使う)

/// 種を決めた乱数 (SplitMix64)。同じ種なら、いつも同じ並びになる。
/// 中身は KikimimiCore の `SeededRandom` (画面を触る確認 `--selftest-monkey` も、同じ物を使う)
typealias Monkey = SeededRandom

/// よく落ちる原因になる値の集まり。試験ごとに、ここから選ぶ (足りない値は、ここへ足す)。
/// 数と文のかけらは、KikimimiCore の `HostileValues` に在る (画面を触る確認も使うので、そちらへ足す)
enum MonkeyPool {
    /// 秒数・長さなどの、端の値
    static var doubles: [Double] { HostileValues.doubles }

    /// JSON に書ける数だけ (無限大と NaN は、JSON に書けない)
    static var finiteDoubles: [Double] { doubles.filter(\.isFinite) }

    /// 文のかけら。空・空白・改行の仲間・区切りの記号・絵文字・向きを変える印・とても長い文
    static var textFragments: [String] { HostileValues.textFragments }

    /// HTML のかけら。閉じないタグ・題名・注釈・script・文字参照・タグの中の `<`
    static let markupFragments: [String] = [
        "<", ">", "</", "<title>", "</title>", "</title >", "<TITLE a=1>", "<titlex>", "<title", "</title",
        "<!--", "-->", "<script>", "</script>", "<script", "<style>", "</style>", "<p>", "</p>", "<br>", "<br/>",
        "<td>", "<a href=\"x\">", "<a b", "&", "&amp;", "&lt;", "&#12354;", "&#x1F600;", "&#0;", "&#xD800;",
        "&unknown;", "\n", " ", "text", "漢字", "😀", "<svg><title>s</title></svg>", "<img src=\"a<b\">"
    ]

    /// URL のかけら。名前・利用者名・ポート・IP の直書き・内の名前・句読点
    static let urlFragments: [String] = [
        "https://", "http://", "HTTPS://", "ftp://", "user:pw@", "@", "example.com", "a.co", "news.example.org",
        ":443", ":8080", ":0", ":", "[::1]", "127.0.0.1", "0x7f.1", "localhost", "a.local", "b.internal", "xn--p1ai",
        "/path", "/", "?q=1", "#frag", "%2e", "%40", ".", "..", ")", "(", "]", "[", ",", "'", " ", "\n",
        "日本.jp", "a_b.com", "-a.com", "a.com.", "😀"
    ]

    /// JSON のかけら。名前 (鍵) と文字列の中の、そのままの制御文字・壊れた逃がし (`\\u` の続き)・とても大きい数・UTF-8 でないバイト
    static let jsonFragments: [[UInt8]] = [
        "{", "}", "[", "]", "\"", "\\", "\\u", "\\u0001", "\\uD800", "\\uDC00", "\\uZZZZ", "\\x", ":", ",", " ",
        "0", "-", "1e999", "-1e-999", "1.5", "true", "null", "a", "id", "duration", "é", "😀",
        "\u{0}", "\u{1}", "\u{1c}", "\u{1f}", "\t", "\n", "\r", "\u{7f}"
    ].map { Array($0.utf8) } + [[0xFF], [0xC0, 0x80], [0xE3, 0x81], [0xED, 0xA0, 0x80]]

    /// チャットの答えに出る動作の印のかけら (閉じない印・入れ子・大文字・空の値)
    static let chatMarkerFragments: [String] = [
        "[[", "]]", "[", "]", "set ", "SET ", "set:", "set\t", "open", "open settings", "=", "==", " ", "\n",
        "on", "off", "true", "no", "ja", "en", "ko", "xx", "1", "-1", "1e300", "useVAD", "showNotes",
        "translationLanguage", "uiLanguage", "modelID", "llmModelID", "unknownKey", "text", "漢字", "😀",
        // 印を取り除くと、前後がつながって新しい印になる形 (`[[se` + `[[set a=b]]` + `t c=d]]`)
        "[[se", "t showNotes=on]]", "[[op", "en]]", "[[set useVAD=off]]"
    ]
}

/// 落ちた時のための足あと。危ない呼び出しの前に、何を試していたかを 1 行だけ書いておく
enum MonkeyTrail {
    static let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kikimimi-monkey-last.txt")

    static func mark(_ name: String, seed: UInt64, round: Int, input: String) {
        let line = "\(name) seed \(seed) round \(round) input \(input.prefix(400))\n"
        try? Data(line.utf8).write(to: url)
    }
}

/// 裏で走らせた仕事の答えを受け取る入れ物 (`finishes(within:)` の仕事から、答えを持ち帰るため)。
/// 書くのは裏の仕事、読むのは終わるのを待った後だけなので、同時には触らない
final class MonkeyBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension XCTestCase {
    /// でたらめな入力を作って (make)、決まりを見る (check)。
    /// check は、決まりが守られていれば nil、破れていれば、その訳の文を返す。
    /// - seeds: 種。環境変数 `KIKIMIMI_MONKEY_SEED` が在れば、その 1 つだけ
    /// - rounds: 種ごとの回の数。環境変数 `KIKIMIMI_MONKEY_ROUNDS` が在れば、その数
    func monkey<Input>(_ name: String, seeds: [UInt64] = [1, 2, 3], rounds: Int = 200,
                       file: StaticString = #filePath, line: UInt = #line,
                       make: (inout Monkey) -> Input,
                       describe: (Input) -> String = { String(describing: $0) },
                       check: (Input) throws -> String?) {
        let environment = ProcessInfo.processInfo.environment
        let useSeeds = environment["KIKIMIMI_MONKEY_SEED"].flatMap { UInt64($0) }.map { [$0] } ?? seeds
        let useRounds = environment["KIKIMIMI_MONKEY_ROUNDS"].flatMap { Int($0) } ?? rounds
        for seed in useSeeds {
            var rng = Monkey(seed: seed)
            for round in 0..<useRounds {
                let input = make(&rng)
                let shown = describe(input)
                MonkeyTrail.mark(name, seed: seed, round: round, input: shown)
                do {
                    if let broken = try check(input) {
                        XCTFail("\(name): \(broken) (seed \(seed), round \(round), input \(shown.prefix(400)))",
                                file: file, line: line)
                        return
                    }
                } catch {
                    XCTFail("\(name): threw \(error) (seed \(seed), round \(round), input \(shown.prefix(400)))",
                            file: file, line: line)
                    return
                }
            }
        }
    }

    /// work が、seconds 秒の内に終わるかを見る。終わらなければ false を返す
    /// (work は裏で走り続けるので、呼んだ試験は、そこで失敗にして終わる)
    func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }
}

// MARK: - 見本の試験

final class MonkeyTests: XCTestCase {
    // 形 1「落ちない」: 時刻の文字は、どんな秒数でも作れる (保存ファイルに、変な数が入っていても落ちない)
    func testTimeFormatTakesAnySeconds() {
        monkey("time format", rounds: 100,
               make: { rng in rng.pick(MonkeyPool.doubles) },
               check: { seconds in
                   let short = TimeFormat.short(seconds)
                   let srt = TimeFormat.srt(seconds)
                   let vtt = TimeFormat.vtt(seconds)
                   if short.isEmpty { return "short is empty" }
                   if srt.range(of: #"^\d{2,}:\d{2}:\d{2},\d{3}$"#, options: .regularExpression) == nil {
                       return "srt has an unexpected shape: \(srt)"
                   }
                   if vtt.range(of: #"^\d{2,}:\d{2}:\d{2}\.\d{3}$"#, options: .regularExpression) == nil {
                       return "vtt has an unexpected shape: \(vtt)"
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: 保存ファイルから読んだ、変な区間 (終わりが始まりより前・とても大きい時刻・変な文) でも、
    // どの書き出しの形も作れる。区間は、JSON から読んで作る (作る時の直しを通らない値を入れるため)
    func testExportTakesHostileSegments() {
        monkey("export", rounds: 60,
               make: { rng -> String in
                   var items: [String] = []
                   for _ in 0..<rng.int(0...6) {
                       let start = rng.pick(MonkeyPool.finiteDoubles)
                       let end = rng.pick(MonkeyPool.finiteDoubles)
                       let text = rng.text(from: MonkeyPool.textFragments, pieces: 0...3)
                       let translation = rng.int(0...2) == 0 ? "null" : Self.jsonString(rng.text(from: MonkeyPool.textFragments, pieces: 0...2))
                       items.append("{\"id\":\"\(UUID().uuidString)\",\"start\":\(start),\"end\":\(end),"
                           + "\"text\":\(Self.jsonString(text)),\"translation\":\(translation)}")
                   }
                   return "[" + items.joined(separator: ",") + "]"
               },
               describe: { json in String(json.prefix(400)) },
               check: { json in
                   let segments = try LibraryStore.decoder().decode([TranscriptSegment].self, from: Data(json.utf8))
                   let transcript = Transcript(sourceName: "monkey.wav", segments: segments, language: "en",
                                               translationLanguage: "ja")
                   for format in ExportFormat.allCases {
                       for content in ExportContent.available(for: format) {
                           _ = Exporter.render(transcript, as: format, content: content)
                       }
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: SRT・WebVTT は、どんな文でも、書き出す行の数だけ字幕が在り (時刻の印 `-->` は時刻の行にだけ)、
    // 字幕の 1 枚の中に空の行が無い (区間の文の `-->` や空の行で、字幕の区切りが壊れない。2026-11-29 に足した)
    func testSubtitlesKeepOneCuePerRow() {
        monkey("subtitle cues", rounds: 150,
               make: { rng -> Transcript in
                   let fragments = MonkeyPool.textFragments.filter { $0.count < 100 } + ["--", ">", "-->", "\n\n", " \n ", "\r", "->"]
                   var segments = (0..<rng.int(0...5)).map { i in
                       TranscriptSegment(start: Double(i), end: Double(i) + 0.5, text: rng.text(from: fragments, pieces: 0...6))
                   }
                   for i in segments.indices where rng.int(0...1) == 0 {
                       segments[i].translation = rng.text(from: fragments, pieces: 0...4)
                   }
                   return Transcript(sourceName: "m", segments: segments, language: "en", translationLanguage: "ja")
               },
               describe: { t in t.segments.map { "\($0.text.debugDescription)/\(($0.translation ?? "nil").debugDescription)" }
                   .joined(separator: ", ") },
               check: { transcript in
                   for content in ExportContent.allCases {
                       let rows = Exporter.rows(transcript, content, target: "ja").count
                       if let broken = Self.cueProblem(Exporter.srt(transcript, content: content, target: "ja"), rows: rows, srt: true) {
                           return "srt \(content): \(broken)"
                       }
                       if let broken = Self.cueProblem(Exporter.vtt(transcript, content: content, target: "ja"), rows: rows, srt: false) {
                           return "vtt \(content): \(broken)"
                       }
                   }
                   return nil
               })
    }

    /// 字幕の形の崩れ (無ければ nil)。字幕の 1 枚は「(SRT は番号の行) 時刻の行 文の行… 空の行」。
    /// 空の行 (空白だけの行も) は、字幕を読む道具が区切りと見るので、1 枚の中に在ると、そこで切れる
    static func cueProblem(_ text: String, rows: Int, srt: Bool) -> String? {
        var lines = text.components(separatedBy: CharacterSet.newlines)
        if !srt {
            guard lines.first == "WEBVTT" else { return "no WEBVTT header" }
            lines.removeFirst()
        }
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        var cues = 0
        var i = 0
        while i < lines.count {
            if blank(lines[i]) { i += 1; continue }
            if srt {
                guard lines[i] == String(cues + 1) else { return "line \(i) is \(lines[i].debugDescription), not the number \(cues + 1)" }
                i += 1
            }
            guard i < lines.count, lines[i].contains("-->") else { return "no time line for cue \(cues + 1)" }
            cues += 1
            i += 1
            while i < lines.count, !blank(lines[i]) {
                if lines[i].contains("-->") { return "cue \(cues) has --> in its text" }
                i += 1
            }
        }
        return cues == rows ? nil : "\(cues) cues for \(rows) rows"
    }

    // 形 2「行って戻る」: ライブラリの日時は、書いて読むと、元とまったく同じ値になる
    func testLibraryDateRoundTrips() {
        monkey("library date", rounds: 300,
               make: { rng -> Double in
                   // 1970 年から 2100 年ごろまでの、秒より細かい所の在る時刻
                   let whole = Double(rng.int(-978_307_200...3_124_224_000))
                   let fraction = rng.pick([0, 0.5, 0.123_456, 1e-5, 0.999_999, Double(rng.int(0...999_999)) / 1_000_000])
                   return whole + fraction
               },
               check: { t in
                   let date = Date(timeIntervalSinceReferenceDate: t)
                   let text = LibraryDate.string(from: date)
                   guard let back = LibraryDate.date(from: text) else { return "could not read back \(text)" }
                   return back == date ? nil : "\(text) reads back as \(back.timeIntervalSinceReferenceDate), not \(t)"
               })
    }

    // 形 1「落ちない」: 日時でない文を読んでも、落ちずに nil か日時を返す
    func testLibraryDateTakesAnyText() {
        let fragments = ["2026", "-11-", "12", "T", "10:20:30", "Z", ".", "123456789012345678901234567890",
                         "e5", "+09:00", "٣", "１２", "\u{200F}", " ", "T.", "..", "Z.5Z", "", "-", ":"]
        monkey("library date text", rounds: 300,
               make: { rng in rng.text(from: fragments, pieces: 0...8) },
               check: { text in
                   _ = LibraryDate.date(from: text)
                   return nil
               })
    }

    // 形 3「時間の内に終わる」: Web ページの読み取りは、わざと作った長いページでも、15 秒の内に終わる
    // (読む長さの上限いっぱいの、閉じないタグ・閉じない題名・閉じない注釈)
    func testWebPageTextFinishesOnHostilePages() {
        let limit = WebPageText.maxHTMLLength
        let cases: [(name: String, html: String)] = [
            ("only <", String(repeating: "<", count: limit)),
            ("unclosed titles", String(repeating: "<title>", count: limit / 7)),
            ("unclosed comments", String(repeating: "<!--", count: limit / 4)),
            ("unclosed scripts", String(repeating: "<script>", count: limit / 8)),
            ("ampersands", String(repeating: "&", count: limit)),
            ("open tags with text", String(repeating: "<a b", count: limit / 4))
        ]
        for item in cases {
            let html = item.html
            MonkeyTrail.mark("web page text", seed: 0, round: 0, input: item.name)
            // 手元 (M 系の Mac、試験の組み立て) では、いちばん遅い "only <" で 2 秒ほど。直す前は、3.2 万字で 6.5 秒
            // (長さの 2 乗) だったので、上限の長さでは何時間もかかる。CI の遅い Mac でも余るように 15 秒にする
            let ok = finishes(within: 15) { _ = WebPageText.extract(html: html) }
            XCTAssertTrue(ok, "WebPageText.extract did not finish in 15 s for: \(item.name) (\(html.count) characters)")
            if !ok { return }
        }
    }

    // MARK: - 見張りの試験 (2026-11-28 に足した)

    // 形 1「落ちない」: 時刻の文字は、範囲の外の値を端の値にする (無限大・とても大きい値は上限、負の値・NaN は 0)
    func testTimeRangeClampsAnySeconds() {
        monkey("time range", rounds: 100,
               make: { rng in rng.pick(MonkeyPool.doubles) },
               check: { seconds in
                   let clamped = TimeRange.clamped(seconds)
                   if !(clamped >= 0 && clamped <= TimeRange.maxSeconds) { return "clamped to \(clamped)" }
                   if seconds >= 0, seconds <= TimeRange.maxSeconds, clamped != seconds { return "changed \(seconds) to \(clamped)" }
                   if seconds > TimeRange.maxSeconds, TimeFormat.srt(seconds) != "99999:59:59,000" {
                       return "srt of a too large value is \(TimeFormat.srt(seconds))"
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: 保存ファイルの区間・長さに変な数が在っても、読み込んだ後は、どの時刻も使える範囲に入り、
    // 終わりは始まりより前にならない (読み込む所で 1 度だけ直す。LibraryStore.loadAll・load・loadVersion)
    func testLibraryStoreClampsHostileTimes() throws {
        let root = try Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        monkey("library times", rounds: 15,
               make: { rng -> String in
                   var items: [String] = []
                   for _ in 0..<rng.int(0...4) {
                       items.append("{\"id\":\"\(UUID().uuidString)\",\"start\":\(rng.pick(MonkeyPool.finiteDoubles)),"
                           + "\"end\":\(rng.pick(MonkeyPool.finiteDoubles)),\"text\":\"a\"}")
                   }
                   return "{\"sourceName\":\"m.wav\",\"segments\":[" + items.joined(separator: ",") + "],"
                       + "\"duration\":\(rng.pick(MonkeyPool.finiteDoubles)),\"elapsed\":\(rng.pick(MonkeyPool.finiteDoubles))}"
               },
               check: { transcriptJSON in
                   let id = UUID()
                   let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                   try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                   defer { try? FileManager.default.removeItem(at: folder) }
                   let version = UUID()
                   let document = "{\"formatVersion\":1,\"id\":\"\(id.uuidString)\",\"title\":\"m\",\"isRecording\":false,"
                       + "\"createdAt\":\"2026-11-28T10:00:00Z\",\"updatedAt\":\"2026-11-28T10:00:00Z\","
                       + "\"transcript\":\(transcriptJSON),\"versions\":[]}"
                   try Data(document.utf8).write(to: folder.appendingPathComponent("document.json"))
                   let versions = folder.appendingPathComponent("versions", isDirectory: true)
                   try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
                   let versionJSON = "{\"info\":{\"id\":\"\(version.uuidString)\",\"savedAt\":\"2026-11-28T10:00:00Z\","
                       + "\"label\":\"\",\"origin\":\"manual\"},\"transcript\":\(transcriptJSON),\"notes\":\"\"}"
                   try Data(versionJSON.utf8).write(to: versions.appendingPathComponent(version.uuidString + ".json"))
                   guard let one = store.load(id: id) else { return "load(id:) could not read the document" }
                   let all = store.loadAll().documents.filter { $0.id == id }
                   guard all.count == 1 else { return "loadAll read \(all.count) documents" }
                   let kept = try store.loadVersion(documentID: id, versionID: version)
                   for (name, t) in [("load", one.transcript), ("loadAll", all[0].transcript), ("loadVersion", kept.transcript)] {
                       if let broken = Self.timeProblem(in: t) { return "\(name): \(broken)" }
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: 保存ファイルに同じ ID の区間が在っても、読み込んだ後は、区間の ID がどれも違う
    // (読み込む所で 1 度だけ直す。LibraryStore.loadAll・load・loadVersion)。同じ ID のままだと、行を直す画面が
    // `Dictionary(uniqueKeysWithValues:)` で落ちた (2026-11-29、画面を触る確認 --selftest-monkey の種 3 で見つけた)。
    // 初めの区間の ID は変えない (訳のまとまり・直しの記録は、そちらを指したまま)。同じファイルなら、何度読んでも同じ ID
    func testLibraryStoreMakesSegmentIDsUnique() throws {
        let root = try Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        monkey("library segment ids", rounds: 15,
               make: { rng -> [UUID] in
                   let pool = (0..<rng.int(1...3)).map { _ in UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", rng.int(0...5)))! }
                   return (0..<rng.int(0...6)).map { _ in rng.pick(pool) }
               },
               describe: { ids in ids.map { String($0.uuidString.suffix(2)) }.joined(separator: " ") },
               check: { ids in
                   let items = ids.enumerated().map { i, id in
                       "{\"id\":\"\(id.uuidString)\",\"start\":\(i),\"end\":\(i + 1),\"text\":\"t\(i)\"}"
                   }
                   let transcriptJSON = "{\"sourceName\":\"m.wav\",\"segments\":[" + items.joined(separator: ",") + "],\"duration\":9,\"elapsed\":1}"
                   let id = UUID()
                   let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                   try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                   defer { try? FileManager.default.removeItem(at: folder) }
                   let version = UUID()
                   let document = "{\"formatVersion\":1,\"id\":\"\(id.uuidString)\",\"title\":\"m\",\"isRecording\":false,"
                       + "\"createdAt\":\"2026-11-28T10:00:00Z\",\"updatedAt\":\"2026-11-28T10:00:00Z\","
                       + "\"transcript\":\(transcriptJSON),\"versions\":[]}"
                   try Data(document.utf8).write(to: folder.appendingPathComponent("document.json"))
                   let versions = folder.appendingPathComponent("versions", isDirectory: true)
                   try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
                   let versionJSON = "{\"info\":{\"id\":\"\(version.uuidString)\",\"savedAt\":\"2026-11-28T10:00:00Z\","
                       + "\"label\":\"\",\"origin\":\"manual\"},\"transcript\":\(transcriptJSON),\"notes\":\"\"}"
                   try Data(versionJSON.utf8).write(to: versions.appendingPathComponent(version.uuidString + ".json"))
                   guard let one = store.load(id: id), let again = store.load(id: id) else { return "load(id:) could not read the document" }
                   let all = store.loadAll().documents.filter { $0.id == id }
                   guard all.count == 1 else { return "loadAll read \(all.count) documents" }
                   let kept = try store.loadVersion(documentID: id, versionID: version)
                   for (name, t) in [("load", one.transcript), ("loadAll", all[0].transcript), ("loadVersion", kept.transcript)] {
                       let read = t.segments.map(\.id)
                       if Set(read).count != read.count { return "\(name): the same segment ID twice" }
                       if read.count != ids.count { return "\(name): \(read.count) segments, not \(ids.count)" }
                       for (i, original) in ids.enumerated() where ids.firstIndex(of: original) == i && read[i] != original {
                           return "\(name): the first segment with an ID got a new ID"
                       }
                       if t.segments.map(\.text) != ids.indices.map({ "t\($0)" }) { return "\(name): the texts changed" }
                   }
                   if again.transcript.segments.map(\.id) != one.transcript.segments.map(\.id) { return "two loads give different IDs" }
                   return nil
               })
    }

    // 形 1「落ちない」: ライブラリのフォルダに、でたらめなバイト・正しい JSON の一部を壊した物が在っても、
    // 読み込みは落ちず、どのフォルダも「読めた」か「名前を変えてとっておいた」のどちらかになる
    func testLibraryLoadAllTakesBrokenFolders() throws {
        let root = try Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let good = try LibraryStore.encoder().encode(SavedDocument(
            title: "m", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.5),
            transcript: Transcript(sourceName: "m.wav", segments: [TranscriptSegment(start: 1, end: 2, text: "a")],
                                   duration: 3, elapsed: 1)))
        monkey("library load all", rounds: 12,
               make: { rng -> [Data] in
                   (0..<rng.int(1...4)).map { _ -> Data in
                       var bytes = [UInt8](good)
                       switch rng.int(0...4) {
                       case 0: // でたらめなバイト
                           return Data((0..<rng.int(0...64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                       case 1: // 途中で切る
                           return Data(bytes.prefix(rng.int(0...bytes.count)))
                       case 2: // 1 バイトを変える
                           let i = rng.int(0...(bytes.count - 1))
                           bytes[i] = UInt8(truncatingIfNeeded: rng.next())
                           return Data(bytes)
                       case 3: // 数を、とても大きい数にする
                           let text = String(decoding: bytes, as: UTF8.self)
                               .replacingOccurrences(of: "\"duration\" : 3", with: "\"duration\" : 1e300")
                           return Data(text.utf8)
                       default:
                           return Data(bytes)
                       }
                   }
               },
               describe: { files in files.map { String(decoding: $0.prefix(80), as: UTF8.self) }.joined(separator: " | ") },
               check: { files in
                   var ids: [UUID] = []
                   for data in files {
                       let id = UUID()
                       let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                       try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                       try data.write(to: folder.appendingPathComponent("document.json"))
                       ids.append(id)
                   }
                   defer { for id in ids { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) } }
                   let result = store.loadAll()
                   let read = Set(result.documents.map(\.id))
                   for id in ids {
                       let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
                       let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                       let asideFile = names.contains { $0.hasPrefix("document.unreadable-") }
                       let aside = result.setAside.contains { $0.deletingLastPathComponent().lastPathComponent == id.uuidString }
                       if read.contains(id) {
                           if aside || asideFile { return "\(id) was read and also set aside" }
                       } else if !(aside && asideFile && !names.contains("document.json")) {
                           return "\(id) was neither read nor set aside (files \(names))"
                       }
                   }
                   for document in result.documents {
                       if let broken = Self.timeProblem(in: document.transcript) { return broken }
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: ファイルから読む JSON は、見張り (JSONInput) を通せば、どんな壊れ方でも落ちずに、読めるか投げるか。
    // macOS 14 の JSONDecoder は、名前の中のそのままの制御文字 (`{"<0x01>":0}`) で、投げずに落ちる (2026-11-28 に見つけた)
    func testJSONInputTakesAnyBytes() {
        struct Probe: Decodable { var id: String?; var duration: Double?; var a: [Int]? }
        XCTAssertThrowsError(try JSONInput.decode([String: Int].self, from: Data([0x7B, 0x22, 0x01, 0x22, 0x3A, 0x30, 0x7D]),
                                                  with: JSONDecoder()))
        XCTAssertEqual(try JSONInput.decode([String: Int].self, from: Data(#"{"\u0001":0}"#.utf8), with: JSONDecoder()), ["\u{1}": 0])
        XCTAssertThrowsError(try JSONInput.decode([String: Int].self, from: Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x30, 0x7D]),
                                                  with: JSONDecoder()))
        monkey("json input", rounds: 400,
               make: { rng -> [UInt8] in
                   // 半分は、名前の形 (`{"` + かけら + `":0}`) にする (落ちるのは、名前の中だったので)
                   var bytes: [UInt8] = Array("{\"".utf8)
                   for _ in 0..<rng.int(0...12) { bytes += rng.pick(MonkeyPool.jsonFragments) }
                   if rng.int(0...1) == 0 { bytes += Array("\":0}".utf8) }
                   return bytes
               },
               describe: { bytes in String(decoding: bytes, as: UTF8.self).debugDescription },
               check: { bytes in
                   let data = Data(bytes)
                   _ = try? JSONInput.decode(Probe.self, from: data, with: JSONDecoder())
                   _ = try? JSONInput.decode([String: Double].self, from: data, with: LibraryStore.decoder())
                   _ = try? JSONInput.decode(SavedDocument.self, from: data, with: LibraryStore.decoder())
                   return nil
               })
    }

    // 形 2「行って戻る」: 正しい JSON は、見張り (JSONInput) が断らない (断ると、利用者の結果が「読めない」扱いになる)。
    // (1) アプリが書いた保存の形 (変な文・制御文字・絵文字・\u{0} を含む結果) は、必ず通り、元と同じに読める
    func testJSONInputPassesWhatTheAppWrites() {
        monkey("json input passes the library encoder", rounds: 150,
               make: { rng -> SavedDocument in
                   let fragments = MonkeyPool.textFragments + ["\u{1}", "\u{1f}", "\u{7f}", "\u{8}", "\u{c}", "/", "\u{FEFF}", "\u{10FFFF}"]
                   let segments = (0..<rng.int(0...4)).map { i in
                       TranscriptSegment(start: Double(i), end: Double(i) + 1, text: rng.text(from: fragments, pieces: 0...4),
                                         translation: rng.int(0...1) == 0 ? nil : rng.text(from: fragments, pieces: 0...3))
                   }
                   return SavedDocument(title: rng.text(from: fragments, pieces: 0...4),
                                        sourcePath: rng.int(0...1) == 0 ? nil : rng.text(from: fragments, pieces: 1...3),
                                        createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                        transcript: Transcript(sourceName: rng.text(from: fragments, pieces: 0...2), segments: segments))
               },
               describe: { document in document.title.prefix(80).debugDescription },
               check: { document in
                   let data = try LibraryStore.encoder().encode(document)
                   if let offset = JSONInput.problemOffset(in: data) { return "refused at byte \(offset)" }
                   var back = try JSONInput.decode(SavedDocument.self, from: data, with: LibraryStore.decoder())
                   back.notes = document.notes
                   return back == document ? nil : "reads back differently"
               })
    }

    // (2) JSONSerialization が書いた物 (でたらめな名前と値。逃がしの書き方が JSONEncoder と違う) も、必ず通り、元と同じに読める
    func testJSONInputPassesJSONSerialization() {
        monkey("json input passes JSONSerialization", rounds: 300,
               make: { rng -> [String: String] in
                   let fragments = MonkeyPool.textFragments + ["\u{1}", "\u{1f}", "\u{7f}", "\u{8}", "\u{c}", "/", "\u{FEFF}", "</", "\u{D7FF}", "\u{E000}"]
                   var object: [String: String] = [:]
                   for _ in 0..<rng.int(0...5) {
                       object[rng.text(from: fragments, pieces: 0...3)] = rng.text(from: fragments, pieces: 0...4)
                   }
                   return object
               },
               describe: { object in object.map { "\($0.key.prefix(30).debugDescription):\($0.value.prefix(30).debugDescription)" }
                   .joined(separator: ", ") },
               check: { object in
                   for options in [JSONSerialization.WritingOptions(), [.prettyPrinted, .sortedKeys], [.withoutEscapingSlashes]] {
                       let data = try JSONSerialization.data(withJSONObject: object, options: options)
                       if let offset = JSONInput.problemOffset(in: data) {
                           return "refused at byte \(offset) of \(String(decoding: data, as: UTF8.self).debugDescription.prefix(200))"
                       }
                       let back = try JSONInput.decode([String: String].self, from: data, with: JSONDecoder())
                       if back != object { return "reads back differently (options \(options.rawValue))" }
                   }
                   return nil
               })
    }

    // (3) 手で書いた正しい例: どの逃がしも、対になったサロゲート、文字列の外の空白 (タブ・改行・復帰)、頭の BOM
    func testJSONInputPassesHandWrittenValidJSON() throws {
        let cases: [(json: String, value: [String: String])] = [
            (#"{"a":"\" \\ \/ \b \f \n \r \t \u00e9 \u00E9"}"#, ["a": "\" \\ / \u{8} \u{c} \n \r \t é é"]),
            (#"{"\" \\ \/ \b \f \n \r \t \u00e9":"k"}"#, ["\" \\ / \u{8} \u{c} \n \r \t é": "k"]),
            (#"{"e":"\ud83d\ude00","\uD83D\uDE00":"\uD83D\uDE00x"}"#, ["e": "😀", "😀": "😀x"]),
            ("{\t\"a\"\n:\r\n\"b\" ,\r\"c\" : \"\\u0000\\u001f\"\t}\n", ["a": "b", "c": "\u{0}\u{1f}"]),
            ("\u{FEFF}{\"a\":\"b\"}", ["a": "b"]),
            ("{\"a\":\"é😀\u{7f}\u{10FFFF}\"}", ["a": "é😀\u{7f}\u{10FFFF}"]),
            ("{}", [:]),
            ("  {  }  ", [:])
        ]
        for item in cases {
            let data = Data(item.json.utf8)
            XCTAssertNil(JSONInput.problemOffset(in: data), "refused \(item.json.debugDescription)")
            XCTAssertEqual(try? JSONInput.decode([String: String].self, from: data, with: JSONDecoder()), item.value,
                           item.json.debugDescription)
        }
        // 数・真偽・null・入れ子 (文字列の外の物) も通る
        struct Other: Decodable, Equatable { var n: Double; var t: Bool; var f: Bool; var z: Int?; var a: [[Int]]; var o: [String: String] }
        let other = Data(#"{"n":-1.5e-3,"t":true,"f":false,"z":null,"a":[[1,2],[]],"o":{"b":"\/"}}"#.utf8)
        XCTAssertNil(JSONInput.problemOffset(in: other))
        XCTAssertEqual(try JSONInput.decode(Other.self, from: other, with: JSONDecoder()),
                       Other(n: -0.0015, t: true, f: false, z: nil, a: [[1, 2], []], o: ["b": "/"]))
    }

    // 形 2「行って戻る」: でたらめに作った結果を、保存の形で書いて読むと、元と同じ (メモは別のファイルなので除く)
    func testSavedDocumentRoundTrips() {
        monkey("saved document", rounds: 80,
               make: { rng -> SavedDocument in
                   let segments = (0..<rng.int(0...5)).map { _ -> TranscriptSegment in
                       let start = Double(rng.int(0...360_000)) / 8
                       return TranscriptSegment(start: start, end: start + Double(rng.int(0...80)) / 8,
                                                text: rng.text(from: MonkeyPool.textFragments, pieces: 0...3),
                                                translation: rng.int(0...1) == 0 ? nil
                                                    : rng.text(from: MonkeyPool.textFragments, pieces: 0...2),
                                                language: rng.pick([nil, "en", "ja"]))
                   }
                   let transcript = Transcript(sourceName: rng.text(from: MonkeyPool.textFragments, pieces: 0...2),
                                               segments: segments, language: rng.pick([nil, "en", "ja"]),
                                               model: rng.pick([nil, "small-q5_1"]),
                                               duration: Double(rng.int(0...360_000)) / 4,
                                               elapsed: Double(rng.int(0...10_000)) / 16,
                                               translationLanguage: rng.pick([nil, "ja", "ko"]))
                   let created = Date(timeIntervalSinceReferenceDate: Double(rng.int(-978_307_200...3_124_224_000))
                                      + Double(rng.int(0...999_999)) / 1_000_000)
                   return SavedDocument(title: rng.text(from: MonkeyPool.textFragments, pieces: 0...3),
                                        sourcePath: rng.int(0...1) == 0 ? nil : rng.text(from: MonkeyPool.textFragments, pieces: 1...2),
                                        isRecording: rng.int(0...1) == 0, createdAt: created,
                                        languageCode: rng.pick([nil, "en", "ja"]), vadSkippedAutomatically: rng.int(0...1) == 0,
                                        transcript: transcript)
               },
               describe: { document in "\(document.title.prefix(60)) / \(document.transcript.segments.count) segments" },
               check: { document in
                   let data = try LibraryStore.encoder().encode(document)
                   var back = try LibraryStore.decoder().decode(SavedDocument.self, from: data)
                   back.notes = document.notes
                   return back == document ? nil : "reads back differently"
               })
    }

    // 形 1「落ちない」: チャットの答えに、どんな印のかけらが在っても落ちない。出てくる案の鍵は、目録に在る鍵だけ。
    // 見える文に、閉じた動作の印 (`[[set …]]`・`[[open …]]`) が残らない (印を取り除いて、前後がつながってできた印も)
    func testChatActionParserTakesAnyText() {
        let catalog = ChatSettingsCatalog.items()
        let keys = Set(catalog.map(\.key))
        monkey("chat action parser", rounds: 300,
               make: { rng -> String in
                   let fragments = MonkeyPool.chatMarkerFragments + MonkeyPool.textFragments.prefix(8)
                   var text = rng.text(from: fragments, pieces: 0...14)
                   // 3 回に 1 回は、印のかけらで印をはさむ (取り除いた後に、前後がつながる形)
                   if rng.int(0...2) == 0 {
                       text = rng.pick(["[[se", "[[", "[[op", "[[s"]) + rng.pick(["[[set useVAD=off]]", "[[open]]"])
                           + rng.pick(["t showNotes=on]]", "en]]", "set showNotes=on]]", "et a=b]]"]) + text
                   }
                   return text
               },
               check: { text in
                   let result = ChatActionParser.parse(text, catalog: catalog)
                   if let key = result.proposals.map(\.key).first(where: { !keys.contains($0) }) { return "proposal for \(key)" }
                   if result.proposals.count > ChatActionParser.maxProposals { return "\(result.proposals.count) proposals" }
                   let left = ChatActionParser.findMarkers(in: result.visibleText)
                   if let marker = left.first { return "the visible text keeps \(marker.raw)" }
                   let blocked = ChatActionParser.parse(text, catalog: catalog, allowSettings: false)
                   if !blocked.proposals.isEmpty { return "proposals although settings are not allowed" }
                   _ = ChatActionParser.visiblePrefix(text)
                   return nil
               })
    }

    // 形 1「落ちない」: 変な URL のかけらをつないでも落ちない。isAllowed が通した URL は、https で、利用者名が無く、
    // ポートが無いか 443 で、名前に `:` が無い
    func testChatURLsTakeAnyText() {
        monkey("chat urls", rounds: 400,
               make: { rng in rng.text(from: MonkeyPool.urlFragments, pieces: 1...8) },
               check: { text in
                   let urls = ChatURLs.urls(in: text)
                   if urls.count > ChatURLs.maxCount { return "\(urls.count) URLs" }
                   for url in urls + [URL(string: text)].compactMap({ $0 }) where ChatURLs.isAllowed(url) {
                       if url.scheme?.lowercased() != "https" { return "allowed \(url) (scheme)" }
                       if url.user != nil || url.password != nil { return "allowed \(url) (user)" }
                       if let port = url.port, port != 443 { return "allowed \(url) (port)" }
                       if url.host?.contains(":") != false { return "allowed \(url) (host)" }
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: 直した文を整えるのは、2 度かけても同じ
    func testLineEditNormalizedIsStable() {
        monkey("line edit normalized", rounds: 300,
               make: { rng in rng.text(from: MonkeyPool.textFragments + ["\u{3000}", "\u{3000}\u{3000}", "\u{85}", "\u{7F}"],
                                       pieces: 0...8) },
               check: { text in
                   let once = LineEdit.normalized(text)
                   let twice = LineEdit.normalized(once)
                   return once == twice ? nil : "normalized twice is \(twice.debugDescription), once \(once.debugDescription)"
               })
    }

    // 形 1「落ちない」: メモへの引用は、どんな時刻と文でも、終わりに改行が 1 つで、途中に改行が無い
    func testNoteQuoteIsOneLine() {
        monkey("note quote", rounds: 300,
               make: { rng in (rng.pick(MonkeyPool.doubles), rng.text(from: MonkeyPool.textFragments, pieces: 0...6)) },
               check: { input in
                   let (time, text) = input
                   let line = NoteQuote.line(time: time, text: text)
                   guard line.hasSuffix("\n"), !line.hasSuffix("\n\n") else { return "does not end with one newline" }
                   if line.dropLast().contains(where: \.isNewline) { return "has a newline inside: \(line.debugDescription)" }
                   return nil
               })
    }

    // 形 1「落ちない」: JSON の書き出しは、どんな結果でも JSON として読める
    func testExportedJSONReadsBack() {
        monkey("export json", rounds: 100,
               make: { rng -> Transcript in
                   let segments = (0..<rng.int(0...5)).map { _ in
                       TranscriptSegment(start: rng.pick(MonkeyPool.finiteDoubles), end: rng.pick(MonkeyPool.finiteDoubles),
                                         text: rng.text(from: MonkeyPool.textFragments, pieces: 0...3))
                   }
                   return Transcript(sourceName: rng.text(from: MonkeyPool.textFragments, pieces: 0...2), segments: segments,
                                     duration: rng.pick(MonkeyPool.finiteDoubles))
               },
               describe: { t in t.segments.map { "\($0.start)-\($0.end) \($0.text.prefix(30).debugDescription)" }.joined(separator: ", ") },
               check: { transcript in
                   let json = Exporter.render(transcript, as: .json)
                   let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
                   guard let dictionary = object as? [String: Any],
                         (dictionary["segments"] as? [Any])?.count == transcript.segments.count else {
                       return "the JSON does not hold the segments"
                   }
                   return nil
               })
    }

    // 形 1「落ちない」: WAV の読み取りは、でたらめなバイト・正しい頭の一部を壊した物でも落ちない (読めなければ投げる)
    func testWAVDecodeTakesBrokenBytes() {
        let good = [UInt8](WAV.encode(samples: (0..<64).map { Float($0) / 64 }, sampleRate: 16_000))
        monkey("wav decode", rounds: 400,
               make: { rng -> [UInt8] in
                   var bytes = rng.int(0...3) == 0 ? (0..<rng.int(0...80)).map { _ in UInt8(truncatingIfNeeded: rng.next()) } : good
                   if rng.int(0...1) == 0 { bytes = Array(bytes.prefix(rng.int(0...bytes.count))) }
                   for _ in 0..<rng.int(0...4) where !bytes.isEmpty {
                       // 頭の 44 バイトの中 (大きさ・形式・チャンネルの数) を、よく壊す
                       let i = rng.int(0...(min(bytes.count, 44) - 1))
                       bytes[i] = rng.pick([0, 1, 2, 0x7F, 0x80, 0xFF, UInt8(truncatingIfNeeded: rng.next())])
                   }
                   return bytes
               },
               describe: { bytes in bytes.prefix(48).map { String(format: "%02x", $0) }.joined() },
               check: { bytes in
                   if let decoded = try? WAV.decode(Data(bytes)), decoded.samples.contains(where: { !$0.isFinite }) {
                       return "decoded samples that are not numbers"
                   }
                   return nil
               })
    }

    // 形 3「時間の内に終わる」: タグのかけらの寄せ集めで落ちず、5 秒の内に終わる。題名は 1 行
    func testWebPageTextTakesTagFragments() {
        monkey("web page fragments", rounds: 150,
               make: { rng in rng.text(from: MonkeyPool.markupFragments, pieces: 0...40) },
               check: { html in
                   let box = MonkeyBox<(title: String, text: String)>((title: "", text: ""))
                   let ok = finishes(within: 5) { box.value = WebPageText.extract(html: html) }
                   guard ok else { return "did not finish in 5 s" }
                   let page = box.value
                   // 文の中にタグの形が残る事は在る (`<` を中に含むタグ・文字参照の `&lt;` は、文として残す決まり) ので、見ない
                   if page.title.contains("\n") { return "the title has a newline" }
                   return nil
               })
    }

    // 形 1「落ちない」: 聞き取りの後の掃除 (決まり文句・繰り返し) と、数の抜けの数え方は、変な文でも落ちない
    func testTextFiltersTakeAnyText() {
        let fragments = MonkeyPool.textFragments + ["2025", "1,000", "3.14", "-7", "１２３", "二十", "ok ok ok ", "Thank you.", "ご視聴ありがとうございました"]
        monkey("text filters", rounds: 80,
               make: { rng -> [String] in (0..<rng.int(0...5)).map { _ in rng.text(from: fragments, pieces: 0...6) } },
               describe: { texts in texts.map { $0.prefix(60).debugDescription }.joined(separator: ", ") },
               check: { texts in
                   for text in texts {
                       _ = HallucinationFilter.isStockPhrase(text)
                       _ = HallucinationFilter.shouldDrop(text: text, noSpeechProbability: 0.9)
                       _ = RepetitionFilter.collapseInlineRepeats(text)
                   }
                   let segments = texts.enumerated().map { i, text in
                       TranscriptSegment(start: Double(i), end: Double(i) + 0.5, text: text)
                   }
                   let cleaned = RepetitionFilter.clean(segments)
                   if cleaned.count > segments.count { return "clean made \(cleaned.count) segments from \(segments.count)" }
                   let lost = LLMEval.numbersLost(sources: texts, translation: texts.last ?? "")
                   if lost.lost.count > lost.checked { return "lost \(lost.lost.count) of \(lost.checked) numbers" }
                   return nil
               })
    }

    /// 結果の時刻のうち、使える範囲の外の物・終わりが始まりより前の物 (無ければ nil)
    static func timeProblem(in t: Transcript) -> String? {
        func bad(_ x: Double) -> Bool { !(x >= 0 && x <= TimeRange.maxSeconds) }
        if bad(t.duration) || bad(t.elapsed) { return "duration \(t.duration), elapsed \(t.elapsed)" }
        for s in t.segments where bad(s.start) || bad(s.end) || s.end < s.start {
            return "segment \(s.start)-\(s.end)"
        }
        return nil
    }

    /// 試験だけに使う、一時のライブラリのフォルダ (利用者の本物のライブラリには触らない)
    static func temporaryLibrary() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kikimimi-monkey-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 文を、JSON の文字列の形にする (試験の入力を作るため)
    static func jsonString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
