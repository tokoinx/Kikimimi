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

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// 行の終わりで止めるための見張り
    @ObservationIgnored private var lineEndObserver: Any?
    /// 行を再生するたびに増やす (前の行の見張りから遅れて届いた知らせを無視する)
    @ObservationIgnored private var lineGeneration = 0

    /// Whisper の時刻はおおよそなので、行の前後を少し広げて再生する
    static let lineLeadIn: TimeInterval = 0.15
    static let lineTail: TimeInterval = 0.25

    func load(url: URL) {
        guard url != self.url else { return }
        unload()
        self.url = url
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.currentTime = time.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.endLine()
            }
        }
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self?.duration = d.seconds
            }
        }
    }

    func unload() {
        endLine()
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        url = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    /// 再生 / 一時停止 (下の再生ボタン)。1 行だけの再生は終わりにする
    func togglePlay() {
        guard let player else { return }
        endLine()
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 { move(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    /// 指定の位置へ移る (つまみ・「ここから続けて再生」)。1 行だけの再生は終わりにする
    func seek(to seconds: TimeInterval, andPlay: Bool = false) {
        guard player != nil else { return }
        endLine()
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

    /// 1 行だけを、始めから終わりまで再生して止まる
    func playLine(id: UUID, start: TimeInterval, end: TimeInterval) {
        guard let player else { return }
        endLine()
        let from = max(0, start - Self.lineLeadIn)
        var to = max(end, start) + Self.lineTail
        if duration > 0 { to = min(to, duration) }
        move(to: from)
        lineGeneration += 1
        let generation = lineGeneration
        playingLineID = id
        // 終わりの位置を通ったら止める (ファイルの終わりまで届いたときは endObserver が止める)
        lineEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: to, preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            Task { @MainActor in self?.lineDidReachEnd(generation) }
        }
        player.play()
        isPlaying = true
    }

    /// 1 行だけの再生を、その場で止める
    func stopLine() {
        guard playingLineID != nil else { return }
        player?.pause()
        isPlaying = false
        endLine()
    }

    private func lineDidReachEnd(_ generation: Int) {
        guard generation == lineGeneration, playingLineID != nil else { return }
        player?.pause()
        isPlaying = false
        endLine()
    }

    /// 1 行だけの再生の印と見張りを外す (再生そのものは止めない)
    private func endLine() {
        if let player, let lineEndObserver { player.removeTimeObserver(lineEndObserver) }
        lineEndObserver = nil
        playingLineID = nil
    }

    private func move(to seconds: TimeInterval) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }
}
#endif
