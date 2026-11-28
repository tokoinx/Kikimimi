// 画面の重さの確認の、終わりの実験の段 (原因を調べるための測り。目安とは比べず、SLOW にも終了コードにも入れない):
// 一覧の終わりを追いかけたまま 300 行を足すと重くなる行の数 (CI の macOS 15 で、毎回同じ数で重い) で、
// 足し方を変えて、同じ行の数どうしで比べる。重さは行の数で変わるので、1 回ごとに、ちょうどその行の数の
// 新しい文字起こし中の結果を作って選ぶ。

import Foundation
import KikimimiCore

extension LoadRun {
    /// 実験の、始めの行の数 (CI で、追いかけたまま 300 行を足すと重かった数)
    static let experimentBases = [3988, 8087, 8088, 8987, 9288]

    /// 実験の段を走らせるか。ふだんは走らせない (CI の時間を 1 分ほど使うので)。原因を調べ直す時だけ true にする
    /// (2026-11-28 に 1 度走らせた。結果は docs/HANDOFF.md)
    nonisolated static let experimentEnabled = true

    /// この確認で行う、始めの行の数。CI の 8000 行の段は 4 分で打ち切られるので、5 つを 2 つの確認に分ける
    /// (3000 行の確認 (打ち切りは 10 分) で始めの 3 つ、8000 行の確認で残りの 2 つ。手元で 1 つあたり 10 秒ほど)
    var experimentBasesForThisRun: [Int] {
        rows < 8000 ? Array(Self.experimentBases.prefix(3)) : Array(Self.experimentBases.dropFirst(3))
    }

    /// 実験の結果の、全体の長さ (秒)。その行の数が CI で重かった確認の、文字起こし中の結果と同じ
    /// (3988 は 3000 行の確認、ほかは 8000 行の確認。どちらの確認で行っても同じ形にする)
    static func experimentDuration(base: Int) -> Double {
        Double(base < 8000 ? 3000 : 8000) * UILoadSelfTest.rowSpacing * 2
    }

    /// 実験の、足し方の 1 つ (足すのは、いつも合わせて 300 行)
    struct ExperimentVariant {
        /// 行に出す名前
        var name: String
        /// 1 回ごとに足す行の数 (前の回で、メインが空いてから次を足す)
        var batches: [Int]
        /// 追いかけるのをやめてから足し、空いたあと、また追いかける (「末尾へ」と同じ道)
        var unfollowed = false
        /// 足すのと一覧を動かすのを分ける: 追いかけるのをやめ (位置は前の終わりのまま)、300 行を 1 回で足し、
        /// そのあと、この行の数ずつ一覧を下へ動かして新しい終わりまで行き、また追いかける
        var scrollStep: Int?
        /// scrollStep の動かし方: nil なら 1 回ごとにメインが空くまで待つ。値があれば、その秒ごとに次を動かす
        /// (空くのは、最後のあとにだけ待つ)
        var scrollCadence: Double?
    }

    /// 実験の足し方 (この順で行い、この順で行に出す)
    static let experimentVariants = [
        ExperimentVariant(name: "control", batches: [300]),
        ExperimentVariant(name: "steps of 10", batches: Array(repeating: 10, count: 30)),
        ExperimentVariant(name: "append unfollowed, then follow", batches: [300], unfollowed: true),
        ExperimentVariant(name: "scroll steps of 10", batches: [300], scrollStep: 10),
        ExperimentVariant(name: "scroll steps of 20", batches: [300], scrollStep: 20),
        ExperimentVariant(name: "scroll steps of 30", batches: [300], scrollStep: 30),
        ExperimentVariant(name: "scroll steps of 10, every 30 ms", batches: [300], scrollStep: 10, scrollCadence: 0.03)
    ]

    /// 実験の 1 回の結果 (まとめの行に使う)
    struct ExperimentResult {
        var line: String
        var bodies: Int
        var worst: Double
        var longestWait: Double?
        var total: Double
        var job: Job
    }

    /// 実験の段のあいだの、見張りの合図の段階の名前 (測る段階の集計には入らない)
    static let experimentPhase = "experiment stage (not measured)"

    /// 実験の段: 始めの行の数ごと・足し方ごとに、新しい文字起こし中の結果 (段階 4 と同じ形) を作って選び、
    /// 終わりを追いかけている事を確かめてから足して、body を動かした行の数などを 1 行に出す。
    /// 参考の段 (notFollowingRound) のあとに呼ぶ (このあとに確認は無い)。作った結果は、次の結果を選んでから消す
    func experimentRound() async -> [String] {
        guard Self.experimentEnabled else { return [] }
        var lines = ["experiment (not compared with any limit): for each row count, a new running job with exactly that"
                     + " many rows (as the running job of phase 4), selected and following the end, then 300 rows added"
                     + " in different ways (applied directly with AppModel.applyLive, each step after the previous one"
                     + " is idle). \"scroll steps of N\": stop following without moving the list (it stays at the old"
                     + " end), add the 300 rows at once and wait until idle (append bodies = bodies of that part), then"
                     + " scrollTo the row base + N*k - 1 at the bottom for k = 1, 2, ... (waiting until idle after each;"
                     + " \"every 30 ms\": the next one 30 ms after the previous one, idle only after the last, and a step"
                     + " = from its scrollTo until the 30 ms wait returned), then follow again and wait until idle."
                     + " bodies / inits = PlayableRow bodies and inits from the first step until the last step is idle;"
                     + " total = that time; worst / median step idle = over the steps (append and scroll steps);"
                     + " longest wait = the longest watchdog wait during the whole trial; rows = rows before -> after;"
                     + " following = the list followed the end before the first step; follow back = the first scroll"
                     + " step after which the list followed the end again on its own (none = only after the last)"]
        lines.append("UI LOAD: experiment row counts in this run: "
                     + experimentBasesForThisRun.map(String.init).joined(separator: ", ")
                     + " (3988, 8087, 8088 in the run with fewer than 8000 rows; 8987, 9288 in the others)")
        Self.live("experiment: start")
        let stageStarted = UILoadSelfTest.now()
        player.stopLine()
        player.selfTestSetTime(0, playing: false)
        probe.setPhase(Self.experimentPhase)
        probe.start()
        var previous: Job?
        var summaries: [String] = []
        func f(_ seconds: Double) -> String { String(format: "%.1f", UILoadSelfTest.ms(seconds)) }
        for base in experimentBasesForThisRun {
            var bodies: [String] = []
            var times: [String] = []
            for variant in Self.experimentVariants {
                Self.live("experiment: rows \(base) \"\(variant.name)\"")
                let trial = await experimentTrial(base: base, variant: variant, previous: previous)
                previous = trial.job
                lines.append(trial.line)
                bodies.append("\(variant.name) \(trial.bodies)")
                let wait = trial.longestWait.map(f) ?? "unknown"
                times.append("\(variant.name) \(f(trial.worst))/\(wait)/\(f(trial.total)) ms")
            }
            summaries.append("UI LOAD: experiment summary rows \(base): " + bodies.joined(separator: "; "))
            summaries.append("UI LOAD: experiment times rows \(base) (worst step idle/longest wait/total): "
                             + times.joined(separator: "; "))
        }
        probe.stop()
        // 選んでいた文字起こし中の結果に戻してから、最後に作った結果を消す
        model.select(running)
        if let previous { model.delete(previous) }
        lines += summaries
        let took = UILoadSelfTest.seconds(from: stageStarted, to: UILoadSelfTest.now())
        lines.append("UI LOAD: experiment took \(String(format: "%.1f", took)) s")
        Self.live("experiment: done")
        return lines
    }

    /// 実験の 1 回: 結果を作って選び (前の回の結果は、選び替えてから消す)、追いかけている事を確かめ、足し方のとおりに足す
    private func experimentTrial(base: Int, variant: ExperimentVariant, previous: Job?) async -> ExperimentResult {
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
        let prefix = "UI LOAD: experiment rows \(base) \"\(variant.name)\": "
        guard let setFollowing = UILoadHooks.setFollowing, let scrollList = UILoadHooks.scrollList,
              let isFollowing = UILoadHooks.isFollowing else {
            return ExperimentResult(line: prefix + "skipped (the list did not register its hooks)", bodies: -1,
                                    worst: 0, longestWait: nil, total: 0, job: job)
        }
        // 段階 4 と同じく、終わりを追いかけている所から始める (選んだだけで追いかけていなければ、「末尾へ」と同じ道で)
        if !isFollowing(), let last = job.transcript?.segments.last?.id {
            setFollowing(true)
            scrollList(last, .bottom)
            await settle()
        }
        let following = isFollowing()
        // 追いかけるのをやめる (参考の段と同じ: 終わりから 15 行ほど上へ動かし、追いかけるのをやめる)
        if variant.unfollowed, let segments = job.transcript?.segments, segments.count > 15 {
            scrollList(segments[segments.count - 15].id, .bottom)
            setFollowing(false)
            await settle()
        }
        // 一覧を動かす足し方: 位置は前の終わりのまま、追いかけるのだけをやめる
        if variant.scrollStep != nil {
            setFollowing(false)
            _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
        }
        let followingBeforeSteps = isFollowing()
        let rowsBefore = job.transcript?.segments.count ?? 0
        let inits = UILoadHooks.rowsBuilt
        let bodies = UILoadHooks.rowBodies
        let started = UILoadSelfTest.now()
        var next = rowsBefore
        var stepTimes: [Double] = []
        for count in variant.batches {
            let segments = UILoadSelfTest.makeSegments(next..<(next + count))
            next += count
            let stepStarted = UILoadSelfTest.now()
            AppModel.applyLive(LiveSegmentBuffer.Batch(segments: segments), to: job)
            let idle = await UILoadSelfTest.untilIdleDetail(since: stepStarted)
            stepTimes.append(idle.seconds)
        }
        let appendBodies = UILoadHooks.rowBodies - bodies
        var followBack: Int?
        var scrollTimes: [Double] = []
        if let step = variant.scrollStep, let segments = job.transcript?.segments {
            let ids = stride(from: rowsBefore + step - 1, to: segments.count, by: step).map { segments[$0].id }
            for (index, id) in ids.enumerated() {
                let stepStarted = UILoadSelfTest.now()
                scrollList(id, .bottom)
                if let cadence = variant.scrollCadence {
                    if index == ids.count - 1 {
                        let idle = await UILoadSelfTest.untilIdleDetail(since: stepStarted)
                        scrollTimes.append(idle.seconds)
                    } else {
                        await UILoadSelfTest.sleep(cadence)
                        scrollTimes.append(UILoadSelfTest.seconds(from: stepStarted, to: UILoadSelfTest.now()))
                    }
                } else {
                    let idle = await UILoadSelfTest.untilIdleDetail(since: stepStarted)
                    scrollTimes.append(idle.seconds)
                }
                if followBack == nil, index < ids.count - 1, isFollowing() { followBack = index + 1 }
            }
            // また追いかける
            let stepStarted = UILoadSelfTest.now()
            setFollowing(true)
            let idle = await UILoadSelfTest.untilIdleDetail(since: stepStarted)
            stepTimes.append(idle.seconds)
        }
        if variant.unfollowed, let last = job.transcript?.segments.last?.id {
            // また追いかける (「末尾へ」と同じ: 追いかけるのを戻し、終わりの行へ動かす)
            let stepStarted = UILoadSelfTest.now()
            setFollowing(true)
            scrollList(last, .bottom)
            let idle = await UILoadSelfTest.untilIdleDetail(since: stepStarted)
            stepTimes.append(idle.seconds)
        }
        let ended = UILoadSelfTest.now()
        let builtBodies = UILoadHooks.rowBodies - bodies
        let builtInits = UILoadHooks.rowsBuilt - inits
        let rowsAfter = job.transcript?.segments.count ?? 0
        // 見張りの合図が届くのを待ってから、この回のあいだのいちばん長い待ちを取る
        // (見張りは 50 ms ごとに合図を積む。メインは空いているので、1 回分より少し長く待てば足りる)
        await UILoadSelfTest.sleep(0.08)
        let windowEnd = UILoadSelfTest.now()
        let longest = probe.samples().filter { $0.posted >= started && $0.posted < windowEnd }.map(\.wait).max()
        let wait = longest.map { "\(f($0)) ms" } ?? "unknown (no watchdog samples)"
        var followingText = "following \(following)"
        if variant.unfollowed || variant.scrollStep != nil {
            followingText += " (then stopped: following \(followingBeforeSteps))"
        }
        let allSteps = stepTimes + scrollTimes
        let worst = allSteps.max() ?? 0
        let total = UILoadSelfTest.seconds(from: started, to: ended)
        let steps = variant.batches.count + scrollTimes.count + (variant.unfollowed || variant.scrollStep != nil ? 1 : 0)
        var line = prefix + "bodies \(builtBodies), inits \(builtInits), steps \(steps),"
            + " total \(f(total)) ms, worst step idle \(f(worst)) ms,"
            + " longest wait \(wait), rows \(rowsBefore) -> \(rowsAfter), \(followingText)"
        if variant.scrollStep != nil {
            let median = UILoadSelfTest.percentile(allSteps.sorted(), 0.5)
            line += ", append bodies \(appendBodies), median step idle \(f(median)) ms,"
                + " scroll steps \(scrollTimes.count), follow back \(followBack.map { "at scroll step \($0)" } ?? "none")"
        }
        return ExperimentResult(line: line, bodies: builtBodies, worst: worst, longestWait: longest, total: total, job: job)
    }
}
