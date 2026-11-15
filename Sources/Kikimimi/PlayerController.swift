#if os(macOS)
import AVFoundation
import Foundation
import Observation

/// 結果の行をクリックして、その行だけを再生するための小さなプレイヤー
@MainActor
@Observable
final class PlayerController {
    private(set) var url: URL?
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    /// 1 行だけを再生しているときの、その行。終わりで自動で止まる。ふつうの再生では nil
    private(set) var playingLineID: UUID?
    /// 再生の速さ (1.0 がふつう)。ふつうの再生にも 1 行だけの再生にも使う。再生中に変えると、その場で変わる。
    /// 声の高さは変えない (audioTimePitchAlgorithm を .timeDomain にする)
    var rate: Double = 1.0 {
        didSet {
            guard rate != oldValue else { return }
            applyRate()
        }
    }

    /// 頼まれた 1 行が、行の終わりまで来て自分で止まった (止めた・別の行に替えた・古い知らせでは呼ばない)。
    /// 呼ぶのは、こちらの状態 (止まった印・位置) を整えたあと
    @ObservationIgnored var onLineFinished: (@MainActor (UUID) -> Void)?
    /// 再生ボタン・つまみ・「ここから続けて再生」・音声を閉じる、で、使う人が再生を自分で動かした (練習の続きを止めるため)。
    /// 1 行だけの再生 (playLine / stopLine) では呼ばない
    @ObservationIgnored var onUserControl: (@MainActor () -> Void)?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// 1 行だけを再生しているときの、止める位置 (秒)。ふつうの再生では nil
    @ObservationIgnored private var lineEnd: TimeInterval?
    /// 1 行だけの再生の、いまの行の始め (秒)
    @ObservationIgnored private var lineStart: TimeInterval = 0
    /// 1 行だけの再生の番号。行を始めるときと、1 行だけの再生を終えるときに増やす。
    /// 行の始めへ移り終わった知らせが届いたとき、番号が変わっていれば (前の行のもの) 何もしない
    @ObservationIgnored private var lineGeneration = 0
    /// いまの行の始めへ移り終わり、止める位置 (forwardPlaybackEndTime) を渡して再生を始めたところ。
    /// それより前に届いた終わりの知らせは、いまの行のものではない
    @ObservationIgnored private var lineArmed = false
    /// いまの行で、外れた終わりの知らせのあとに再生をやり直した回数 (やり直しが繰り返されないように数える)
    @ObservationIgnored private var lineRestarts = 0
    /// 1 行だけの再生が、行の終わりで止まったところ (次に再生するときは、その位置へ移り直してから始める)
    @ObservationIgnored private var stoppedAtLineEnd = false

    /// Whisper の時刻はおおよそなので、行の前後を少し広げて再生する
    static let lineLeadIn: TimeInterval = 0.15
    static let lineTail: TimeInterval = 0.25

    func load(url: URL) {
        guard url != self.url else { return }
        unload()
        self.url = url
        let item = AVPlayerItem(url: url)
        // 速さを変えても、声の高さはそのまま (話し声に向いたやり方)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        self.item = item
        self.player = player
        // play() は、この速さで始まる (macOS 13 から)
        player.defaultRate = Float(rate)
        // どちらの見張りもメインのキューで呼ばれるので、その場で反映する
        // (Task を挟むと、メインスレッドが混んでいるときに知らせが遅れて溜まる)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.timeDidChange(seconds) }
        }
        // ファイルの終わり、または 1 行だけの再生で止める位置 (forwardPlaybackEndTime) に着いた
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidPlayToEnd() }
        }
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self?.duration = d.seconds
            }
        }
    }

    func unload() {
        onUserControl?()
        endLine()
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
        item = nil
        stoppedAtLineEnd = false
        timeObserver = nil
        endObserver = nil
        url = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    /// 再生 / 一時停止 (下の再生ボタン・スペースキー)。1 行だけの再生は終わりにする
    /// (行を再生し終えたあとなら、その行の終わりから続ける)
    func togglePlay() {
        guard let player else { return }
        onUserControl?()
        endLine()
        if isPlaying {
            player.pause()
            isPlaying = false
            syncTime()
        } else {
            // ファイルの終わりまで再生したあとは、始めから。行の終わりで止まったあとは、その位置から続ける
            let now = player.currentTime().seconds
            if duration > 0, now.isFinite, now >= duration - 0.05 {
                move(to: 0)
            } else if stoppedAtLineEnd, now.isFinite {
                move(to: now)
            }
            stoppedAtLineEnd = false
            player.play()
            isPlaying = true
        }
    }

    /// 指定の位置へ移る (つまみ・「ここから続けて再生」)。1 行だけの再生は終わりにする
    func seek(to seconds: TimeInterval, andPlay: Bool = false) {
        guard player != nil else { return }
        onUserControl?()
        endLine()
        stoppedAtLineEnd = false
        move(to: seconds)
        if andPlay, !isPlaying {
            player?.play()
            isPlaying = true
        }
    }

    /// 行をクリックしたとき: その行を再生中なら止め、そうでなければその行だけを再生する
    func toggleLine(id: UUID, start: TimeInterval, end: TimeInterval) {
        if playingLineID == id {
            stopLine()
        } else {
            playLine(id: id, start: start, end: end)
        }
    }

    /// 1 行だけを、始めから終わりまで再生して止まる。
    /// 止めるのは AVPlayer そのもの (forwardPlaybackEndTime) なので、メインスレッドが混んでいても行の終わりで止まる。
    ///
    /// 順番: 止める → 行の始めへ移る → 移り終わってから止める位置を渡す → 再生する。
    /// 止める位置を先に渡すと、いまの位置がそれより後ろ (ふつうの再生で 30:00 にいて、05:00 の行を押した) のとき、
    /// AVFoundation がその場で終わりにしてしまい、押した行がすぐ止まる。
    /// - 行 A の再生中に行 B を押す: A の止める位置は endLine で外し、番号を変える。A の終わりの知らせが遅れて届いても、
    ///   B の止める位置を渡す前なら無視し、渡したあとでも位置が B の終わりから遠ければ無視する (止まっていれば再生し直す)。
    ///   A の移り終わりの知らせは、番号が違うので何もしない。
    /// - ふつうの再生中に、いまより前の行を押す: 止めてから移るので、止める位置を渡すときは行の始めにいる。
    /// - 行の終わりがファイルの終わり: 止める位置はファイルの長さになり、ファイルの終わりの知らせで止まる
    ///   (位置は行の終わりの近くなので、いまの行の終わりとして受け取る)。
    /// - 行がふつうに終わる: AVFoundation が止める位置で止まり、知らせが届く。位置が行の終わりの近くなので受け取り、止める。
    /// - 速さを変えていても同じ: 止める位置も、知らせの位置も、音声の中の時刻 (速さによらない) で比べる。
    ///   再生は play() で始め、play() は defaultRate (いまの速さ) で鳴らす。
    func playLine(id: UUID, start: TimeInterval, end: TimeInterval) {
        guard let player else { return }
        endLine()
        let from = max(0, start - Self.lineLeadIn)
        var to = max(end, start) + Self.lineTail
        if duration > 0 { to = min(to, duration) }
        // ファイルの終わりより後ろの行 (時刻がずれている) は再生しない
        guard to > from + 0.05 else { return }
        stoppedAtLineEnd = false
        // 1. 止める (止める位置は endLine で外してある)
        player.pause()
        lineStart = from
        lineEnd = to
        lineRestarts = 0
        playingLineID = id
        // 押したらすぐ再生中に見せる (音が出るのは、移り終わってから)
        isPlaying = true
        timeDidChange(from)
        // 2. 行の始めへ移る。3. 移り終わってから、止める位置を渡して再生する (lineSeekDidFinish)
        let generation = lineGeneration
        player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: .zero) { @Sendable [self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.lineSeekDidFinish(generation: generation) }
            }
        }
    }

    /// 行の始めへ移り終わった: 止める位置を渡して、再生を始める。
    /// 移るのが途中で打ち切られた (finished が false) ときも、番号が同じなら始める (止める位置で止まるのは変わらない)
    private func lineSeekDidFinish(generation: Int) {
        guard generation == lineGeneration, playingLineID != nil, let player, let item, let lineEnd else { return }
        item.forwardPlaybackEndTime = CMTime(seconds: lineEnd, preferredTimescale: 600)
        lineArmed = true
        player.play()
    }

    /// 1 行だけの再生を、その場で止める
    func stopLine() {
        guard playingLineID != nil else { return }
        player?.pause()
        isPlaying = false
        syncTime()
        endLine()
    }

    /// ファイルの終わり、または 1 行だけの再生で止める位置に着いた、という知らせ
    private func itemDidPlayToEnd() {
        guard let player else { return }
        let now = player.currentTime().seconds
        if playingLineID != nil, let lineEnd {
            // まだ行の始めへ移っている途中 (止める位置を渡す前): 前の行かふつうの再生の知らせ。移り終わると再生が始まる
            guard lineArmed else { return }
            // 位置がいまの行の終わりから遠い: 前の行の知らせが遅れて届いた、または移り終わる前に終わりにされた。
            // 再生の速さによらず無視し、止められていたら再生し直す (やり直しは 1 行につき 2 回まで。
            // 時刻のずれた行がファイルの終わりで止まり続けるときに、繰り返さないように)
            if now.isFinite, abs(now - lineEnd) > 0.5, lineRestarts < 2 {
                if player.rate == 0 {
                    lineRestarts += 1
                    // 行の中にいればそこから、行の外 (終わりより後ろ) にいれば行の始めから
                    move(to: now < lineEnd - 0.5 ? max(now, lineStart) : lineStart)
                    player.play()
                }
                return
            }
        } else if player.rate != 0, duration > 0, now.isFinite, now < duration - 0.5 {
            // ふつうの再生中に、前の行の知らせが遅れて届いた (まだ鳴っていて、ファイルの終わりから遠い) なら無視する
            return
        }
        // 先に音を止めてから、止まった印にする (印だけ先に変わると、次の再生ボタンが「止める」ではなく「再生」になり、止められない)
        player.pause()
        let finished = playingLineID
        stoppedAtLineEnd = finished != nil
        isPlaying = false
        if now.isFinite { timeDidChange(now) }
        endLine()
        // 頼まれた行が、行の終わりまで来た (こちらの状態を整えてから知らせる。知らせを受けて次の行を始めてもよい)
        if let finished { onLineFinished?(finished) }
    }

    /// 1 行だけの再生の印と止める位置を外す (再生そのものは止めない。そこから先も続けて再生できるようにする)。
    /// 番号を変えるので、移っている途中の行は、移り終わっても再生を始めない
    private func endLine() {
        lineGeneration += 1
        lineArmed = false
        lineEnd = nil
        if let item, item.forwardPlaybackEndTime.isValid { item.forwardPlaybackEndTime = .invalid }
        if playingLineID != nil { playingLineID = nil }
    }

    /// 速さを AVPlayer に渡す: これからの play() の速さ (defaultRate) と、鳴っていれば、いまの速さ
    private func applyRate() {
        guard let player else { return }
        let value = Float(rate)
        player.defaultRate = value
        if player.rate != 0 { player.rate = value }
    }

    /// 再生位置を変える (同じ値なら変えない: 変えると、位置を見ている画面が描き直される)
    private func timeDidChange(_ seconds: TimeInterval) {
        guard seconds.isFinite, abs(seconds - currentTime) > 0.001 else { return }
        currentTime = seconds
    }

    private func syncTime() {
        if let player { timeDidChange(player.currentTime().seconds) }
    }

    private func move(to seconds: TimeInterval) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: 画面の重さの確認 (--selftest-ui-load) だけで使う

    /// 再生位置の見張りが知らせるのと同じように、位置と再生中かを変える (音声は動かさない)
    func selfTestSetTime(_ seconds: TimeInterval, playing: Bool) {
        timeDidChange(seconds)
        if playingLineID == nil, isPlaying != playing { isPlaying = playing }
    }

    /// AVPlayer の実際の再生位置と速さ (音声を開いていなければ nil)
    var selfTestPlayback: (time: TimeInterval, rate: Float)? {
        guard let player else { return nil }
        return (player.currentTime().seconds, player.rate)
    }
}
#endif
