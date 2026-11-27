// 画面の重さの確認 (--selftest-ui-load) の入口: 引数を読み、確認を順に走らせ、終了コードを決めて終わる。
// 確認ごとの中身は UILoad〜.swift に在る。

import AppKit
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
/// 保存の確認のあとに、監査の流れの確認 (AUDIT FLOW CHECK。UILoadAuditFlowCheck.swift) も行う: LLM の代わりを入れて、
/// AppModel の監査 (規則だけの段 → LLM の段) を 2 つの確認用の結果で通し、学習した直しの提案・反映・自動の直しを見る。
/// そのあと、訳し直しの確認 (RETRANSLATE CHECK。UILoadRetranslateCheck.swift) も行う: 訳の付いた確認用の結果を、
/// LLM の代わりで別の言語へ訳し直し、訳し直す前の版 (自動) が 1 つだけ残る事と、訳が新しい言語になる事を見る。
///
/// 終了コードの数と、複数が失敗した時にどれを返すかは、KikimimiCore の `UILoadExit` (UILoadExit.swift) の表に在る。
///
/// `--audio` のとき、行の確認のあとに練習の確認 (PRACTICE CHECK) も行う: 本当の練習の係 (PracticeController) と
/// 再生の係で、遅くした 1 行・繰り返し・間・自動で次へ・次と前とまた・スペースキー を確かめる (30 秒ほど。音を出せない Mac では飛ばす)。
/// `--screenshots` なら、そのあと練習の絵 (09 隠した行と目のボタン、10 書き取りの欄と答え合わせ) も残す
enum UILoadSelfTest {
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
        // チャットの確認 (CHAT CHECK。窓を開け、絵 14〜17 を撮る) のぶんも足す
        // 監査の流れの確認 (AUDIT FLOW CHECK。監査を 2 回、LLM の代わりで) のぶんも足す
        // 訳し直しの確認 (RETRANSLATE CHECK。翻訳を 1 回、LLM の代わりで) のぶんも足す。
        // 絵のときは、狭いウインドウの絵 (21・22) のぶんも足す
        // 終わりの参考の段 (UILoadAppendDetail.swift。追いかけたまま・追いかけずに、300 行を 3 回ずつ足す) のぶんも足す
        let hangLimit = (screenshots == nil ? 200.0 : 310.0) + (audio == nil ? 0 : 45.0) + 40.0 + 20.0 + 15.0 + 45.0
        DispatchQueue.global().asyncAfter(deadline: .now() + hangLimit) {
            finish(header + ["UI LOAD FAILED: the self-test did not finish in \(Int(hangLimit)) s"
                             + " (the main thread may be stuck)"], code: .hang, reportPath: reportPath)
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
        // 実行機の 1 行 (CI と手元を比べるため)
        var lines = header + [environmentDetailLine]
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
            finish(lines + ["UI LOAD FAILED: no main window after 20 s"], code: .noWindow, reportPath: reportPath)
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

        // 保存の確認 (ふだんと同じ AppModel の関数で)。絵を残すときは、そのあとメモの欄・履歴の画面・ゴミ箱に入れるかの確かめの画面も撮る
        let library = await load.libraryCheck(root: libraryRoot)
        lines += library.lines
        if let screenshots {
            lines += await load.takeLibraryScreenshots(into: screenshots)
        }
        // 監査の流れの確認 (AUDIT FLOW CHECK): アプリの監査の呼び方を、LLM の代わりで最後まで通す。
        // 失敗した時の終了コードは、保存の確認と同じ (UILoadExit.library。終了コードの表は変えていない)
        let auditFlow = await load.auditFlowCheck(root: libraryRoot)
        lines += auditFlow.lines
        // 訳し直しの確認 (RETRANSLATE CHECK): 「〇〇語で訳し直す」の道を、LLM の代わりで最後まで通す。
        // 失敗した時の終了コードは、監査の流れの確認と同じ (UILoadExit.library)
        let retranslate = await load.retranslateCheck(root: libraryRoot)
        lines += retranslate.lines

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
        // 6. チャットの確認 (LLM もネットワークも使わない)。設定の画面の「追加学習」の、GGUF でない差分のお知らせも見る
        let chatFailed = await ChatCheck.run(model: model, screenshots: screenshots, lines: &lines)
        let adapterMessageFailed = ChatCheck.adapterMessageCheck(lines: &lines)
        // 参考の段: 一覧の終わりを追いかけていない時に 300 行を足す (目安と比べず、終了コードにも入れない)。
        // 文字起こし中の結果の行が増えるので、ほかの測り・絵・確認がすべて終わったあとに置く
        lines += await load.notFollowingRound()
        // 失敗した確認を集め、返す 1 つを UILoadExit の表 (順) で決める
        var failed: Set<UILoadExit> = []
        if slow { failed.insert(.slow) }
        if lineFailed { failed.insert(.line) }
        if library.failed || adapterMessageFailed || auditFlow.failed || retranslate.failed { failed.insert(.library) }
        if practiceFailed { failed.insert(.practice) }
        if chatFailed { failed.insert(.chat) }
        let code = UILoadExit.decide(failed: failed)
        if code == .ok { lines.append("UI LOAD OK") }
        // 書きかけを待ってから、確認用のライブラリの一時フォルダを消す
        model.flushLibrary()
        try? FileManager.default.removeItem(at: libraryRoot)
        finish(lines, code: code, reportPath: reportPath)
    }

    private static func finish(_ lines: [String], code: UILoadExit, reportPath: String?) -> Never {
        // macOS が確認のあいだに本物の設定へ書いた物を元に戻し、戻した鍵を合格の行の前に出す (合否・終了コードは変えない)
        let restored = SettingsWriter.putBackAfterSelfTest().map { SettingsSnapshot.reportLines(restored: $0) } ?? []
        let lines = SettingsSnapshot.insert(restored, into: lines, before: "UI LOAD OK")
        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        LaunchLog.note("UI load self-test finished with code \(code.rawValue)")
        if let reportPath {
            try? text.write(toFile: (reportPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        exit(code.rawValue)
    }
}
