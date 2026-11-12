import AppKit
import CoreFoundation
import Foundation
import KikimimiCore

/// `Kikimimi --selftest-ui-load [行数] [--audio <音声>] [--report <ファイル>]`
///
/// ふつうに起動して (画面も出す)、行数 (既定 3000) の結果を出したまま、使っているときと同じ操作を起こし、
/// 操作ごとに、メインスレッドがまた空くまでの時間を測る (長い録音を文字起こししている最中に画面が固まった不具合の確認)。
///
/// 入れるジョブ: 終わったジョブ 2 つ (対訳で出す英語と日本語のもの・ふつうに出す日本語だけのもの、どちらも行数の行)、
/// 文字起こし中のジョブ 1 つ (行数の行から増えていく)。文字起こし中のジョブへの区間は、AppModel.run と同じ入れ物
/// (AppModel.liveFeed) に、認識と同じく別のスレッドから届ける (まとめて足すところも測る)。
///
/// 段階 (それぞれのあいだ、別のスレッドの見張りも 50 ms ごとにメインスレッドの待ちを測る):
/// 1. 終わったジョブ (対訳): 再生位置 (1 秒に 5 回)、1 行だけの再生の開始と停止 (1 秒に 1 回ずつ)、
///    選んでいない文字起こし中のジョブへの区間 (1 秒に 2 回、1 つずつ)、その進み具合 (1 秒に 2 回)
/// 2. 終わったジョブ (ふつう): 1 と同じ
/// 3. 文字起こし中のジョブ (1 秒に 10 区間): 初めの 2.5 秒は再生なし (一覧の終わりを追いかける)、
///    そのあとは 1 行だけの再生の開始と停止 (1 秒に 1 回ずつ) と、その行の中の再生位置。進み具合 (1 秒に 2 回)
/// 4. 文字起こし中のジョブ (いっぺんに届く): 1 つずつの区間 (6 回) と、300 の区間をいっぺんに (3 回)
/// ジョブを選ぶ操作は段階の外で測る (3 回ずつ)。行にマウスを載せたときの色は、行の中だけの状態なので、外から変えられない。
///
/// `--audio` を付けると、その音声で 1 行 (5〜7 秒あたり) を本当に再生し、行の終わりで自分で止まるかと、
/// そのあと下の再生ボタンで行の終わりから続くかも確かめる。行は 0 秒から押すときと、ふつうの再生が後ろ (30 秒あたり)
/// にいるときに押すときの 2 回。音を出せるかは先にふつうの再生で確かめ、出せない Mac では、その部分は飛ばす。
///
/// 終了コード: 0 = 成功、1 = メインのウインドウが出ない、3 = 終わらない (メインスレッドが止まっている)、
/// 5 = 重い (UI LOAD: SLOW)、6 = 1 行だけの再生が行の終わりで止まらない・続きから再生しない
enum UILoadSelfTest {
    /// 合格の目安 (秒)。GitHub の macOS の実行機 (3 コア、仮想の GPU) で決めた、ゆるい値。測った数が集まったら締める
    fileprivate enum Limits {
        /// 再生位置・1 行だけの再生の開始と停止・選んでいないジョブへの区間・進み具合: 95 パーセンタイルと最大
        static let quickP95 = 0.100
        static let quickMax = 0.300
        /// 選んでいる、文字起こし中のジョブに区間を 1 つ足す: 95 パーセンタイルと最大
        static let appendP95 = 0.150
        static let appendMax = 0.400
        /// 300 の区間がいっぺんに届いてから、すべてが一覧に入り、メインスレッドが空くまで
        static let burst = 1.5
        /// 段階ごとに、そのあいだに見張りが測った最大の待ち。
        /// 段階 1・2 (終わったジョブ)、段階 3 (文字起こし中のジョブ、1 秒に 10 区間)
        static let bilingualWatchdogMax = 0.5
        static let plainWatchdogMax = 0.5
        static let steadyWatchdogMax = 0.5
        /// 段階 4 (300 の区間がいっぺんに届く): いっぺんに足すあいだは待つので、300 の区間の目安と同じ
        static let burstWatchdogMax = 1.5
        /// ジョブを選ぶ (ゆるく。最大だけ)
        static let selectMax = 3.0
    }

    /// 測る操作の名前 (出力の順)
    fileprivate enum Action {
        static let selectBilingual = "select finished job (bilingual)"
        static let selectPlain = "select finished job (plain)"
        static let selectRunning = "select running job"
        static let tick = "time tick"
        static let lineStart = "one-line start"
        static let lineStop = "one-line stop"
        static let appendSelected = "append 1 segment to the selected running job"
        static let appendOther = "append 1 segment to a job that is not selected"
        static let burst = "burst: 300 segments delivered at once to the selected running job"
        static let progress = "progress update"
        /// 段階 3 で、まとめて足した 1 回 (1 秒に 10 区間なので、1 回に 2〜3 区間)。目安は段階の見張りで見る
        static let steadyBatch = "steady: one batch applied to the selected running job (10 segments/s)"

        static let all = [selectBilingual, selectPlain, selectRunning, tick, lineStart, lineStop,
                          appendSelected, appendOther, burst, progress, steadyBatch]
    }

    /// 段階の名前 (見張りの出力)
    fileprivate enum Phase {
        static let bilingual = "finished job (bilingual)"
        static let plain = "finished job (plain)"
        static let steady = "running job, steady 10 segments/s with ticks and one-line starts"
        static let burst = "running job, single segments and bursts of 300"
        /// 段階の外 (ジョブを選ぶ・落ち着くのを待つ)。見張りの出力には出さない
        static let between = "between phases"
        static let all = [bilingual, plain, steady, burst]
    }

    /// 作る行の長さと間隔 (秒)
    fileprivate static let rowSpacing = 2.5
    fileprivate static let rowLength = 2.3

    /// 起動の前に呼ぶ。確認を予約するだけで、すぐに戻る
    static func arm(arguments: [String]) {
        let rows: Int = {
            guard let i = arguments.firstIndex(of: "--selftest-ui-load"), i + 1 < arguments.count,
                  let value = Int(arguments[i + 1]), value > 0 else { return 3000 }
            return min(max(value, 10), 50_000)
        }()
        let reportPath = value(after: "--report", in: arguments)
        let audio = value(after: "--audio", in: arguments).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        let header = [
            LaunchLog.versionLine + " UI load self-test",
            LaunchLog.environmentLine,
            "rows: \(rows), audio: \(audio?.path ?? "(none)")",
        ]
        // メインスレッドが止まったまま終わらないなら、別のスレッドから知らせて終わる
        let hangLimit = 120.0
        DispatchQueue.global().asyncAfter(deadline: .now() + hangLimit) {
            finish(header + ["UI LOAD FAILED: the self-test did not finish in \(Int(hangLimit)) s"
                             + " (the main thread may be stuck)"], code: 3, reportPath: reportPath)
        }
        Task { @MainActor in
            await run(rows: rows, audio: audio, header: header, reportPath: reportPath)
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    @MainActor
    private static func run(rows: Int, audio: URL?, header: [String], reportPath: String?) async {
        var lines = header
        // 1. メインのウインドウと、その中のモデルを待つ
        var found: AppModel?
        for _ in 0..<80 {
            if let model = AppDelegate.shared?.model, MainWindow.all().contains(where: { $0.isVisible }) {
                found = model
                break
            }
            await sleep(0.25)
        }
        guard let model = found else {
            finish(lines + ["UI LOAD FAILED: no main window after 20 s"], code: 1, reportPath: reportPath)
        }
        AppDelegate.shared?.keepRunningWithoutWindows = true

        // 2. 終わったジョブ 2 つと、文字起こし中のジョブを入れる。
        // 音声が無いときは、無いファイルを開く (行の再生の印は出て、再生しても音は出ない)
        let url = audio ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kikimimi-ui-load-no-audio.wav")
        let load = LoadRun(model: model, rows: rows, url: url)
        load.insertJobs()
        lines.append("shown bilingual: finished (bilingual) \(load.isShownBilingual(load.doneBilingual)),"
                     + " finished (plain) \(load.isShownBilingual(load.donePlain)), running \(load.isShownBilingual(load.running))")

        // 3. 操作を起こしながら測る
        await load.drive()
        lines += load.report()
        let failures = load.limitFailures()
        for failure in failures {
            lines.append("UI LOAD: SLOW (\(failure))")
        }
        let slow = !failures.isEmpty

        // 4. 音声があれば、1 行を本当に再生して、行の終わりで止まるかを見る
        var lineFailed = false
        if let audio {
            model.select(load.doneBilingual)
            lineFailed = await checkLinePlayback(player: model.player, segments: load.doneBilingual.transcript?.segments ?? [],
                                                 audio: audio, lines: &lines)
        }
        let code: Int32 = slow ? 5 : (lineFailed ? 6 : 0)
        if code == 0 { lines.append("UI LOAD OK") }
        finish(lines, code: code, reportPath: reportPath)
    }

    /// 5〜7 秒あたりの行を再生して、行の終わりで自分で止まるかと、そのあとの再生ボタンで続きから再生するかを確かめる。
    /// 失敗なら true (音を出せない Mac では確かめずに false)
    ///
    /// 音を出せるかは、行ではなく、ふつうの再生で先に確かめる (行がすぐ止まる不具合と、音を出せない Mac とは、
    /// 行の再生だけでは見分けられない)。行は 2 回再生する: 0 秒から押したときと、ふつうの再生が行より後ろ (30 秒あたり)
    /// にいるときに押したとき (止める位置より後ろにいると、押した行がすぐ止まる不具合があった)
    @MainActor
    private static func checkLinePlayback(player: PlayerController, segments: [TranscriptSegment], audio: URL,
                                          lines: inout [String]) async -> Bool {
        var waited = 0
        while player.duration <= 0, waited < 40 {
            await sleep(0.1)
            waited += 1
        }
        guard player.duration > 0,
              let segment = segments.first(where: { $0.start >= 5 }), segment.end < player.duration else {
            lines.append("UI LOAD: no audio playback here (the audio did not open: duration \(player.duration) s)")
            return false
        }
        let from = max(0, segment.start - PlayerController.lineLeadIn)
        let to = min(segment.end + PlayerController.lineTail, player.duration)

        // 1. この Mac で音を出せるか: 0 秒から、ふつうに 0.8 秒ほど再生して、位置が 0.3 秒以上進むかを見る
        player.stopLine()
        if player.isPlaying { player.togglePlay() }
        player.seek(to: 0)
        await sleep(0.3)
        let probeFrom = player.selfTestPlayback?.time ?? 0
        player.seek(to: 0, andPlay: true)
        await sleep(0.8)
        let probeTo = player.selfTestPlayback?.time ?? 0
        if player.isPlaying { player.togglePlay() }
        lines.append(String(format: "normal playback from 0 s: position %.2f s -> %.2f s in 0.8 s", probeFrom, probeTo))
        guard probeTo - probeFrom >= 0.3 else {
            lines.append(String(format: "UI LOAD: no audio playback here (normal playback moved the position by only %.2f s)",
                                probeTo - probeFrom))
            return false
        }

        // 2. 0 秒にいるときに行を押す
        player.seek(to: 0)
        await sleep(0.3)
        var failed = await playRowOnce(player: player, segment: segment, from: from, to: to,
                                       label: "from 0 s", lines: &lines)

        // 3. ふつうの再生が行より後ろ (30 秒あたり) にいるときに行を押す
        let later = min(30, player.duration - 1)
        if later > to + 1 {
            player.seek(to: later, andPlay: true)
            await sleep(0.3)
            let playingAt = player.selfTestPlayback?.time ?? -1
            let label = String(format: "while normal playback was at %.2f s", playingAt)
            let laterFailed = await playRowOnce(player: player, segment: segment, from: from, to: to,
                                                label: label, lines: &lines)
            if laterFailed { failed = true }
        } else {
            lines.append(String(format: "line after normal playback at a later position: skipped (the audio is only %.2f s)",
                                player.duration))
        }

        // 4. 下の再生ボタン: 行の終わりから続ける (行の始めや 0 秒に戻らない)
        let before = player.selfTestPlayback?.time ?? 0
        player.togglePlay()
        await sleep(0.6)
        let continued = player.selfTestPlayback?.time ?? 0
        if player.isPlaying { player.togglePlay() }
        lines.append(String(format: "play button after the row: from %.2f s to %.2f s", before, continued))
        if continued < before - 0.05 || continued < to - 0.35 {
            lines.append("UI LOAD: PLAY AFTER THE ROW DID NOT CONTINUE from the end of the row")
            failed = true
        }
        return failed
    }

    /// 行を 1 回押して、行の終わりで自分で止まるかを見る。止まりが早すぎる・止まらない・止まった位置が行の終わりから遠いなら true
    @MainActor
    private static func playRowOnce(player: PlayerController, segment: TranscriptSegment, from: Double, to: Double,
                                    label: String, lines: inout [String]) async -> Bool {
        let length = to - from
        let limit = length + 1.5
        player.playLine(id: segment.id, start: segment.start, end: segment.end)
        let started = Date()
        var stoppedAfter: Double?
        while Date().timeIntervalSince(started) < limit {
            await sleep(0.05)
            if !player.isPlaying {
                stoppedAfter = Date().timeIntervalSince(started)
                break
            }
        }
        let after = player.selfTestPlayback
        let position = after?.time ?? -1
        let how = stoppedAfter.map { String(format: "stopped by itself after %.2f s (row %.2f s, limit %.2f s)", $0, length, limit) }
            ?? String(format: "still playing after %.2f s", limit)
        lines.append(String(format: "line %.2f-%.2f s ", from, to) + label + ": " + how
                     + String(format: ", position %.2f s (row end %.2f s), rate %.1f", position, to, Double(after?.rate ?? -1)))
        var failed = false
        if let stoppedAfter, stoppedAfter < length - 0.5 {
            lines.append("UI LOAD: LINE STOPPED TOO EARLY, before the end of the row (\(label))")
            failed = true
        } else if stoppedAfter == nil || (after?.rate ?? 0) != 0 {
            lines.append("UI LOAD: LINE DID NOT STOP at the end of the row (\(label))")
            failed = true
        } else if abs(position - to) > 0.35 {
            lines.append("UI LOAD: LINE STOPPED AWAY FROM the end of the row (\(label))")
            failed = true
        }
        // 止まっていないときは、ここで止める (止まったあとは何もしない)
        player.stopLine()
        return failed
    }

    /// 英語と日本語を交互に、ありそうな長さで。英語の 3 行に 1 行は訳つき (対訳の表示を通す)。
    /// japaneseOnly では日本語の行だけ (訳す行が無いので、対訳ではなく、ふつうに出る)
    fileprivate static func makeSegments(_ range: Range<Int>, japaneseOnly: Bool = false) -> [TranscriptSegment] {
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

    /// 操作のあと、メインスレッドがまた空くまで待ち、started (操作の直前の uptime のナノ秒) からの秒を返す。
    ///
    /// 1. DispatchQueue.main.async で積んだ仕事が動くまで待つ (操作のあいだに積まれた、メインのキューの仕事が先に済む)。
    /// 2. そのあと、メインの run loop が眠る直前 (beforeWaiting) まで待つ。run loop は、メインのキューや入力に
    ///    すぐ行う仕事が残っていると眠らないので、ここまで来れば手が空いている。SwiftUI の描き直しと Core Animation の
    ///    反映も、眠る直前の観測者で行われるので、こちらの観測者は順番を最後 (CFIndex.max) にして、それらのあとで時刻を取る。
    /// 1 だけでは、描き直しの前に動いてしまうことがあり、2 だけでは、操作で積まれたメインのキューの仕事を待たないことがある。
    ///
    /// 1 と 2 を 1 回りとして、何回か繰り返す。描き直しの中で積まれた仕事 (一覧の scrollTo は、描き直しの中から
    /// Task で次の回に回している) は、こちらの観測者と同じ眠る直前に積まれ、時刻を取ったあとで動くので、1 回りでは測れない。
    /// 前の回りの眠る直前から、この回りの眠る直前までが短ければ (idleGap より短い)、そのあいだに新しい仕事は無かった:
    /// そこで終わる (少なくとも 2 回り、多くても maxRounds 回り)。終わりの時刻は、最後の回りの眠る直前。
    /// 測り始めから 2 秒たっても終わらなければ、そこで打ち切る (その時間を記録するので、遅いものとして出る)
    @MainActor
    fileprivate static func untilIdle(since started: UInt64) async -> Double {
        let giveUp = now() + 2_000_000_000
        var previous: UInt64?
        var ended = now()
        for round in 1...maxRounds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            let left = seconds(from: now(), to: giveUp)
            guard left > 0, let at = await nextBeforeWaiting(timeout: left) else {
                // 打ち切り
                ended = now()
                break
            }
            ended = at
            if round >= 2, let previous, seconds(from: previous, to: at) < idleGap { break }
            previous = at
        }
        return seconds(from: started, to: ended)
    }

    /// untilIdle の回りの数の上限
    private static let maxRounds = 10
    /// untilIdle で、前の回りの眠る直前から、この回りの眠る直前までがこれより短ければ、新しい仕事は無かったとみなす (秒)。
    /// 仕事の無い回りは、メインのキューの小さな仕事 2 つ分 (数十マイクロ秒) で済む
    private static let idleGap = 0.003

    /// 次に、メインの run loop が眠る直前 (beforeWaiting) になった時刻 (uptime のナノ秒)。timeout 秒たっても来なければ nil。
    /// 観測者 (CF の型で Sendable ではない) は ResumeOnce の中だけに置き、ほかのクロージャには ResumeOnce だけを渡す
    @MainActor
    private static func nextBeforeWaiting(timeout: Double) async -> UInt64? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
            let once = ResumeOnce(continuation)
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                once.resume(DispatchTime.now().uptimeNanoseconds)
            }
            once.hold(observer)
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    private static var commonModes: CFRunLoopMode {
        #if os(macOS)
        return CFRunLoopMode.commonModes
        #else
        return kCFRunLoopCommonModes
        #endif
    }

    fileprivate static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    fileprivate static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }

    fileprivate static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    fileprivate static func ms(_ seconds: Double) -> Double { seconds * 1000 }

    /// 小さい順に並べた値の p (0...1) の位置の値
    fileprivate static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private static func finish(_ lines: [String], code: Int32, reportPath: String?) -> Never {
        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        LaunchLog.note("UI load self-test finished with code \(code)")
        if let reportPath {
            try? text.write(toFile: (reportPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        exit(code)
    }
}

/// 画面の重さの確認の、ジョブと操作と測った値
@MainActor
private final class LoadRun {
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
    private var feed: LiveSegmentBuffer?
    let log = ActionLog()
    let probe = LatencyProbe()
    /// 操作ごとの、メインスレッドがまた空くまでの秒
    private var measured: [String: [Double]] = [:]
    /// まとめて足した区間を、どの操作として記録するか (nil なら記録しない: いっぺんに届く 300 は別に測る)
    private var feedAction: String?
    /// 文字起こし中のジョブへ次に届ける区間の番号
    private var nextSegment: Int
    /// 届けた区間の数
    private var delivered = 0
    /// ふつうの再生の、まねている位置 (秒)
    private var simulated = 0.0
    /// 段階ごとの始まりと終わり (uptime のナノ秒)
    private var phaseTimes: [String: (start: UInt64, end: UInt64)] = [:]
    private var ticks = 0
    private var lineStarts = 0

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
        doneBilingual.transcript = Transcript(sourceName: doneBilingual.name, segments: UILoadSelfTest.makeSegments(0..<rows),
                                              language: "en", duration: duration, elapsed: 1)
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
            job.exported = true
        }
        // 文字起こし中のジョブも、はじめから行数の行がある (長い録音の途中で、数千行が出ているところ)
        running.transcript = Transcript(sourceName: running.name, segments: UILoadSelfTest.makeSegments(0..<rows),
                                        language: "en", duration: duration * 2)
        running.status = .running
        running.progress = 0.5
        running.message = "認識中 50%"
        running.exported = true
        feed = AppModel.liveFeed(for: running) { [weak self] count, started in
            self?.batchApplied(count: count, started: started)
        }
        model.jobs.insert(running, at: 0)
        model.jobs.insert(donePlain, at: 0)
        model.jobs.insert(doneBilingual, at: 0)
    }

    func isShownBilingual(_ job: Job) -> String {
        guard let transcript = job.transcript else { return "no" }
        let stats = job.status == .done ? transcript.translationStats : Transcript.TranslationStats()
        return model.isBilingual(stats, in: job) ? "yes" : "no"
    }

    // MARK: 操作

    func drive() async {
        probe.start()
        let started = Date()
        // 1. 終わったジョブ (対訳)
        await measure(Action.selectBilingual) { model.select(doneBilingual) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.bilingual) {
            feedAction = Action.appendOther
            await drivePlayback(seconds: 5, lineJob: doneBilingual, steady: false)
        }
        // 2. 終わったジョブ (ふつう)
        await measure(Action.selectPlain) { model.select(donePlain) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.plain) {
            await drivePlayback(seconds: 5, lineJob: donePlain, steady: false)
        }
        // 3. 文字起こし中のジョブ (1 秒に 10 区間)
        feedAction = nil
        // ふつうの再生をまねるのをやめる (段階 3 の初めは、再生していないときに一覧の終わりを追いかけるところを見る)
        player.selfTestSetTime(simulated, playing: false)
        await measure(Action.selectRunning) { model.select(running) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.steady) {
            feedAction = Action.steadyBatch
            await drivePlayback(seconds: 7, lineJob: running, steady: true)
        }
        feedAction = nil
        player.stopLine()
        player.selfTestSetTime(simulated, playing: false)
        // ジョブを選び直す (2 回目)。文字起こし中のジョブを選び直すと、一覧はまた終わりを追いかける
        await selectRound()
        // 4. 文字起こし中のジョブ (いっぺんに届く)
        await phase(Phase.burst) {
            feedAction = Action.appendSelected
            for _ in 0..<6 {
                deliver(1)
                await UILoadSelfTest.sleep(0.5)
            }
            feedAction = nil
            for _ in 0..<3 {
                await burst(300)
                await UILoadSelfTest.sleep(1.0)
            }
        }
        // ジョブを選び直す (3 回目)
        await selectRound()
        probe.stop()
        // 届いていない合図を待つ
        await UILoadSelfTest.sleep(0.3)
        log.summaryLine = String(format: "driven for %.1f s: %d ticks, %d one-line starts, %d segments delivered to the running job"
                                 + " (it now has %d rows)",
                                 Date().timeIntervalSince(started), ticks, lineStarts, delivered,
                                 running.transcript?.segments.count ?? 0)
    }

    private func selectRound() async {
        await measure(Action.selectBilingual) { model.select(doneBilingual) }
        await UILoadSelfTest.sleep(0.3)
        await measure(Action.selectPlain) { model.select(donePlain) }
        await UILoadSelfTest.sleep(0.3)
        await measure(Action.selectRunning) { model.select(running) }
        await UILoadSelfTest.sleep(0.5)
    }

    /// 段階を 1 つ行う (見張りの値を、この段階の名前で分ける)。終わりに、まとめて足すのが済むまで待つ
    private func phase(_ name: String, _ body: () async -> Void) async {
        probe.setPhase(name)
        let start = UILoadSelfTest.now()
        await body()
        await UILoadSelfTest.sleep(LiveSegmentBuffer.interval + 0.15)
        phaseTimes[name] = (start, UILoadSelfTest.now())
        probe.setPhase(Phase.between)
    }

    /// 1 秒に 10 回の拍で、再生位置・1 行だけの再生・区間・進み具合を起こす。
    /// steady でないとき: ふつうの再生をまね (位置は 1 秒に 5 回)、1 行だけの再生を 1 秒に 1 回始め / 止め、
    /// 文字起こし中のジョブ (選んでいない) へ 1 秒に 2 回、区間を 1 つずつ届ける。
    /// steady のとき: 区間を毎拍 1 つ (1 秒に 10)。初めの 2.5 秒は再生しない。そのあとは 1 行だけの再生を 1 秒に 1 回始め、
    /// 0.5 秒後に止め、再生しているあいだは、その行の中で位置を進める。
    /// どちらも進み具合を 1 秒に 2 回変える
    private func drivePlayback(seconds: Double, lineJob: Job, steady: Bool) async {
        let started = Date()
        var tick = 0
        while Date().timeIntervalSince(started) < seconds {
            let elapsed = Date().timeIntervalSince(started)
            if steady || tick % 5 == 0 { deliver(1) }
            if tick % 2 == 0 {
                if !steady {
                    if player.playingLineID == nil {
                        // 行が 1〜2 回に 1 回変わるように進める
                        simulated += 1.3
                        if simulated > Double(rows) * UILoadSelfTest.rowSpacing { simulated = 0 }
                        let position = simulated
                        await measure(Action.tick) { player.selfTestSetTime(position, playing: true) }
                        ticks += 1
                    }
                } else if player.playingLineID != nil {
                    let position = player.currentTime + 0.2
                    await measure(Action.tick) { player.selfTestSetTime(position, playing: true) }
                    ticks += 1
                }
            }
            let lineTicks = !steady || elapsed >= 2.5
            if lineTicks, tick % 10 == 5 {
                if player.playingLineID != nil {
                    await measure(Action.lineStop) { player.stopLine() }
                } else {
                    await startLine(in: lineJob)
                }
            } else if steady, lineTicks, tick % 10 == 0, player.playingLineID != nil {
                await measure(Action.lineStop) { player.stopLine() }
            }
            if tick % 5 == 2 {
                await measure(Action.progress) {
                    running.progress = min(0.99, running.progress + 0.001)
                    running.message = "認識中 \(Int(running.progress * 100))%"
                }
            }
            tick += 1
            let next = started.addingTimeInterval(Double(tick) * 0.1)
            await UILoadSelfTest.sleep(max(0, next.timeIntervalSinceNow))
        }
        if player.playingLineID != nil {
            await measure(Action.lineStop) { player.stopLine() }
        }
    }

    /// いまの位置の少し後ろの行を、1 行だけ再生する (音声が短いときは、音声の中の行)
    private func startLine(in job: Job) async {
        guard let segments = job.transcript?.segments, !segments.isEmpty else { return }
        var index = min(segments.count - 1, Int(simulated / UILoadSelfTest.rowSpacing) + 3)
        if job === running {
            // 文字起こし中のジョブでは、終わりのほうの行 (使う人が、出てきた行を聞き直すところ)
            index = max(0, segments.count - 1 - (lineStarts % 20))
        }
        if player.duration > 0, segments[index].start > player.duration - 1 {
            index = lineStarts % max(1, min(segments.count, Int(player.duration / UILoadSelfTest.rowSpacing) - 1))
        }
        let segment = segments[index]
        await measure(Action.lineStart) { player.playLine(id: segment.id, start: segment.start, end: segment.end) }
        lineStarts += 1
    }

    /// 文字起こし中のジョブへ、区間を別のスレッドから届ける (認識のスレッドと同じく、1 つずつ入れ物に入れる)
    private func deliver(_ count: Int) {
        guard let feed else { return }
        let segments = UILoadSelfTest.makeSegments(nextSegment..<(nextSegment + count))
        nextSegment += count
        delivered += count
        log.note(count == 1 ? "deliver 1 segment to the running job" : "deliver \(count) segments to the running job")
        DispatchQueue.global(qos: .userInitiated).async {
            for segment in segments { feed.append(segment) }
        }
    }

    /// 300 の区間をいっぺんに届け、すべてが文字起こしに入り、メインスレッドが空くまでを測る
    private func burst(_ count: Int) async {
        let target = (running.transcript?.segments.count ?? 0) + count
        let started = UILoadSelfTest.now()
        deliver(count)
        let deadline = Date().addingTimeInterval(5)
        while (running.transcript?.segments.count ?? 0) < target, Date() < deadline {
            await UILoadSelfTest.sleep(0.01)
        }
        let seconds = await UILoadSelfTest.untilIdle(since: started)
        measured[Action.burst, default: []].append(seconds)
    }

    /// 入れ物が、まとめた区間を足した (AppModel.liveFeed から)。足し始めてから、メインスレッドが空くまでを測る
    private func batchApplied(count: Int, started: UInt64) {
        log.note("batch of \(count) segments applied to the running job", at: started)
        guard let action = feedAction else { return }
        // 1 つずつの区間のはずが、まとめて足された (届けるのが遅れた) ものは、1 つの区間の操作に入れない
        if action != Action.steadyBatch, count != 1 { return }
        Task { @MainActor in
            let seconds = await UILoadSelfTest.untilIdle(since: started)
            self.measured[action, default: []].append(seconds)
        }
    }

    /// 操作をメインスレッドで行い、メインスレッドがまた空くまでを測る
    private func measure(_ action: String, _ body: () -> Void) async {
        log.note(action)
        let started = UILoadSelfTest.now()
        body()
        let seconds = await UILoadSelfTest.untilIdle(since: started)
        measured[action, default: []].append(seconds)
    }

    // MARK: 結果

    func report() -> [String] {
        /// 秒を、小数 1 けたのミリ秒の文字に
        func f(_ seconds: Double) -> String { String(format: "%.1f", UILoadSelfTest.ms(seconds)) }
        var lines: [String] = []
        if let summary = log.summaryLine { lines.append(summary) }
        lines.append("hover: not driven (the hover tint is state inside each row)")
        lines.append("actions: time from just before the action until the main thread is idle again"
                     + " (rounds of a main-queue block and the run loop's beforeWaiting, at least 2, until a round"
                     + " finds no new work)")
        for action in Action.all {
            let values = (measured[action] ?? []).sorted()
            guard !values.isEmpty else {
                lines.append("UI LOAD: action \"\(action)\": no samples")
                continue
            }
            lines.append("UI LOAD: action \"\(action)\": n \(values.count), median \(f(UILoadSelfTest.percentile(values, 0.5))) ms,"
                         + " p95 \(f(UILoadSelfTest.percentile(values, 0.95))) ms, max \(f(values[values.count - 1])) ms")
        }
        let samples = probe.samples()
        lines.append("watchdog: a background thread posts a block to the main queue every 50 ms (without waiting for the"
                     + " previous one) and records how long it waited")
        for name in Phase.all {
            let mine = samples.filter { $0.phase == name }
            let waits = mine.map(\.wait).sorted()
            let span = phaseTimes[name].map { UILoadSelfTest.seconds(from: $0.start, to: $0.end) } ?? 0
            let expected = Int(span / LatencyProbe.interval)
            lines.append("UI LOAD: phase \"\(name)\" (" + String(format: "%.1f", span) + " s): samples expected \(expected),"
                         + " sent \(probe.sent(in: name)), received \(mine.count),"
                         + " median \(f(UILoadSelfTest.percentile(waits, 0.5))) ms, p95 \(f(UILoadSelfTest.percentile(waits, 0.95))) ms,"
                         + " max \(f(waits.last ?? 0)) ms, main thread unavailable \(f(LatencyProbe.unavailable(mine))) ms")
        }
        // いちばん長い待ち 5 つ (4 つの段階の中。ジョブを選ぶ待ちは、上の select の行に出ている)
        let longest = samples.filter { Phase.all.contains($0.phase) }.sorted { $0.wait > $1.wait }.prefix(5)
        for (i, sample) in longest.enumerated() {
            lines.append("UI LOAD: stall \(i + 1): \(f(sample.wait)) ms in \"\(sample.phase)\","
                         + " last action before it: \(log.last(before: sample.ran) ?? "(none)")")
        }
        return lines
    }

    /// 目安を超えたもの (無ければ空)
    func limitFailures() -> [String] {
        func f(_ seconds: Double) -> String { String(format: "%.0f", UILoadSelfTest.ms(seconds)) }
        var failures: [String] = []
        func check(_ action: String, p95 p95Limit: Double?, max maxLimit: Double) {
            let values = (measured[action] ?? []).sorted()
            guard !values.isEmpty else {
                failures.append("\"\(action)\" was not measured")
                return
            }
            let p95 = UILoadSelfTest.percentile(values, 0.95)
            let worst = values[values.count - 1]
            if let p95Limit, p95 >= p95Limit {
                failures.append("\"\(action)\" p95 \(f(p95)) ms >= \(f(p95Limit)) ms")
            }
            if worst >= maxLimit {
                failures.append("\"\(action)\" max \(f(worst)) ms >= \(f(maxLimit)) ms")
            }
        }
        for action in [Action.tick, Action.lineStart, Action.lineStop, Action.appendOther, Action.progress] {
            check(action, p95: Limits.quickP95, max: Limits.quickMax)
        }
        check(Action.appendSelected, p95: Limits.appendP95, max: Limits.appendMax)
        check(Action.burst, p95: nil, max: Limits.burst)
        for action in [Action.selectBilingual, Action.selectPlain, Action.selectRunning] {
            check(action, p95: nil, max: Limits.selectMax)
        }
        // 見張り: 4 つの段階のどれも
        let watchdogLimits: [(phase: String, max: Double)] = [
            (Phase.bilingual, Limits.bilingualWatchdogMax),
            (Phase.plain, Limits.plainWatchdogMax),
            (Phase.steady, Limits.steadyWatchdogMax),
            (Phase.burst, Limits.burstWatchdogMax)
        ]
        let samples = probe.samples()
        for limit in watchdogLimits {
            let waits = samples.filter { $0.phase == limit.phase }.map(\.wait)
            guard let worst = waits.max() else {
                failures.append("the watchdog received no samples in \"\(limit.phase)\"")
                continue
            }
            if worst >= limit.max {
                failures.append("watchdog max \(f(worst)) ms >= \(f(limit.max)) ms in \"\(limit.phase)\"")
            }
        }
        return failures
    }
}

/// 起こした操作の記録 (どのスレッドからでも書ける)。長い待ちの前に、最後に何をしたかを出すのに使う
final class ActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(time: UInt64, name: String)] = []
    /// 操作の数などをまとめた 1 行 (メインスレッドだけで使う)
    var summaryLine: String?

    func note(_ name: String, at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        entries.append((time, name))
        lock.unlock()
    }

    /// time より前の、最後の操作
    func last(before time: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.time <= time }.max { $0.time < $1.time }?.name
    }
}

/// 続きを 1 回だけ再開する (眠る直前の知らせと、打ち切りの、先に来たほう)。
/// 眠る直前の観測者も持ち、再開するときに無効にする (CF の型は Sendable ではないので、ほかのクロージャには持たせない。
/// 観測者はメインの run loop の上でだけ動き、打ち切りもメインのキューから呼ぶ)
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt64?, Never>?
    private var observer: CFRunLoopObserver?

    init(_ continuation: CheckedContinuation<UInt64?, Never>) {
        self.continuation = continuation
    }

    /// 観測者を預かる。もう再開していれば、すぐに無効にする
    func hold(_ observer: CFRunLoopObserver?) {
        lock.lock()
        let done = continuation == nil
        if !done { self.observer = observer }
        lock.unlock()
        if done, let observer, CFRunLoopObserverIsValid(observer) { CFRunLoopObserverInvalidate(observer) }
    }

    func resume(_ value: UInt64?) {
        lock.lock()
        let c = continuation
        continuation = nil
        let o = observer
        observer = nil
        lock.unlock()
        if let o, CFRunLoopObserverIsValid(o) { CFRunLoopObserverInvalidate(o) }
        c?.resume(returning: value)
    }
}

/// メインスレッドの待ちを、別のスレッドから測る見張り: 50 ms ごとに (前の合図が戻るのを待たずに) メインのキューへ
/// 小さな仕事を積み、始まるまでの時間を、積んだときの段階の名前とともに記録する
final class LatencyProbe: @unchecked Sendable {
    struct Sample {
        var phase: String
        /// 積んだ時刻と、始まった時刻 (uptime のナノ秒)
        var posted: UInt64
        var ran: UInt64
        var wait: Double { UILoadSelfTest.seconds(from: posted, to: ran) }
    }

    /// 積む間隔 (秒)
    static let interval = 0.05

    private let lock = NSLock()
    private var recorded: [Sample] = []
    private var sentCount: [String: Int] = [:]
    private var phase = "between phases"
    private var running = false

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            let origin = DispatchTime.now().uptimeNanoseconds
            var n: UInt64 = 0
            while let phase = self.nextPhase() {
                let posted = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    self.record(Sample(phase: phase, posted: posted, ran: DispatchTime.now().uptimeNanoseconds))
                }
                // 決まった刻みで積む (遅れても、前の合図を待たない)
                n += 1
                let next = origin + n * UInt64(LatencyProbe.interval * 1_000_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                if next > now { Thread.sleep(forTimeInterval: Double(next - now) / 1_000_000_000) }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func setPhase(_ name: String) {
        lock.lock()
        phase = name
        lock.unlock()
    }

    func samples() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sent(in phase: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sentCount[phase] ?? 0
    }

    /// 待っていた区間 (積んでから始まるまで) を重ねた長さ: メインスレッドが合図に応えられなかった時間
    static func unavailable(_ samples: [Sample]) -> Double {
        var total: UInt64 = 0
        var end: UInt64 = 0
        for s in samples.sorted(by: { $0.posted < $1.posted }) {
            let from = max(s.posted, end)
            if s.ran > from { total += s.ran - from }
            end = max(end, s.ran)
        }
        return Double(total) / 1_000_000_000
    }

    /// 動いているなら、いまの段階の名前を返し、積んだ数を数える。止めたら nil
    private func nextPhase() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return nil }
        sentCount[phase, default: 0] += 1
        return phase
    }

    private func record(_ sample: Sample) {
        lock.lock()
        recorded.append(sample)
        lock.unlock()
    }
}
