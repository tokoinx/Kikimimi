// 画面の重さの確認の、終わりの実験の段 (原因を調べるための測り。目安とは比べず、SLOW にも終了コードにも入れない):
// 文字起こし中で一覧の終わりを追いかけている時に、ウインドウを隠している (画面に出ていない) あいだに行が 10 行ずつ
// 届くと、一覧がどうなるか (隠しているあいだに重いか、また出した時に、届いた行をいっぺんに並べて止まるか) を、
// 隠し方を変えて、同じ行の数どうしで比べる。重さは行の数で変わるので、1 回ごとに、ちょうどその行の数の
// 新しい文字起こし中の結果を作って選ぶ。

import AppKit
import Foundation
import KikimimiCore

extension LoadRun {
    /// 実験の、始めの行の数 (CI で、追いかけたまま 300 行を足すと重かった数)
    static let experimentBases = [3988, 8087, 8088, 8987, 9288]

    /// 実験の段を走らせるか。ふだんは走らせない (CI の時間を 1 分ほど使うので)。原因を調べ直す時だけ true にする
    /// (2026-11-28 に 1 度走らせた。結果は docs/HANDOFF-ARCHIVE.md)
    nonisolated static let experimentEnabled = false

    /// この確認で行う、始めの行の数。CI の 8000 行の段は 4 分で打ち切られるので、2 つの確認に分ける。
    /// 隠し方の実験は 1 つの数あたり手元で 20 秒ほどかかるので、それぞれの確認で減らしてある
    /// (3000 行の確認で 3988 と 8087、8000 行の確認で 8987)
    static let experimentBasesFewRows = [3988, 8087]
    static let experimentBasesManyRows = [8987]
    var experimentBasesForThisRun: [Int] {
        rows < 8000 ? Self.experimentBasesFewRows : Self.experimentBasesManyRows
    }

    /// 実験の結果の、全体の長さ (秒)。その行の数が CI で重かった確認の、文字起こし中の結果と同じ
    /// (3988 は 3000 行の確認、ほかは 8000 行の確認。どちらの確認で行っても同じ形にする)
    static func experimentDuration(base: Int) -> Double {
        Double(base < 8000 ? 3000 : 8000) * UILoadSelfTest.rowSpacing * 2
    }

    /// 実験の、隠し方の 1 つ (どれも、隠したあと 10 行ずつ 30 回、合わせて 300 行を足してから、また出す)
    enum ExperimentHide: CaseIterable {
        case visible
        case orderOut
        case miniaturize
        case appHide

        var name: String {
            switch self {
            case .visible: return "visible, 10 at a time"
            case .orderOut: return "hidden (orderOut), 10 at a time, then shown"
            case .miniaturize: return "miniaturized, 10 at a time, then restored"
            case .appHide: return "app hidden, 10 at a time, then unhidden"
            }
        }
    }

    /// 実験の段のあいだの、見張りの合図の段階の名前 (測る段階の集計には入らない)
    static let experimentPhase = "experiment stage (not measured)"

    /// 実験の段: 始めの行の数ごと・隠し方ごとに、新しい文字起こし中の結果 (段階 4 と同じ形) を作って選び、
    /// 終わりを追いかけている事を確かめてから、ウインドウを隠し、10 行ずつ 30 回足し、また出して、
    /// 隠しているあいだと、出したあとを分けて 1 行に出す。
    /// 参考の段 (notFollowingRound) のあとに呼ぶ (このあとに確認は無い)。作った結果は、次の結果を選んでから消す
    func experimentRound() async -> [String] {
        guard Self.experimentEnabled else { return [] }
        var lines = ["experiment (not compared with any limit): for each row count, a new running job with exactly that"
                     + " many rows (as the running job of phase 4), selected and following the end; then the main window"
                     + " is hidden in different ways, 300 rows are added as 30 batches of 10 (AppModel.applyLive, each"
                     + " batch after the previous one is idle: the live shape, one jump to the end per batch), and the"
                     + " window is shown again. while hidden = from the first batch until the last one is idle; after"
                     + " showing = from the show call until the window is back and the main thread is idle (idle after);"
                     + " bodies / inits = PlayableRow bodies and inits; scrollTo calls = the tracker's scrollTo calls;"
                     + " longest wait = the longest watchdog wait in that part; window visible before/after = the main"
                     + " window's isVisible while the rows were added / after showing; following = the list followed the"
                     + " end after showing; catch-ups started = stepped tail catch-ups during the trial"]
        lines.append("UI LOAD: experiment row counts in this run: "
                     + experimentBasesForThisRun.map(String.init).joined(separator: ", ")
                     + " (3988, 8087 in the run with fewer than 8000 rows; 8987 in the others; 8088 and 9288 dropped for time)")
        Self.live("experiment: start")
        let stageStarted = UILoadSelfTest.now()
        player.stopLine()
        player.selfTestSetTime(0, playing: false)
        probe.setPhase(Self.experimentPhase)
        probe.start()
        var previous: Job?
        var summaries: [String] = []
        for base in experimentBasesForThisRun {
            var parts: [String] = []
            for hide in ExperimentHide.allCases {
                Self.live("experiment: rows \(base) \"\(hide.name)\"")
                let trial = await experimentTrial(base: base, hide: hide, previous: previous)
                previous = trial.job
                lines.append(trial.line)
                parts.append("\(hide.name) \(trial.summary)")
            }
            summaries.append("UI LOAD: experiment summary rows \(base): " + parts.joined(separator: "; "))
        }
        probe.stop()
        // 選んでいた文字起こし中の結果に戻してから、最後に作った結果を消す
        model.select(running)
        if let previous { model.delete(previous) }
        await settle()
        lines += summaries
        let took = UILoadSelfTest.seconds(from: stageStarted, to: UILoadSelfTest.now())
        lines.append("UI LOAD: experiment took \(String(format: "%.1f", took)) s")
        Self.live("experiment: done")
        return lines
    }

    /// 実験の 1 回: 結果を作って選び (前の回の結果は、選び替えてから消す)、追いかけている事を確かめ、隠して足して、また出す
    private func experimentTrial(base: Int, hide: ExperimentHide,
                                 previous: Job?) async -> (line: String, summary: String, job: Job) {
        func f(_ seconds: Double) -> String { String(format: "%.1f", UILoadSelfTest.ms(seconds)) }
        // 段階 4 の文字起こし中の結果と同じ形 (行の文・長さ・言語・全体の長さ・状態)
        let job = Job(name: "文字起こし中 (確認用, 実験 \(base) 行)", url: running.url)
        job.transcript = Transcript(sourceName: job.name, segments: UILoadSelfTest.makeSegments(0..<base),
                                    language: "en", duration: Self.experimentDuration(base: base))
        job.status = .running
        job.progress = 0.5
        job.message = "認識中 50%"
        model.adopt(job, at: model.jobs.count)
        model.select(job)
        if let previous { model.delete(previous) }
        await settle()
        let prefix = "UI LOAD: experiment rows \(base) \"\(hide.name)\": "
        guard let setFollowing = UILoadHooks.setFollowing, let scrollList = UILoadHooks.scrollList,
              let isFollowing = UILoadHooks.isFollowing,
              let window = MainWindow.all().first(where: { $0.isVisible }) else {
            return (prefix + "skipped (no list hooks or no visible main window)", "skipped", job)
        }
        // 段階 4 と同じく、終わりを追いかけている所から始める (選んだだけで追いかけていなければ、「末尾へ」と同じ道で)
        if !isFollowing(), let last = job.transcript?.segments.last?.id {
            setFollowing(true)
            scrollList(last, .bottom)
            await settle()
        }
        let wasKey = window.isKeyWindow
        let wasActive = NSApp.isActive
        let catchUpsBefore = UILoadHooks.catchUpsStarted
        // 隠す
        var notes: [String] = []
        switch hide {
        case .visible:
            break
        case .orderOut:
            window.orderOut(nil)
        case .miniaturize:
            window.miniaturize(nil)
            if !(await Self.waitUntil(3) { window.isMiniaturized }) { notes.append("did not miniaturize in 3 s") }
        case .appHide:
            NSApp.hide(nil)
            if !(await Self.waitUntil(3) { NSApp.isHidden }) { notes.append("the app did not hide in 3 s") }
        }
        _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
        let visibleWhileAdding = window.isVisible
        let appHiddenWhileAdding = NSApp.isHidden
        // 1. 隠しているあいだに、10 行ずつ 30 回足す
        var inits = UILoadHooks.rowsBuilt
        var bodies = UILoadHooks.rowBodies
        let calls = UILoadHooks.scrollToCalls
        let started = UILoadSelfTest.now()
        var next = job.transcript?.segments.count ?? 0
        for _ in 0..<30 {
            let segments = UILoadSelfTest.makeSegments(next..<(next + 10))
            next += 10
            let stepStarted = UILoadSelfTest.now()
            AppModel.applyLive(LiveSegmentBuffer.Batch(segments: segments), to: job)
            _ = await UILoadSelfTest.untilIdleDetail(since: stepStarted)
        }
        let ended = UILoadSelfTest.now()
        let hiddenBodies = UILoadHooks.rowBodies - bodies
        let hiddenInits = UILoadHooks.rowsBuilt - inits
        let hiddenCalls = UILoadHooks.scrollToCalls - calls
        await UILoadSelfTest.sleep(0.08)
        let hiddenWait = longestWait(from: started)
        // 2. また出す
        inits = UILoadHooks.rowsBuilt
        bodies = UILoadHooks.rowBodies
        let showStarted = UILoadSelfTest.now()
        switch hide {
        case .visible:
            break
        case .orderOut:
            window.makeKeyAndOrderFront(nil)
        case .miniaturize:
            window.deminiaturize(nil)
            if !(await Self.waitUntil(3) { !window.isMiniaturized && window.isVisible }) {
                notes.append("did not restore in 3 s")
            }
        case .appHide:
            NSApp.unhide(nil)
            if !(await Self.waitUntil(3) { !NSApp.isHidden && window.isVisible }) { notes.append("the app did not unhide in 3 s") }
        }
        let idle = await UILoadSelfTest.untilIdleDetail(since: showStarted)
        let shownBodies = UILoadHooks.rowBodies - bodies
        let shownInits = UILoadHooks.rowsBuilt - inits
        await UILoadSelfTest.sleep(0.08)
        let shownWait = longestWait(from: showStarted)
        // 次の回と、確認の終わりのために、ウインドウを出したまま、キーかどうかを前と同じにする
        if !window.isVisible || window.isMiniaturized || NSApp.isHidden {
            notes.append("the window had to be restored again")
            if NSApp.isHidden { NSApp.unhide(nil) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            _ = await Self.waitUntil(3) { window.isVisible && !window.isMiniaturized }
        }
        // 隠したアプリは、出しても前面にならない: 前面だったなら、前面に戻してからキーにする
        if wasActive, !NSApp.isActive {
            NSApp.activate()
            _ = await Self.waitUntil(2) { NSApp.isActive }
        }
        if wasKey, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            _ = await Self.waitUntil(1) { window.isKeyWindow }
        }
        await settle()
        let visibleAfter = window.isVisible
        let followingAfter = UILoadHooks.isFollowing?() ?? false
        let wait1 = hiddenWait.map(f) ?? "unknown"
        let wait2 = shownWait.map(f) ?? "unknown"
        var line = prefix + "while hidden: bodies \(hiddenBodies), inits \(hiddenInits), scrollTo calls \(hiddenCalls),"
            + " total \(f(UILoadSelfTest.seconds(from: started, to: ended))) ms, longest wait \(wait1) ms;"
            + " after showing: bodies \(shownBodies), inits \(shownInits), idle after \(f(idle.seconds)) ms,"
            + " longest wait \(wait2) ms; window visible before/after \(visibleWhileAdding)/\(visibleAfter),"
            + " following \(followingAfter), catch-ups started \(UILoadHooks.catchUpsStarted - catchUpsBefore)"
        if hide == .appHide { line += ", app hidden while adding \(appHiddenWhileAdding)" }
        line += ", key before/after \(wasKey)/\(window.isKeyWindow), app active before/after \(wasActive)/\(NSApp.isActive)"
        if !notes.isEmpty { line += " (" + notes.joined(separator: "; ") + ")" }
        return (line, "\(hiddenBodies)+\(shownBodies) (\(wait2) ms)", job)
    }

    /// from から今までに積まれた、見張りの合図のいちばん長い待ち (秒。合図が無ければ nil)
    private func longestWait(from start: UInt64) -> Double? {
        let end = UILoadSelfTest.now()
        return probe.samples().filter { $0.posted >= start && $0.posted < end }.map(\.wait).max()
    }

    /// 条件が満たされるまで待つ (50 ms ごとに見る。Dock の動きなどを待つだけなので、タイマーでよい)。満たされたか
    private static func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let giveUp = UILoadSelfTest.now() + UInt64(seconds * 1_000_000_000)
        while !condition() {
            if UILoadSelfTest.now() >= giveUp { return false }
            await UILoadSelfTest.sleep(0.05)
        }
        return true
    }
}
