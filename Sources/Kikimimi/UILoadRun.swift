// 画面の重さの確認の、ジョブと測った値を持つ LoadRun の本体 (保存する値・init・ジョブを入れる所) と、
// 確認に使う結果の行を作る所。

import Foundation
import KikimimiCore

/// 画面の重さの確認の、ジョブと操作と測った値
@MainActor
final class LoadRun {
    typealias Action = UILoadSelfTest.Action
    typealias Phase = UILoadSelfTest.Phase
    typealias Limits = UILoadSelfTest.Limits

    let model: AppModel
    let rows: Int
    let player: PlayerController
    let doneBilingual: Job
    let donePlain: Job
    let running: Job
    /// 文字起こし中のジョブの区間の入れ物 (AppModel.run と同じもの)
    var feed: LiveSegmentBuffer?
    let log = ActionLog()
    let probe = LatencyProbe()
    /// 操作ごとの、メインスレッドがまた空くまでの秒
    var measured: [String: [Double]] = [:]
    /// まとめて足した区間を、どの操作として記録するか (nil なら記録しない: いっぺんに届く 300 は別に測る)
    var feedAction: String?
    /// 段階 3 (文字起こし中のジョブ、1 秒に 10 区間) のあいだ。再生位置・1 行だけの再生を Action.whileAdded の名前で記録する
    var rowsAdded = false
    /// 文字起こし中のジョブへ次に届ける区間の番号
    var nextSegment: Int
    /// 届けた区間の数
    var delivered = 0
    /// ふつうの再生の、まねている位置 (秒)
    var simulated = 0.0
    /// 段階ごとの始まりと終わり (uptime のナノ秒)
    var phaseTimes: [String: (start: UInt64, end: UInt64)] = [:]
    var ticks = 0
    /// ticks のうち、いまの行が変わったもの
    var rowChanges = 0
    var lineStarts = 0
    /// 300 の区間をいっぺんに届けているところ (まとめて足し始めた時刻を覚える)
    var awaitingBurst = false
    /// いっぺんに届けた区間を、まとめて足し始めた時刻 (uptime のナノ秒)
    var burstApplied: UInt64?
    /// いっぺんに届けてから、まとめて足し始めるまでの秒 (まとめる間を待つ。メインスレッドは空いている)
    var burstWaits: [Double] = []
    /// 一覧の行を作る手間を測ったときに、足した分だけを作る道を通らなかった回数
    var appendPathMissed = 0
    /// ジョブを選ぶ・再生位置を遠くへ動かす操作ごとの、その 1 回で一覧が作った行の数 (PlayableRow の init。測った順)
    var rowsBuiltBySelect: [String: [Int]] = [:]
    /// 同じく、その 1 回で一覧が body を動かした行の数 (PlayableRow.body。測った順)
    var rowBodiesBySelect: [String: [Int]] = [:]
    /// 測る段階のすべて (drive) で、一覧が作った行の数 (init)
    var rowsBuiltTotal: Int?
    /// 測る段階のすべて (drive) で、一覧が body を動かした行の数
    var rowBodiesTotal: Int?
    /// 段階ごとの、一覧が作った行の数 (init) と、body を動かした行の数 (名前は Phase の名前)
    var rowInitsByPhase: [String: Int] = [:]
    var rowBodiesByPhase: [String: Int] = [:]
    /// 操作ごとの、一覧が作った行の数 (init) と、body を動かした行の数の合計 (名前は Action の名前)。
    /// 操作が重なった時 (まとめて足した 1 回を測っている間に、次の操作が始まった時) は、後から始まった方に入れる
    /// (同じ行を 2 回数えないため。合計から名前の付いた分を引いた残りが、操作の外)
    var rowInitsByAction: [String: Int] = [:]
    var rowBodiesByAction: [String: Int] = [:]
    /// 操作ごとの、一覧そのもの (TranscriptListView) の body が動いた回数の合計 (分け方は行の数と同じ)
    var listBodiesByAction: [String: Int] = [:]
    /// 測る部分のすべてで、一覧の body が動いた回数
    var listBodiesTotal: Int?
    /// いま開いている操作の名前 (始めた順)。数を分けるのに使う
    var openActions: [String] = []
    /// 操作ごとに数を分けた、前の時点の数 (行の init と body、一覧の body)。nil なら分けていない (測る部分の外)
    var rowCountMark: (inits: Int, bodies: Int, lists: Int)?
    /// 測る段階のすべて (drive) で、マウスが行に載った・行から出た回数
    var rowHoverChangesTotal: Int?
    /// 測る部分の始め・各段階の始めと終わりで、マウスの位置がメインのウインドウの枠の中に在ったか (見た順)
    var mouseInsideChecks: [Bool] = []
    /// 同じ時に、アプリが前面 (active) だったか・メインのウインドウがキーだったか (見た順)。
    /// 前面でない間に、行を描き直す回数が変わるかを見るための値
    var appActiveChecks: [Bool] = []
    var windowKeyChecks: [Bool] = []
    /// 段階 4 の、足す操作 1 回ごとの内わけの行 (UILoadAppendDetail.swift。目安とは比べない)
    var appendDetails: [AppendDetail] = []
    /// 内わけの行に付けた、1 行足す操作の番号
    var singleAppendDetails = 0

    init(model: AppModel, rows: Int, url: URL) {
        self.model = model
        self.rows = rows
        player = model.player
        doneBilingual = Job(name: "画面の重さの確認 (対訳, \(rows) 行)", url: url)
        donePlain = Job(name: "画面の重さの確認 (日本語, \(rows) 行)", url: url)
        running = Job(name: "文字起こし中 (確認用)", url: url)
        nextSegment = rows
    }

    func insertJobs() {
        let duration = Double(rows) * UILoadSelfTest.rowSpacing
        var bilingual = Transcript(sourceName: doneBilingual.name, segments: UILoadSelfTest.makeSegments(0..<rows),
                                   language: "en", duration: duration, elapsed: 1)
        // 一部の行を、利用者が直した訳にする (一覧に「直した」の印が出る)
        UILoadSelfTest.markEditedTranslations(&bilingual)
        doneBilingual.transcript = bilingual
        // 対訳で出す (設定は変えない: 行の「訳」を押したときと同じ、このジョブだけの対訳)
        doneBilingual.showsLineTranslations = true
        // 日本語だけ: 訳す行が無いので、対訳の設定によらず、ふつうに出る
        donePlain.transcript = Transcript(sourceName: donePlain.name,
                                          segments: UILoadSelfTest.makeSegments(0..<rows, japaneseOnly: true),
                                          language: "ja", duration: duration, elapsed: 1)
        for job in [doneBilingual, donePlain] {
            job.status = .done
            job.progress = 1
            job.message = "完了"
        }
        // 文字起こし中のジョブも、はじめから行数の行がある (長い録音の途中で、数千行が出ているところ)
        running.transcript = Transcript(sourceName: running.name, segments: UILoadSelfTest.makeSegments(0..<rows),
                                        language: "en", duration: duration * 2)
        running.status = .running
        running.progress = 0.5
        running.message = "認識中 50%"
        feed = AppModel.liveFeed(for: running) { [weak self] count, started in
            self?.batchApplied(count: count, started: started)
        }
        // ふだんと同じ入れ方 (保存の受け口が付き、終わったジョブ 2 つは、確認用のライブラリに保存される)
        model.adopt(running)
        model.adopt(donePlain)
        model.adopt(doneBilingual)
    }

    func isShownBilingual(_ job: Job) -> String {
        guard let transcript = job.transcript else { return "no" }
        let stats = job.status == .done ? model.translationStats(of: transcript) : Transcript.TranslationStats()
        return model.isBilingual(stats, in: job) ? "yes" : "no"
    }
}

extension UILoadSelfTest {
    /// 作る行の長さと間隔 (秒)
    static let rowSpacing = 2.5
    static let rowLength = 2.3

    /// makeSegments で作った rows 行のうち、位置 t (秒) にある行の番号。CurrentLineTracker と同じ決まり
    /// (t までに始まった最後の行で、t がその行の終わりより前。行のあいだなら nil)
    static func rowIndex(at t: Double, rows: Int) -> Int? {
        guard t >= 0 else { return nil }
        let index = Int(t / rowSpacing)
        guard index < rows else { return nil }
        let start = Double(index) * rowSpacing
        return t < start + max(rowLength, 0.3) ? index : nil
    }

    /// 英語と日本語を交互に、ありそうな長さで。英語の 3 行に 1 行は訳つき (対訳の表示を通す)。
    /// japaneseOnly では日本語の行だけ (訳す行が無いので、対訳ではなく、ふつうに出る)
    static func makeSegments(_ range: Range<Int>, japaneseOnly: Bool = false) -> [TranscriptSegment] {
        range.map { i in
            let start = Double(i) * rowSpacing
            let english = !japaneseOnly && i % 2 == 0
            let text = english ? englishLines[(i / 2) % englishLines.count]
                : japaneseLines[(japaneseOnly ? i : i / 2) % japaneseLines.count]
            let translation = english && i % 3 == 0 ? japaneseLines[(i / 2 + 1) % japaneseLines.count] : nil
            return TranscriptSegment(start: start, end: start + rowLength, text: text, translation: translation,
                                     language: english ? "en" : "ja")
        }
    }

    /// 訳のある行の 4 つに 1 つを、利用者が直した訳にする ("edited" の覚えを付ける)。
    /// 別の 4 つに 1 つには、訳の関門の印 ("llm" + 数の抜け) の覚えを付ける (「要確認」の橙の印が出る)。
    /// 印つきの行が在っても重さを測るため。区間は訳のまとまりを作らない (1 区間 1 訳) ので、原文はその区間の文だけ
    fileprivate static func markEditedTranslations(_ transcript: inout Transcript) {
        var notes: [TranslationNote] = []
        var translated = 0
        for i in transcript.segments.indices {
            guard let machine = transcript.segments[i].translation else { continue }
            defer { translated += 1 }
            if translated % 4 == 2 {
                // 訳は変えない (機械の訳に、印だけを付ける)
                let source = Transcript.join([transcript.segments[i].text])
                notes.append(TranslationNote(head: transcript.segments[i].id,
                                             signature: Transcript.reviewSignature(source: source, translation: machine),
                                             flags: [TranslationGate.number], detail: "number: 2025",
                                             origin: TranslationNote.llm))
                continue
            }
            guard translated % 4 == 0 else { continue }
            let edited = machine + "（直した訳）"
            transcript.segments[i].translation = edited
            let source = Transcript.join([transcript.segments[i].text])
            notes.append(TranslationNote(head: transcript.segments[i].id,
                                         signature: Transcript.reviewSignature(source: source, translation: edited),
                                         origin: TranslationNote.edited, machine: machine))
        }
        transcript.translationReview = notes.isEmpty ? nil : notes
    }

    private static let englishLines = [
        "So the first thing I want to talk about today is how the system behaves when the input gets really large.",
        "Right, and that is exactly the point where most of the people in this room have run into trouble before.",
        "If you look at the second chart, you can see the latency going up almost linearly with the number of items.",
        "We tried caching, we tried batching, and in the end the simplest change made the biggest difference.",
        "Okay, let me stop here for a moment and take a couple of questions before we move on.",
        "Thank you. That was a great question, and I think the short answer is: it depends on the hardware.",
    ]

    private static let japaneseLines = [
        "まず今日お話ししたいのは、入力がとても大きくなったときに、仕組みがどう振る舞うかということです。",
        "そうですね、ここにいる多くの方が、まさにその所でつまずいた経験があると思います。",
        "二つ目のグラフを見ると、項目の数にほぼ比例して待ち時間が増えているのがわかります。",
        "キャッシュも試しましたし、まとめて処理するのも試しましたが、結局いちばん単純な変更が効きました。",
        "では、ここで少し区切って、次に進む前に質問をいくつか受けたいと思います。",
        "ありがとうございます。良い質問でした。短く答えると、機械によります。",
    ]
}
