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
        // 「行の言語が変わる直し」として、どの組も当たらない (今はこう返す)。
        // ただし、今のアプリでは、行に zh の印は付かない。行の言語の印を付けるのは「日本語＋英語」の文字起こし
        // (`MixedPipeline.transcriptSegment`) だけで、候補はいつも ja と en (`Languages.candidates(for:)` は「ja+en」の時だけ
        // ["ja", "en"]、自動で混ざりを確かめる時も `MixedProbe.languages` の ["ja", "en"])。言語を中国語にした時・自動の時の
        // 1 つの言語の文字起こし (`WhisperContext` の segmentFromContext・filtered) は、行に言語の印を付けない。
        // なので、このコードは直していない (印が付く道ができた時は、ここを直す)
        XCTAssertEqual(lines.map { Script.spokenLanguage(of: $0.text, among: ["ja", "en"], fallback: "zh") }, ["ja", "ja", "ja"])
        XCTAssertTrue(ledger.fixes(for: lines, language: "zh").isEmpty)
        // 印を付ける道の候補が、今も ja と en だけである事の見張り
        XCTAssertNil(Languages.candidates(for: "zh"))
        XCTAssertNil(Languages.candidates(for: "auto"))
        XCTAssertEqual(Languages.candidates(for: "ja+en"), ["ja", "en"])
        XCTAssertEqual(MixedProbe.languages, ["ja", "en"])
    }

    /// 切り出したタイ語の組を台帳に 2 回覚えさせた時、ほかの行にどう当たるか。
    /// タイ語は語の間に空白を書かないので、組の前後に字が続いてよい代わりに、当てる場所の頭と尻が
    /// OS の語の切れ目 (切り出しと同じ `.byWords`) に合う事を求める (`Auditor.termRange`)。
    /// 語の分け方は OS の辞書なので、値は今の Mac (macOS 14) で返る物。タイ語の分かる人は、例の文を見ていない
    func testThaiPairsOnOtherLines() throws {
        // 手で直した行から切り出した組を、2 回覚えさせる (自動で当たる)
        let pair = try XCTUnwrap(pair("ฉันไม้ชอบกาแฟ", "ฉันไม่ชอบกาแฟ"))
        XCTAssertEqual(pair, p("ไม้", "ไม่"))
        var ledger = CorrectionLedger()
        for _ in 0..<2 { ledger.record(wrong: pair.wrong, right: pair.right, language: "th", example: nil, accepted: true) }
        // 覚えた文そのもの (語の切れ目: ฉัน|ไม้|ชอบ|กาแฟ) に当たる
        XCTAssertEqual(Auditor.applyFix(to: "ฉันไม้ชอบกาแฟ", wrong: "ไม้", right: "ไม่", surfaceOnly: true), "ฉันไม่ชอบกาแฟ")
        // 別の文の中の同じ語 (เขา|ไม้|มา) に当たる。行の言語の印 (th) が在っても無くても当たる
        let lines = [
            TranscriptSegment(start: 0, end: 2, text: "เขาไม้มา"),
            TranscriptSegment(start: 2, end: 4, text: "เขาไม้มา", language: "th"),
            TranscriptSegment(start: 4, end: 6, text: "เขา ไม้ มา"),
            // 長い語の一部 (ไม้บรรทัด は 1 語・ต้นไม้ の尻) は、切れ目に合わないので当たらない
            TranscriptSegment(start: 6, end: 8, text: "ไม้บรรทัดอยู่ไหน"),
            TranscriptSegment(start: 8, end: 10, text: "ต้นไม้ใหญ่"),
        ]
        // (場所は字のかたまりの数で数える。ไม้บรรทัด は 7 かたまり、ต้นไม้ は 4 かたまり)
        XCTAssertEqual(LineEdit.wordRanges("ไม้บรรทัดอยู่ไหน").first, 0..<7)
        XCTAssertEqual(LineEdit.wordRanges("ต้นไม้ใหญ่"), [0..<4, 4..<7])
        let fixes = ledger.fixes(for: lines, language: "th")
        XCTAssertEqual(fixes.map(\.original.text), ["เขาไม้มา", "เขาไม้มา", "เขา ไม้ มา"])
        XCTAssertEqual(fixes.map(\.replacement), ["เขาไม่มา", "เขาไม่มา", "เขา ไม่ มา"])
        XCTAssertTrue(fixes.allSatisfy(\.isConfident))
        // 2 語にまたがる組 (ที|บ้าน → ที่บ้าน) も、頭と尻が切れ目なら当たる
        XCTAssertEqual(Auditor.applyFix(to: "เขาไปทีบ้านเพื่อน", wrong: "ทีบ้าน", right: "ที่บ้าน", surfaceOnly: true),
                       "เขาไปที่บ้านเพื่อน")
        // 字のかたまりの途中では切らない: 「ไม」(声調の印なし) は、「ไม่ชอบ」の中の、印の前までには当たらない
        XCTAssertNil(Auditor.applyFix(to: "ฉันไม่ชอบกาแฟ", wrong: "ไม", right: "ไม่", surfaceOnly: true))
        // 当てた後の字が壊れない (かたまりの数が、置き換えた分だけ合う。結合する印で始まるかたまりが無い)
        for fix in fixes {
            let fixed = try XCTUnwrap(fix.replacement)
            XCTAssertEqual(fixed.count, fix.original.text.count)
            XCTAssertFalse(fixed.contains { $0.unicodeScalars.first?.properties.generalCategory == .nonspacingMark })
        }
        // 正しい語が、もう文の中の語として入っている行は、そのまま (「正しい語がもう入っている」の見方も、語の切れ目で見る)
        XCTAssertTrue(Auditor.containsTerm("เขาไม่มา", "ไม่"))
        XCTAssertFalse(Auditor.containsTerm("ฉันไม่ชอบกาแฟ", "ไม่"), "ไม่ชอบ is one word for the OS")
    }

    /// ラオ語・クメール語: タイ語と同じく、OS の語の切れ目で当てる (今の Mac は、どちらも語に分けられる)
    func testLaoAndKhmerPairsOnOtherLines() throws {
        // ラオ語: ບໍ (1 かたまり) を ບໍ່ に直す。2 字に満たないので右隣の語 (ມັກ) まで広げた組になる
        XCTAssertEqual(LineEdit.wordRanges("ຂ້ອຍບໍມັກກາເຟ").count, 4)
        let lao = try XCTUnwrap(pair("ຂ້ອຍບໍມັກກາເຟ", "ຂ້ອຍບໍ່ມັກກາເຟ"))
        XCTAssertEqual(lao, p("ບໍມັກ", "ບໍ່ມັກ"))
        XCTAssertEqual(Auditor.applyFix(to: "ລາວບໍມັກປາ", wrong: lao.wrong, right: lao.right, surfaceOnly: true), "ລາວບໍ່ມັກປາ")
        // クメール語: ចិត្ដ (字の形が違う ដ) を ចិត្ត に直す
        let khmer = try XCTUnwrap(pair("ខ្ញុំមិនចូលចិត្ដកាហ្វេ", "ខ្ញុំមិនចូលចិត្តកាហ្វេ"))
        XCTAssertEqual(khmer, p("ចិត្ដ", "ចិត្ត"))
        XCTAssertEqual(Auditor.applyFix(to: "ខ្ញុំមិនចូលចិត្ដកាហ្វេ", wrong: khmer.wrong, right: khmer.right, surfaceOnly: true),
                       "ខ្ញុំមិនចូលចិត្តកាហ្វេ")
        // 文字の見分け方 (タイ・ラオ・ビルマ・クメール)
        XCTAssertTrue(["ก", "ກ", "က", "ក"].allSatisfy { Auditor.isUnspacedSoutheastAsian(Character($0)) })
        XCTAssertFalse(["a", "あ", "漢", "한"].contains { Auditor.isUnspacedSoutheastAsian(Character($0)) })
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
