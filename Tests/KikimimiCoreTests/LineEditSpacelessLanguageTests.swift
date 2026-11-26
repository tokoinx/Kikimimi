import Foundation
import XCTest
@testable import KikimimiCore

/// 語を空白で分けない言語 (中国語の簡体・繁体、タイ語) で、手で直した行から「聞き取った字 → 直した字」の組を切り出す
/// (`LineEdit.suggestedSpan`) 試験。どの例でも、次が成り立つ事を見る:
/// 切り出した wrong が聞き取った行に在り、right が直した行に在り、聞き取った行のその場所の wrong を right に置き換えると直した行になる。
/// 語の分け方は OS の辞書なので、値は今の Mac (macOS 14) で返る物 (変わったら、成り立つべき事を先に見る)
final class LineEditSpacelessLanguageTests: XCTestCase {
    /// 組を切り出し、成り立つべき事を見て、組を返す (切り出せなければ nil)
    @discardableResult
    private func pair(_ heard: String, _ edited: String, file: StaticString = #filePath,
                      line: UInt = #line) -> AuditChange.Pair? {
        guard let span = LineEdit.suggestedSpan(heard: heard, edited: edited) else {
            XCTAssertNil(LineEdit.suggestedPair(heard: heard, edited: edited), file: file, line: line)
            return nil
        }
        let h = Array(LineEdit.normalized(heard))
        let e = LineEdit.normalized(edited)
        XCTAssertEqual(String(h[span.range]), span.pair.wrong, file: file, line: line)
        XCTAssertTrue(LineEdit.normalized(heard).contains(span.pair.wrong), "wrong is in the heard line", file: file, line: line)
        XCTAssertTrue(e.contains(span.pair.right), "right is in the edited line", file: file, line: line)
        let replaced = String(h[..<span.range.lowerBound]) + span.pair.right + String(h[span.range.upperBound...])
        XCTAssertEqual(replaced, e, "replacing gives the edited text", file: file, line: line)
        // 字のかたまり (grapheme) の途中で切らない: wrong・right の頭が、結合する印 (声調・母音の印など) で始まらず、
        // 切った後ろの字も、結合する印で始まらない
        func startsWithMark(_ text: some StringProtocol) -> Bool {
            guard let first = text.unicodeScalars.first else { return false }
            switch first.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
        XCTAssertFalse(startsWithMark(span.pair.wrong), "wrong starts inside a grapheme", file: file, line: line)
        XCTAssertFalse(startsWithMark(span.pair.right), "right starts inside a grapheme", file: file, line: line)
        XCTAssertFalse(startsWithMark(String(h[span.range.upperBound...])), "cut inside a grapheme", file: file, line: line)
        // 字の数で数えても、字のかたまりの数で数えても、置き換えた後の行は同じ数 (かたまりがくっつき直していない)
        XCTAssertEqual(replaced.count, e.count, file: file, line: line)
        XCTAssertEqual(LineEdit.suggestedPair(heard: heard, edited: edited), span.pair, file: file, line: line)
        return span.pair
    }

    private func p(_ wrong: String, _ right: String) -> AuditChange.Pair {
        AuditChange.Pair(wrong: wrong, right: right)
    }

    /// 中国語 (簡体)。1 字だけの違いは、2 字に満たないので右隣の語まで広げる (今の決まりの 4)
    func testSimplifiedChinese() {
        // 「滨」が 1 字の語なので、右隣の「步」まで広げる
        XCTAssertEqual(pair("他每天在公园滨步。", "他每天在公园跑步。"), p("滨步", "跑步"))
        // 辞書で 1 語 (平果) なので、そのまま 2 字
        XCTAssertEqual(pair("我喜欢吃平果。", "我喜欢吃苹果。"), p("平果", "苹果"))
        // 2 か所が違う: 頭と尻の同じ所を除くと、間の読点 (，) をまたぐので、組にしない (覚えない)
        XCTAssertNil(pair("我在北京工做，他在上海学习。", "我在北京工作，她在上海学习。"))
        // 句読点だけが違う: 右隣の語まで広げると句読点が入るので、組にしない
        XCTAssertNil(pair("你好,世界。", "你好，世界。"))
        // 尻に句読点を足しただけ: 組にしない
        XCTAssertNil(pair("今天天气很好", "今天天气很好。"))
    }

    /// 手で直した中国語の行から切り出した組を、台帳に 2 回覚えさせた (自動) 時、ほかの行にどう当たるか。
    /// 句読点をまたぐ 2 か所の直しは組にならないので覚えず、関係の無い行 (你先做，他后做。) は書き換わらない
    func testSimplifiedChinesePairsOnOtherLines() {
        var ledger = CorrectionLedger()
        let edits = [("我在北京工做，他在上海学习。", "我在北京工作，她在上海学习。"), ("我喜欢吃平果。", "我喜欢吃苹果。")]
        let pairs = edits.compactMap { LineEdit.suggestedPair(heard: $0.0, edited: $0.1) }
        XCTAssertEqual(pairs, [p("平果", "苹果")])
        for _ in 0..<2 {
            for pair in pairs { ledger.record(wrong: pair.wrong, right: pair.right, language: "zh", example: nil, accepted: true) }
        }
        let lines = [
            TranscriptSegment(start: 0, end: 2, text: "他买了三个平果。", language: "zh"),
            TranscriptSegment(start: 2, end: 4, text: "你先做，他后做。", language: "zh"),
            TranscriptSegment(start: 4, end: 6, text: "平果手机很贵。", language: "zh"),
        ]
        // 行に言語の印が無い時 (ふつうの文字起こし): 台帳の言語 (zh) で当たる。「你先做，他后做。」は、そのまま
        let plain = lines.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) }
        let fixes = ledger.fixes(for: plain, language: "zh")
        XCTAssertEqual(fixes.map(\.original.text), ["他买了三个平果。", "平果手机很贵。"])
        XCTAssertEqual(fixes.map(\.replacement), ["他买了三个苹果。", "苹果手机很贵。"])
        XCTAssertTrue(fixes.allSatisfy(\.isConfident))
        // 行に言語の印 (zh) が在る時: 漢字だけの行は「日本語の字」と見なされ (`Script.spokenLanguage` が ja を返す)、
        // 「行の言語が変わる直し」として、どの組も当たらない (今はこう返す。報告に挙げた)
        XCTAssertEqual(lines.map { Script.spokenLanguage(of: $0.text, among: ["ja", "en"], fallback: "zh") }, ["ja", "ja", "ja"])
        XCTAssertTrue(ledger.fixes(for: lines, language: "zh").isEmpty)
    }

    /// 切り出したタイ語の組を台帳に 2 回覚えさせた時、ほかの行にどう当たるか (今はこう返す。報告用)。
    /// タイ語の字は「空白で分ける言語の字」として扱われ、組の前後に字が続くと当たらない (語の切れ目を、字の続きで見るため)。
    /// タイ語は語の間に空白を入れないので、文の中の語には、ほぼ当たらない
    func testThaiPairsOnOtherLines() {
        var ledger = CorrectionLedger()
        for _ in 0..<2 { ledger.record(wrong: "ไม้", right: "ไม่", language: "th", example: nil, accepted: true) }
        XCTAssertTrue(ledger.fixes(for: [TranscriptSegment(start: 0, end: 2, text: "เขาไม้มา")], language: "th").isEmpty)
        XCTAssertNil(Auditor.applyFix(to: "ฉันไม้ชอบกาแฟ", wrong: "ไม้", right: "ไม่", surfaceOnly: true))
        XCTAssertNil(Auditor.applyFix(to: "เขาไปทีบ้านเพื่อน", wrong: "ทีบ้าน", right: "ที่บ้าน", surfaceOnly: true))
        // 前後が空白なら当たる
        XCTAssertEqual(ledger.fixes(for: [TranscriptSegment(start: 0, end: 2, text: "เขา ไม้ มา")], language: "th").map(\.replacement),
                       ["เขา ไม่ มา"])
    }

    /// 中国語 (繁体)。簡体と同じ形で返る
    func testTraditionalChinese() {
        XCTAssertEqual(pair("他每天在公園滨步。", "他每天在公園跑步。"), p("滨步", "跑步"))
        XCTAssertEqual(pair("我喜歡吃平果。", "我喜歡吃蘋果。"), p("平果", "蘋果"))
        XCTAssertNil(pair("我在台北工做，他在高雄學習。", "我在台北工作，她在高雄學習。"))
    }

    /// タイ語。声調の印・母音の印は、前の字と 1 つのかたまり (Swift の Character) なので、途中で切らない
    func testThaiKeepsGraphemesWhole() {
        // 声調の印だけが違う (ม้ → ม่): かたまりごと入れ替わり、語 (ไม้ → ไม่) の組になる
        XCTAssertEqual(pair("ฉันไม้ชอบกาแฟ", "ฉันไม่ชอบกาแฟ"), p("ไม้", "ไม่"))
        // 声調の印を足した (ที → ที่): 1 かたまりの語なので、右隣の語まで広げる
        XCTAssertEqual(pair("เขาไปทีบ้าน", "เขาไปที่บ้าน"), p("ทีบ้าน", "ที่บ้าน"))
        // 母音の印つきの 1 かたまりの語 (ดี) を書き換えた: 右隣の語まで広げる
        XCTAssertEqual(pair("วันนี้อากาศดีมาก", "วันนี้อากาศร้อนมาก"), p("ดีมาก", "ร้อนมาก"))
        // 文の終わりの語 (ครับ → ค่ะ)
        XCTAssertEqual(pair("สวัสดีครับ", "สวัสดีค่ะ"), p("ครับ", "ค่ะ"))
        // 語の切れ目に語を足しただけ: 組にしない
        XCTAssertNil(pair("ผมกินข้าวผัดทุกวัน", "ผมกินข้าวผัดกุ้งทุกวัน"))
        // かたまりの数え方: ที่ は 3 つの字 (Unicode のスカラー) だが、1 つのかたまり
        XCTAssertEqual("ที่".count, 1)
        XCTAssertEqual("ที่".unicodeScalars.count, 3)
        XCTAssertEqual(LineEdit.letterCount("ที่"), 1)
    }

    // MARK: 句読点をまたぐ組は覚えない (日本語・英語)

    /// 日本語: 1 行の 2 か所 (橋・箸) を直すと、間の読点をまたぐので組にしない。1 か所なら今まで通り組にする
    func testJapanesePairAcrossPunctuationIsNotLearned() throws {
        XCTAssertNil(pair("箸を渡って、橋で食べた。", "橋を渡って、箸で食べた。"))
        let one = try XCTUnwrap(pair("箸を渡って、箸で食べた。", "橋を渡って、箸で食べた。"))
        XCTAssertTrue(one.wrong.contains("箸") && one.right.contains("橋"))
        XCTAssertFalse(one.wrong.contains("、") || one.right.contains("、"))
        // 中黒・長音は語の中の印なので、組に入ってよい
        XCTAssertEqual(pair("ジョン・スミズさんが来た。", "ジョン・スミスさんが来た。"), p("スミズ", "スミス"))
    }

    /// 英語: 2 つの文にまたがる直しは組にしない。アポストロフィ・ハイフン・数の中の「.」「,」は語の中の印なので、組にする
    func testEnglishPairAcrossPunctuationIsNotLearned() {
        XCTAssertNil(pair("I red it. He red it too.", "I read it. He read it too."))
        XCTAssertNil(pair("Wait, what", "Wait. What"))
        XCTAssertEqual(pair("He don't know.", "He doesn't know."), p("don't", "doesn't"))
        XCTAssertEqual(pair("He don’t know.", "He doesn’t know."), p("don’t", "doesn’t"))
        XCTAssertEqual(pair("It costs 3.5 euros.", "It costs 3,5 euros."), p("3.5", "3,5"))
        XCTAssertEqual(pair("We sold 1,000 units.", "We sold 1,500 units."), p("1,000", "1,500"))
        XCTAssertEqual(pair("a well-knwon name", "a well-known name"), p("knwon", "known"))
        // 印の見分け方そのもの
        XCTAssertTrue(LineEdit.hasSeparatingPunctuation(Array("a, b")))
        XCTAssertTrue(LineEdit.hasSeparatingPunctuation(Array("做，他")))
        XCTAssertTrue(LineEdit.hasSeparatingPunctuation(Array("3.")))
        XCTAssertFalse(LineEdit.hasSeparatingPunctuation(Array("don't-x_y・ー")))
        XCTAssertFalse(LineEdit.hasSeparatingPunctuation(Array("1,000.5")))
    }
}
