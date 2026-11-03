import AVFoundation
import Foundation
import NoSlopKit
import Observation

/// Owns the one `AVPlayer`, what is playing, and how the player is presented (hidden, full screen over the tabs,
/// or the mini player above the tab bar).
///
/// STUB (Task 1B, presentation only). Task 10 owns this file and implements playback; the API below is final.
/// Until then `open` records the video and expands the overlay, `expand`/`minimize`/`close` change `presentation`,
/// and the transport functions only move the published numbers. Nothing is loaded into `avPlayer`.
@MainActor
@Observable
final class PlayerController {
    enum Presentation: Equatable {
        case hidden, expanded, minimized
    }

    enum State: Equatable {
        case idle, loading, playing, paused, buffering, ended
        case failed(String)
    }

    struct SkipNotice: Equatable, Identifiable {
        var id: String
        var segment: SponsorSegment
    }

    private let streams: any StreamResolving
    private let sponsorBlock: any SponsorBlockProviding
    private let captions: any CaptionsProviding
    private let library: LibraryStore
    private let settingsStore: SettingsStore
    private let downloads: DownloadManager
    /// What the watch page offered as "Up next" (autoplay candidates). Task 10 uses it for autoplay.
    @ObservationIgnored private var upNext: [VideoSummary] = []

    init(
        streams: any StreamResolving,
        sponsorBlock: any SponsorBlockProviding,
        captions: any CaptionsProviding,
        library: LibraryStore,
        settingsStore: SettingsStore,
        downloads: DownloadManager
    ) {
        self.streams = streams
        self.sponsorBlock = sponsorBlock
        self.captions = captions
        self.library = library
        self.settingsStore = settingsStore
        self.downloads = downloads
        self.quality = settingsStore.settings.wifiQuality
        self.rate = Float(settingsStore.settings.defaultPlaybackRate)
    }

    /// The single player instance; the video surface and Picture in Picture both attach to it.
    let avPlayer = AVPlayer()

    // MARK: Published state

    private(set) var presentation: Presentation = .hidden
    private(set) var currentVideo: VideoSummary?
    private(set) var streamInfo: StreamInfo?
    private(set) var state: State = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var bufferedTime: Double = 0
    private(set) var segments: [SponsorSegment] = []
    private(set) var chapters: [Chapter] = []
    private(set) var skipNotice: SkipNotice?
    private(set) var captionText: String?
    private(set) var isPlayingOffline = false
    private(set) var isPictureInPictureActive = false
    /// Videos that play after the current one, in order.
    private(set) var queue: [VideoSummary] = []

    var isFullscreen = false
    var rate: Float
    var quality: QualityPreference
    var selectedCaption: CaptionTrack?

    // MARK: Loading

    /// Starts `video` (resuming at `startAt` or the saved position) and expands the player. `queue` plays afterwards.
    func open(_ video: VideoSummary, startAt: Double?, queue: [VideoSummary]) {
        currentVideo = video
        self.queue = queue
        streamInfo = nil
        state = .idle
        currentTime = max(0, startAt ?? 0)
        duration = Double(video.durationSeconds ?? 0)
        bufferedTime = 0
        segments = []
        chapters = []
        skipNotice = nil
        captionText = nil
        isPlayingOffline = false
        presentation = .expanded
    }

    /// The chapters of the current video (from the watch page); the seek bar draws them.
    func setChapters(_ chapters: [Chapter]) {
        self.chapters = chapters
    }

    /// The related videos the watch page found, for autoplay once the queue is empty.
    func setUpNext(_ videos: [VideoSummary]) {
        upNext = videos
    }

    // MARK: Transport

    func play() {
        guard currentVideo != nil else { return }
        state = .playing
    }

    func pause() {
        guard currentVideo != nil else { return }
        state = .paused
    }

    func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        currentTime = max(0, seconds)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Jumps back to the start of the SponsorBlock segment that was just skipped.
    func undoSkip() {
        if let notice = skipNotice {
            seek(to: notice.segment.start)
        }
        skipNotice = nil
    }

    /// Starts the next queued video; returns false when the queue is empty.
    @discardableResult
    func playNext() -> Bool {
        guard let next = queue.first else { return false }
        open(next, startAt: nil, queue: Array(queue.dropFirst()))
        return true
    }

    // MARK: Presentation

    /// Brings the player back over the tabs. Does nothing while no video is loaded.
    func expand() {
        guard currentVideo != nil else { return }
        presentation = .expanded
    }

    /// Shrinks the expanded player to the mini player. Does nothing unless the player is expanded.
    func minimize() {
        guard presentation == .expanded else { return }
        isFullscreen = false
        presentation = .minimized
    }

    /// Stops playback and hides the player.
    func close() {
        currentVideo = nil
        streamInfo = nil
        state = .idle
        queue = []
        upNext = []
        segments = []
        chapters = []
        skipNotice = nil
        captionText = nil
        currentTime = 0
        duration = 0
        bufferedTime = 0
        isPlayingOffline = false
        isFullscreen = false
        presentation = .hidden
    }

    func toggleFullscreen() {
        isFullscreen.toggle()
    }

    func startPictureInPicture() {}
}
