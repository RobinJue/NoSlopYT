import AVFoundation
import Foundation
import Network
import NoSlopKit
import Observation
import OSLog
import UIKit

/// Owns the one `AVPlayer`, what is playing, and how the player is presented (hidden, full screen over the tabs,
/// or the mini player above the tab bar).
///
/// What it does, in the order a video goes through it:
/// - `open` saves the progress of the previous video, resolves the stream (a finished download wins over streaming),
///   builds the `AVPlayerItem` with the quality cap for the current connection, resumes where the viewer left off and
///   starts playing.
/// - A 0.5 s time observer drives `currentTime`, the buffered range, the caption line, SponsorBlock auto-skip and the
///   progress saved to the library (every 10 s while playing, and on pause, close, background, the end and a switch to
///   another video).
/// - A failure is mapped to a `PlaybackFailure`; `PlaybackRecovery` decides between re-resolving fresh URLs,
///   waiting for the connection, and the error screen (only after a second failure).
/// - Picking a quality rebuilds the player item from the stream info in hand (see `rebuildItemForQualityChange`), so the
///   new quality shows within seconds instead of after the minutes AVPlayer has buffered.
/// - In the background it keeps playing (video detached from its layers) or pauses, depending on the setting, unless
///   Picture in Picture has taken over. Lock screen controls come from `NowPlayingCenter`.
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

    // MARK: Collaborators

    private let streams: any StreamResolving
    private let sponsorBlock: any SponsorBlockProviding
    private let deArrow: any DeArrowProviding
    private let captions: any CaptionsProviding
    private let library: LibraryStore
    private let settingsStore: SettingsStore
    private let downloads: DownloadManager

    /// Picture in Picture and the registry of video layers; `VideoSurfaceView` registers with it.
    let pictureInPicture: PictureInPictureController
    @ObservationIgnored private let audioSession = AudioSessionController()
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()
    @ObservationIgnored private let network = PlaybackNetworkMonitor()

    /// The single player instance; the video surface and Picture in Picture both attach to it.
    let avPlayer = AVPlayer()

    // MARK: Published state

    private(set) var presentation: Presentation = .hidden
    private(set) var currentVideo: VideoSummary?
    private(set) var streamInfo: StreamInfo?
    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                Self.log.debug("state \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)")
            }
        }
    }
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var bufferedTime: Double = 0
    /// The SponsorBlock segments to draw in the seek bar (what `SegmentSkipPlanner` says is visible).
    private(set) var segments: [SponsorSegment] = []
    private(set) var chapters: [Chapter] = []
    private(set) var skipNotice: SkipNotice?
    private(set) var captionText: String?
    private(set) var isPlayingOffline = false
    private(set) var isPictureInPictureActive = false
    /// Videos that play after the current one, in order.
    private(set) var queue: [VideoSummary] = []

    /// Picture in Picture could start right now.
    private(set) var isPictureInPicturePossible = false
    /// Playing a downloaded audio-only file: there is no picture, the thumbnail stays up.
    private(set) var isAudioOnlyPlayback = false
    /// A live stream: no duration, no scrubbing. The copy of the video the player was opened with sets it first; the
    /// resolved stream has the last word (see `accept`).
    private(set) var isLive = false
    /// The first frame has played at least once for this video (until then the thumbnail is shown as a poster).
    private(set) var hasStartedPlayback = false
    /// The community title DeArrow has for the current video; nil while it is not known, and when there is none.
    private(set) var betterTitle: String?
    /// Recovery is waiting for the device to come back online.
    private(set) var isWaitingForConnection = false

    var isFullscreen = false

    /// Playback speed. Setting it applies it at once.
    var rate: Float {
        didSet { rateDidChange() }
    }

    /// The resolution cap. Starts at the Wi-Fi or cellular preference of each video; picking one overrides it for
    /// this video and rebuilds the player item, so it takes effect within seconds.
    var quality: QualityPreference {
        didSet { qualityDidChange(from: oldValue) }
    }

    /// The caption track shown, nil for off. Setting it loads the cues.
    var selectedCaption: CaptionTrack? {
        didSet { selectedCaptionDidChange() }
    }

    // MARK: Bookkeeping (not observed)

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var segmentsTask: Task<Void, Never>?
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var skipNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemNotifications: [any NSObjectProtocol] = []
    @ObservationIgnored private var lifecycleNotifications: [any NSObjectProtocol] = []

    /// The viewer's intent: open and play set it, pause clears it, and so do the pause and play buttons that reach the
    /// player without going through here (see `playerRateDidChange`). It decides whether the item starts once it is
    /// ready (and the play/pause button while loading), so it is observed.
    private var shouldPlayWhenReady = true
    @ObservationIgnored private var isItemReady = false
    @ObservationIgnored private var awaitingInitialStart = false
    @ObservationIgnored private var pendingStart: Double = 0
    /// `pendingStart` is where the viewer already was (a quality change), not a saved position or a link's start time
    /// that may be so close to the end that watching again from the start is the better guess.
    @ObservationIgnored private var pendingStartIsExact = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var seekToken = 0
    @ObservationIgnored private var resumeAfterSeek = false

    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private var recoveryBaseline: Double = 0
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var forceStreaming = false

    @ObservationIgnored private var upNext: [VideoSummary] = []
    /// The video whose chapters and up-next list were handed over (`setUpNext`), the page's or the owner's.
    @ObservationIgnored private var detailsHandedOverFor: String?
    /// What follows `queue`: the rest of the list it came from (a playlist), which arrives in pages. The next page is
    /// asked for when the queue runs low and when it runs out. Nil for a queue that is all there is.
    @ObservationIgnored private var queueSource: QueueSource?
    /// The request for the next page of `queueSource` that is on its way.
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    /// Set while the player waits for that page because nothing was queued: what to do when it arrives.
    @ObservationIgnored private var pendingAdvance: QueueAdvance.Request?
    @ObservationIgnored private var progressThrottle = ProgressSaveThrottle()
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var didDetachSurfaces = false
    @ObservationIgnored private var qualityIsManual = false
    @ObservationIgnored private var isApplyingDefaultQuality = false

    @ObservationIgnored private var rawSegments: [SponsorSegment] = []
    @ObservationIgnored private var planner: SegmentSkipPlanner?
    @ObservationIgnored private var plannerEnabled = true
    @ObservationIgnored private var plannerBehaviors: [SponsorCategory: SegmentBehavior] = [:]
    /// The length of the video the planner was built for; nil when it was not known then.
    @ObservationIgnored private var plannerLength: Double?
    /// The video whose segments were asked for and not given up on: set when the lookup starts, cleared when every
    /// attempt failed, so that the next chance (Retry, a reload, the connection coming back) asks again.
    @ObservationIgnored private var segmentsRequestedFor: String?
    @ObservationIgnored private var betterTitleRequestedFor: String?
    @ObservationIgnored private var declinedSkips: Set<String> = []
    @ObservationIgnored private var lastSkip: (id: String, at: Date)?

    @ObservationIgnored private var cueTimeline = CueTimeline(cues: [])
    @ObservationIgnored private var lastLoggedSize = CGSize.zero

    private static let log = Logger(subsystem: "com.robinjungerich.noslopyt", category: "player")

    // MARK: Init

    init(
        streams: any StreamResolving,
        sponsorBlock: any SponsorBlockProviding,
        deArrow: any DeArrowProviding,
        captions: any CaptionsProviding,
        library: LibraryStore,
        settingsStore: SettingsStore,
        downloads: DownloadManager
    ) {
        self.streams = streams
        self.sponsorBlock = sponsorBlock
        self.deArrow = deArrow
        self.captions = captions
        self.library = library
        self.settingsStore = settingsStore
        self.downloads = downloads
        self.quality = settingsStore.settings.wifiQuality
        self.rate = Self.clampedRate(settingsStore.settings.defaultPlaybackRate)
        self.pictureInPicture = PictureInPictureController(player: avPlayer)

        avPlayer.allowsExternalPlayback = true
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        avPlayer.actionAtItemEnd = .pause
        avPlayer.defaultRate = rate

        wireCollaborators()
        installPlayerObservers()
        #if DEBUG
        PlayerDebugScript.runIfRequested(on: self)
        #endif
    }

    // MARK: Derived state for the views

    /// The viewer wants (or has) playback running: the pause button shows instead of the play button.
    var isPlaybackActive: Bool {
        switch state {
        case .playing, .buffering: return true
        case .loading: return shouldPlayWhenReady
        case .idle, .paused, .ended, .failed: return false
        }
    }

    /// The caption tracks the video offers.
    var captionTracks: [CaptionTrack] {
        streamInfo?.captions ?? []
    }

    /// Whether `playNext` has a video to start: a queued one, or the first of the next page of the list the queue came
    /// from.
    var canPlayNext: Bool {
        !queue.isEmpty || queueSource?.hasMore == true
    }

    /// The thumbnail shows where the picture is not (yet): nothing has played yet, or the file has no picture. The video
    /// surface is transparent (`VideoSurfaceView`), so the thumbnail drawn below it is what shows until the first frame.
    var showsPoster: Bool {
        !hasStartedPlayback || isAudioOnlyPlayback
    }

    /// The message of the failed state, if any.
    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// The title of the current video as the app shows it: DeArrow's community title when "De-clickbait titles" is on
    /// and one is known, else the original. The lock screen and Control Center get this one, and so does the spoken
    /// label of the mini player. Nil when no video is loaded.
    var displayTitle: String? {
        guard let video = currentVideo else { return nil }
        return DisplayTitle.resolve(original: video.title, better: betterTitle, deArrowEnabled: settings.deArrowTitles)
    }

    // MARK: Loading

    /// Starts `video` (resuming at `startAt` or the saved position) and expands the player. `queue` plays afterwards,
    /// and `more` supplies what follows the queue when it comes from a list that is not loaded to its end (a long
    /// playlist): the next page is taken from it when the queue runs low. A video opened without a `more` plays on
    /// with `queue` alone.
    /// Opening the video that is already loaded only expands the player (and seeks when `startAt` is given); after a
    /// failure it starts over, keeping what the watch page published for it (see `start`).
    func open(_ video: VideoSummary, startAt: Double?, queue: [VideoSummary], more: QueueSource? = nil) {
        if let current = currentVideo, current.id == video.id, canReuseCurrentPlayback {
            adoptQueue(queue, more: more)
            presentation = .expanded
            if let startAt {
                seek(to: startAt)
            } else if state == .ended {
                seek(to: 0)
            }
            updateNowPlaying()
            return
        }
        start(video, startAt: startAt, queue: queue, more: more, expand: true)
    }

    private var canReuseCurrentPlayback: Bool {
        switch state {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// The chapters of the current video (from the watch details); the seek bar draws them.
    func setChapters(_ chapters: [Chapter]) {
        self.chapters = chapters
    }

    /// The related videos of the current video, for autoplay once the queue is empty. The watch page hands them over
    /// while it is on screen, and `detailsNeeded` has them loaded while it is not. They replace whatever list autoplay
    /// carried over, and a restart of the same video keeps them (see `start`).
    func setUpNext(_ videos: [VideoSummary]) {
        upNext = videos
        detailsHandedOverFor = currentVideo?.id
    }

    /// Completes the current video with what its watch page says (`VideoSummary.filledIn(from:)`). A video opened from a
    /// link starts as a bare id: the stream brings its title and the channel's name (`accept`), the page brings the
    /// channel's picture and handle, the views and the age, which the history and the lists then show. Whatever is there
    /// already stays; a page of another video does nothing.
    func complete(with details: VideoSummary) {
        guard let video = currentVideo, video.id == details.id else { return }
        let completed = video.filledIn(from: details)
        guard completed != video else { return }
        currentVideo = completed
        updateNowPlaying()
    }

    /// Asks for the chapters and the up-next list of a video that nobody is going to hand over, because no watch page is
    /// on screen to do it (see `requestDetailsIfNoPageShows`). Set by `AppEnvironment`, which loads the details and
    /// answers with `setChapters` and `setUpNext`.
    @ObservationIgnored var detailsNeeded: ((VideoSummary) -> Void)?

    /// The watch page loads and hands over the details of the video when the player is expanded and the app is on
    /// screen. In every other case (the player is minimized, so there is no page, or the app is in the background,
    /// where a page for a video that autoplay just started may not be built) the owner of the player is asked to load
    /// them, unless they were handed over already. Without them the new video has no chapters, and autoplay has only
    /// what was left of the list of the video before.
    private func requestDetailsIfNoPageShows(for video: VideoSummary) {
        let pageShows = presentation == .expanded && UIApplication.shared.applicationState == .active
        guard !pageShows, detailsHandedOverFor != video.id else { return }
        Self.log.info("no watch page shows: loading the details of \(video.id, privacy: .public) for the player")
        detailsNeeded?(video)
    }

    /// Starts `video`. A video opened from outside starts with an empty up-next list (the watch page fills it, or the
    /// owner of the player when no page shows: `detailsNeeded`); when autoplay moves on by itself, `upNext` is what
    /// remains of the list, so it can keep going until the new video's own list has arrived, or when that cannot be
    /// loaded (offline).
    ///
    /// `queue` and `more` are what follows the video (see `adoptQueue`): the queue moving on to its next video passes
    /// the source it has, an open from outside brings its own, and autoplay leaves the queue behind.
    ///
    /// Starting the video that is already current (a link to it opened from the error screen, a queue that repeats it)
    /// keeps the chapters and the up-next list the watch page published for it. They belong to the video, not to the
    /// item, and the page, still on screen, publishes them only once. `close` forgets them, so a video opened after
    /// that is published afresh.
    private func start(
        _ video: VideoSummary,
        startAt: Double?,
        queue: [VideoSummary],
        more: QueueSource?,
        upNext: [VideoSummary] = [],
        expand: Bool
    ) {
        saveProgress(force: true)
        tearDownItem()
        cancelWork()

        generation += 1
        let token = generation

        let isSameVideo = currentVideo?.id == video.id
        currentVideo = video
        adoptQueue(queue, more: more)
        if !(isSameVideo && upNext.isEmpty) {
            self.upNext = upNext
        }
        streamInfo = nil
        currentTime = max(0, startAt ?? 0)
        duration = Double(video.durationSeconds ?? 0)
        bufferedTime = 0
        segments = []
        if !isSameVideo {
            chapters = []
            detailsHandedOverFor = nil
        }
        skipNotice = nil
        captionText = nil
        isPlayingOffline = false
        isAudioOnlyPlayback = false
        isLive = video.isLive
        hasStartedPlayback = false
        isWaitingForConnection = false
        isRecovering = false
        forceStreaming = false
        recoveryAttempts = 0
        declinedSkips = []
        lastSkip = nil
        rawSegments = []
        planner = nil
        plannerLength = nil
        segmentsRequestedFor = nil
        cueTimeline = CueTimeline(cues: [])
        selectedCaption = nil
        shouldPlayWhenReady = true
        resumeAfterSeek = false
        pendingStart = 0
        pendingStartIsExact = false
        qualityIsManual = false
        applyDefaultQuality()
        rate = Self.clampedRate(settings.defaultPlaybackRate)
        betterTitle = nil
        betterTitleRequestedFor = nil
        ensureBetterTitle(for: video.id)

        if expand {
            presentation = .expanded
        }
        state = .loading
        audioSession.activate()
        updateNowPlaying()
        Self.log.info("open \(video.id, privacy: .public)")
        if !isSameVideo {
            requestDetailsIfNoPageShows(for: video)
        }

        loadTask = Task { [weak self] in
            await self?.load(video, startAt: startAt, token: token)
        }
    }

    private func load(_ video: VideoSummary, startAt: Double?, token: Int) async {
        let start = startAt ?? resumePosition(for: video.id)
        pendingStart = start
        currentTime = start
        ensureSegments(for: video.id)

        if let local = localSource(for: video.id) {
            isPlayingOffline = true
            isAudioOnlyPlayback = local.isAudioOnly
            // A download is never live, whatever the copy of the video it was opened from says, and offline there is no
            // stream info to correct it.
            isLive = false
            if let current = currentVideo, current.isLive || current.isUpcoming {
                currentVideo = current.settingLiveState(to: false)
            }
            Self.log.info("playing the download of \(video.id, privacy: .public)")
            attach(AVPlayerItem(url: local.url))
            loadStreamInfoForOfflinePlayback(of: video.id, token: token)
            return
        }

        do {
            let info = try await streams.streamInfo(videoID: video.id)
            guard token == generation else { return }
            accept(info)
            guard let url = playbackURL(for: info) else {
                fail(message: "This video can't be played in this app. Try opening it on YouTube.")
                return
            }
            attach(AVPlayerItem(url: url))
            selectDefaultCaption(from: info)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            fail(with: error)
        }
    }

    /// While a download plays there is no stream info, but captions and chapters want its caption tracks. Best effort:
    /// offline this simply fails.
    private func loadStreamInfoForOfflinePlayback(of videoID: String, token: Int) {
        Task { [weak self] in
            guard let self else { return }
            guard let info = try? await self.streams.streamInfo(videoID: videoID), token == self.generation else { return }
            self.accept(info)
            self.selectDefaultCaption(from: info)
        }
    }

    /// The finished download of the video whose file is still there: the sharpest video download first, an audio-only
    /// one when that is all there is.
    private func localSource(for videoID: String) -> (url: URL, isAudioOnly: Bool)? {
        guard !forceStreaming else { return nil }
        var candidates = downloads.items.filter { $0.video.id == videoID && $0.state == .completed }
        if candidates.isEmpty, let single = downloads.completedItem(videoID: videoID) {
            candidates = [single]
        }
        candidates.sort { Self.sharpness(of: $0.quality) > Self.sharpness(of: $1.quality) }
        for item in candidates {
            if let url = downloads.fileURL(for: item), FileManager.default.fileExists(atPath: url.path) {
                return (url, item.quality == .audioOnly)
            }
        }
        return nil
    }

    private static func sharpness(of quality: DownloadQuality) -> Int {
        switch quality {
        case .video(let maxHeight): return maxHeight
        case .audioOnly: return -1
        }
    }

    /// The HLS manifest, else the best progressive MP4 AVFoundation can play within the quality cap (the lowest one
    /// when every rendition is above it).
    private func playbackURL(for info: StreamInfo) -> URL? {
        if let hls = info.hlsURL {
            return hls
        }
        let progressive = info.formats
            .filter { $0.isProgressive && $0.isAVFoundationCompatible && !$0.isAudioOnly }
            .sorted { ($0.height ?? 0) < ($1.height ?? 0) }
        if let cap = quality.maxHeight {
            return (progressive.last { ($0.height ?? 0) <= cap } ?? progressive.first)?.url
        }
        return progressive.last?.url
    }

    /// Takes over the facts of the resolved stream: expiry, length, live, and the title and channel when the video
    /// was opened from a bare link.
    ///
    /// The stream is the truth about live and upcoming; the copy of the video the player was opened with, made earlier
    /// by a list, is not. A card saved while a broadcast was live says so long after it became an ordinary video, and
    /// would play without a scrubber, without a place in the history and with the lock screen announcing a live stream.
    /// The copy that goes to the history and to the lock screen is corrected as well.
    private func accept(_ info: StreamInfo) {
        streamInfo = info
        isLive = info.isLive
        if info.isLive {
            pendingStart = 0
        }
        if duration <= 0, info.lengthSeconds > 0 {
            duration = Double(info.lengthSeconds)
        }
        rebuildPlannerIfLengthChanged()
        guard var video = currentVideo, video.id == info.videoID else { return }
        var changed = false
        if video.isLive != info.isLive || video.isUpcoming {
            video = video.settingLiveState(to: info.isLive)
            changed = true
        }
        if video.title.isEmpty, !info.title.isEmpty {
            video.title = info.title
            changed = true
        }
        if (video.channel?.name ?? "").isEmpty, !info.author.isEmpty {
            video.channel = ChannelRef(id: info.channelID, name: info.author)
            changed = true
        }
        if video.thumbnails.isEmpty, !info.thumbnails.isEmpty {
            video.thumbnails = info.thumbnails
            changed = true
        }
        if video.durationSeconds == nil, info.lengthSeconds > 0 {
            video.durationSeconds = info.lengthSeconds
            changed = true
        }
        if changed {
            currentVideo = video
            updateNowPlaying()
        }
    }

    private func resumePosition(for videoID: String) -> Double {
        guard let entry = library.progress(for: videoID), entry.progressSeconds > 10, !entry.isFinished else { return 0 }
        return entry.progressSeconds
    }

    // MARK: Item

    /// Makes `item` the current item and watches it. Playback starts once it reports ready.
    private func attach(_ item: AVPlayerItem) {
        isItemReady = false
        awaitingInitialStart = false
        isRecovering = false
        isSeeking = false
        applyQuality(to: item)
        observe(item)
        avPlayer.replaceCurrentItem(with: item)
        applyAutomaticPictureInPicture()
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.itemStatusChanged() }
            },
        ]
        let center = NotificationCenter.default
        itemNotifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.itemDidPlayToEnd() }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                MainActor.assumeIsolated { self?.itemFailedToPlayToEnd(error: error) }
            },
        ]
    }

    /// Lets go of the current item: its observers, its stall watch and, unless the caller attaches the next item right
    /// away (`replacingRightAway`), the item itself. In that case the player is only paused and never left without an
    /// item, so Picture in Picture and AirPlay do not see an empty player in between. The video area stays black until
    /// the new item has its first frame (seen in the simulator).
    private func tearDownItem(replacingRightAway: Bool = false) {
        itemObservations.removeAll()
        let center = NotificationCenter.default
        for token in itemNotifications {
            center.removeObserver(token)
        }
        itemNotifications.removeAll()
        stallTask?.cancel()
        stallTask = nil
        isItemReady = false
        awaitingInitialStart = false
        isSeeking = false
        resumeAfterSeek = false
        // A seek still in flight belongs to the item that is going away.
        seekToken += 1
        if avPlayer.currentItem != nil {
            avPlayer.pause()
            if !replacingRightAway {
                avPlayer.replaceCurrentItem(with: nil)
            }
        }
    }

    private func cancelWork() {
        loadTask?.cancel()
        recoveryTask?.cancel()
        segmentsTask?.cancel()
        titleTask?.cancel()
        captionTask?.cancel()
        skipNoticeTask?.cancel()
        loadTask = nil
        recoveryTask = nil
        segmentsTask = nil
        titleTask = nil
        captionTask = nil
        skipNoticeTask = nil
    }

    private func itemStatusChanged() {
        guard let item = avPlayer.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard !isItemReady else { return }
            isItemReady = true
            refreshDuration()
            rebuildPlannerIfLengthChanged()
            #if DEBUG
            if DebugLaunchHooks.silentPlayback {
                Task { [weak self] in
                    await self?.debugDropAudio(of: item)
                    guard let self, avPlayer.currentItem === item, isItemReady else { return }
                    beginPlayback()
                }
                return
            }
            #endif
            beginPlayback()
        case .failed:
            handleFailure(error: item.error, item: item)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// The item is ready: jump to the start position, then play if the viewer wants playback.
    private func beginPlayback() {
        var target = pendingStart
        let isExact = pendingStartIsExact
        pendingStart = 0
        pendingStartIsExact = false
        if duration > 0, target > duration - 2, !isExact {
            target = 0
        }
        awaitingInitialStart = true
        if target > 0.5 {
            seekPlayer(to: target)
        } else {
            startPlaybackIfRequested()
        }
        updateNowPlaying()
    }

    private func startPlaybackIfRequested() {
        awaitingInitialStart = false
        if shouldPlayWhenReady {
            audioSession.activate()
            avPlayer.play()
        } else {
            state = .paused
        }
        updateNowPlaying()
    }

    private func itemDidPlayToEnd() {
        guard let video = currentVideo else { return }
        stallTask?.cancel()
        state = .ended
        if duration > 0, !isLive {
            currentTime = duration
        }
        if hasStartedPlayback, !isLive {
            let length = duration > 0 ? duration : Double(video.durationSeconds ?? 0)
            library.recordProgress(video: video, seconds: length, duration: length > 0 ? length : nil)
            Task { await library.flush() }
        }
        updateNowPlaying()
        Self.log.info("ended \(video.id, privacy: .public)")

        // The queue first. With nothing queued but more of the list behind it, the next video is in the page that is
        // asked for now (`refillFinished`).
        if advanceQueue(as: .whenEnded) { return }
        autoplayAfterQueue(of: video)
    }

    /// The queue is over: autoplay chooses the next video, when the viewer turned it on.
    private func autoplayAfterQueue(of video: VideoSummary) {
        guard settings.autoplayNext, let step = autoplayStep(after: video) else { return }
        // What stays up next goes along: with the player minimized the watch page is not on screen to replace the
        // list, and the next hop would find it empty. Autoplay leaves the list of the queue behind.
        start(step.next, startAt: nil, queue: [], more: nil, upNext: step.remaining, expand: false)
    }

    /// The first up-next suggestion the viewer has not watched and the viewer's filters allow, and the suggestions that
    /// stay up next behind it.
    private func autoplayStep(after video: VideoSummary) -> AutoplayPlanner.Step? {
        // The filters as they are now, not as they were when the list was published: a channel blocked since (on Home
        // while the mini player showed, or between two videos of a run that carries the list along) counts, whatever
        // the watch page did or did not get to hear about it.
        let filter = ContentFilter(settings: settings)
        return AutoplayPlanner.step(
            after: video.id,
            upNext: upNext,
            progress: { [library] id in library.progress(for: id)?.progressSeconds },
            allows: { filter.allows($0) }
        )
    }

    // MARK: Failures and recovery

    private func itemFailedToPlayToEnd(error: NSError?) {
        guard let item = avPlayer.currentItem else { return }
        handleFailure(error: error ?? item.error, item: item)
    }

    private func handleFailure(error: (any Error)?, item: AVPlayerItem?) {
        guard currentVideo != nil, !isRecovering else { return }
        let failure = Self.classify(error: error, item: item)
        Self.log.error("playback error: \(String(describing: error), privacy: .public)")
        recover(from: failure, position: currentPositionForRecovery())
    }

    private func recover(from failure: PlaybackFailure, position: Double) {
        let action = PlaybackRecovery.action(
            for: failure,
            position: position,
            streamExpiresAt: isPlayingOffline ? nil : streamInfo?.expiresAt,
            now: Date(),
            attempt: recoveryAttempts
        )
        Self.log.info("failure \(String(describing: failure), privacy: .public) -> \(String(describing: action), privacy: .public)")

        switch action {
        case .reresolveAndResume(let at):
            recoveryAttempts += 1
            beginReload(at: at, waitForConnection: false)
        case .waitForNetworkThenRetry(let at):
            recoveryAttempts += 1
            beginReload(at: at, waitForConnection: true)
        case .showError:
            fail(message: failure.message)
        }
    }

    /// Rebuilds the item from freshly resolved stream URLs and resumes at `position`.
    private func beginReload(at position: Double, waitForConnection: Bool) {
        guard let video = currentVideo else { return }
        Self.log.info("reload \(video.id, privacy: .public) at \(position), waiting for connection: \(waitForConnection)")
        generation += 1
        let token = generation
        loadTask?.cancel()
        recoveryTask?.cancel()
        tearDownItem()

        // A download that cannot be played falls back to streaming.
        if isPlayingOffline {
            forceStreaming = true
            isPlayingOffline = false
            isAudioOnlyPlayback = false
        }
        isRecovering = true
        recoveryBaseline = position
        pendingStart = position
        currentTime = position
        state = hasStartedPlayback ? .buffering : .loading

        recoveryTask = Task { [weak self] in
            guard let self else { return }
            if waitForConnection {
                self.isWaitingForConnection = true
                await self.network.waitUntilOnline()
                self.isWaitingForConnection = false
                guard !Task.isCancelled, token == self.generation else { return }
            }
            await self.load(video, startAt: position, token: token)
        }
    }

    private func fail(with error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? Self.classify(error: error, item: nil).message
        fail(message: message)
    }

    private func fail(message: String) {
        Self.log.error("failed: \(message, privacy: .public)")
        stallTask?.cancel()
        isRecovering = false
        isWaitingForConnection = false
        state = .failed(message)
        shouldPlayWhenReady = false
        saveProgress(force: true)
        updateNowPlaying()
    }

    /// Tries again from the error screen: fresh URLs, same position, and a clean slate for the failure counter.
    func retry() {
        guard currentVideo != nil else { return }
        recoveryAttempts = 0
        shouldPlayWhenReady = true
        beginReload(at: currentTime, waitForConnection: false)
    }

    private func currentPositionForRecovery() -> Double {
        let time = avPlayer.currentTime()
        if time.isValid, time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
            return time.seconds
        }
        return currentTime
    }

    /// Reduces an `AVPlayerItem` failure to what `PlaybackRecovery` understands, using the error chain and the HTTP
    /// status of the last entry of the item's error log.
    private static func classify(error: (any Error)?, item: AVPlayerItem?) -> PlaybackFailure {
        var chain: [PlaybackFailure.ErrorLink] = []
        var next = error.map { $0 as NSError }
        while let current = next, chain.count < 6 {
            chain.append(PlaybackFailure.ErrorLink(domain: current.domain, code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let status = item?.errorLog()?.events.last?.errorStatusCode
        return PlaybackFailure.classify(chain: chain, httpStatus: status)
    }

    /// The video buffers for a long time: nothing is coming. Offline, wait for the connection; online, try fresh URLs.
    private func watchForStall() {
        Self.log.debug("watching for a stall (state \(String(describing: self.state), privacy: .public), online \(self.network.isOnline))")
        stallTask?.cancel()
        let token = generation
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, token == self.generation, self.state == .buffering else { return }
            if !self.network.isOnline {
                self.recover(from: .network, position: self.currentPositionForRecovery())
                return
            }
            try? await Task.sleep(for: .seconds(33))
            guard !Task.isCancelled, token == self.generation, self.state == .buffering else { return }
            self.recover(from: .unknown, position: self.currentPositionForRecovery())
        }
    }

    // MARK: Transport

    func play() {
        guard currentVideo != nil else { return }
        Self.log.debug("play (state \(String(describing: self.state), privacy: .public))")
        shouldPlayWhenReady = true
        if case .failed = state {
            retry()
            return
        }
        if state == .ended {
            // Replay from the start.
            resumeAfterSeek = true
            currentTime = 0
            seekPlayer(to: 0)
            return
        }
        // Paused for hours: the stream URLs are gone. Get new ones before they fail.
        if !isPlayingOffline, let info = streamInfo, info.isExpired(), avPlayer.currentItem != nil {
            beginReload(at: currentPositionForRecovery(), waitForConnection: false)
            return
        }
        guard avPlayer.currentItem != nil, isItemReady else { return }
        audioSession.activate()
        applyAutomaticPictureInPicture()
        avPlayer.play()
    }

    func pause() {
        guard currentVideo != nil else { return }
        Self.log.debug("pause (state \(String(describing: self.state), privacy: .public))")
        shouldPlayWhenReady = false
        avPlayer.pause()
        if state == .loading, isItemReady {
            state = .paused
        }
        saveProgress(force: true)
    }

    func togglePlayPause() {
        if isPlaybackActive {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = clampedToDuration(seconds)
        Self.log.debug("seek to \(target)")
        currentTime = target
        guard avPlayer.currentItem != nil, isItemReady else {
            // Still loading: start there instead.
            pendingStart = target
            return
        }
        if state == .ended {
            resumeAfterSeek = true
        }
        seekPlayer(to: target)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Jumps back to the start of the SponsorBlock segment that was just skipped and does not skip it again.
    func undoSkip() {
        guard let notice = skipNotice else { return }
        declinedSkips.insert(notice.segment.id)
        skipNotice = nil
        skipNoticeTask?.cancel()
        seek(to: notice.segment.start)
    }

    /// Starts the next queued video (the Next button of the lock screen); returns false when there is none to start,
    /// now or once the next page of the list behind the queue has arrived.
    @discardableResult
    func playNext() -> Bool {
        advanceQueue(as: .now)
    }

    // MARK: Queue

    /// Starts the first queued video. With nothing queued but more of the list behind the queue, asks for the next page
    /// instead and starts its first video when it arrives (`refillFinished`). Returns false when there is nothing to
    /// start, now or later.
    private func advanceQueue(as request: QueueAdvance.Request) -> Bool {
        if let next = queue.first {
            start(next, startAt: nil, queue: Array(queue.dropFirst()), more: queueSource, expand: false)
            return true
        }
        guard let source = queueSource, source.hasMore else { return false }
        // A viewer who pressed Next keeps asking for the next video, whether or not the one that plays has ended since.
        if pendingAdvance != .now {
            pendingAdvance = request
        }
        refill(from: source)
        return true
    }

    /// Takes over the queue a list handed in: the videos that follow the current one, and the source of the rest of the
    /// list. A source other than the one in hand ends the wait for a page of the old one.
    private func adoptQueue(_ videos: [VideoSummary], more: QueueSource?) {
        queue = videos
        if more !== queueSource {
            refillTask?.cancel()
            refillTask = nil
            pendingAdvance = nil
            queueSource = more
        }
        refillQueueIfNeeded()
    }

    /// Asks the source for its next page when the queue is running low, so that it is there before the queue runs out.
    private func refillQueueIfNeeded() {
        guard let source = queueSource, source.needsRefill(queued: queue.count) else { return }
        refill(from: source)
    }

    /// Asks `source` for its next page, unless one is on its way already.
    ///
    /// A page that arrives for a source the player has left (another list was opened, or the player was closed) is
    /// dropped: the identity of the source is the guard here, not the video, because the queue goes on from video to
    /// video with the same source.
    private func refill(from source: QueueSource) {
        guard refillTask == nil else { return }
        refillTask = Task { [weak self] in
            let page: [VideoSummary]?
            do {
                page = try await source.next()
            } catch {
                if !Task.isCancelled {
                    Self.log.error("the next page of the queue could not be loaded: \(String(describing: error), privacy: .public)")
                }
                page = nil
            }
            guard let self, self.queueSource === source else { return }
            self.refillTask = nil
            self.refillFinished(with: page, from: source)
        }
    }

    /// The page the queue asked for has come in (`nil` when it could not be loaded).
    private func refillFinished(with page: [VideoSummary]?, from source: QueueSource) {
        let added = page ?? []
        queue += added
        Self.log.info("queue: +\(added.count), \(self.queue.count) queued, more: \(source.hasMore)")
        // The list is over: nothing is left to ask for.
        if !source.hasMore {
            queueSource = nil
        }

        let request = pendingAdvance
        pendingAdvance = nil
        switch QueueAdvance.action(for: request, queued: queue.count, isEnded: state == .ended) {
        case .startNext:
            _ = advanceQueue(as: .now)
        case .autoplay:
            if let video = currentVideo {
                autoplayAfterQueue(of: video)
            }
        case .nothing:
            // A page can hold a video or two only (the filter hid the rest): still low, so the next one is asked for. A
            // page that failed or brought nothing waits for the next chance (the next video, the end of the queue).
            if !added.isEmpty {
                refillQueueIfNeeded()
            }
        }
        updateNowPlaying()
    }

    private func seekPlayer(to seconds: Double) {
        isSeeking = true
        seekToken += 1
        let token = seekToken
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        Task { [weak self] in
            guard let self else { return }
            _ = await self.avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            // A newer seek supersedes this one.
            guard token == self.seekToken else { return }
            self.isSeeking = false
            self.syncTimeFromPlayer()
            if self.awaitingInitialStart {
                self.startPlaybackIfRequested()
            } else if self.resumeAfterSeek {
                self.resumeAfterSeek = false
                self.shouldPlayWhenReady = true
                self.state = .buffering
                self.avPlayer.play()
            }
            self.updateNowPlaying()
        }
    }

    /// A seek to (or past) the end lands `PlaybackSeek.endMargin` before it: AVPlayer parked exactly at the end of an
    /// item waits there for media that never comes, a moment earlier it plays out and reaches the end the usual way,
    /// which is what ends the video, starts the queue and records the progress. That includes a SponsorBlock segment that
    /// runs to the end of the video.
    private func clampedToDuration(_ seconds: Double) -> Double {
        PlaybackSeek.clamped(seconds, duration: duration, isLive: isLive)
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
        if isFullscreen {
            isFullscreen = false
            requestOrientation(landscape: false)
        }
        presentation = .minimized
        // The watch page goes away with the expanded player, perhaps before it had loaded the details.
        if let video = currentVideo {
            requestDetailsIfNoPageShows(for: video)
        }
    }

    /// Stops playback and hides the player.
    func close() {
        saveProgress(force: true)
        Task { await library.flush() }
        generation += 1
        cancelWork()
        pictureInPicture.stop()
        tearDownItem()
        audioSession.deactivate()
        nowPlaying.clear()

        let wasFullscreen = isFullscreen
        currentVideo = nil
        streamInfo = nil
        state = .idle
        queue = []
        refillTask?.cancel()
        refillTask = nil
        pendingAdvance = nil
        queueSource = nil
        upNext = []
        detailsHandedOverFor = nil
        segments = []
        chapters = []
        skipNotice = nil
        captionText = nil
        currentTime = 0
        duration = 0
        bufferedTime = 0
        isPlayingOffline = false
        isAudioOnlyPlayback = false
        isLive = false
        hasStartedPlayback = false
        isWaitingForConnection = false
        isRecovering = false
        rawSegments = []
        planner = nil
        plannerLength = nil
        segmentsRequestedFor = nil
        betterTitle = nil
        betterTitleRequestedFor = nil
        cueTimeline = CueTimeline(cues: [])
        selectedCaption = nil
        isFullscreen = false
        presentation = .hidden
        if wasFullscreen {
            requestOrientation(landscape: false)
        }
    }

    func toggleFullscreen() {
        isFullscreen.toggle()
        Self.log.info("fullscreen \(self.isFullscreen)")
        requestOrientation(landscape: isFullscreen)
    }

    func startPictureInPicture() {
        pictureInPicture.start()
    }

    func togglePictureInPicture() {
        if isPictureInPictureActive {
            pictureInPicture.stop()
        } else {
            pictureInPicture.start()
        }
    }

    /// iPhone only: rotates to landscape for full screen and back. (On iPad full screen is only a layout.)
    private func requestOrientation(landscape: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { error in
            Logger(subsystem: "com.robinjungerich.noslopyt", category: "player")
                .error("orientation request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Observers

    private func wireCollaborators() {
        audioSession.onInterruptionBegan = { [weak self] in self?.audioInterruptionBegan() }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in self?.audioInterruptionEnded(shouldResume: shouldResume) }
        audioSession.onOutputDeviceUnavailable = { [weak self] in self?.pause() }

        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onSkip = { [weak self] seconds in self?.skip(by: seconds) }
        nowPlaying.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        nowPlaying.onNext = { [weak self] in _ = self?.playNext() }

        pictureInPicture.onActiveChange = { [weak self] active in self?.pictureInPictureActiveChanged(active) }
        pictureInPicture.onPossibleChange = { [weak self] possible in self?.isPictureInPicturePossible = possible }
        pictureInPicture.onRestoreUserInterface = { [weak self] in self?.expand() }

        network.onChange = { [weak self] in self?.networkChanged() }
    }

    private func installPlayerObservers() {
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }

        playerObservations = [
            avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.timeControlStatusChanged() }
            },
        ]

        let center = NotificationCenter.default
        // Read here, on the main actor: `AVPlayer`'s constants are main-actor isolated, the observer below is not.
        let reasonKey = AVPlayer.rateDidChangeReasonKey
        lifecycleNotifications = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillEnterForeground() }
            },
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveProgress(force: true) }
            },
            center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: avPlayer, queue: .main) { [weak self] note in
                let reason = note.userInfo?[reasonKey] as? String
                MainActor.assumeIsolated { self?.playerRateDidChange(reasonNamed: reason) }
            },
        ]
    }

    /// The rate of the player changed. When someone *set* it, that someone is the viewer or AVKit acting for the viewer,
    /// and the wish follows: the pause and play buttons of the Picture in Picture window and the remote of an AirPlay
    /// receiver reach `AVPlayer` directly, and `pause()` and `play()` here never run for them. Left alone, the wish would
    /// still say "playing" after a pause in the Picture in Picture window, and the next quality change, or the end of a
    /// phone call, would start the video again by itself.
    ///
    /// What the system does on its own (an interruption, the background) is not the viewer's doing and leaves the wish
    /// alone: `audioInterruptionBegan` and the background handling rely on it. So does the controller's own `pause()` of
    /// an item that is going away, which arrives while nothing is ready (`PlaybackIntent` has the rule).
    private func playerRateDidChange(reasonNamed name: String?) {
        let isSettled: Bool
        switch state {
        case .loading, .playing, .paused, .buffering: isSettled = true
        case .idle, .ended, .failed: isSettled = false
        }
        let wanted = PlaybackIntent.wantsPlayback(
            afterRateChangeTo: avPlayer.rate,
            reason: Self.rateChangeReason(named: name),
            wasWanted: shouldPlayWhenReady,
            isSettled: isSettled && currentVideo != nil && isItemReady && !isRecovering
        )
        if wanted != shouldPlayWhenReady {
            Self.log.info("the viewer \(wanted ? "resumed" : "paused", privacy: .public) outside the app's own buttons")
            shouldPlayWhenReady = wanted
        }
    }

    /// Why the rate changed, by the name the notification carries (nil when it names none, or one this app does not
    /// know).
    private static func rateChangeReason(named name: String?) -> PlaybackIntent.RateChangeReason? {
        guard let name else { return nil }
        switch AVPlayer.RateDidChangeReason(rawValue: name) {
        case .setRateCalled: return .setRateCalled
        case .setRateFailed: return .setRateFailed
        case .audioSessionInterrupted: return .audioSessionInterrupted
        case .appBackgrounded: return .appBackgrounded
        default: return nil
        }
    }

    private func timeControlStatusChanged() {
        guard currentVideo != nil, avPlayer.currentItem != nil, isItemReady, !isRecovering else { return }
        if case .failed = state { return }
        switch avPlayer.timeControlStatus {
        case .playing:
            stallTask?.cancel()
            if !hasStartedPlayback {
                hasStartedPlayback = true
                saveProgress(force: true)
            }
            state = .playing
        case .waitingToPlayAtSpecifiedRate:
            // A seek or a stall; a deliberate pause never lands here. The watch starts at every entry into waiting, not
            // only when the state turns to buffering: a reload (`beginReload`), a replay and a seek from the end set
            // `.buffering` before the item starts to wait, and an item that hangs there must end in the error screen
            // after the second failure just like the first one did.
            if state != .buffering { state = .buffering }
            watchForStall()
        case .paused:
            stallTask?.cancel()
            if state != .ended, !awaitingInitialStart {
                state = .paused
                saveProgress(force: true)
            }
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    // MARK: Time observer

    private func tick(_ time: CMTime) {
        guard currentVideo != nil, avPlayer.currentItem != nil, isItemReady, !isRecovering else { return }
        if !isSeeking, time.isValid, time.isNumeric, time.seconds.isFinite {
            setCurrentTime(max(0, time.seconds))
        }
        refreshDuration()
        rebuildPlannerIfLengthChanged()
        refreshBufferedTime()
        if let item = avPlayer.currentItem { logPresentationSizeChange(of: item) }
        refreshCaption()
        syncPlannerWithSettings()
        autoSkipSegmentIfNeeded()
        if state == .playing {
            saveProgress(force: false)
        }
        resetRecoveryCounterWhenHealthy()
        applyAutomaticPictureInPicture()
    }

    private func setCurrentTime(_ seconds: Double) {
        if abs(seconds - currentTime) > 0.05 {
            currentTime = seconds
        }
    }

    private func syncTimeFromPlayer() {
        let time = avPlayer.currentTime()
        if time.isValid, time.isNumeric, time.seconds.isFinite {
            currentTime = max(0, time.seconds)
        }
    }

    private func refreshDuration() {
        guard let item = avPlayer.currentItem else { return }
        let reported = item.duration
        guard reported.isValid, reported.isNumeric, reported.seconds.isFinite, reported.seconds > 0 else {
            if reported.isIndefinite, !isLive, streamInfo?.isLive == true {
                isLive = true
            }
            return
        }
        var value = reported.seconds
        // Some fragmented MP4 sources report twice their real length; the length YouTube gave is the truth then.
        // (Offline there is no stream info, but the video's own length from the list it was opened from.)
        if let length = streamInfo?.lengthSeconds ?? currentVideo?.durationSeconds, length > 0 {
            let ratio = value / Double(length)
            if ratio > 1.8, ratio < 2.2 {
                value = Double(length)
            }
        }
        if abs(value - duration) > 0.25 {
            duration = value
            updateNowPlaying()
        }
    }

    private func logPresentationSizeChange(of item: AVPlayerItem) {
        let size = item.presentationSize
        guard size != lastLoggedSize else { return }
        lastLoggedSize = size
        Self.log.debug("video \(Int(size.width))x\(Int(size.height)), quality cap \(self.quality.label, privacy: .public)")
    }

    private func refreshBufferedTime() {
        guard let item = avPlayer.currentItem else { return }
        let now = currentTime
        var buffered = now
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if start <= now + 0.5, end > buffered {
                buffered = end
            }
        }
        if abs(buffered - bufferedTime) > 0.5 {
            bufferedTime = buffered
        }
    }

    private func resetRecoveryCounterWhenHealthy() {
        if recoveryAttempts > 0, state == .playing, currentTime >= recoveryBaseline + 3 {
            recoveryAttempts = 0
        }
    }

    // MARK: Progress

    /// Saves the position to the library: every `ProgressSaveThrottle.interval` seconds while playing (the time
    /// observer asks without `force`), and at once when asked with `force` (pause, close, background, a failure, the
    /// first frame and a switch to another video). The library rewrites its whole history file for each batch of
    /// changes, so playback must not save on every tick.
    private func saveProgress(force: Bool) {
        guard let video = currentVideo, hasStartedPlayback, !isLive else { return }
        guard progressThrottle.shouldSave(now: Date(), force: force) else { return }
        Self.log.debug("save progress \(video.id, privacy: .public) at \(self.currentTime) (forced: \(force))")
        let length = duration > 0 ? duration : video.durationSeconds.map(Double.init)
        library.recordProgress(video: video, seconds: currentTime, duration: length)
    }

    // MARK: SponsorBlock

    private var settings: AppSettings {
        settingsStore.settings
    }

    /// Fetches the segments once per video, when SponsorBlock is on.
    ///
    /// A lookup that fails is tried again a few times (`SegmentLookup`), all inside this one task. Only an answer keeps
    /// the video marked as asked for, and "no segments" is an answer. When every try failed the mark is cleared, so the
    /// next chance asks again: Retry or a reload (`load` comes by here), a change of the SponsorBlock settings, the
    /// connection coming back (`networkChanged`).
    private func ensureSegments(for videoID: String) {
        guard settings.sponsorBlockEnabled, segmentsRequestedFor != videoID else { return }
        segmentsRequestedFor = videoID
        segmentsTask?.cancel()
        segmentsTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await SegmentLookup.fetch(videoID: videoID, from: self.sponsorBlock)
            guard !Task.isCancelled, self.currentVideo?.id == videoID else { return }
            switch outcome {
            case .loaded(let loaded):
                self.rawSegments = loaded
                self.rebuildPlanner()
            case .failed:
                Self.log.info("SponsorBlock lookup for \(videoID, privacy: .public) failed, will ask again later")
                self.segmentsRequestedFor = nil
            }
        }
    }

    private func rebuildPlanner() {
        let current = settings
        plannerEnabled = current.sponsorBlockEnabled
        plannerBehaviors = current.segmentBehaviors
        let length = knownLength
        plannerLength = length
        guard current.sponsorBlockEnabled, !rawSegments.isEmpty else {
            planner = nil
            if !segments.isEmpty { segments = [] }
            return
        }
        let built = SegmentSkipPlanner(segments: rawSegments, behaviors: current.segmentBehaviors, videoLength: length)
        planner = built
        let visible = built.visibleSegments
        if visible != segments { segments = visible }
    }

    /// How long the video is, as far as the player is sure: what the item reports once it is ready (`duration`), before
    /// that the length of the resolved stream. Not the length of the copy of the video the player was opened with: the
    /// video may have been trimmed since that was made. Nil for a live stream and while nothing is known.
    private var knownLength: Double? {
        guard !isLive else { return nil }
        if isItemReady, duration > 0 { return duration }
        if let length = streamInfo?.lengthSeconds, length > 0 { return Double(length) }
        return nil
    }

    /// The planner drops segments of another cut of the video once it knows the length, and the length comes after the
    /// segments may have (with the stream, then with the item). Builds the planner again when the length first becomes
    /// known or moves.
    private func rebuildPlannerIfLengthChanged() {
        guard !rawSegments.isEmpty else { return }
        switch (plannerLength, knownLength) {
        case (nil, nil):
            return
        case let (old?, new?) where abs(old - new) <= 0.25:
            return
        default:
            rebuildPlanner()
        }
    }

    /// The viewer changed the SponsorBlock settings while a video plays.
    private func syncPlannerWithSettings() {
        let current = settings
        guard current.sponsorBlockEnabled != plannerEnabled || current.segmentBehaviors != plannerBehaviors else { return }
        if current.sponsorBlockEnabled, let id = currentVideo?.id {
            ensureSegments(for: id)
        }
        rebuildPlanner()
    }

    private func autoSkipSegmentIfNeeded() {
        // No destination: the playhead already is at the end margin of a segment that runs to the end of the video, and
        // a skip would only repeat the notice.
        guard state == .playing, !isSeeking, let planner,
              let segment = planner.segmentToSkip(at: currentTime, alreadySkipped: declinedSkips),
              let destination = PlaybackSeek.skipDestination(of: segment, from: currentTime, duration: duration, isLive: isLive)
        else { return }
        // A skip that just happened is still settling.
        if let lastSkip, lastSkip.id == segment.id, Date().timeIntervalSince(lastSkip.at) < 1.5 { return }
        lastSkip = (segment.id, Date())
        Self.log.info("skip \(segment.category.rawValue, privacy: .public) \(segment.start)-\(segment.end) -> \(destination)")
        seek(to: destination)
        showSkipNotice(for: segment)
    }

    private func showSkipNotice(for segment: SponsorSegment) {
        skipNotice = SkipNotice(id: segment.id, segment: segment)
        skipNoticeTask?.cancel()
        let id = segment.id
        let duration = PlayerAccessibility.skipNoticeDuration(assistiveTechnologyOn: assistiveTechnologyIsRunning)
        skipNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.skipNotice?.id == id else { return }
            self.skipNotice = nil
        }
    }

    /// VoiceOver or Switch Control is running (in a Debug build `-assistiveTechnology YES` stands in).
    private var assistiveTechnologyIsRunning: Bool {
        #if DEBUG
        if DebugLaunchHooks.assistiveTechnology { return true }
        #endif
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    // MARK: De-clickbait title

    /// Looks up the community title of the video once, when "De-clickbait titles" is on. A title the lists already
    /// asked for (`DeArrowTitleCache`) is taken at once; otherwise it arrives a moment later and the lock screen is
    /// told. No answer, and a failed lookup, leave the original title.
    private func ensureBetterTitle(for videoID: String) {
        guard settings.deArrowTitles, betterTitleRequestedFor != videoID else { return }
        betterTitleRequestedFor = videoID
        titleTask?.cancel()
        if let known = DeArrowTitleCache.shared.lookup(videoID) {
            betterTitle = known.title
            return
        }
        titleTask = Task { [weak self] in
            guard let self else { return }
            let title = await self.deArrow.betterTitle(videoID: videoID)
            guard !Task.isCancelled, self.currentVideo?.id == videoID else { return }
            DeArrowTitleCache.shared.store(title, for: videoID)
            self.betterTitle = title
            self.updateNowPlaying()
        }
    }

    /// The viewer switched "De-clickbait titles" while a video is loaded: the lock screen follows, and the community
    /// title is looked up if it never was (the setting was off when the video started).
    func deArrowSettingChanged() {
        guard let id = currentVideo?.id else { return }
        ensureBetterTitle(for: id)
        updateNowPlaying()
    }

    // MARK: Captions

    func toggleCaptions() {
        if selectedCaption != nil {
            selectedCaption = nil
        } else {
            selectedCaption = Self.preferredTrack(in: captionTracks, language: settings.preferredCaptionLanguage)
        }
    }

    /// Shows the preferred caption language right away when the viewer set one and the video has it.
    private func selectDefaultCaption(from info: StreamInfo) {
        guard selectedCaption == nil,
              let language = settings.preferredCaptionLanguage, !language.isEmpty,
              let track = Self.matchingTrack(in: info.captions, language: language) else { return }
        selectedCaption = track
    }

    private static func preferredTrack(in tracks: [CaptionTrack], language: String?) -> CaptionTrack? {
        let device = Locale.current.language.languageCode?.identifier
        for candidate in [language, device, "en"] {
            if let candidate, !candidate.isEmpty, let track = matchingTrack(in: tracks, language: candidate) {
                return track
            }
        }
        return tracks.first(where: { !$0.isAutoGenerated }) ?? tracks.first
    }

    /// A track in `language` ("en" also matches "en-US"); written captions before auto-generated ones.
    private static func matchingTrack(in tracks: [CaptionTrack], language: String) -> CaptionTrack? {
        let wanted = baseLanguage(language)
        let matches = tracks.filter { baseLanguage($0.languageCode) == wanted }
        return matches.first(where: { !$0.isAutoGenerated }) ?? matches.first
    }

    private static func baseLanguage(_ code: String) -> String {
        code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code.lowercased()
    }

    private func selectedCaptionDidChange() {
        captionTask?.cancel()
        cueTimeline = CueTimeline(cues: [])
        captionText = nil
        guard let track = selectedCaption else { return }
        captionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cues = try await self.captions.cues(for: track)
                guard !Task.isCancelled, self.selectedCaption == track else { return }
                self.cueTimeline = CueTimeline(cues: cues)
                self.refreshCaption()
            } catch {
                guard !Task.isCancelled, self.selectedCaption == track else { return }
                // Captions that cannot be loaded are shown as off rather than as "on" with nothing to read.
                self.selectedCaption = nil
            }
        }
    }

    private func refreshCaption() {
        let text = selectedCaption == nil ? nil : cueTimeline.text(at: currentTime)
        if text != captionText {
            captionText = text
        }
    }

    // MARK: Rate and quality

    private func rateDidChange() {
        let clamped = Self.clampedRate(Double(rate))
        if clamped != rate {
            rate = clamped
        }
        avPlayer.defaultRate = clamped
        if avPlayer.rate != 0 {
            avPlayer.rate = clamped
        }
        updateNowPlaying()
    }

    private static func clampedRate(_ value: Double) -> Float {
        guard value.isFinite, value > 0 else { return 1 }
        return Float(min(max(value, 0.25), 4))
    }

    private func qualityDidChange(from previous: QualityPreference) {
        guard quality != previous else { return }
        if let item = avPlayer.currentItem {
            applyQuality(to: item)
        }
        // The connection chose it (Wi-Fi or cellular, when a video opens or the connection changes): the cap shapes what
        // is fetched from now on and nothing that is playing is thrown away.
        guard !isApplyingDefaultQuality else { return }
        qualityIsManual = true
        rebuildItemForQualityChange()
    }

    /// The viewer picked a quality. The cap alone only shapes what AVPlayer fetches from now on, and it keeps playing
    /// the minutes it has already buffered in the old quality. So the player item is rebuilt from the stream info in
    /// hand (no new resolve) and picks up at the current position; the new item starts with an empty buffer.
    ///
    /// Everything that belongs to the video rather than to the item stays: playing or paused, the rate (`defaultRate`
    /// starts the new item at it), the caption track and its cues, the SponsorBlock segments with the ones declined, and
    /// the time observer, which hangs on the player.
    ///
    /// Nothing is rebuilt when there is nothing buffered to replace (still starting, ended, failed), when the video
    /// comes from a download (one quality), or when the device is offline (the buffer is all there is). Those keep the
    /// cap, which the next item or the replay applies.
    private func rebuildItemForQualityChange() {
        guard currentVideo != nil, let info = streamInfo, !isPlayingOffline,
              avPlayer.currentItem != nil, isItemReady, hasStartedPlayback, !isRecovering,
              state != .ended, failureMessage == nil,
              network.isOnline else { return }

        let position = isLive ? 0 : PlaybackSeek.clamped(currentPositionForRecovery(), duration: duration, isLive: isLive)

        // Links that expired while the video was paused need new ones, not a rebuild from the old.
        guard !info.isExpired() else {
            beginReload(at: position, waitForConnection: false)
            return
        }
        guard let url = playbackURL(for: info) else { return }

        Self.log.info("quality \(self.quality.label, privacy: .public): rebuilding the item at \(position)")
        tearDownItem(replacingRightAway: true)
        pendingStart = position
        pendingStartIsExact = true
        currentTime = position
        bufferedTime = position
        // Playing: buffering until the first frame. Paused: stays paused, the item loads and waits.
        state = shouldPlayWhenReady ? .buffering : .loading
        attach(AVPlayerItem(url: url))
        if shouldPlayWhenReady {
            watchForStall()
        }
        updateNowPlaying()
    }

    private func applyDefaultQuality() {
        isApplyingDefaultQuality = true
        quality = network.isExpensive ? settings.cellularQuality : settings.wifiQuality
        isApplyingDefaultQuality = false
    }

    /// `preferredMaximumResolution` is a box. The long edge of a 16:9 picture of height `h` is `h * 16 / 9`, so a square
    /// box of that side lets 16:9 (and 4:3, and portrait) video up to the chosen label through and nothing bigger.
    private func applyQuality(to item: AVPlayerItem) {
        guard let height = quality.maxHeight else {
            item.preferredMaximumResolution = .zero
            item.preferredPeakBitRate = 0
            return
        }
        let side = (Double(height) * 16.0 / 9.0).rounded()
        item.preferredMaximumResolution = CGSize(width: side, height: side)
        item.preferredPeakBitRate = Self.peakBitRate(forHeight: height)
    }

    /// Bits per second, comfortably above YouTube's H.264 renditions of that height so it never forces a lower one.
    private static func peakBitRate(forHeight height: Int) -> Double {
        switch height {
        case ...360: return 1_500_000
        case ...480: return 2_500_000
        case ...720: return 5_000_000
        default: return 10_000_000
        }
    }

    private func networkChanged() {
        if !qualityIsManual {
            applyDefaultQuality()
        }
        // A SponsorBlock lookup that failed for good asks again now that there may be a connection. Nothing happens
        // unless one did.
        if network.isOnline, let id = currentVideo?.id {
            ensureSegments(for: id)
        }
    }

    // MARK: Audio interruptions

    private func audioInterruptionBegan() {
        // The system may have paused the player before this arrives (and a second interruption arrives with the
        // player already paused), so `state` cannot say whether playback was running. The viewer's wish can:
        // `pause()` clears it, the system's pause does not.
        switch state {
        case .idle, .ended, .failed:
            wasPlayingBeforeInterruption = false
        case .loading, .playing, .buffering, .paused:
            wasPlayingBeforeInterruption = shouldPlayWhenReady
        }
    }

    private func audioInterruptionEnded(shouldResume: Bool) {
        defer { wasPlayingBeforeInterruption = false }
        guard shouldResume, wasPlayingBeforeInterruption, currentVideo != nil else { return }
        play()
    }

    // MARK: Background and Picture in Picture

    private func pictureInPictureActiveChanged(_ active: Bool) {
        isPictureInPictureActive = active
    }

    /// Auto-PiP has to be armed before the app leaves the foreground, so the setting is applied while playing.
    private func applyAutomaticPictureInPicture() {
        let wanted = settings.autoPictureInPicture
        if pictureInPicture.startsAutomaticallyFromInline != wanted {
            pictureInPicture.startsAutomaticallyFromInline = wanted
        }
    }

    private func appDidEnterBackground() {
        saveProgress(force: true)
        Task { await library.flush() }
        guard currentVideo != nil else { return }

        if pictureInPicture.isActive || pictureInPicture.isStarting {
            return
        }
        // Asked now, before the wait below: the system may pause a player that still renders into a layer once the
        // app is in the background, and by the time that wait is over `state` would say the viewer had paused.
        let wasPlaying = isPlaybackActive
        // With automatic PiP on, the system starts it around now; look again once it had its say.
        let mayStartPictureInPicture = settings.autoPictureInPicture && pictureInPicture.isPossible && state == .playing
        if mayStartPictureInPicture {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.settleBackgroundPlayback(wasPlaying: wasPlaying)
            }
        } else {
            settleBackgroundPlayback(wasPlaying: wasPlaying)
        }
    }

    /// Background without Picture in Picture: keep the audio going (video detached from its layers) or pause.
    /// `wasPlaying` is whether playback was running when the app left the foreground.
    private func settleBackgroundPlayback(wasPlaying: Bool) {
        guard currentVideo != nil, UIApplication.shared.applicationState != .active else { return }
        if pictureInPicture.isActive || pictureInPicture.isStarting { return }
        if settings.backgroundPlayback {
            Self.log.info("background: video detached, audio continues")
            pictureInPicture.setSurfacesAttached(false)
            didDetachSurfaces = true
            // Leaving the app with a rendering layer may have paused the player; the viewer did not ask for that.
            if wasPlaying, shouldPlayWhenReady, isItemReady, avPlayer.rate == 0, state != .ended {
                avPlayer.play()
            }
        } else {
            Self.log.info("background: paused (background playback is off)")
            pause()
        }
    }

    private func appWillEnterForeground() {
        if didDetachSurfaces {
            pictureInPicture.setSurfacesAttached(true)
            didDetachSurfaces = false
        }
        syncTimeFromPlayer()
    }

    // MARK: Now Playing

    private func updateNowPlaying() {
        guard let video = currentVideo else { return }
        let playing = state == .playing
        nowPlaying.update(
            video: video,
            title: displayTitle ?? video.title,
            duration: duration,
            elapsed: currentTime,
            rate: playing ? Double(avPlayer.rate) : 0,
            isLive: isLive,
            canPlayNext: canPlayNext
        )
    }
}

#if DEBUG
// MARK: - Simulator checks

/// What `PlayerDebugScript` (checks in the simulator that links cannot reach, driven by a launch argument) needs from
/// the controller's internals. Debug builds only.
extension PlayerController {
    var debugSettingsStore: SettingsStore {
        settingsStore
    }

    /// Adds a SponsorBlock segment to the loaded ones, for example an outro that runs to the end of the video.
    /// `videoDuration` is the length of the video the segment claims to have been submitted for.
    func debugAddSegment(start: Double, end: Double, videoDuration: Double? = nil) {
        rawSegments.append(
            SponsorSegment(
                id: "debug-\(start)-\(end)",
                category: .sponsor,
                actionType: .skip,
                start: start,
                end: end,
                videoDuration: videoDuration
            )
        )
        rebuildPlanner()
    }

    /// `-silentPlayback`: plays the item without its audio rendition, so no audio queue has to start.
    func debugDropAudio(of item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        item.select(nil, in: group)
    }

    /// Adds a highlight (`poi_highlight`: a moment, start and end are the same second) to the loaded segments.
    func debugAddHighlight(at time: Double) {
        rawSegments.append(SponsorSegment(id: "debug-highlight-\(time)", category: .poiHighlight, actionType: .poi, start: time, end: time))
        rebuildPlanner()
    }

    /// Ends the video with the error screen, as a stream that cannot be played would.
    func debugFail(message: String = "Failed on purpose by the player script.") {
        fail(message: message)
    }

    /// Opens the video that is current once more, the way a link to it does.
    func debugReopen() {
        guard let video = currentVideo else { return }
        open(video, startAt: nil, queue: [])
    }

    /// Opens `id` the way a row of Watch Later does for a broadcast that has ended since it was saved: the saved copy
    /// still says live and upcoming, and has no length.
    func debugOpenStaleLive(id: String) {
        var video = SampleData.video(id: id) ?? VideoSummary(id: id, title: "Saved while it was live")
        video.isLive = true
        video.isUpcoming = true
        video.durationSeconds = nil
        open(video, startAt: nil, queue: [])
    }

    /// Sets the quality the way the connection does (Wi-Fi or cellular): only the cap, no new item. That is also how a
    /// pick behaved before the item was rebuilt.
    func debugApplyCapOnly(_ quality: QualityPreference) {
        isApplyingDefaultQuality = true
        self.quality = quality
        isApplyingDefaultQuality = false
    }

    /// Records a minute of the sample video `id` in the history, so that autoplay treats it as watched.
    func debugMarkWatched(_ id: String) {
        guard let video = SampleData.video(id: id) else { return }
        library.recordProgress(video: video, seconds: 60, duration: video.durationSeconds.map(Double.init))
    }

    /// Shows the skip notice of the first segment and leaves it up (it has no timer), for screenshots.
    func debugPinNotice() {
        guard let segment = segments.first ?? rawSegments.first else { return }
        skipNoticeTask?.cancel()
        skipNotice = SkipNotice(id: segment.id, segment: segment)
    }

    /// One line with the state of the player for the log (`xcrun simctl spawn <udid> log stream --level debug`).
    func debugLogSnapshot(_ tag: String) {
        let size = avPlayer.currentItem?.presentationSize ?? .zero
        let caption = captionText ?? "-"
        let notice = skipNotice?.segment.category.rawValue ?? "-"
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let bounds = window?.bounds ?? .zero
        let insets = window?.safeAreaInsets ?? .zero
        Self.log.info("""
            [script] \(tag, privacy: .public) state=\(String(describing: self.state), privacy: .public) \
            time=\(self.currentTime) duration=\(self.duration) rate=\(self.avPlayer.rate) \
            quality=\(self.quality.label, privacy: .public) size=\(Int(size.width))x\(Int(size.height)) \
            captions=\(self.selectedCaption?.id ?? "off", privacy: .public) caption=\(caption, privacy: .public) \
            notice=\(notice, privacy: .public) segments=\(self.segments.count) upNext=\(self.upNext.count) \
            upNextHead=\(self.upNext.first?.id ?? "-", privacy: .public) \
            chapters=\(self.chapters.count) queue=\(self.queue.count) more=\(self.queueSource?.hasMore ?? false) \
            blocked=\(self.settings.blockedChannels.count) \
            video=\(self.currentVideo?.id ?? "-", privacy: .public) \
            live=\(self.isLive) videoLive=\(self.currentVideo?.isLive ?? false) \
            videoUpcoming=\(self.currentVideo?.isUpcoming ?? false) \
            history=\(self.library.history.map(\.id).joined(separator: ","), privacy: .public) \
            nowPlaying=\(self.nowPlaying.debugPublished, privacy: .public) \
            displayTitle=\(self.displayTitle ?? "-", privacy: .public) \
            presentation=\(String(describing: self.presentation), privacy: .public) fullscreen=\(self.isFullscreen) \
            window=\(Int(bounds.width))x\(Int(bounds.height)) safeTop=\(insets.top) safeBottom=\(insets.bottom)
            """)
    }
}
#endif

// MARK: - Captions

/// Caption cues ordered by start time, with a binary search for the cue showing at a time.
private struct CueTimeline {
    private let cues: [CaptionCue]

    init(cues: [CaptionCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    /// The text of the latest-starting cue that covers `time`. Auto-generated captions overlap, so a few earlier cues
    /// are considered too.
    func text(at time: Double) -> String? {
        guard !cues.isEmpty else { return nil }
        // Index of the first cue that starts after `time`.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var index = low - 1
        var checked = 0
        while index >= 0, checked < 4 {
            let cue = cues[index]
            if time < cue.end {
                let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            index -= 1
            checked += 1
        }
        return nil
    }
}

// MARK: - Connectivity

/// Online/offline and Wi-Fi/cellular from `NWPathMonitor`: it picks the default quality cap and lets recovery wait for
/// the connection.
@MainActor
final class PlaybackNetworkMonitor {
    private(set) var isOnline = true
    /// Cellular, a personal hotspot, or Low Data Mode.
    private(set) var isExpensive = false
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.update(isOnline: online, isExpensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "com.robinjungerich.noslopyt.network-path"))
    }

    private func update(isOnline: Bool, isExpensive: Bool) {
        guard self.isOnline != isOnline || self.isExpensive != isExpensive else { return }
        self.isOnline = isOnline
        self.isExpensive = isExpensive
        onChange?()
    }

    /// Returns once the device is online (immediately when it already is) or the calling task is cancelled.
    func waitUntilOnline() async {
        while !isOnline {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }
}
