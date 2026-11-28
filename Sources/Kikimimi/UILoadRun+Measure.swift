// 画面の重さを測る所: 操作を起こす段階、1 回ずつ測る所、一覧の行を作る手間、結果の行と、目安を超えた物。

import AppKit
import Foundation
import KikimimiCore

extension LoadRun {
    // MARK: 操作

    func drive() async {
        probe.start()
        let started = Date()
        let rowsAtStart = UILoadHooks.rowsBuilt
        let bodiesAtStart = UILoadHooks.rowBodies
        let hoverAtStart = UILoadHooks.rowHoverChanges
        let listsAtStart = UILoadHooks.listBodies
        // ここから、行の数を操作ごとに分け始める
        rowCountMark = (rowsAtStart, bodiesAtStart, listsAtStart)
        checkMouse()
        // 1. 終わったジョブ (対訳)
        await measure(Action.selectBilingual) { model.select(doneBilingual) }
        await UILoadSelfTest.sleep(0.5)
        await phase(Phase.bilingual) {
            feedAction = Action.appendOther
            await drivePlayback(seconds: 8, lineJob: doneBilingual, steady: false)
        }
        // 同じジョブの中で、再生位置を遠くへ動かす (段階の外。2 回ずつ)
        await jumpRound()
        // 同じジョブを出したまま、メモと練習の書き取りの欄を書き換える (段階の外。一覧の行が作り直されないかを数える)
        await typingRound()
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
            for index in 1...3 {
                await burst(300, index: index, of: 3)
                await UILoadSelfTest.sleep(1.0)
            }
        }
        // ジョブを選び直す (3 回目)
        await selectRound()
        probe.stop()
        // 届いていない合図を待つ
        await UILoadSelfTest.sleep(0.3)
        // 操作ごとに分けるのは、ここまで (合計と同じ所で止める)
        flushRowCounts()
        rowCountMark = nil
        rowsBuiltTotal = UILoadHooks.rowsBuilt - rowsAtStart
        rowBodiesTotal = UILoadHooks.rowBodies - bodiesAtStart
        listBodiesTotal = UILoadHooks.listBodies - listsAtStart
        rowHoverChangesTotal = UILoadHooks.rowHoverChanges - hoverAtStart
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

    /// 終わったジョブ (対訳) を出したまま、メモを 20 回、練習の書き取りの欄の文を 20 回、1 文字ずつ書き足す
    /// (欄で打つのと同じく、job.notes と practice.dictation.typed を変える)。一覧の決まり 4 (一覧の body と行は
    /// メモ・練習を見ない) を、作り直した行の数で確かめるため。段階 1 のあと (jumpRound のあと) に呼ぶ。
    /// メモは確認用の一時フォルダにだけ保存される。終わりに、メモと書き取りの欄を元に戻し、再生していたかも戻す
    private func typingRound() async {
        let time = player.currentTime
        let wasPlaying = player.isPlaying
        // 再生位置が動くと、いまの行が変わって行が描き直されることがあるので、止めておく
        player.selfTestSetTime(time, playing: false)
        await settle()
        let notesBefore = doneBilingual.notes
        for i in 0..<20 {
            await measure(Action.notesEdit) { doneBilingual.notes = notesBefore + String(repeating: "a", count: i + 1) }
            await UILoadSelfTest.sleep(0.05)
        }
        let dictation = model.practice.dictation
        let typedBefore = dictation.typed
        for i in 0..<20 {
            await measure(Action.dictationEdit) { dictation.typed = typedBefore + String(repeating: "a", count: i + 1) }
            await UILoadSelfTest.sleep(0.05)
        }
        doneBilingual.notes = notesBefore
        dictation.typed = typedBefore
        player.selfTestSetTime(time, playing: wasPlaying)
        await settle()
    }

    /// 段階を 1 つ行う (見張りの値を、この段階の名前で分ける)。終わりに、まとめて足すのが済むまで待つ
    private func phase(_ name: String, _ body: () async -> Void) async {
        probe.setPhase(name)
        checkMouse()
        let initsBefore = UILoadHooks.rowsBuilt
        let bodiesBefore = UILoadHooks.rowBodies
        let start = UILoadSelfTest.now()
        await body()
        await UILoadSelfTest.sleep(batchInterval + 0.15)
        phaseTimes[name] = (start, UILoadSelfTest.now())
        rowInitsByPhase[name, default: 0] += UILoadHooks.rowsBuilt - initsBefore
        rowBodiesByPhase[name, default: 0] += UILoadHooks.rowBodies - bodiesBefore
        checkMouse()
        probe.setPhase(Phase.between)
    }

    /// マウスの位置が、メインのウインドウの枠の中に在るかを見て、覚える (見えるメインのウインドウが無ければ、外とする)
    private func checkMouse() {
        let location = NSEvent.mouseLocation
        let window = MainWindow.all().first { $0.isVisible }
        mouseInsideChecks.append(window.map { NSMouseInRect(location, $0.frame, false) } ?? false)
        // 同じ時の、アプリが前面か・ウインドウがキーか
        appActiveChecks.append(NSApplication.shared.isActive)
        windowKeyChecks.append(window?.isKeyWindow ?? false)
    }

    /// 前の時点から増えた行の数 (init と body) を、いま開いている操作のうち、後から始まった方に入れる
    /// (開いている操作が無ければ、どこにも入れない: 操作の外)。測る部分の外 (rowCountMark が nil) では何もしない
    private func flushRowCounts() {
        guard let mark = rowCountMark else { return }
        let inits = UILoadHooks.rowsBuilt
        let bodies = UILoadHooks.rowBodies
        let lists = UILoadHooks.listBodies
        if let current = openActions.last {
            rowInitsByAction[current, default: 0] += inits - mark.inits
            rowBodiesByAction[current, default: 0] += bodies - mark.bodies
            listBodiesByAction[current, default: 0] += lists - mark.lists
        }
        rowCountMark = (inits, bodies, lists)
    }

    /// 操作を始める (ここからの行の数を、この操作に入れる)
    private func beginRowCount(_ action: String) {
        flushRowCounts()
        if rowCountMark != nil {
            rowInitsByAction[action, default: 0] += 0
            rowBodiesByAction[action, default: 0] += 0
            listBodiesByAction[action, default: 0] += 0
        }
        openActions.append(action)
    }

    /// 操作を終える (ここまでの行の数を入れてから、開いている操作から外す)
    private func endRowCount(_ action: String) {
        flushRowCounts()
        if let index = openActions.lastIndex(of: action) { openActions.remove(at: index) }
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
    private func burst(_ count: Int, index: Int, of total: Int) async {
        beginRowCount(Action.burst)
        let timed = await timedBurst(count, detail: "burst", index: index, of: total)
        burstWaits.append(timed.wait)
        endRowCount(Action.burst)
        measured[Action.burst, default: []].append(timed.seconds)
    }

    /// burst の中身: 届けて、まとめて足し始めるのを待ち、メインスレッドが空くまでを測る。内わけの行も appendDetails に足す。
    /// 返すのは、足し始めてから空くまでの秒 (seconds) と、届けてから足し始めるまでの秒 (wait)。
    /// 追いかけていない時の参考の段 (UILoadAppendDetail.swift) も使う (そちらは measured に入れない)。
    ///
    /// 一覧が終わりへ小刻みに追いついた (TailCatchUp。macOS 15 以降) 時は、追いつき終わってメインが空くまで待つ
    /// (上限 10 秒。終わらなければ注記を出して続ける。失敗にはしない)。その時の seconds は、合わせた時間ではなく、
    /// このあいだの見張りのいちばん長い待ち (小刻みに追いつくあいだ、メインは 1 回ずつ空くので、合わせた時間のあいだ
    /// 止まっているわけではない。止まった長さは、見張りの待ちで見る)。追いつかなかった時は、これまでと同じ
    func timedBurst(_ count: Int, detail name: String, index: Int, of total: Int) async -> (seconds: Double, wait: Double) {
        let before = running.transcript?.segments.count ?? 0
        let target = before + count
        let mark = detailMark()
        let catchUpsBefore = UILoadHooks.catchUpsStarted
        let stepsBefore = UILoadHooks.catchUpSteps
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
        let idle = await UILoadSelfTest.untilIdleDetail(since: applied)
        burstsTimed += 1
        guard UILoadHooks.catchUpsStarted > catchUpsBefore else {
            appendDetails.append(detailLine(name, index: index, of: total, rowsBefore: before, since: mark, idle: idle,
                                            start: started))
            return (idle.seconds, UILoadSelfTest.seconds(from: started, to: applied))
        }
        // 小刻みに追いついている: 終わるまで、描き直しの 1 回りずつ待つ (タイマーで間をあけない)
        let giveUp = UILoadSelfTest.now() + 10_000_000_000
        while UILoadHooks.isCatchingUp?() == true, UILoadSelfTest.now() < giveUp {
            await MainRunLoopTurn.afterRedraw(timeout: 0.1)
        }
        if UILoadHooks.isCatchingUp?() == true {
            catchUpNotes.append("UI LOAD: note: the tail catch-up did not finish in 10 s (\"\(name)\" \(index) of \(total))")
        }
        _ = await UILoadSelfTest.untilIdleDetail(since: UILoadSelfTest.now())
        let catchUpTotal = UILoadSelfTest.seconds(from: applied, to: UILoadSelfTest.now())
        var detail = detailLine(name, index: index, of: total, rowsBefore: before, since: mark, idle: idle, start: started)
        detail.text += ", catch-up steps \(UILoadHooks.catchUpSteps - stepsBefore),"
            + " catch-up total \(String(format: "%.1f", UILoadSelfTest.ms(catchUpTotal))) ms"
        detail.caughtUp = true
        appendDetails.append(detail)
        // 見張りの合図が届くのを待ってから、このあいだのいちばん長い待ちを取る (50 ms ごとの合図の 1 回分より少し長く)
        await UILoadSelfTest.sleep(0.08)
        let end = UILoadSelfTest.now()
        let longest = probe.samples().filter { $0.posted >= started && $0.posted < end }.map(\.wait).max()
        burstCatchUps.append((catchUpTotal, longest))
        return (longest ?? catchUpTotal, UILoadSelfTest.seconds(from: started, to: applied))
    }

    /// 入れ物が、まとめた区間を足した (AppModel.liveFeed から)。足し始めてから、メインスレッドが空くまでを測る
    func batchApplied(count: Int, started: UInt64) {
        log.note("batch of \(count) segments applied to the running job", at: started)
        if awaitingBurst, burstApplied == nil { burstApplied = started }
        guard let action = feedAction else { return }
        // 1 つずつの区間のはずが、まとめて足された (届けるのが遅れた) ものは、1 つの区間の操作に入れない
        if action != Action.steadyBatch, count != 1 { return }
        beginRowCount(action)
        // 選んでいる文字起こし中のジョブに 1 行足した操作は、内わけの行も出す (足すのは済んでいるので、足した時間は最後の 1 回)
        let detailed = action == Action.appendSelected
        let mark = detailed ? detailMark(applyDone: true) : nil
        Task { @MainActor in
            guard let mark else {
                let seconds = await UILoadSelfTest.untilIdle(since: started)
                self.endRowCount(action)
                self.measured[action, default: []].append(seconds)
                return
            }
            let idle = await UILoadSelfTest.untilIdleDetail(since: started)
            self.endRowCount(action)
            self.measured[action, default: []].append(idle.seconds)
            self.singleAppendDetails += 1
            self.appendDetails.append(self.detailLine("append 1 segment", index: self.singleAppendDetails, of: 6,
                                                      rowsBefore: mark.rows - count, since: mark, idle: idle,
                                                      start: started))
        }
    }

    /// 操作をメインスレッドで行い、メインスレッドがまた空くまでを測る。
    /// 段階 3 のあいだは、再生位置・1 行だけの再生を Action.whileAdded の名前で記録する
    private func measure(_ action: String, _ body: () -> Void) async {
        let name = rowsAdded ? (Action.whileAdded[action] ?? action) : action
        log.note(name)
        let rowsBefore = UILoadHooks.rowsBuilt
        let bodiesBefore = UILoadHooks.rowBodies
        beginRowCount(name)
        let started = UILoadSelfTest.now()
        body()
        let seconds = await UILoadSelfTest.untilIdle(since: started)
        endRowCount(name)
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
            // 段階ごと・操作ごとの内わけ (名前の付いた分を引いた残りが「outside …」。どの目安とも比べない)
            func split(_ what: String, _ counts: [String: Int], _ order: [String], total: Int, outside: String) -> String {
                let named = order.filter { counts[$0] != nil }
                let rest = total - named.reduce(0) { $0 + (counts[$1] ?? 0) }
                let parts = named.map { "\($0) \(counts[$0] ?? 0)" } + ["\(outside) \(rest)"]
                return "UI LOAD: \(what): " + parts.joined(separator: ", ")
            }
            lines.append(split("row bodies by phase", rowBodiesByPhase, Phase.all, total: rowBodiesTotal,
                               outside: "outside the phases"))
            lines.append(split("row inits by phase", rowInitsByPhase, Phase.all, total: rowsBuiltTotal,
                               outside: "outside the phases"))
            lines.append(split("row bodies by action", rowBodiesByAction, Action.all, total: rowBodiesTotal,
                               outside: "outside the measured actions"))
            lines.append(split("row inits by action", rowInitsByAction, Action.all, total: rowsBuiltTotal,
                               outside: "outside the measured actions"))
            // 一覧そのもの (TranscriptListView) の body が動いた回数の内わけ
            if let listBodiesTotal {
                lines.append(split("list bodies by action", listBodiesByAction, Action.all, total: listBodiesTotal,
                                   outside: "outside the measured actions"))
            }
        }
        if let rowHoverChangesTotal {
            let inside = mouseInsideChecks.filter { $0 }.count
            let active = appActiveChecks.filter { $0 }.count
            let key = windowKeyChecks.filter { $0 }.count
            // 見た順の印 (+ = そうだった、- = 違った)。始め・段階 1 の始めと終わり・…・段階 4 の始めと終わり
            func marks(_ checks: [Bool]) -> String { checks.map { $0 ? "+" : "-" }.joined() }
            lines.append("UI LOAD: row hover changes \(rowHoverChangesTotal) (the mouse pointer was inside the main window"
                         + " at \(inside) of \(mouseInsideChecks.count) checks \(marks(mouseInsideChecks));"
                         + " the app was active at \(active) \(marks(appActiveChecks)),"
                         + " the main window was key at \(key) \(marks(windowKeyChecks)))")
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
        // 段階 4 の、足す操作 1 回ごとの内わけ (目安とは比べない)
        if !appendDetails.isEmpty {
            lines.append(Self.appendDetailLegend)
            // 最後の操作の「次まで」は、段階 4 の終わりまで
            let end = phaseTimes[Phase.burst]?.end ?? UILoadSelfTest.now()
            lines += renderDetails(appendDetails[...], until: end)
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
        // 一覧の決まり 4 (CLAUDE.md「結果の一覧」): 一覧の body と行は、再生位置・メモ・練習を見ない。
        // 一覧の body が見ていれば、これらの操作のたびに一覧の body が動く (行は作り直されないので、一覧の body の回数で見る)。
        // 行が見ていれば、行が作り直される (init) か、行の body が動く。時間でなく数なので、実行機の重さに左右されない。
        // いまの行が変わるときは、前といまの行が描き直されてよいので、行は init だけを見る (一覧の body は 0 のまま)。
        // 文字起こし中に測った分 (while rows are added) は、行が足されているので見ない。測っていない操作 (n が 0) も見ない
        let unchangedRows: [(action: String, bodies: Bool, reads: String)] = [
            (Action.tick, true, "the playback position"),
            (Action.rowChange, false, "the playback position"),
            (Action.notesEdit, true, "the notes (job.notes)"),
            (Action.dictationEdit, true, "the practice state (practice.dictation)")
        ]
        for rule in unchangedRows where !(measured[rule.action] ?? []).isEmpty {
            let lists = listBodiesByAction[rule.action] ?? 0
            let inits = rowInitsByAction[rule.action] ?? 0
            let bodies = rowBodiesByAction[rule.action] ?? 0
            let counts = "list bodies \(lists), row inits \(inits), row bodies \(bodies)"
            if lists > 0 {
                failures.append("\"\(rule.action)\" re-ran the list (\(counts); list bodies must be 0): the list body reads"
                                + " \(rule.reads) (CLAUDE.md, results list rule 4)")
            } else if inits > 0 || (rule.bodies && bodies > 0) {
                let must = rule.bodies ? "row inits and row bodies must be 0" : "row inits must be 0"
                failures.append("\"\(rule.action)\" rebuilt rows (\(counts); \(must)): a row reads \(rule.reads)"
                                + " (CLAUDE.md, results list rule 4)")
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
