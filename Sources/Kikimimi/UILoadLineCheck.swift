// 1 行だけの再生の確認: 行の終わりで止まるかと、そのあと続きから再生するか (--audio の時)。

import Foundation
import KikimimiCore

extension UILoadSelfTest {
    /// 5〜7 秒あたりの行を再生して、行の終わりで自分で止まるかと、そのあとの再生ボタンで続きから再生するかを確かめる。
    /// failed: 失敗なら true (音を出せない Mac では確かめずに false)。played: この Mac で音を出せた (練習の確認に進める)
    ///
    /// 音を出せるかは、行ではなく、ふつうの再生で先に確かめる (行がすぐ止まる不具合と、音を出せない Mac とは、
    /// 行の再生だけでは見分けられない)。行は 2 回再生する: 0 秒から押したときと、ふつうの再生が行より後ろ (30 秒あたり)
    /// にいるときに押したとき (止める位置より後ろにいると、押した行がすぐ止まる不具合があった)
    @MainActor
    static func checkLinePlayback(player: PlayerController, segments: [TranscriptSegment], audio: URL,
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
}
