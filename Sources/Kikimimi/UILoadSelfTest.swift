import AppKit
import Foundation
import KikimimiCore

/// `Kikimimi --selftest-ui-load [行数] [--audio <音声>] [--report <ファイル>]`
///
/// ふつうに起動して (画面も出す)、行数 (既定 3000) の結果を出したまま、使っているときと同じ変化を数秒間起こし、
/// そのあいだメインスレッドがどれだけ待たせるかを、別のスレッドから測る (長い録音で画面が固まった不具合の確認)。
/// 起こす変化: 再生位置 (1 秒に 5 回)、1 行だけの再生の開始と停止 (1 秒に 1 回)、
/// 別のジョブの文字起こしに区間を足す (1 秒に 10 回)。対訳の表示 → ふつうの表示 → 文字起こし中のジョブの表示の順に切り替える。
/// 行にマウスを載せたときの色は、行の中だけの状態なので、外から変えられない (ここでは起こさない)。
///
/// `--audio` を付けると、その音声で 1 行 (5〜7 秒あたり) を本当に再生し、行の終わりで自分で止まるかと、
/// そのあと下の再生ボタンで行の終わりから続くかも確かめる。行は 0 秒から押すときと、ふつうの再生が後ろ (30 秒あたり)
/// にいるときに押すときの 2 回。音を出せるかは先にふつうの再生で確かめ、出せない Mac では、その部分は飛ばす。
///
/// 終了コード: 0 = 成功、1 = メインのウインドウが出ない、3 = 終わらない (メインスレッドが止まっている)、
/// 5 = 重い (UI LOAD: SLOW)、6 = 1 行だけの再生が行の終わりで止まらない・続きから再生しない
enum UILoadSelfTest {
    /// 変化を起こす時間 (秒): 対訳の表示 / ふつうの表示 / 文字起こし中のジョブ
    private static let phases: [Double] = [2.5, 2.5, 2.0]
    /// 合格の目安 (秒): いちばん長い待ちと、95 パーセンタイル
    private static let maxLimit = 1.0
    private static let p95Limit = 0.25
    /// 作る行の長さと間隔 (秒)
    private static let rowSpacing = 2.5
    private static let rowLength = 2.3

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

        // 2. 終わったジョブ (rows 行) と、文字起こし中のジョブ (その半分から増えていく) を入れて、終わったほうを選ぶ。
        // 音声が無いときは、無いファイルを開く (行の再生の印は出て、再生しても音は出ない)
        let url = audio ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kikimimi-ui-load-no-audio.wav")
        let done = Job(name: "画面の重さの確認 (\(rows) 行)", url: url)
        done.transcript = Transcript(sourceName: done.name, segments: makeSegments(0..<rows), language: "en",
                                     duration: Double(rows) * rowSpacing, elapsed: 1)
        done.status = .done
        done.progress = 1
        done.message = "完了"
        done.exported = true
        // 対訳で出す (設定は変えない: 行の「訳」を押したときと同じ、このジョブだけの対訳)
        done.showsLineTranslations = true
        let runningCount = max(rows / 2, 1)
        let running = Job(name: "文字起こし中 (確認用)", url: url)
        running.transcript = Transcript(sourceName: running.name, segments: makeSegments(0..<runningCount),
                                        language: "en", duration: Double(rows) * rowSpacing)
        running.status = .running
        running.progress = 0.5
        running.message = "認識中 50%"
        running.exported = true
        model.jobs.insert(running, at: 0)
        model.jobs.insert(done, at: 0)
        let selectStarted = Date()
        model.select(done)
        await mainThreadTurn()
        lines.append(String(format: "select: the main thread was free again after %.0f ms", ms(Date().timeIntervalSince(selectStarted))))
        await sleep(1.0)

        // 3. 変化を起こしながら、メインスレッドの待ちを測る
        let player = model.player
        let probe = LatencyProbe()
        probe.start()
        let started = Date()
        let total = phases.reduce(0, +)
        var tick = 0
        var simulated = 0.0
        var nextRunning = runningCount
        var phase = 0
        var lineStarts = 0
        while true {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= total { break }
            // 表示を切り替える: 対訳 → ふつう → 文字起こし中のジョブ
            let wanted = elapsed < phases[0] ? 0 : (elapsed < phases[0] + phases[1] ? 1 : 2)
            if wanted != phase {
                phase = wanted
                if phase == 1 { done.showsLineTranslations = false }
                if phase == 2 {
                    player.stopLine()
                    model.select(running)
                }
            }
            // 文字起こしの続き (1 秒に 10 回)。AppModel が区間を受け取ったときと同じ書き方
            running.transcript?.segments.append(contentsOf: makeSegments(nextRunning..<(nextRunning + 1)))
            nextRunning += 1
            running.progress = min(0.99, running.progress + 0.001)
            running.message = "認識中 \(Int(running.progress * 100))%"
            // 再生位置 (1 秒に 5 回)。行が 1〜2 回に 1 回変わるように進める
            if tick % 2 == 0, player.playingLineID == nil {
                simulated += 1.3
                if simulated > Double(rows) * rowSpacing { simulated = 0 }
                player.selfTestSetTime(simulated, playing: true)
            }
            // 1 行だけの再生の開始と停止 (1 秒に 1 回)
            if tick % 10 == 5 {
                if player.playingLineID != nil {
                    player.stopLine()
                } else if let segments = (phase == 2 ? running : done).transcript?.segments, !segments.isEmpty {
                    var index = min(segments.count - 1, Int(simulated / rowSpacing) + 3)
                    // 音声が短いときは、音声の中の行を選ぶ (後ろの行は再生しない)
                    if player.duration > 0, segments[index].start > player.duration - 1 {
                        index = (tick / 10) % max(1, min(segments.count, Int(player.duration / rowSpacing) - 1))
                    }
                    let segment = segments[index]
                    player.playLine(id: segment.id, start: segment.start, end: segment.end)
                    lineStarts += 1
                }
            }
            tick += 1
            let next = started.addingTimeInterval(Double(tick) * 0.1)
            await sleep(max(0, next.timeIntervalSinceNow))
        }
        player.stopLine()
        player.selfTestSetTime(simulated, playing: false)
        let driven = Date().timeIntervalSince(started)
        probe.stop()
        // 届いていない合図を待つ
        await sleep(0.3)
        let result = probe.summary()
        lines.append(String(format: "driven for %.1f s: %d ticks, %d one-line starts, %d segments appended",
                            driven, tick, lineStarts, nextRunning - runningCount))
        lines.append("hover: not driven (the hover tint is state inside each row)")
        lines.append(String(format: "UI LOAD: rows %d, samples %d (sent %d), median %.1f ms, p95 %.1f ms, max %.1f ms",
                            rows, result.count, result.sent, ms(result.median), ms(result.p95), ms(result.max)))
        let slow = result.count == 0 || result.max >= maxLimit || result.p95 >= p95Limit
        if slow {
            lines.append(String(format: "UI LOAD: SLOW (limits: max < %.0f ms, p95 < %.0f ms)", ms(maxLimit), ms(p95Limit)))
        }

        // 4. 音声があれば、1 行を本当に再生して、行の終わりで止まるかを見る
        var lineFailed = false
        if let audio {
            model.select(done)
            lineFailed = await checkLinePlayback(player: player, segments: done.transcript?.segments ?? [],
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

    /// 英語と日本語を交互に、ありそうな長さで。英語の 3 行に 1 行は訳つき (対訳の表示を通す)
    private static func makeSegments(_ range: Range<Int>) -> [TranscriptSegment] {
        range.map { i in
            let start = Double(i) * rowSpacing
            let english = i % 2 == 0
            let text = english ? englishLines[(i / 2) % englishLines.count]
                : japaneseLines[(i / 2) % japaneseLines.count]
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

    /// メインスレッドが、いま積まれている仕事 (選んだあとの描き直しを含む) を終えるまで待つ
    @MainActor
    private static func mainThreadTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private static func ms(_ seconds: Double) -> Double { seconds * 1000 }

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

/// メインスレッドの待ちを、別のスレッドから測る: 50 ms ごとにメインのキューへ小さな仕事を積み、始まるまでの時間を記録する
final class LatencyProbe: @unchecked Sendable {
    struct Summary {
        var count = 0
        var sent = 0
        var median = 0.0
        var p95 = 0.0
        var max = 0.0
    }

    private let lock = NSLock()
    private var samples: [Double] = []
    private var sent = 0
    private var running = false

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            while self.isRunning {
                let posted = DispatchTime.now().uptimeNanoseconds
                self.countSent()
                DispatchQueue.main.async {
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000_000
                    self.record(waited)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func summary() -> Summary {
        lock.lock()
        let sorted = samples.sorted()
        let sentCount = sent
        lock.unlock()
        guard !sorted.isEmpty else { return Summary(sent: sentCount) }
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        return Summary(count: sorted.count, sent: sentCount, median: percentile(0.5), p95: percentile(0.95),
                       max: sorted[sorted.count - 1])
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func countSent() {
        lock.lock()
        sent += 1
        lock.unlock()
    }

    private func record(_ seconds: Double) {
        lock.lock()
        samples.append(seconds)
        lock.unlock()
    }
}
