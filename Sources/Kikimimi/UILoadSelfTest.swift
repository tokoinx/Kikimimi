import AppKit
import CoreFoundation
import Foundation
import KikimimiCore

/// `Kikimimi --selftest-ui-load [行数] [--audio <音声>] [--report <ファイル>] [--screenshots <フォルダ>]`
///
/// ふつうに起動して (画面も出す)、行数 (既定 3000) の結果を出したまま、使っているときと同じ操作を起こし、
/// 操作ごとに、メインスレッドがまた空くまでの時間を測る (長い録音を文字起こししている最中に画面が固まった不具合の確認)。
///
/// 入れるジョブ: 終わったジョブ 2 つ (対訳で出す英語と日本語のもの・ふつうに出す日本語だけのもの、どちらも行数の行)、
/// 文字起こし中のジョブ 1 つ (行数の行から増えていく)。文字起こし中のジョブへの区間は、AppModel.run と同じ入れ物
/// (AppModel.liveFeed) に、認識と同じく別のスレッドから届ける (まとめて足すところも測る)。
///
/// 段階 (それぞれのあいだ、別のスレッドの見張りも 50 ms ごとにメインスレッドの待ちを測る):
/// 1. 終わったジョブ (対訳): ふつうの再生の再生位置 (本当の見張りと同じく 1 秒に 5 回、0.2 秒ずつ進む。いまの行が
///    変わるのは数秒に 1 回で、変わった回は「current row changes」として別に数える)。後半は、1 行だけの再生の開始と
///    停止 (1 秒に 1 回ずつ、0.5 秒鳴らす)。選んでいない文字起こし中のジョブへの区間 (1.5 秒に 1 回、1 つずつ)、
///    その進み具合 (1 秒に 2 回)
/// 2. 終わったジョブ (ふつう): 1 と同じ
/// 3. 文字起こし中のジョブ (1 秒に 10 区間): 初めの 2.5 秒は再生なし (一覧の終わりを追いかける)、
///    そのあとは 1 行だけの再生の開始と停止 (1 秒に 1 回ずつ) と、その行の中の再生位置。進み具合 (1 秒に 2 回)。
///    再生位置・1 行だけの再生は「(while rows are added)」の付いた名前で別に数える (1 秒に 1 回ほど、まとめて足すのと
///    測る間が重なり、その手間も入る)。1・2 の名前の目安は、1・2 の段階で測ったものだけに当てる
/// 4. 文字起こし中のジョブ (いっぺんに届く): 1 つずつの区間 (6 回、まとめる間より長くあけて) と、
///    300 の区間をいっぺんに (3 回)
/// ジョブを選ぶ操作は段階の外で測る (3 回ずつ)。測った数が 20 に足りない操作は、p95 を出すが目安と比べず、最大だけを比べる。
/// ジョブを選ぶ操作は、測った順の値も出す (初めの 1 回だけが遅いのか、あとの回も遅いのかを見分けるため)。
/// 段階 1 のすぐあと (段階の外) に、同じジョブを一覧の始めで出したまま、再生位置を 8 割ほど下の行へ動かして再生し、
/// また始めのほうの行へ戻す (2 回ずつ。再生のつまみを遠くへ動かして再生したとき)。目安は、ジョブを選ぶのと同じく最大だけ。
/// ジョブを選ぶ操作と、再生位置を遠くへ動かす操作は、その 1 回で一覧が作った行の数 (PlayableRow の init) と、body を
/// 動かした行の数を出し、body の数を目安 (600) と比べる (一覧が見える分だけを並べているか。時間だけでは、遅い実行機と
/// 見分けにくい。init は、一覧が終わりへ飛ぶとすべての行の分が呼ばれ、数千になるが、それは軽いので比べない)。
/// 行にマウスを載せたときの色は、行の中だけの状態なので、外から変えられない。
/// 段階の前に、画面を使わずに、一覧の行を作る手間 (TranscriptRowCache: すべてから作り直す / 10 区間を足す) も測る。
///
/// `--audio` を付けると、その音声で 1 行 (5〜7 秒あたり) を本当に再生し、行の終わりで自分で止まるかと、
/// そのあと下の再生ボタンで行の終わりから続くかも確かめる。行は 0 秒から押すときと、ふつうの再生が後ろ (30 秒あたり)
/// にいるときに押すときの 2 回。音を出せるかは先にふつうの再生で確かめ、出せない Mac では、その部分は飛ばす。
///
/// `--screenshots` を付けると、測り終えたあと (測る段階の外で) ウインドウを 1200 x 800 にして、決まった場面の
/// ウインドウの絵を PNG で、そのフォルダに残す (無ければ作る)。絵を残せなくても、終了コードは変えない。
///
/// 測り終えたあと (絵も残すときは、その 06 のあと) に、保存の確認 (LIBRARY CHECK) も行う: 始めにモデルの保存先を
/// 一時フォルダにしておき (終わりに消す)、ふだんと同じ AppModel の関数で、メモ・版の保存・上書き・戻す・消すを行い、
/// フォルダを新しい LibraryStore で読み直して比べる。`--screenshots` なら、そのあとメモの欄 (07) と履歴の画面 (08) の絵も残す。
///
/// 終了コード: 0 = 成功、1 = メインのウインドウが出ない、3 = 終わらない (メインスレッドが止まっている)、
/// 5 = 重い (UI LOAD: SLOW)、6 = 1 行だけの再生が行の終わりで止まらない・続きから再生しない、
/// 7 = 保存の確認に失敗 (LIBRARY CHECK FAILED)、8 = 練習の確認に失敗 (PRACTICE CHECK FAILED)
///
/// `--audio` のとき、行の確認のあとに練習の確認 (PRACTICE CHECK) も行う: 本当の練習の係 (PracticeController) と
/// 再生の係で、遅くした 1 行・繰り返し・間・自動で次へ・次と前とまた・スペースキー を確かめる (30 秒ほど。音を出せない Mac では飛ばす)。
/// `--screenshots` なら、そのあと練習の絵 (09 隠した行と目のボタン、10 書き取りの欄と答え合わせ) も残す
enum UILoadSelfTest {
    /// 合格の目安 (秒)。GitHub の macOS の実行機 (3 コア、仮想の GPU。ふつうの Mac より遅い) のための値。
    /// p95 は 95 パーセンタイル、max は最大
    fileprivate enum Limits {
        /// 再生位置 (0.2 秒進む。いまの行は変わらない): 一覧も行も描き直さないので、ほぼ何もかからない
        static let tickP95 = 0.050
        static let tickMax = 0.250
        /// いまの行が変わる再生位置・1 行だけの再生の開始と停止: 色が変わる行だけを描き直す
        static let rowP95 = 0.120
        static let rowMax = 0.350
        /// 進み具合・選んでいないジョブへの区間
        static let progressP95 = 0.150
        static let progressMax = 0.500 // 測った最大 360 ms (まとめて足す 1 回と重なったとき)
        /// 選んでいる、文字起こし中のジョブに区間を 1 つ足す
        static let appendP95 = 0.250
        static let appendMax = 0.500
        /// 段階 3 で、まとめて足した 1 回
        static let steadyBatchP95 = 0.300
        static let steadyBatchMax = 0.600 // 測った最大 290 ms (中央の値 110〜180 ms。遅い実行機のぶん余らせる)
        /// 300 の区間をまとめて足し始めてから、すべてが一覧に入り、メインスレッドが空くまで
        static let burst = 1.5
        /// 段階ごとに、そのあいだに見張りが測った最大の待ち (段階 1・2・3)
        static let watchdogMax = 0.5
        /// 段階 4 (300 の区間がいっぺんに届く): いっぺんに足すあいだは待つので、300 の区間の目安と同じ
        static let burstWatchdogMax = 1.5
        /// 段階 3 (文字起こし中のジョブ、1 秒に 10 区間) で、メインスレッドが見張りに応えられなかった時間の割合
        static let steadyUnavailableShare = 0.25 // 測った値 4.5〜12.4% (遅い実行機のぶん余らせる)
        /// 段階 3 (文字起こし中のジョブ、1 秒に 10 区間) の再生位置・いまの行が変わる再生位置・1 行だけの再生の開始と停止。
        /// まとめて足す 1 回と測る間が重なると、その手間 (GitHub の実行機で 130〜260 ms ほど) も入る。
        /// GitHub の実行機に合わせた値で、測った値がたまったら詰める
        static let whileAddedP95 = 0.400
        static let whileAddedMax = 0.700
        /// ジョブを選ぶ (最大だけ)
        static let selectMax = 3.0 // 測った値 0.22〜0.94 秒
        /// 終わったジョブの中で、再生位置を遠くへ動かす (最大だけ)。新しく足したもので、まだ測った値に合わせていない
        /// (ジョブを選ぶのと同じ値にしてある)
        static let jumpMax = 3.0
        /// ジョブを選ぶ 1 回・再生位置を遠くへ動かす 1 回で、一覧が body を動かす行の数 (秒ではなく行の数。init の数ではない:
        /// 一覧が終わりへ飛ぶと、LazyVStack はすべての行の init を呼ぶので数千になるが、それは軽く、並べるのは見える分だけ)。
        /// ウインドウに出る行は 15〜40 ほどで、LazyVStack はその前後も少し並べる。数千行の body が動くなら、一覧が行を
        /// 遅れて並べなくなっている (親の部品が一覧に望みの大きさを尋ねたとき: HSplitView に入れたときは、選ぶ 1 回が
        /// 5〜21 秒になった。一覧が前のジョブの、下まで動かした位置のまま並べたとき: 16.8 秒)
        static let selectRowsBuiltMax = 600
        /// 測った数がこれより少ない操作は、p95 を目安と比べない (少ないと、p95 は最大と同じになる)。最大だけを比べる
        static let p95MinSamples = 20
    }

    /// 測る操作の名前 (出力の順)
    fileprivate enum Action {
        static let selectBilingual = "select finished job (bilingual)"
        static let selectPlain = "select finished job (plain)"
        static let selectRunning = "select running job"
        /// 終わったジョブ (対訳) を一覧の始めで出したまま、再生位置を 8 割ほど下の行の始まりへ動かして再生する
        /// (再生のつまみを遠くへ動かして再生したとき)。そのあと、始めのほうの行へ戻す
        static let jumpFar = "jump far ahead (bilingual)"
        static let jumpBack = "jump back to the top (bilingual)"
        /// 再生位置が 0.2 秒進み、いまの行は変わらない
        static let tick = "time tick"
        /// 再生位置が 0.2 秒進み (または 1 行だけの再生のあと、ふつうの再生の位置へ戻り)、いまの行が変わる
        static let rowChange = "current row changes"
        static let lineStart = "one-line start"
        static let lineStop = "one-line stop"
        static let appendSelected = "append 1 segment to the selected running job"
        static let appendOther = "append 1 segment to a job that is not selected"
        static let burst = "burst: 300 segments delivered at once to the selected running job"
        static let progress = "progress update"
        /// 段階 3 で、まとめて足した 1 回 (1 秒に 10 区間。数千行ではまとめる間が 1 秒なので、1 回に 10 区間ほど)
        static let steadyBatch = "steady: one batch applied to the selected running job (10 segments/s)"
        /// 段階 3 (文字起こし中のジョブ、1 秒に 10 区間) で起こした、上の 4 つ。まとめて足す 1 回と測る間が重なると、
        /// その手間も入るので、別に数える
        static let tickWhileAdded = "time tick (while rows are added)"
        static let rowChangeWhileAdded = "current row changes (while rows are added)"
        static let lineStartWhileAdded = "one-line start (while rows are added)"
        static let lineStopWhileAdded = "one-line stop (while rows are added)"
        /// 段階 3 のあいだに測ったときの名前
        static let whileAdded: [String: String] = [
            tick: tickWhileAdded,
            rowChange: rowChangeWhileAdded,
            lineStart: lineStartWhileAdded,
            lineStop: lineStopWhileAdded
        ]

        static let all = [selectBilingual, selectPlain, selectRunning, jumpFar, jumpBack, tick, rowChange, lineStart, lineStop,
                          tickWhileAdded, rowChangeWhileAdded, lineStartWhileAdded, lineStopWhileAdded,
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

    /// makeSegments で作った rows 行のうち、位置 t (秒) にある行の番号。CurrentLineTracker と同じ決まり
    /// (t までに始まった最後の行で、t がその行の終わりより前。行のあいだなら nil)
    fileprivate static func rowIndex(at t: Double, rows: Int) -> Int? {
        guard t >= 0 else { return nil }
        let index = Int(t / rowSpacing)
        guard index < rows else { return nil }
        let start = Double(index) * rowSpacing
        return t < start + max(rowLength, 0.3) ? index : nil
    }

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
        let screenshots = value(after: "--screenshots", in: arguments).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        let header = [
            LaunchLog.versionLine + " UI load self-test",
            LaunchLog.environmentLine,
            "rows: \(rows), audio: \(audio?.path ?? "(none)")",
        ]
        // メインスレッドが止まったまま終わらないなら、別のスレッドから知らせて終わる
        // (8000 行では、段階と、行を作る手間を測るのとで 2 分近くかかることがある)
        // ウインドウの絵も残すときは、場面を出して落ち着くのを待つぶん、長くかかる
        // 保存の確認 (数千行の結果を何回か書く) のぶんも足す
        // 音声があるときは、練習の確認 (30 秒ほど) のぶんも足す。絵のときは、練習の絵 (09・10) のぶんも入れてある
        let hangLimit = (screenshots == nil ? 200.0 : 300.0) + (audio == nil ? 0 : 45.0)
        DispatchQueue.global().asyncAfter(deadline: .now() + hangLimit) {
            finish(header + ["UI LOAD FAILED: the self-test did not finish in \(Int(hangLimit)) s"
                             + " (the main thread may be stuck)"], code: 3, reportPath: reportPath)
        }
        Task { @MainActor in
            await run(rows: rows, audio: audio, screenshots: screenshots, header: header,
                      reportPath: reportPath)
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    @MainActor
    private static func run(rows: Int, audio: URL?, screenshots: URL?, header: [String],
                            reportPath: String?) async {
        var lines = header
        // 一覧が、絵を残すときに動かす口を入れる (一覧が出る前に)
        UILoadHooks.isActive = true
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
        // 保存先を、空の一時フォルダにする (ふだんのライブラリには書かない。終わりに消す)
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimimi-ui-load-library-\(UUID().uuidString)", isDirectory: true)
        model.useLibrary(at: libraryRoot)

        // 2. 終わったジョブ 2 つと、文字起こし中のジョブを入れる。
        // 音声が無いときは、無いファイルを開く (行の再生の印は出て、再生しても音は出ない)
        let url = audio ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kikimimi-ui-load-no-audio.wav")
        let load = LoadRun(model: model, rows: rows, url: url)
        load.insertJobs()
        // 画面を使わずに、一覧の行を作る手間を測る
        lines += load.costReport()
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

        // 測り終えたあとで、ウインドウの絵を残す (測る段階の外。見張りも止めてある)
        if let screenshots {
            lines += await load.takeScreenshots(into: screenshots)
        }

        // 保存の確認 (ふだんと同じ AppModel の関数で)。絵を残すときは、そのあとメモの欄と履歴の画面も撮る
        let library = await load.libraryCheck(root: libraryRoot)
        lines += library.lines
        if let screenshots {
            lines += await load.takeLibraryScreenshots(into: screenshots)
        }

        // 4. 音声があれば、1 行を本当に再生して、行の終わりで止まるかを見る
        var lineFailed = false
        var practiceFailed = false
        if let audio {
            model.select(load.doneBilingual)
            let line = await checkLinePlayback(player: model.player, segments: load.doneBilingual.transcript?.segments ?? [],
                                               audio: audio, lines: &lines)
            lineFailed = line.failed
            // 5. 練習 (続けて流す・速さ・繰り返し・間・自動で次へ・キー) を、本当の練習の係と再生の係で確かめる。音を出せない Mac では飛ばす
            if line.played {
                practiceFailed = await PracticeCheck.run(model: model, job: load.doneBilingual, lines: &lines)
            } else {
                lines.append("PRACTICE: skipped (no audio playback here)")
            }
        }
        // 練習の絵 (09 隠した行、10 書き取り)。音声がなくても撮れる
        if let screenshots {
            lines += await load.takePracticeScreenshots(into: screenshots)
        }
        let code: Int32 = slow ? 5 : (lineFailed ? 6 : (library.failed ? 7 : (practiceFailed ? 8 : 0)))
        if code == 0 { lines.append("UI LOAD OK") }
        // 書きかけを待ってから、確認用のライブラリの一時フォルダを消す
        model.flushLibrary()
        try? FileManager.default.removeItem(at: libraryRoot)
        finish(lines, code: code, reportPath: reportPath)
    }

    /// 5〜7 秒あたりの行を再生して、行の終わりで自分で止まるかと、そのあとの再生ボタンで続きから再生するかを確かめる。
    /// failed: 失敗なら true (音を出せない Mac では確かめずに false)。played: この Mac で音を出せた (練習の確認に進める)
    ///
    /// 音を出せるかは、行ではなく、ふつうの再生で先に確かめる (行がすぐ止まる不具合と、音を出せない Mac とは、
    /// 行の再生だけでは見分けられない)。行は 2 回再生する: 0 秒から押したときと、ふつうの再生が行より後ろ (30 秒あたり)
    /// にいるときに押したとき (止める位置より後ろにいると、押した行がすぐ止まる不具合があった)
    @MainActor
    private static func checkLinePlayback(player: PlayerController, segments: [TranscriptSegment], audio: URL,
                                          lines: inout [String]) async -> (failed: Bool, played: Bool) {
        var waited = 0
        while player.duration <= 0, waited < 40 {
            await sleep(0.1)
            waited += 1
        }
        guard player.duration > 0,
              let segment = segments.first(where: { $0.start >= 5 }), segment.end < player.duration else {
            lines.append("UI LOAD: no audio playback here (the audio did not open: duration \(player.duration) s)")
            return (false, false)
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
            return (false, false)
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
        return (failed, true)
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

/// 画面の重さの確認から、結果の一覧を動かすための口。確認のあいだだけ、一覧 (TranscriptListView) が現れたときに入れる
/// (ScrollViewProxy と ListFollow は一覧の中にしか無い)。ふだんの起動では、どれも nil のまま。
/// 一覧はジョブごとに作り直すので、ジョブを選ぶと、新しい一覧の register と古い一覧の unregister が、どちらが先にも来る:
/// register はいつも入れ替え (あとから現れた一覧のものになる)、unregister は、入れた一覧のものが残っているときだけ外す
@MainActor
enum UILoadHooks {
    /// 行のどちらの端に合わせて動かすか
    enum Edge {
        case top
        case bottom
    }

    /// 確認の最中か (一覧は、このときだけ下の口を入れる)
    static var isActive = false
    /// 一覧を、その行 (行の id) が上の端か下の端に来るように動かす
    static var scrollList: (@MainActor (UUID, Edge) -> Void)?
    /// 一覧の終わりを追いかけるか (ListFollow.isOn) を変える
    static var setFollowing: (@MainActor (Bool) -> Void)?
    /// 一覧の終わりを追いかけているか
    static var isFollowing: (@MainActor () -> Bool)?
    /// 一覧が作った行の数 (PlayableRow を作った回数。確認の最中だけ数える)。一覧が終わりへ飛ぶと、
    /// LazyVStack はすべての行を作る (1 つ 0.1 ms ほど) ので、数千にもなる。重さは次の rowBodies で見る
    static var rowsBuilt = 0
    /// 一覧が body を動かした行の数 (PlayableRow.body の回数。確認の最中だけ数える)。本当に並べた行で、手間はこちら
    static var rowBodies = 0
    /// いまの口を入れた一覧 (その一覧の ListFollow)
    private static var owner: ObjectIdentifier?

    /// 現れた一覧が、口を入れる (前の一覧のものは入れ替える)
    static func register(owner: ObjectIdentifier,
                         scrollList: @escaping @MainActor (UUID, Edge) -> Void,
                         setFollowing: @escaping @MainActor (Bool) -> Void,
                         isFollowing: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.scrollList = scrollList
        self.setFollowing = setFollowing
        self.isFollowing = isFollowing
    }

    /// 消えた一覧が、口を外す。ほかの一覧 (あとから現れた、新しいジョブの一覧) が入れたものは外さない
    static func unregister(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        scrollList = nil
        setFollowing = nil
        isFollowing = nil
    }
}

/// 練習の確認 (PRACTICE CHECK)。本当の練習の係 (PracticeController) と再生の係 (PlayerController) で、終わったジョブ (対訳) の
/// 5 秒あたりの行 (前後を広げて 4.85〜7.55 秒) を流して確かめる。行の確認 (checkLinePlayback) で音を出せたときだけ呼ぶ。
/// a. 速さ 0.5 で 1 回: 行の終わりで自分で止まり (位置が行の終わりから 0.15 秒以内)、かかった時間が行の長さの 1.6〜2.6 倍
/// b. 速さ 1.25、2 回、間なし: 同じ行が 2 回始まり、そのあと行の終わりで止まる
/// c. 速さ 1.25、2 回、行と同じ長さの間: 2 回目は、1 回目が終わってから 1.0 秒より後に始まる
/// d. 速さ 1.25、自動で次へ: 1 行目のあと、次の行が自分で始まる。次の行の途中で止めると、そのあと何も鳴らない
/// e. 次・前・もう一度で、いまの行が思ったとおりに動く。最初の行で「前」を押しても何もしない
/// f. スペースキーと同じ道 (togglePlay) で、流している最中も、間を待っている最中も、続けて流すのが止まる
/// 終わったら、練習の設定を決まりの値に戻す。失敗なら true
@MainActor
enum PracticeCheck {
    static func run(model: AppModel, job: Job, lines: inout [String]) async -> Bool {
        let practice = model.practice
        let player = model.player
        let started = Date()
        let segments = job.transcript?.segments ?? []
        guard let i = segments.firstIndex(where: { $0.start >= 5 }), i > 0, i + 1 < segments.count,
              segments[i + 1].end + PlayerController.lineTail < player.duration else {
            lines.append("PRACTICE CHECK FAILED: setup (no row at 5 s with a next row inside the audio,"
                         + " audio \(player.duration) s)")
            return true
        }
        let row = segments[i]
        let next = segments[i + 1]
        let first = segments[0]
        let from = max(0, row.start - PlayerController.lineLeadIn)
        let to = min(row.end + PlayerController.lineTail, player.duration)
        let length = to - from
        var failedStep: String?
        func report(_ step: String, _ ok: Bool, _ detail: String) {
            lines.append("PRACTICE: \(step): " + (ok ? "ok" : "FAILED") + " (\(detail))")
            if !ok, failedStep == nil { failedStep = step }
        }
        func position() -> Double { player.selfTestPlayback?.time ?? -1 }
        func idle() -> Bool { practice.activeLineID == nil && !player.isPlaying }
        func starts(since: Date) -> [PracticeController.Event] {
            practice.events.filter { $0.kind == .started && $0.time >= since }
        }
        func finishes(since: Date) -> [PracticeController.Event] {
            practice.events.filter { $0.kind == .finished && $0.time >= since }
        }

        practice.stop()
        if player.isPlaying { player.togglePlay() }
        practice.showsDictation = false
        lines.append(String(format: "practice: row %.2f-%.2f s (%.2f s), next row %.2f s, first row %.2f s",
                            from, to, length, next.start, first.start))

        // a. 速さ 0.5 で 1 回
        practice.settings = PracticeSettings(rate: 0.5)
        let sinceA = Date()
        practice.toggleLine(row.id)
        let startedA = practice.activeLineID == row.id
        let doneA = await waitUntil(length / 0.5 + 3) { idle() }
        let wallA = Date().timeIntervalSince(sinceA)
        let posA = position()
        let ratio = wallA / length
        report("a rate 0.5", startedA && doneA && abs(posA - to) <= 0.15 && ratio >= 1.6 && ratio <= 2.6,
               "started \(startedA), stopped by itself \(doneA)"
               + String(format: " after %.2f s for a %.2f s row (%.2fx), position %.2f s (row end %.2f s)",
                        wallA, length, ratio, posA, to))

        // b. 速さ 1.25、2 回、間なし
        practice.settings = PracticeSettings(rate: 1.25, repeatCount: 2)
        let sinceB = Date()
        practice.toggleLine(row.id)
        let doneB = await waitUntil(2 * length / 1.25 + 4) { idle() }
        let posB = position()
        await UILoadSelfTest.sleep(0.6)
        let startsB = starts(since: sinceB)
        report("b repeat 2", doneB && startsB.count == 2 && startsB.allSatisfy { $0.id == row.id } && abs(posB - to) <= 0.15
               && idle(),
               "plays started \(startsB.count), all the same row \(startsB.allSatisfy { $0.id == row.id }),"
               + " stopped \(doneB)" + String(format: ", position %.2f s (row end %.2f s)", posB, to))

        // c. 速さ 1.25、2 回、行と同じ長さの間
        practice.settings = PracticeSettings(rate: 1.25, repeatCount: 2, gap: .lineLength)
        let gap = PracticeSettings.lineLengthGap(duration: row.end - row.start, rate: 1.25)
        let sinceC = Date()
        practice.toggleLine(row.id)
        var sawWaiting = false
        let doneC = await waitUntil(2 * length / 1.25 + gap + 4) {
            if practice.isWaiting { sawWaiting = true }
            return idle()
        }
        let startsC = starts(since: sinceC)
        let finishesC = finishes(since: sinceC)
        var gapC = -1.0
        if startsC.count >= 2, let end = finishesC.first?.time { gapC = startsC[1].time.timeIntervalSince(end) }
        report("c gap", doneC && startsC.count == 2 && gapC >= 1.0 && sawWaiting,
               "plays started \(startsC.count), waited \(sawWaiting)"
               + String(format: ", second play %.2f s after the first ended (gap %.2f s)", gapC, gap))

        // d. 速さ 1.25、自動で次へ
        practice.settings = PracticeSettings(rate: 1.25, autoAdvance: true)
        let sinceD = Date()
        practice.toggleLine(row.id)
        let reachedNext = await waitUntil(length / 1.25 + 3) { player.playingLineID == next.id }
        await UILoadSelfTest.sleep(0.5)
        practice.stop()
        await UILoadSelfTest.sleep(0.2)
        let d0 = position()
        await UILoadSelfTest.sleep(1.5)
        let d1 = position()
        let startsD = starts(since: sinceD)
        report("d auto-advance", reachedNext && startsD.map(\.id) == [row.id, next.id] && abs(d1 - d0) < 0.05
               && practice.activeLineID == nil && !player.isPlaying && practice.currentLineID == next.id,
               "next row started by itself \(reachedNext), plays started \(startsD.count),"
               + " active after stop \(practice.activeLineID != nil)"
               + String(format: ", position after stop %.2f s -> %.2f s in 1.5 s", d0, d1))

        // e. 次・前・もう一度
        practice.settings = PracticeSettings(rate: 1.25)
        practice.toggleLine(row.id)
        practice.stop()
        practice.next()
        let afterNext = practice.currentLineID
        practice.stop()
        practice.previous()
        let afterPrevious = practice.currentLineID
        practice.stop()
        practice.replay()
        let afterReplay = practice.currentLineID
        let replayPlays = practice.activeLineID == row.id && player.playingLineID == row.id
        practice.stop()
        practice.toggleLine(first.id)
        practice.stop()
        practice.previous()
        let atFirst = practice.currentLineID
        let nothingAtFirst = practice.activeLineID == nil && player.playingLineID == nil
        report("e next/previous/replay", afterNext == next.id && afterPrevious == row.id && afterReplay == row.id
               && replayPlays && atFirst == first.id && nothingAtFirst,
               "next \(afterNext == next.id), previous \(afterPrevious == row.id), replay \(afterReplay == row.id)"
               + " (playing \(replayPlays)), previous at the first row stays \(atFirst == first.id)"
               + " and plays nothing \(nothingAtFirst)")

        // f. スペースキーと同じ道 (togglePlay): 流している最中と、間を待っている最中
        practice.settings = PracticeSettings(rate: 1.25, repeatCount: PracticeSettings.untilStopped)
        practice.toggleLine(row.id)
        await UILoadSelfTest.sleep(0.6)
        let wasPlaying = practice.activeLineID == row.id && player.isPlaying
        practice.togglePlay()
        let stoppedPlaying = practice.activeLineID == nil && !player.isPlaying
        let f0 = position()
        await UILoadSelfTest.sleep(1.0)
        let f1 = position()
        practice.settings = PracticeSettings(rate: 1.25, repeatCount: PracticeSettings.untilStopped, gap: .lineLength)
        practice.toggleLine(row.id)
        let reachedGap = await waitUntil(length / 1.25 + 3) { practice.isWaiting }
        practice.togglePlay()
        let stoppedWaiting = practice.activeLineID == nil && !practice.isWaiting && !player.isPlaying
        await UILoadSelfTest.sleep(gap + 0.5)
        let quietAfterGap = practice.activeLineID == nil && !player.isPlaying
        report("f space key", wasPlaying && stoppedPlaying && abs(f1 - f0) < 0.05 && reachedGap && stoppedWaiting
               && quietAfterGap,
               "while playing: was playing \(wasPlaying), stopped \(stoppedPlaying)"
               + String(format: " (position %.2f s -> %.2f s in 1 s)", f0, f1)
               + "; in the gap: reached \(reachedGap), stopped \(stoppedWaiting), nothing after the gap \(quietAfterGap)")

        // 決まりの設定に戻す
        practice.stop()
        practice.settings = PracticeSettings()
        practice.showsDictation = false
        practice.selfTestForget()
        lines.append(String(format: "practice check took %.1f s", Date().timeIntervalSince(started)))
        if let failedStep {
            lines.append("PRACTICE CHECK FAILED: \(failedStep)")
            return true
        }
        lines.append("PRACTICE CHECK OK")
        return false
    }

    /// condition が成り立つまで (長くて timeout 秒) 待つ。成り立ったら true
    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return true }
            await UILoadSelfTest.sleep(0.05)
        }
        return condition()
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
    /// 段階 3 (文字起こし中のジョブ、1 秒に 10 区間) のあいだ。再生位置・1 行だけの再生を Action.whileAdded の名前で記録する
    private var rowsAdded = false
    /// 文字起こし中のジョブへ次に届ける区間の番号
    private var nextSegment: Int
    /// 届けた区間の数
    private var delivered = 0
    /// ふつうの再生の、まねている位置 (秒)
    private var simulated = 0.0
    /// 段階ごとの始まりと終わり (uptime のナノ秒)
    private var phaseTimes: [String: (start: UInt64, end: UInt64)] = [:]
    private var ticks = 0
    /// ticks のうち、いまの行が変わったもの
    private var rowChanges = 0
    private var lineStarts = 0
    /// 300 の区間をいっぺんに届けているところ (まとめて足し始めた時刻を覚える)
    private var awaitingBurst = false
    /// いっぺんに届けた区間を、まとめて足し始めた時刻 (uptime のナノ秒)
    private var burstApplied: UInt64?
    /// いっぺんに届けてから、まとめて足し始めるまでの秒 (まとめる間を待つ。メインスレッドは空いている)
    private var burstWaits: [Double] = []
    /// 一覧の行を作る手間を測ったときに、足した分だけを作る道を通らなかった回数
    private var appendPathMissed = 0
    /// ジョブを選ぶ・再生位置を遠くへ動かす操作ごとの、その 1 回で一覧が作った行の数 (PlayableRow の init。測った順)
    private var rowsBuiltBySelect: [String: [Int]] = [:]
    /// 同じく、その 1 回で一覧が body を動かした行の数 (PlayableRow.body。測った順)
    private var rowBodiesBySelect: [String: [Int]] = [:]
    /// 測る段階のすべて (drive) で、一覧が作った行の数 (init)
    private var rowsBuiltTotal: Int?
    /// 測る段階のすべて (drive) で、一覧が body を動かした行の数
    private var rowBodiesTotal: Int?

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
        let stats = job.status == .done ? transcript.translationStats : Transcript.TranslationStats()
        return model.isBilingual(stats, in: job) ? "yes" : "no"
    }

    // MARK: 操作

    func drive() async {
        probe.start()
        let started = Date()
        let rowsAtStart = UILoadHooks.rowsBuilt
        let bodiesAtStart = UILoadHooks.rowBodies
        // 1. 終わったジョブ (対訳)
        await measure(Action.selectBilingual) { model.select(doneBilingual) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.bilingual) {
            feedAction = Action.appendOther
            await drivePlayback(seconds: 8, lineJob: doneBilingual, steady: false)
        }
        // 同じジョブの中で、再生位置を遠くへ動かす (段階の外。2 回ずつ)
        await jumpRound()
        // 2. 終わったジョブ (ふつう)
        await measure(Action.selectPlain) { model.select(donePlain) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.plain) {
            await drivePlayback(seconds: 8, lineJob: donePlain, steady: false)
        }
        // 3. 文字起こし中のジョブ (1 秒に 10 区間)
        feedAction = nil
        // ふつうの再生をまねるのをやめる (段階 3 の初めは、再生していないときに一覧の終わりを追いかけるところを見る)
        player.selfTestSetTime(simulated, playing: false)
        await measure(Action.selectRunning) { model.select(running) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.steady) {
            feedAction = Action.steadyBatch
            rowsAdded = true
            await drivePlayback(seconds: 7, lineJob: running, steady: true)
            rowsAdded = false
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
                // まとめる間より長くあける (1 つずつ足されるように)
                await UILoadSelfTest.sleep(batchInterval + 0.4)
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
        rowsBuiltTotal = UILoadHooks.rowsBuilt - rowsAtStart
        rowBodiesTotal = UILoadHooks.rowBodies - bodiesAtStart
        log.summaryLine = String(format: "driven for %.1f s: %d ticks (%d of them moved the current row), %d one-line starts,"
                                 + " %d segments delivered to the running job (it now has %d rows; batches are applied every"
                                 + " %.2f s at that size)",
                                 Date().timeIntervalSince(started), ticks, rowChanges, lineStarts, delivered,
                                 running.transcript?.segments.count ?? 0, batchInterval)
    }

    private func selectRound() async {
        await measure(Action.selectBilingual) { model.select(doneBilingual) }
        await UILoadSelfTest.sleep(0.3)
        await measure(Action.selectPlain) { model.select(donePlain) }
        await UILoadSelfTest.sleep(0.3)
        await measure(Action.selectRunning) { model.select(running) }
        await UILoadSelfTest.sleep(0.5)
    }

    /// 終わったジョブ (対訳) を一覧の始めで出したまま、再生位置を 8 割ほど下の行の始まりへ動かして再生し
    /// (再生のつまみを遠くへ動かして再生したとき。いまの行が変わるので、一覧はその行へ動く)、また始めのほうの行へ戻す。2 回ずつ。
    /// 段階 1 のすぐあとに呼ぶ。終わりに、再生位置と再生中かを段階 1 の終わりのものへ戻し、一覧がそこへ動き終わるのを待つ
    /// (段階 2 は、その位置から、ふつうの再生のまねを続ける)
    private func jumpRound() async {
        guard let segments = doneBilingual.transcript?.segments, segments.count >= 2 else { return }
        if player.playingLineID != nil { player.stopLine() }
        let time = player.currentTime
        let wasPlaying = player.isPlaying
        // 一覧の始めを出す (段階 1 で動いたのは始めのほうだけだが、念のため)
        UILoadHooks.scrollList?(segments[0].id, .top)
        await settle()
        let far = segments[segments.count * 8 / 10]
        let near = segments[1]
        for _ in 0..<2 {
            await measure(Action.jumpFar) { player.selfTestSetTime(far.start, playing: true) }
            await UILoadSelfTest.sleep(0.5)
            await measure(Action.jumpBack) { player.selfTestSetTime(near.start, playing: true) }
            await UILoadSelfTest.sleep(0.5)
        }
        player.selfTestSetTime(time, playing: wasPlaying)
        await settle()
    }

    /// 段階を 1 つ行う (見張りの値を、この段階の名前で分ける)。終わりに、まとめて足すのが済むまで待つ
    private func phase(_ name: String, _ body: () async -> Void) async {
        probe.setPhase(name)
        let start = UILoadSelfTest.now()
        await body()
        await UILoadSelfTest.sleep(batchInterval + 0.15)
        phaseTimes[name] = (start, UILoadSelfTest.now())
        probe.setPhase(Phase.between)
    }

    /// 1 秒に 10 回の拍で、再生位置・1 行だけの再生・区間・進み具合を起こす。
    /// steady でないとき: ふつうの再生をまね (位置は本当の見張りと同じく 1 秒に 5 回、0.2 秒ずつ進む。1 行だけの再生の
    /// あいだは進めない)。後半は、1 行だけの再生を 1 秒に 1 回始め、0.5 秒後に止める。
    /// 文字起こし中のジョブ (選んでいない) へ 1.5 秒に 1 回、区間を 1 つずつ届ける (まとめる間の 1 秒より長くあける)。
    /// steady のとき: 区間を毎拍 1 つ (1 秒に 10)。初めの 2.5 秒は再生しない。そのあとは 1 行だけの再生を 1 秒に 1 回始め、
    /// 0.5 秒後に止め、再生しているあいだは、その行の中で位置を進める。
    /// どちらも進み具合を 1 秒に 2 回変える
    private func drivePlayback(seconds: Double, lineJob: Job, steady: Bool) async {
        let started = Date()
        var tick = 0
        while Date().timeIntervalSince(started) < seconds {
            let elapsed = Date().timeIntervalSince(started)
            if steady || tick % 15 == 0 { deliver(1) }
            if tick % 2 == 0 {
                if !steady {
                    if player.playingLineID == nil {
                        simulated += 0.2
                        if simulated > Double(rows) * UILoadSelfTest.rowSpacing { simulated = 0 }
                        await advance(to: simulated, in: lineJob)
                    }
                } else if player.playingLineID != nil {
                    await advance(to: player.currentTime + 0.2, in: lineJob)
                }
            }
            if steady {
                let lineTicks = elapsed >= 2.5
                if lineTicks, tick % 10 == 5 {
                    if player.playingLineID != nil {
                        await measure(Action.lineStop) { player.stopLine() }
                    } else {
                        await startLine(in: lineJob)
                    }
                } else if lineTicks, tick % 10 == 0, player.playingLineID != nil {
                    await measure(Action.lineStop) { player.stopLine() }
                }
            } else if elapsed >= seconds / 2 {
                if tick % 10 == 0, player.playingLineID == nil {
                    await startLine(in: lineJob)
                } else if tick % 10 == 5, player.playingLineID != nil {
                    await measure(Action.lineStop) { player.stopLine() }
                }
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

    /// 再生位置を変える (本当の見張りの知らせと同じ)。いまの行が変わるかで、操作を分けて記録する
    private func advance(to position: Double, in job: Job) async {
        let count = job.transcript?.segments.count ?? 0
        let moves = UILoadSelfTest.rowIndex(at: player.currentTime, rows: count)
            != UILoadSelfTest.rowIndex(at: position, rows: count)
        await measure(moves ? Action.rowChange : Action.tick) { player.selfTestSetTime(position, playing: true) }
        ticks += 1
        if moves { rowChanges += 1 }
    }

    /// 文字起こし中のジョブで、いまの行の数のときに、届いた区間をまとめて足す間 (秒)
    private var batchInterval: Double {
        LiveSegmentBuffer.interval(forRows: running.transcript?.segments.count ?? 0)
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

    /// 300 の区間をいっぺんに届け、まとめて足し始めてから、すべてが文字起こしに入り、メインスレッドが空くまでを測る。
    /// 届けてから足し始めるまで (まとめる間を待つだけで、メインスレッドは空いている) は、別に記録する
    private func burst(_ count: Int) async {
        let target = (running.transcript?.segments.count ?? 0) + count
        let started = UILoadSelfTest.now()
        awaitingBurst = true
        burstApplied = nil
        deliver(count)
        let deadline = Date().addingTimeInterval(5)
        while (running.transcript?.segments.count ?? 0) < target, Date() < deadline {
            await UILoadSelfTest.sleep(0.01)
        }
        awaitingBurst = false
        let applied = burstApplied ?? started
        burstWaits.append(UILoadSelfTest.seconds(from: started, to: applied))
        let seconds = await UILoadSelfTest.untilIdle(since: applied)
        measured[Action.burst, default: []].append(seconds)
    }

    /// 入れ物が、まとめた区間を足した (AppModel.liveFeed から)。足し始めてから、メインスレッドが空くまでを測る
    private func batchApplied(count: Int, started: UInt64) {
        log.note("batch of \(count) segments applied to the running job", at: started)
        if awaitingBurst, burstApplied == nil { burstApplied = started }
        guard let action = feedAction else { return }
        // 1 つずつの区間のはずが、まとめて足された (届けるのが遅れた) ものは、1 つの区間の操作に入れない
        if action != Action.steadyBatch, count != 1 { return }
        Task { @MainActor in
            let seconds = await UILoadSelfTest.untilIdle(since: started)
            self.measured[action, default: []].append(seconds)
        }
    }

    /// 操作をメインスレッドで行い、メインスレッドがまた空くまでを測る。
    /// 段階 3 のあいだは、再生位置・1 行だけの再生を Action.whileAdded の名前で記録する
    private func measure(_ action: String, _ body: () -> Void) async {
        let name = rowsAdded ? (Action.whileAdded[action] ?? action) : action
        log.note(name)
        let rowsBefore = UILoadHooks.rowsBuilt
        let bodiesBefore = UILoadHooks.rowBodies
        let started = UILoadSelfTest.now()
        body()
        let seconds = await UILoadSelfTest.untilIdle(since: started)
        measured[name, default: []].append(seconds)
        // ジョブを選ぶ・再生位置を遠くへ動かす操作は、そのあいだに一覧が作った行と、body を動かした行の数も記録する
        if Self.rowCountedActions.contains(name) {
            rowsBuiltBySelect[name, default: []].append(UILoadHooks.rowsBuilt - rowsBefore)
            rowBodiesBySelect[name, default: []].append(UILoadHooks.rowBodies - bodiesBefore)
        }
    }

    /// ジョブを選ぶ操作 (目安は最大だけ。結果には、測った順の値も出す)
    private static let selectActions = [Action.selectBilingual, Action.selectPlain, Action.selectRunning]
    /// 終わったジョブの中で、再生位置を遠くへ動かす操作 (ジョブを選ぶ操作と同じく、目安は最大だけで、測った順の値も出す)
    private static let jumpActions = [Action.jumpFar, Action.jumpBack]
    /// 一覧が作った行と、body を動かした行の数を記録し、body の数を目安 (selectRowsBuiltMax) と比べる操作
    private static let rowCountedActions = selectActions + jumpActions

    /// 操作ごとの目安 (p95 が nil なら最大だけ)。required でないものは、測れなくても失敗にしない
    /// (段階 3 で、いまの行が変わる再生位置は、起きないことがある)
    private static var actionLimits: [(action: String, p95: Double?, max: Double, required: Bool)] {
        var limits: [(action: String, p95: Double?, max: Double, required: Bool)] = [
            (Action.tick, Limits.tickP95, Limits.tickMax, true)
        ]
        for action in [Action.rowChange, Action.lineStart, Action.lineStop] {
            limits.append((action, Limits.rowP95, Limits.rowMax, true))
        }
        for action in [Action.tickWhileAdded, Action.lineStartWhileAdded, Action.lineStopWhileAdded] {
            limits.append((action, Limits.whileAddedP95, Limits.whileAddedMax, true))
        }
        limits.append((Action.rowChangeWhileAdded, Limits.whileAddedP95, Limits.whileAddedMax, false))
        for action in [Action.progress, Action.appendOther] {
            limits.append((action, Limits.progressP95, Limits.progressMax, true))
        }
        limits.append((Action.appendSelected, Limits.appendP95, Limits.appendMax, true))
        limits.append((Action.steadyBatch, Limits.steadyBatchP95, Limits.steadyBatchMax, true))
        limits.append((Action.burst, nil, Limits.burst, true))
        for action in selectActions {
            limits.append((action, nil, Limits.selectMax, true))
        }
        for action in jumpActions {
            limits.append((action, nil, Limits.jumpMax, true))
        }
        return limits
    }

    // MARK: 一覧の行を作る手間 (画面を使わない)

    /// 結果の画面が、文字起こしが変わるたびに呼ぶもの (TranscriptRowCache: 翻訳の状況・言語の名前と、一覧の行) の手間を、
    /// 画面を使わずに測る。すべてから作り直す (終わったジョブ 2 つと文字起こし中のジョブ) と、文字起こし中のジョブに
    /// 10 区間を足す (足した分だけを作る道) を、それぞれ 20 回
    func costReport() -> [String] {
        let repetitions = 20
        func f(_ seconds: Double) -> String { String(format: "%.2f", UILoadSelfTest.ms(seconds)) }
        func timed(_ body: () -> Void) -> Double {
            let start = UILoadSelfTest.now()
            body()
            return UILoadSelfTest.seconds(from: start, to: UILoadSelfTest.now())
        }
        func line(_ what: String, _ values: [Double], _ extra: String = "") -> String {
            let sorted = values.sorted()
            return "UI LOAD: cost \(what): median \(f(UILoadSelfTest.percentile(sorted, 0.5))) ms,"
                + " max \(f(sorted.last ?? 0)) ms (\(values.count) runs\(extra))"
        }
        var lines = ["cost: TranscriptRowCache (translation stats, language label and the list rows, what the result view"
                     + " computes when the transcript changes), timed without a window"]
        let cases: [(name: String, job: Job, done: Bool, bilingual: Bool)] = [
            ("finished, bilingual", doneBilingual, true, true),
            ("finished, plain", donePlain, true, false),
            ("running", running, false, false)
        ]
        for c in cases {
            guard let transcript = c.job.transcript else { continue }
            var values: [Double] = []
            for _ in 0..<repetitions {
                let cache = TranscriptRowCache()
                values.append(timed {
                    _ = cache.summary(of: transcript, job: c.job.id, done: c.done)
                    _ = cache.items(of: transcript, job: c.job.id, done: c.done, bilingual: c.bilingual, query: "")
                })
            }
            lines.append(line("full rebuild of \(transcript.segments.count) rows (\(c.name))", values))
        }
        if let base = running.transcript {
            var grown = base
            grown.segments += UILoadSelfTest.makeSegments(nextSegment..<(nextSegment + 10))
            var values: [Double] = []
            var used = 0
            for _ in 0..<repetitions {
                let cache = TranscriptRowCache()
                _ = cache.summary(of: base, job: running.id, done: false)
                _ = cache.items(of: base, job: running.id, done: false, bilingual: false, query: "")
                values.append(timed {
                    _ = cache.summary(of: grown, job: running.id, done: false)
                    _ = cache.items(of: grown, job: running.id, done: false, bilingual: false, query: "")
                })
                if cache.lastSummaryWasAppend && cache.lastItemsWasAppend { used += 1 }
            }
            appendPathMissed = repetitions - used
            lines.append(line("append 10 segments to \(base.segments.count) rows (running)", values,
                              ", the append path was used in \(used)"))
        }
        return lines
    }

    // MARK: ウインドウの絵 (--screenshots)

    /// 決まった場面を順に出し、それぞれ、メインスレッドが空いて絵が落ち着いてから、ウインドウの絵を PNG で残す。
    /// 測り終えたあとに呼ぶ (測る操作の中では撮らない)。出力の行を返す
    func takeScreenshots(into directory: URL) async -> [String] {
        var lines: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["UI LOAD: screenshot failed (all): could not create \(directory.path): \(error.localizedDescription)"]
        }
        guard let window = MainWindow.all().first(where: { $0.isVisible }) else {
            return ["UI LOAD: screenshot failed (all): no visible main window"]
        }
        // 絵の大きさ (左上の位置はそのまま)
        var frame = window.frame
        frame.origin.y += frame.height - 800
        frame.size = CGSize(width: 1200, height: 800)
        window.setFrame(frame, display: true)
        lines.append("screenshots: into \(directory.path), window \(Int(window.frame.width))x\(Int(window.frame.height)) pt")
        player.stopLine()
        player.selfTestSetTime(0, playing: false)

        // 1. 終わったジョブ (対訳)、一覧の始め
        Self.live("scene 01: select the finished bilingual job")
        model.select(doneBilingual)
        await settle()
        lines += await scroll(to: doneBilingual.transcript?.segments.first?.id, .top, for: "01")
        lines.append(shot("01-finished-bilingual", in: window, to: directory))

        // 2. 同じジョブで、見えている 4 行目を 1 行だけ再生しているところ (再生の色と止める印)。
        // 音声が無くても、playLine は行の印を付ける (音は出ない)
        if let segments = doneBilingual.transcript?.segments, segments.count > 3 {
            let segment = segments[3]
            Self.live("scene 02: one-line playback of row 4")
            player.playLine(id: segment.id, start: segment.start, end: segment.end)
            await settle()
            let playing = player.playingLineID == segment.id
            lines.append(shot("02-line-playing", in: window, to: directory))
            if !playing || player.playingLineID != segment.id {
                lines.append("UI LOAD: screenshot 02-line-playing.png: the row was not in one-line playback for the whole"
                             + " picture (it may show no playing tint)")
            }
            player.stopLine()
        } else {
            lines.append("UI LOAD: screenshot failed 02-line-playing.png: the job has fewer than 4 rows")
        }
        player.selfTestSetTime(0, playing: false)

        // 3. 終わったジョブ (日本語だけ)
        Self.live("scene 03: select the finished plain job")
        model.select(donePlain)
        await settle()
        lines += await scroll(to: donePlain.transcript?.segments.first?.id, .top, for: "03")
        lines.append(shot("03-finished-plain", in: window, to: directory))

        // 4. 文字起こし中のジョブ、一覧の終わり (進み具合と、出てきた行)
        Self.live("scene 04: select the running job")
        model.select(running)
        await settle()
        UILoadHooks.setFollowing?(true)
        lines += await scroll(to: running.transcript?.segments.last?.id, .bottom, for: "04")
        lines.append(shot("04-running-job", in: window, to: directory))

        // 5. 同じジョブで、追いかけるのをやめ、15 行ほど上へ動かしたところ (右下の「末尾へ」)
        let segments = running.transcript?.segments ?? []
        Self.live("scene 05: scroll up and stop following")
        lines += await scroll(to: segments.isEmpty ? nil : segments[max(0, segments.count - 15)].id, .bottom, for: "05")
        UILoadHooks.setFollowing?(false)
        await settle()
        if UILoadHooks.isFollowing?() ?? true {
            lines.append("UI LOAD: screenshot 05-running-scrolled-up.png: the list was still following the end"
                         + " (the 末尾へ button may be missing)")
        }
        lines.append(shot("05-running-scrolled-up", in: window, to: directory))
        UILoadHooks.setFollowing?(true)

        // 6. 日本語と英語が混ざっていたので、自動で「日本語＋英語」にした終わったジョブ (案内と「…だけでやり直す」)。
        // AppModel.run が、言語を確かめて混ざっていたときに入れるものと同じものを入れる。訳の無い英語の行には「訳」が出る
        let mixed = Job(name: "日本語と英語が混ざった録音 (確認用)", url: doneBilingual.url)
        let mixedRows = 60
        mixed.transcript = Transcript(sourceName: mixed.name, segments: UILoadSelfTest.makeSegments(0..<mixedRows),
                                      language: "ja", duration: Double(mixedRows) * UILoadSelfTest.rowSpacing, elapsed: 1)
        mixed.status = .done
        mixed.progress = 1
        mixed.message = "完了"
        mixed.autoMixedFrom = "ja"
        mixed.languageCode = Languages.japaneseEnglish.code
        Self.live("scene 06: select the automatically switched job")
        model.adopt(mixed)
        model.select(mixed)
        await settle()
        lines += await scroll(to: mixed.transcript?.segments.first?.id, .top, for: "06")
        lines.append(shot("06-auto-mixed-notice", in: window, to: directory))
        return lines
    }

    /// メインスレッドが空くのを待ち、0.4 秒おいて (絵が落ち着くまで)、また空くのを待つ
    private func settle() async {
        _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
        await UILoadSelfTest.sleep(0.4)
        _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
    }

    /// 一覧を、その行が端に来るように動かし、落ち着くまで待つ。動かせなければ、そのことを出力の行で返す
    private func scroll(to id: UUID?, _ edge: UILoadHooks.Edge, for name: String) async -> [String] {
        guard let id else { return ["UI LOAD: screenshot \(name): could not scroll the list (no rows)"] }
        guard let scrollList = UILoadHooks.scrollList else {
            return ["UI LOAD: screenshot \(name): could not scroll the list (the list did not register its scroll hook)"]
        }
        Self.live("  scroll for \(name)")
        scrollList(id, edge)
        await settle()
        Self.live("  scrolled for \(name)")
        return []
    }

    /// ウインドウの絵を PNG で残し、出力の行を返す。タイトルバーとツールバーも入るよう、内容の外側 (枠の view) から撮り、
    /// 撮れなければ内容の view から撮る
    private func shot(_ name: String, in window: NSWindow, to directory: URL) -> String {
        let file = name + ".png"
        Self.live("  draw \(file)")
        defer { Self.live("  drew \(file)") }
        var picture: (data: Data, width: Int, height: Int)?
        var what = ""
        if let frameView = window.contentView?.superview, let p = Self.png(of: frameView) {
            picture = p
            what = "window frame"
        } else if let content = window.contentView, let p = Self.png(of: content) {
            picture = p
            what = "content view"
        }
        guard let picture else {
            return "UI LOAD: screenshot failed \(file): the view could not be drawn into a PNG"
        }
        do {
            try picture.data.write(to: directory.appendingPathComponent(file))
        } catch {
            return "UI LOAD: screenshot failed \(file): \(error.localizedDescription)"
        }
        return "UI LOAD: screenshot \(file) \(picture.width)x\(picture.height) (\(what))"
    }

    /// いま何をしているかを、その場で標準エラーへ書く (結果の行は終わりにまとめて出るので、途中で止まったときに
    /// どこで止まったかが分かるように)
    private static func live(_ text: String) {
        FileHandle.standardError.write(Data(("UI LOAD (live): " + text + "\n").utf8))
    }

    /// view を描いた PNG と、その画素の幅と高さ (描けなければ nil)
    private static func png(of view: NSView) -> (data: Data, width: Int, height: Int)? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, rep.pixelsWide, rep.pixelsHigh)
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
            let inOrder = measured[action] ?? []
            let values = inOrder.sorted()
            guard !values.isEmpty else {
                lines.append("UI LOAD: action \"\(action)\": no samples")
                continue
            }
            // p95 の目安がある操作で、測った数が足りないときは、p95 を比べないことも出す
            let hasP95Limit = Self.actionLimits.contains { $0.action == action && $0.p95 != nil }
            let unchecked = hasP95Limit && values.count < Limits.p95MinSamples
                ? ", n < \(Limits.p95MinSamples): p95 not checked" : ""
            lines.append("UI LOAD: action \"\(action)\": n \(values.count), median \(f(UILoadSelfTest.percentile(values, 0.5))) ms,"
                         + " p95 \(f(UILoadSelfTest.percentile(values, 0.95))) ms, max \(f(values[values.count - 1])) ms" + unchecked)
            // ジョブを選ぶ・再生位置を遠くへ動かす操作は、測った順の値も出す (初めの 1 回だけが遅いのかを見分ける)
            if Self.rowCountedActions.contains(action) {
                lines.append("UI LOAD: samples \"\(action)\": " + inOrder.map(f).joined(separator: ", ") + " ms")
                let built = (rowsBuiltBySelect[action] ?? []).map { String($0) }.joined(separator: ", ")
                let bodies = (rowBodiesBySelect[action] ?? []).map { String($0) }.joined(separator: ", ")
                lines.append("UI LOAD: rows built \"\(action)\": inits \(built); bodies \(bodies)")
            }
        }
        if let rowsBuiltTotal, let rowBodiesTotal {
            lines.append("UI LOAD: rows built during the measured part: inits \(rowsBuiltTotal), bodies \(rowBodiesTotal)"
                         + " (PlayableRow inits and bodies; limit per select or jump: \(Limits.selectRowsBuiltMax) bodies)")
        }
        let samples = probe.samples()
        lines.append("watchdog: a background thread posts a block to the main queue every 50 ms (without waiting for the"
                     + " previous one) and records how long it waited")
        for name in Phase.all {
            let mine = samples.filter { $0.phase == name }
            let waits = mine.map(\.wait).sorted()
            let span = phaseTimes[name].map { UILoadSelfTest.seconds(from: $0.start, to: $0.end) } ?? 0
            let expected = Int(span / LatencyProbe.interval)
            let unavailable = LatencyProbe.unavailable(mine)
            let share = span > 0 ? unavailable / span * 100 : 0
            lines.append("UI LOAD: phase \"\(name)\" (" + String(format: "%.1f", span) + " s): samples expected \(expected),"
                         + " sent \(probe.sent(in: name)), received \(mine.count),"
                         + " median \(f(UILoadSelfTest.percentile(waits, 0.5))) ms, p95 \(f(UILoadSelfTest.percentile(waits, 0.95))) ms,"
                         + " max \(f(waits.last ?? 0)) ms, main thread unavailable \(f(unavailable)) ms"
                         + " (" + String(format: "%.1f", share) + "% of the phase)")
        }
        if !burstWaits.isEmpty {
            let waits = burstWaits.sorted()
            lines.append("burst: the action is timed from the start of applying the batch; before that the segments waited"
                         + " in the buffer for the batching interval (main thread free): median \(f(UILoadSelfTest.percentile(waits, 0.5))) ms,"
                         + " max \(f(waits[waits.count - 1])) ms")
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
        func check(_ action: String, p95 p95Limit: Double?, max maxLimit: Double, required: Bool) {
            let values = (measured[action] ?? []).sorted()
            guard !values.isEmpty else {
                if required { failures.append("\"\(action)\" was not measured") }
                return
            }
            let p95 = UILoadSelfTest.percentile(values, 0.95)
            let worst = values[values.count - 1]
            // 測った数が少ないと、p95 は最大と同じになるので比べない (最大だけを比べる)
            if let p95Limit, values.count >= Limits.p95MinSamples, p95 >= p95Limit {
                failures.append("\"\(action)\" p95 \(f(p95)) ms >= \(f(p95Limit)) ms")
            }
            if worst >= maxLimit {
                failures.append("\"\(action)\" max \(f(worst)) ms >= \(f(maxLimit)) ms")
            }
        }
        for limit in Self.actionLimits {
            check(limit.action, p95: limit.p95, max: limit.max, required: limit.required)
        }
        // ジョブを選ぶ 1 回・再生位置を遠くへ動かす 1 回で、一覧が body を動かした行の数 (一覧が行を遅れて並べているか)。
        // init の数は比べない (一覧が終わりへ飛ぶと、数千になってよい)
        for action in Self.rowCountedActions {
            if let worst = rowBodiesBySelect[action]?.max(), worst > Limits.selectRowsBuiltMax {
                failures.append("\"\(action)\" ran the body of \(worst) rows in one action > \(Limits.selectRowsBuiltMax)"
                                + " (the list laid out far more rows than it shows)")
            }
        }
        // 一覧が行を並べたのに数えていなければ、上の確かめは役に立たない
        if rowBodiesTotal == 0 {
            failures.append("no row bodies were counted while measuring (UILoadHooks.rowBodies is not incremented by"
                            + " PlayableRow.body)")
        }
        // 見張り: 4 つの段階のどれも
        let watchdogLimits: [(phase: String, max: Double)] = [
            (Phase.bilingual, Limits.watchdogMax),
            (Phase.plain, Limits.watchdogMax),
            (Phase.steady, Limits.watchdogMax),
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
        // 段階 3 で、メインスレッドが応えられなかった時間の割合
        if let times = phaseTimes[Phase.steady] {
            let span = UILoadSelfTest.seconds(from: times.start, to: times.end)
            let unavailable = LatencyProbe.unavailable(samples.filter { $0.phase == Phase.steady })
            if span > 0, unavailable / span >= Limits.steadyUnavailableShare {
                failures.append("main thread unavailable " + String(format: "%.1f", unavailable / span * 100) + "% of \""
                                + Phase.steady + "\" >= " + String(format: "%.0f", Limits.steadyUnavailableShare * 100) + "%")
            }
        } else {
            failures.append("the phase \"\(Phase.steady)\" was not timed")
        }
        if appendPathMissed > 0 {
            failures.append("TranscriptRowCache rebuilt all rows \(appendPathMissed) times when 10 segments were appended"
                            + " (the append path was not used)")
        }
        return failures
    }
}

// MARK: 保存の確認 (LIBRARY CHECK)

extension LoadRun {
    /// ふだんと同じ AppModel の関数で、保存・メモ・版 (新しく・上書き・戻す)・消すを行い、フォルダを読み直して比べる。
    /// 出力の行と、失敗したかを返す
    func libraryCheck(root: URL) async -> (lines: [String], failed: Bool) {
        Self.live("library check")
        var lines: [String] = ["library: a temporary folder for this run: \(root.path)"]
        var failure: String?
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("LIBRARY: \(name): \(ok ? "ok" : "FAILED") (\(detail))")
            if !ok, failure == nil { failure = name }
        }
        let fm = FileManager.default
        let store = LibraryStore(root: root)
        let job = doneBilingual

        // 1. 終わったジョブ 2 つは、ふだんの道 (終わったジョブを一覧に入れたとき) で保存されている。文字起こし中のジョブは保存しない
        model.flushLibrary()
        let bilingualSaved = fm.fileExists(atPath: store.documentURL(for: doneBilingual.id).path)
        let plainSaved = fm.fileExists(atPath: store.documentURL(for: donePlain.id).path)
        let runningSaved = fm.fileExists(atPath: store.folder(for: running.id).path)
        step("saved by the normal path", bilingualSaved && plainSaved && !runningSaved,
             "finished (bilingual) \(bilingualSaved), finished (plain) \(plainSaved), running job \(runningSaved);"
             + " expected true, true, false")

        // 2. 行数の行の結果を、裏の列で書く時間 (ふだんの保存と同じ列・同じ書き方)
        if let writer = model.library, let document = model.snapshot(of: job) {
            let rows = document.transcript.segments.count
            let result = await writer.run { (store: LibraryStore) throws -> Double in
                let start = DispatchTime.now().uptimeNanoseconds
                try store.save(document)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            switch result {
            case .success(let ms):
                lines.append(String(format: "LIBRARY: saved %d rows in %.0f ms (background)", rows, ms))
            case .failure(let error):
                step("save \(rows) rows on the background queue", false, error.localizedDescription)
            }
        } else {
            step("save on the background queue", false, "the model has no library or the job has no transcript")
        }

        // 3. メモと版: A (新しく) → B (新しく) → C (いちばん新しい版に上書き) → A のメモだけに戻す
        let notesA = "A のメモ: have you ever は「〜したことがある」。\n"
        let notesB = "B のメモ\n"
        let notesC = "C のメモ\n"
        step("versions allowed on the finished job", model.canEditVersions(job), model.versionBlockedReason(job) ?? "allowed")
        job.notes = notesA
        let savedA = await model.saveVersion(job, label: "A", mode: .new)
        step("save version A (new)", savedA && job.versions.count == 1, "versions \(job.versions.count), expected 1")
        job.notes = notesB
        let savedB = await model.saveVersion(job, label: "B", mode: .new)
        step("save version B (new)", savedB && job.versions.count == 2, "versions \(job.versions.count), expected 2")
        job.notes = notesC
        let savedC = await model.saveVersion(job, label: "C", mode: .overwriteLatest)
        let labels = job.versions.map { $0.label }
        step("save C over the newest version", savedC && labels == ["C", "A"],
             "versions \(labels), expected [\"C\", \"A\"]")
        let transcriptBefore = job.transcript
        if let a = job.versions.first(where: { $0.label == "A" }) {
            let restored = await model.restoreVersion(job, versionID: a.id, transcript: false, notes: true)
            let newest = job.versions.first
            step("restore version A, notes only",
                 restored && job.notes == notesA && job.transcript == transcriptBefore && job.versions.count == 3
                    && newest?.origin == .beforeRestore && newest?.label == AppModel.beforeRestoreLabel,
                 "notes of A \(job.notes == notesA), transcript unchanged \(job.transcript == transcriptBefore),"
                 + " versions \(job.versions.count) (expected 3), newest origin \(newest.map { "\($0.origin)" } ?? "none")")
            // 自動で残した版には、戻す前のメモ (C) が入っている
            let kept = newest.flatMap { try? store.loadVersion(documentID: job.id, versionID: $0.id) }
            step("the automatic version holds the state before the restore", kept?.notes == notesC,
                 "notes \(kept.map { "\($0.notes.count) characters" } ?? "unreadable")")
        } else {
            step("restore version A, notes only", false, "version A is missing")
        }

        // 4. 書き終えてから、新しい LibraryStore で読み直して比べる
        model.flushLibrary()
        if let loaded = LibraryStore(root: root).load(id: job.id) {
            let sameID = loaded.id == job.id
            let sameTranscript = loaded.transcript == job.transcript
            let sameNotes = loaded.notes == job.notes
            let sameVersions = loaded.versions.map { $0.id } == job.versions.map { $0.id }
            step("reload with a fresh LibraryStore", sameID && sameTranscript && sameNotes && sameVersions,
                 "id \(sameID), transcript equal \(sameTranscript), notes equal \(sameNotes),"
                 + " versions \(loaded.versions.count) of \(job.versions.count) in the same order \(sameVersions)")
        } else {
            step("reload with a fresh LibraryStore", false, "document.json could not be read")
        }

        // 5. 小さなジョブを、モデルから消す: フォルダが無くなる
        let small = Job(name: "消す確認 (確認用)", url: nil)
        small.transcript = Transcript(sourceName: small.name, segments: UILoadSelfTest.makeSegments(0..<10),
                                      language: "en", duration: 10 * UILoadSelfTest.rowSpacing, elapsed: 1)
        small.status = .done
        small.progress = 1
        small.message = "完了"
        model.adopt(small, at: model.jobs.count)
        model.flushLibrary()
        let existed = fm.fileExists(atPath: store.folder(for: small.id).path)
        model.delete(small)
        model.flushLibrary()
        let remains = fm.fileExists(atPath: store.folder(for: small.id).path)
        let listed = model.jobs.contains { $0 === small }
        step("delete a small job through the model", existed && !remains && !listed,
             "folder before \(existed), after \(remains), still listed \(listed)")

        lines.append(failure.map { "LIBRARY CHECK FAILED: \($0)" } ?? "LIBRARY CHECK OK")
        return (lines, failure != nil)
    }

    /// 練習の絵: 09 原文を隠し、1 行だけ目のボタンで見せたところ (繰り返しを 3 回にして「練習」のボタンに色が付く)、
    /// 10 書き取りの欄で、1 語違えて 1 語抜かした文を答え合わせしたところ。撮ったあと、練習の設定を決まりの値に戻す
    func takePracticeScreenshots(into directory: URL) async -> [String] {
        guard let window = MainWindow.all().first(where: { $0.isVisible }) else {
            return ["UI LOAD: screenshot failed (09, 10): no visible main window"]
        }
        let practice = model.practice
        let job = doneBilingual
        let segments = job.transcript?.segments ?? []
        let english = segments.filter { $0.language == "en" }
        guard english.count >= 3 else {
            return ["UI LOAD: screenshot failed (09, 10): the job has fewer than 3 English rows"]
        }
        var lines: [String] = []
        practice.stop()
        if player.isPlaying { player.togglePlay() }
        player.selfTestSetTime(0, playing: false)

        // 9. 原文を隠した一覧 (2 つめの英語の行だけを見せる)
        Self.live("scene 09: hidden source text with one row revealed")
        model.select(job)
        practice.showsDictation = false
        practice.settings = PracticeSettings(repeatCount: 3, hide: .source)
        await settle()
        lines += await scroll(to: segments.first?.id, .top, for: "09")
        practice.reveal.reveal(english[1].id)
        await settle()
        if !practice.isCustomized || practice.hideMode != .source {
            lines.append("UI LOAD: screenshot 09-practice-hidden.png: the practice settings did not change"
                         + " (the 練習 button may not be tinted)")
        }
        lines.append(shot("09-practice-hidden", in: window, to: directory))

        // 10. 書き取りの欄 (3 つめの英語の行を、いまの行にして、1 語違えて 1 語抜かして打ち、答え合わせした)
        Self.live("scene 10: dictation checked with one wrong and one missing word")
        practice.showsDictation = true
        let target = english[2]
        practice.selfTestSetCurrentLine(target.id)
        var words = DictationCheck.tokens(target.text)
        if words.count >= 4 {
            words[1] = "wrongly"
            words.remove(at: 3)
            practice.dictation.typed = words.joined(separator: " ")
            practice.submitDictation()
        }
        await settle()
        let pieces = practice.dictation.result?.pieces ?? []
        let wrong = pieces.filter { if case .wrong = $0 { return true } else { return false } }.count
        let missing = pieces.filter { if case .missing = $0 { return true } else { return false } }.count
        if practice.currentLineID != target.id || wrong != 1 || missing != 1 {
            lines.append("UI LOAD: screenshot 10-dictation.png: expected one wrong and one missing word"
                         + " (current line set \(practice.currentLineID == target.id), wrong \(wrong), missing \(missing))")
        }
        lines.append(shot("10-dictation", in: window, to: directory))

        // 決まりの設定に戻す
        practice.selfTestForget()
        practice.settings = PracticeSettings()
        practice.showsDictation = false
        await settle()
        return lines
    }

    /// 保存の確認のあとの絵: 07 メモの欄、08 履歴の画面 (シートのウインドウそのものを撮る。メインのウインドウを描いても、
    /// シートは入らない)
    func takeLibraryScreenshots(into directory: URL) async -> [String] {
        guard let window = MainWindow.all().first(where: { $0.isVisible }) else {
            return ["UI LOAD: screenshot failed (07, 08): no visible main window"]
        }
        var lines: [String] = []
        let job = doneBilingual
        let wasShowingNotes = model.showNotes

        // 7. 終わったジョブ (対訳) で、メモの欄を出したところ (引用した行を 1 つ含むメモ)
        Self.live("scene 07: the notes pane")
        model.select(job)
        var notes = "have you ever ＝「〜したことがある」。経験をたずねるときの言い方。\n\n聞き取れなかった所: 3 行目の後半。\n"
        if let segment = job.transcript?.segments.first {
            notes = NoteQuote.appending(NoteQuote.line(time: segment.start, text: segment.text), to: notes)
        }
        job.notes = notes
        model.showNotes = true
        await settle()
        lines += await scroll(to: job.transcript?.segments.first?.id, .top, for: "07")
        lines.append(shot("07-notes-pane", in: window, to: directory))

        // 8. 同じジョブの履歴の画面 (版が 3 つ以上で、1 つは自動で残したもの)
        Self.live("scene 08: the history sheet")
        if job.versions.count < 3 || !job.versions.contains(where: { $0.origin == .beforeRestore }) {
            lines.append("UI LOAD: screenshot 08-history-sheet.png: the job has \(job.versions.count) versions"
                         + " (expected 3 or more, one automatic)")
        }
        model.historyJobID = job.id
        await settle()
        // シートが出きるまで待つ
        await UILoadSelfTest.sleep(0.6)
        await settle()
        if let sheet = window.attachedSheet {
            lines.append(shot("08-history-sheet", in: sheet, to: directory))
        } else {
            lines.append("UI LOAD: screenshot failed 08-history-sheet.png: the history sheet is not shown")
        }
        model.historyJobID = nil
        await settle()
        if model.showNotes != wasShowingNotes { model.showNotes = wasShowingNotes }
        return lines
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
