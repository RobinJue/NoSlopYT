import Foundation
import MediaPlayer
import NoSlopKit
import UIKit

/// The lock screen / Control Center / headphone-button side of playback: "Now Playing" info (title, channel,
/// artwork, duration, position, rate) and the remote commands (play, pause, toggle, skip ±10 s, scrub, next).
///
/// It knows nothing about `PlayerController`; the controller sets the `on…` closures and calls `update`.
@MainActor
final class NowPlayingCenter {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    /// Negative to jump back.
    var onSkip: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onNext: (() -> Void)?

    /// How far the lock screen's skip buttons jump.
    nonisolated static let skipInterval: Double = 10

    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []

    private var artwork: MPMediaItemArtwork?
    private var artworkVideoID: String?
    private var artworkTask: Task<Void, Never>?

    /// The last values handed to `update`, so a late artwork can republish them.
    private var lastUpdate: Update?

    private struct Update {
        var video: VideoSummary
        var duration: Double
        var elapsed: Double
        var rate: Double
        var isLive: Bool
        var canPlayNext: Bool
    }

    // MARK: Publishing

    /// Publishes the current state. Cheap; call it on every state change, seek and rate change (not on every tick:
    /// the system extrapolates the position from `rate`).
    func update(video: VideoSummary, duration: Double, elapsed: Double, rate: Double, isLive: Bool, canPlayNext: Bool) {
        installCommandsIfNeeded()
        lastUpdate = Update(video: video, duration: duration, elapsed: elapsed, rate: rate, isLive: isLive, canPlayNext: canPlayNext)
        loadArtworkIfNeeded(for: video)
        publish()

        commands.nextTrackCommand.isEnabled = canPlayNext
        commands.changePlaybackPositionCommand.isEnabled = !isLive && duration > 0
        commands.skipForwardCommand.isEnabled = !isLive
        commands.skipBackwardCommand.isEnabled = !isLive
    }

    #if DEBUG
    /// What the lock screen is told right now, for the simulator checks: the title, the live flag and whether the
    /// scrub command is on.
    var debugPublished: String {
        let info = infoCenter.nowPlayingInfo
        let title = (info?[MPMediaItemPropertyTitle] as? String) ?? "-"
        let live = (info?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool) ?? false
        return "{title: \(title), live: \(live), scrub: \(commands.changePlaybackPositionCommand.isEnabled)}"
    }
    #endif

    /// Removes the lock-screen entry (the player was closed).
    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkVideoID = nil
        lastUpdate = nil
        infoCenter.nowPlayingInfo = nil
    }

    private func publish() {
        guard let update = lastUpdate else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: update.video.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, update.elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: update.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: update.isLive,
        ]
        if let channel = update.video.channel?.name, !channel.isEmpty {
            info[MPMediaItemPropertyArtist] = channel
        }
        if update.duration > 0, update.duration.isFinite, !update.isLive {
            info[MPMediaItemPropertyPlaybackDuration] = update.duration
        }
        if let artwork, artworkVideoID == update.video.id {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoCenter.nowPlayingInfo = info
    }

    // MARK: Artwork

    private func loadArtworkIfNeeded(for video: VideoSummary) {
        guard artworkVideoID != video.id else { return }
        artworkTask?.cancel()
        artwork = nil
        artworkVideoID = video.id
        guard let url = Self.artworkURL(for: video) else { return }

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            // MediaPlayer calls the handler on a background queue: it must not be main-actor isolated.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            self?.artworkLoaded(artwork, for: video.id)
        }
    }

    private func artworkLoaded(_ artwork: MPMediaItemArtwork, for videoID: String) {
        guard artworkVideoID == videoID else { return }
        self.artwork = artwork
        publish()
    }

    /// A true 16:9 rendition when there is one (the 4:3 `hqdefault` and `sddefault` have black bars baked in).
    private static func artworkURL(for video: VideoSummary) -> URL? {
        let all = video.displayThumbnails
        let wide = all.filter { thumbnail in
            guard let width = thumbnail.width, let height = thumbnail.height, height > 0 else { return false }
            return abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.02
        }
        return (wide.isEmpty ? all : wide).best(minWidth: 480)?.url
    }

    // MARK: Remote commands

    private func installCommandsIfNeeded() {
        guard registrations.isEmpty else { return }

        register(commands.playCommand) { $0.onPlay?() }
        register(commands.pauseCommand) { $0.onPause?() }
        register(commands.togglePlayPauseCommand) { $0.onTogglePlayPause?() }
        register(commands.nextTrackCommand) { $0.onNext?() }
        commands.previousTrackCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false

        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commands.skipForwardCommand.isEnabled = true
        let forward = commands.skipForwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in self?.onSkip?(interval) }
            return .success
        }
        registrations.append((commands.skipForwardCommand, forward))

        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commands.skipBackwardCommand.isEnabled = true
        let backward = commands.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in self?.onSkip?(-interval) }
            return .success
        }
        registrations.append((commands.skipBackwardCommand, backward))

        commands.changePlaybackPositionCommand.isEnabled = true
        let position = commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.onSeek?(seconds) }
            return .success
        }
        registrations.append((commands.changePlaybackPositionCommand, position))
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (NowPlayingCenter) -> Void) {
        command.isEnabled = true
        // MediaPlayer may call this on any thread, so the closure is explicitly not main-actor isolated and hops over.
        let token = command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                if let self { action(self) }
            }
            return .success
        }
        registrations.append((command, token))
    }
}
