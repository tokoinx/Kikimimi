// 画面の重さの確認の、一覧の終わりへ小刻みに追いつく (TailCatchUp。ListFollow) 所の行:
// 使っているかと、burst で追いついた回の時間のまとめ、追いかけるのをやめると止まるかの確かめ (目安と比べず、終了コードにも入れない)。

import Foundation
import KikimimiCore

extension LoadRun {
    /// まとめの 1 行: 使っているか (と、その理由)、timedBurst のうち小刻みに追いついた回の数と、時間・いちばん長い待ち
    var tailCatchUpSummary: String {
        func f(_ seconds: Double) -> String { String(format: "%.1f", UILoadSelfTest.ms(seconds)) }
        let state = TailFollowSwitch.enabled ? "on" : "off"
        let variable = TailFollowSwitch.override ?? "not set"
        var line = "UI LOAD: tail catch-up: \(state) (macOS 15 or later: \(TailFollowSwitch.osAtLeast15),"
            + " \(TailFollowSwitch.variable): \(variable)); bursts caught up in steps \(burstCatchUps.count) of \(burstsTimed)"
        let totals = burstCatchUps.map(\.total).sorted()
        if let worst = totals.last {
            let waits = burstCatchUps.compactMap(\.longestWait)
            let wait = waits.max().map { "\(f($0)) ms" } ?? "unknown (no watchdog samples)"
            line += "; total median \(f(UILoadSelfTest.percentile(totals, 0.5))) ms, max \(f(worst)) ms;"
                + " longest wait max \(wait)"
        }
        return line
    }

    /// 追いかけるのをやめると、小刻みに追いつくのが止まるかの確かめ: 文字起こし中の結果に 300 行を足し、2 回動いたところで
    /// 追いかけるのをやめ (画面を上へ動かした時と同じ ListFollow.isOn)、そのあと 1 回より多く動かない事と、
    /// 追いついている最中でなくなる事を見る。終わりに、また追いかける。参考の段のあとに呼ぶ (このあとに測る物は無い)
    func tailCatchUpStopCheck() async -> [String] {
        let name = "UI LOAD: tail catch-up stop check"
        guard TailFollowSwitch.enabled else { return ["\(name): skipped (tail catch-up off)"] }
        Self.live("tail catch-up stop check")
        player.stopLine()
        player.selfTestSetTime(0, playing: false)
        model.select(running)
        await settle()
        guard let setFollowing = UILoadHooks.setFollowing, let scrollList = UILoadHooks.scrollList,
              let isCatchingUp = UILoadHooks.isCatchingUp, let last = running.transcript?.segments.last?.id else {
            return ["\(name): skipped (the list did not register its hooks, or the running job has no rows)"]
        }
        setFollowing(true)
        scrollList(last, .bottom)
        await settle()
        let startsBefore = UILoadHooks.catchUpsStarted
        let stepsBefore = UILoadHooks.catchUpSteps
        let count = 300
        AppModel.applyLive(LiveSegmentBuffer.Batch(segments: UILoadSelfTest.makeSegments(nextSegment..<(nextSegment + count))),
                           to: running)
        nextSegment += count
        // 2 回動くまで待つ (描き直しの 1 回りずつ。3 秒まで)
        let giveUp = UILoadSelfTest.now() + 3_000_000_000
        while UILoadHooks.catchUpSteps - stepsBefore < 2, UILoadSelfTest.now() < giveUp {
            await MainRunLoopTurn.afterRedraw(timeout: 0.1)
        }
        let started = UILoadHooks.catchUpsStarted > startsBefore
        let stepsAtStop = UILoadHooks.catchUpSteps - stepsBefore
        let catchingAtStop = isCatchingUp()
        setFollowing(false)
        // 描き直しの 5 回りと、メインが空くまで待つ
        for _ in 0..<5 { await MainRunLoopTurn.afterRedraw(timeout: 0.1) }
        _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
        let stepsAfter = UILoadHooks.catchUpSteps - stepsBefore - stepsAtStop
        let catchingAfter = isCatchingUp()
        let expected = started && catchingAtStop && stepsAtStop >= 2 && stepsAfter <= 1 && !catchingAfter
        let line = "\(name): \(expected ? "as expected" : "NOT as expected"): catch-up started \(started),"
            + " steps before stopping following \(stepsAtStop) (catching up \(catchingAtStop)),"
            + " steps after stopping \(stepsAfter), catching up after stopping \(catchingAfter)"
            + " (\(count / TailCatchUp.step) steps would reach the end)"
        // また追いかける (「末尾へ」と同じ道)
        if let end = running.transcript?.segments.last?.id {
            setFollowing(true)
            scrollList(end, .bottom)
            await settle()
        }
        return [line]
    }
}
