#if os(macOS)
import AVFoundation
import Foundation
import Observation

/// 結果の行をクリックして該当箇所から再生するための小さなプレイヤー。
@MainActor
@Observable
final class PlayerController {
    private(set) var url: URL?
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

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
            Task { @MainActor in self?.isPlaying = false }
        }
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self?.duration = d.seconds
            }
        }
    }

    func unload() {
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

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: TimeInterval, andPlay: Bool = false) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        if andPlay, !isPlaying {
            player.play()
            isPlaying = true
        }
    }
}
#endif
