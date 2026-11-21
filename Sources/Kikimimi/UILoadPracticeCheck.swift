// 練習の確認 (PRACTICE CHECK) と、練習の絵 (09・10)。

import AppKit
import Foundation
import KikimimiCore

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

extension LoadRun {
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
}
