import Foundation

/// Where `DownloadManager` gets the extras of a video that starts to download (see `DownloadExtras`).
public protocol DownloadExtrasProviding: Sendable {
    /// The extras of the video `info` describes, as far as they can be had right now. Never throws: a part that could not
    /// be had is nil in the answer. `info` is what the download just resolved: its caption tracks are the ones to keep.
    func extras(for info: StreamInfo) async -> DownloadExtras
}

/// The extras from the services the player asks while it streams: SponsorBlock for the segments, the watch page for the
/// chapters and the caption service for the text of the captions.
///
/// The three are asked at once, and each of them has `timeout` (6 seconds) to answer: whatever answered in time is kept,
/// the rest is nil. A source that is slow or down costs the download a few seconds at most and never fails it.
///
/// Captions are the expensive part, one request per track, so only up to `maxCaptionTracks` (three) tracks are fetched,
/// the one captions open with first (`CaptionTrackChoice.tracksToKeep`).
public struct DownloadExtrasFetcher: DownloadExtrasProviding {
    /// The SponsorBlock segments of a video (all categories).
    public typealias SegmentsSource = @Sendable (_ videoID: String) async throws -> [SponsorSegment]
    /// The chapters of a video.
    public typealias ChaptersSource = @Sendable (_ videoID: String) async throws -> [Chapter]
    /// The caption language the viewer chose in the settings, if any.
    public typealias CaptionLanguageSource = @MainActor @Sendable () -> String?

    private let segments: SegmentsSource
    private let chapters: ChaptersSource
    private let captions: any CaptionsProviding
    private let preferredCaptionLanguage: CaptionLanguageSource
    private let deviceLanguage: String?
    private let timeout: Duration
    private let maxCaptionTracks: Int

    public init(
        segments: @escaping SegmentsSource,
        chapters: @escaping ChaptersSource,
        captions: any CaptionsProviding,
        preferredCaptionLanguage: @escaping CaptionLanguageSource = { nil },
        deviceLanguage: String? = CaptionTrackChoice.deviceLanguage,
        timeout: Duration = .seconds(6),
        maxCaptionTracks: Int = 3
    ) {
        self.segments = segments
        self.chapters = chapters
        self.captions = captions
        self.preferredCaptionLanguage = preferredCaptionLanguage
        self.deviceLanguage = deviceLanguage
        self.timeout = timeout
        self.maxCaptionTracks = maxCaptionTracks
    }

    /// The services as the app has them: the chapters come from the watch page (`YouTubeService.videoDetails`).
    public init(
        sponsorBlock: any SponsorBlockProviding,
        youTube: any YouTubeService,
        captions: any CaptionsProviding,
        preferredCaptionLanguage: @escaping CaptionLanguageSource = { nil }
    ) {
        self.init(
            segments: { try await sponsorBlock.segments(videoID: $0) },
            chapters: { try await youTube.videoDetails(id: $0).chapters },
            captions: captions,
            preferredCaptionLanguage: preferredCaptionLanguage
        )
    }

    public func extras(for info: StreamInfo) async -> DownloadExtras {
        let videoID = info.videoID
        let segments = segments
        let chapters = chapters
        let timeout = timeout
        async let foundSegments = TimeBox.run(timeout) { try await segments(videoID) }
        async let foundChapters = TimeBox.run(timeout) { try await chapters(videoID) }
        async let foundCaptions = keptCaptions(of: info)
        return DownloadExtras(segments: await foundSegments, chapters: await foundChapters, captions: await foundCaptions)
    }

    /// The text of the tracks worth keeping. `[]` when the video has no captions at all (known: none); nil when it has
    /// some and not one of the wanted tracks could be fetched (not known).
    private func keptCaptions(of info: StreamInfo) async -> [StoredCaptions]? {
        guard !info.captions.isEmpty else { return [] }
        let language = await preferredCaptionLanguage()
        let wanted = CaptionTrackChoice.tracksToKeep(
            in: info.captions, language: language, deviceLanguage: deviceLanguage, limit: maxCaptionTracks
        )
        let captions = captions
        let timeout = timeout
        let fetched = await withTaskGroup(of: (index: Int, kept: StoredCaptions?).self) { group in
            for (index, track) in wanted.enumerated() {
                group.addTask {
                    let cues = await TimeBox.run(timeout) { try await captions.cues(for: track) }
                    // A track without a single cue has nothing to show offline either.
                    guard let cues, !cues.isEmpty else { return (index, nil) }
                    return (index, StoredCaptions(track: track, cues: cues))
                }
            }
            var found: [(index: Int, kept: StoredCaptions)] = []
            for await result in group {
                if let kept = result.kept { found.append((result.index, kept)) }
            }
            return found.sorted { $0.index < $1.index }.map(\.kept)
        }
        return fetched.isEmpty ? nil : fetched
    }
}

// MARK: - Time box

/// Runs a piece of work for a limited time.
enum TimeBox {
    /// The result of `operation`, or nil when it threw or did not finish within `timeout`.
    ///
    /// At the deadline the operation is cancelled and **not waited for**: this returns at the deadline even when the
    /// operation ignores cancellation (a call that awaits another task's result, or one that is stuck), which a task
    /// group's `cancelAll()` would still wait for. Work that does not stop keeps running in the background and its answer
    /// is dropped. A caller that is cancelled gets nil at once.
    static func run<Value: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let race = Race<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                race.start(continuation, timeout: timeout, operation: operation)
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    /// The operation against the clock; whoever finishes first answers, once.
    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var isFinished = false

        func start(
            _ continuation: CheckedContinuation<Value?, Never>,
            timeout: Duration,
            operation: @escaping @Sendable () async throws -> Value
        ) {
            // The caller was cancelled before this ran: nothing is started.
            let alreadyFinished = lock.withLock { () -> Bool in
                if !isFinished { self.continuation = continuation }
                return isFinished
            }
            if alreadyFinished {
                continuation.resume(returning: nil)
                return
            }
            let work = Task { [self] in
                finish(try? await operation())
            }
            let clock = Task { [self] in
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
            let cancelNow = lock.withLock { () -> Bool in
                tasks = [work, clock]
                return isFinished
            }
            if cancelNow {
                work.cancel()
                clock.cancel()
            }
        }

        func finish(_ value: Value?) {
            let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, [Task<Void, Never>]) in
                guard !isFinished else { return (nil, []) }
                isFinished = true
                defer {
                    self.continuation = nil
                    self.tasks = []
                }
                return (self.continuation, self.tasks)
            }
            for task in tasks { task.cancel() }
            continuation?.resume(returning: value)
        }
    }
}
