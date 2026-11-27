// 画面の重さの確認の、合格の目安・測る操作の名前・段階の名前。

import Foundation

extension UILoadSelfTest {
    /// 合格の目安 (秒)。GitHub の macOS の実行機 (3 コア、仮想の GPU。ふつうの Mac より遅い) のための値。
    /// p95 は 95 パーセンタイル、max は最大
    enum Limits {
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
    enum Action {
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

        /// 出している結果 (対訳) のメモを 1 回書き換える (メモの欄で 1 文字打ったときと同じく、job.notes を変える)
        static let notesEdit = "notes edit"
        /// 練習の書き取りの欄の文を 1 回書き換える (欄で 1 文字打ったときと同じく、practice.dictation.typed を変える)
        static let dictationEdit = "practice dictation typing"

        static let all = [selectBilingual, selectPlain, selectRunning, jumpFar, jumpBack, tick, rowChange, lineStart, lineStop,
                          tickWhileAdded, rowChangeWhileAdded, lineStartWhileAdded, lineStopWhileAdded,
                          appendSelected, appendOther, burst, progress, steadyBatch, notesEdit, dictationEdit]
    }

    /// 段階の名前 (見張りの出力)
    enum Phase {
        static let bilingual = "finished job (bilingual)"
        static let plain = "finished job (plain)"
        static let steady = "running job, steady 10 segments/s with ticks and one-line starts"
        static let burst = "running job, single segments and bursts of 300"
        /// 段階の外 (ジョブを選ぶ・落ち着くのを待つ)。見張りの出力には出さない
        static let between = "between phases"
        static let all = [bilingual, plain, steady, burst]
    }
}
