import Foundation
import Observation
import Synchronization
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Chunked background downloads with duration-clamped muxing, and the list of downloaded videos.
///
/// A download is a list of 10 MiB HTTP Range requests, one URLSession task each, on a background session: they keep
/// going while the app is suspended or the system has ended it, and the system relaunches the app to say they are
/// done. A person who swipes the app away in the app switcher is different: iOS cancels the transfers of a force-quit
/// app and does not relaunch it, so nothing downloads until the app is opened again, and those items come back
/// `.paused`. Finished chunks land in `<root>/.work/<item id>/`; when all are there the manager concatenates them per
/// stream, muxes video and audio into one file whose tracks are cut to the true duration (see `MediaMuxer`), and
/// moves it into `<root>`. A half-written file is never marked completed: every file appears under its final name
/// only when it is whole.
///
/// Persistence: the list lives in `<root>/downloads.json`. Items that were in flight when the app last ran come
/// back `.paused` (their tasks are gone or unknown); the session is then asked what it kept, and those items pick up
/// where they were. `retry` asks YouTube for fresh stream URLs and reuses parts that are still valid. A list that
/// exists but cannot be read (the app was started in the background before the first unlock after a restart, say) is
/// not an empty list: nothing is deleted, cancelled or saved over it, and it is read again once the files can be read.
///
/// A failed download keeps what it fetched, so a retry only fetches what is missing: the chunks that finished, and
/// the concatenated streams of a merge that was interrupted. Only a download that is proven bad (an unreadable stream,
/// a video YouTube no longer offers) is thrown away. A stream address that stops working (it expired, or it was made
/// for an IP address the phone has left) is replaced once, automatically.
///
/// Extras: a download is played offline, so what the player would ask YouTube for while it streams (SponsorBlock
/// segments, chapters, captions: see `DownloadExtras`) is fetched when the download starts, while there is a connection,
/// and kept per video in `<root>/.extras/<video id>.json`, out of the Files app's list like `.work`. The fetch is best
/// effort and time-boxed (`DownloadTuning.extrasTimeout`): it never fails a download, and the wait for it, like the rest of
/// the start, runs on running time borrowed from iOS (`BackgroundTime`), so that a download that is started and left at
/// once still gets its chunk tasks. The file goes when the last download of the video goes. `extras(forVideoID:)` reads it.
@MainActor
@Observable
public final class DownloadManager {
    /// Newest first.
    public private(set) var items: [DownloadItem] = []

    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let streams: any StreamResolving
    @ObservationIgnored private let tuning: DownloadTuning
    @ObservationIgnored private let workspace: DownloadWorkspace
    @ObservationIgnored private let store: DownloadItemStore
    @ObservationIgnored private let engine: DownloadEngine
    /// Fetches the extras of a video when its download starts; nil for none (the tests that do not care).
    @ObservationIgnored private let extrasProvider: (any DownloadExtrasProviding)?
    @ObservationIgnored private let extrasStore: DownloadExtrasStore
    /// Items whose chunk tasks exist, by item id.
    @ObservationIgnored private var jobs: [String: DownloadJob] = [:]
    /// Items that are still resolving their stream URLs and preparing their directory.
    @ObservationIgnored private var starts: [String: DownloadStart] = [:]
    /// Lower-cased names of final files that merges in progress will create.
    @ObservationIgnored private var reservedNames: [String: String] = [:]
    /// The streams each item picked, by item id: set when the item has chosen its formats (before anything is
    /// fetched), kept until it fails, is cancelled or deleted, or is started again. Finished items of an earlier launch
    /// are not in it; `streamsToday(of:info:)` works those out again.
    @ObservationIgnored private var chosenStreams: [String: DownloadStreams] = [:]
    /// Items whose stream addresses were already replaced once, automatically, since the person last started them: a
    /// second dead address is a failure to show, not a loop. Cleared when the item is started by hand, fails, is
    /// cancelled or deleted, or finishes.
    @ObservationIgnored private var refreshedLinks: Set<String> = []
    /// True while `downloads.json` exists but could not be read. The list in memory is then only what was started
    /// since; nothing is saved over the file, and no work directory is deleted as an orphan of a list nobody has seen.
    @ObservationIgnored private var listIsUnreadable = false
#if canImport(UIKit) && !os(watchOS)
    @ObservationIgnored private let notificationObservers = NotificationObservers()
#endif

    /// - Parameters:
    ///   - sessionConfiguration: nil means the background configuration with the global session id.
    ///   - extras: fetches the SponsorBlock segments, chapters and captions of a video when its download starts, to keep
    ///     them with the download (see `DownloadExtras`). nil keeps nothing.
    public convenience init(
        rootDirectory: URL,
        streams: any StreamResolving,
        sessionConfiguration: URLSessionConfiguration? = nil,
        extras: (any DownloadExtrasProviding)? = nil
    ) {
        self.init(rootDirectory: rootDirectory, streams: streams, sessionConfiguration: sessionConfiguration, tuning: .standard, extras: extras)
    }

    init(
        rootDirectory: URL,
        streams: any StreamResolving,
        sessionConfiguration: URLSessionConfiguration?,
        tuning: DownloadTuning,
        extras: (any DownloadExtrasProviding)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.streams = streams
        self.tuning = tuning
        self.extrasProvider = extras
        self.extrasStore = DownloadExtrasStore(root: rootDirectory)
        let workspace = DownloadWorkspace(root: rootDirectory)
        self.workspace = workspace
        self.store = DownloadItemStore(fileURL: rootDirectory.appendingPathComponent("downloads.json"))
        let (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        self.engine = DownloadEngine(
            configuration: sessionConfiguration,
            workspace: workspace,
            events: continuation,
            progressInterval: tuning.progressInterval
        )

        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        DownloadAssembler.excludeFromBackup(rootDirectory)

        // What the last run left behind. Nothing is trusted to still be running until the session confirms it.
        let restored = Self.restore(store.load(), root: rootDirectory)
        listIsUnreadable = restored.isUnreadable
        items = restored.items
        if restored.changed { saveItems() }
        // With a list that could not be read every work directory would look like an orphan: leave them all alone, and
        // leave the session's tasks alone too, until the list can be read (see `reloadIfUnreadable`).
        if !restored.isUnreadable {
            workspace.prune(keeping: restored.unfinishedIDs)
            // The extras of a video whose last download was removed, when the process ended before they were.
            extrasStore.prune(keeping: Set(restored.items.map(\.video.id)))
        }

        // Events are handled one at a time, in order, on the main actor.
        Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        if !restored.isUnreadable {
            Task { @MainActor [weak self] in
                await self?.reconcile(restoredIDs: restored.restoredIDs)
            }
        }
        observeProtectedData()
    }

    deinit {
        engine.shutdown()
    }

    // MARK: - Restoring the list

    /// The list as the last run left it, made ready for this one.
    private struct RestoredList {
        var items: [DownloadItem] = []
        /// Items that were in flight and must be matched up with the session's tasks.
        var restoredIDs: [String] = []
        /// Items that may have a work directory.
        var unfinishedIDs: Set<String> = []
        /// Whether `items` differs from the file.
        var changed = false
        var isUnreadable = false
    }

    nonisolated private static func restore(_ contents: DownloadItemStore.Contents, root: URL) -> RestoredList {
        guard case .items(var loaded) = contents else { return RestoredList(isUnreadable: true) }
        var restored = RestoredList()
        for index in loaded.indices {
            switch loaded[index].state {
            case .queued, .downloading, .merging:
                loaded[index].state = .paused
                loaded[index].errorMessage = nil
                restored.restoredIDs.append(loaded[index].id)
                restored.unfinishedIDs.insert(loaded[index].id)
                restored.changed = true
            case .paused:
                restored.restoredIDs.append(loaded[index].id)
                restored.unfinishedIDs.insert(loaded[index].id)
            case .failed:
                // A failed item has a work directory only when its parts were kept on purpose for the next retry.
                restored.unfinishedIDs.insert(loaded[index].id)
            case .completed:
                if finishedFile(of: loaded[index], in: root) == nil {
                    loaded[index].state = .failed
                    loaded[index].relativeFilePath = nil
                    loaded[index].progress = 0
                    loaded[index].bytesDownloaded = 0
                    loaded[index].errorMessage = "The downloaded file is missing. Retry to download it again."
                    restored.changed = true
                }
            }
        }
        restored.items = loaded
        return restored
    }

    /// Reads `downloads.json` again when it could not be read at launch, and carries on as the launch would have: items
    /// that were in flight come back `.paused`, work directories nobody needs are deleted, and the session's tasks are
    /// matched up. Downloads started in the meantime stay and come first. Does nothing once the list has been read, so
    /// it is cheap to call: when the protected data becomes available, when the app becomes active, and before a new
    /// download is added.
    func reloadIfUnreadable() {
        guard listIsUnreadable else { return }
        let restored = Self.restore(store.load(), root: rootDirectory)
        guard !restored.isUnreadable else { return }
        listIsUnreadable = false

        // What was started meanwhile is newer than the file, and wins where both have an item.
        let known = Set(items.map(\.id))
        items += restored.items.filter { !known.contains($0.id) }
        saveItems()

        var unfinishedIDs = restored.unfinishedIDs
        for item in items where item.state != .completed { unfinishedIDs.insert(item.id) }
        workspace.prune(keeping: unfinishedIDs)
        extrasStore.prune(keeping: Set(items.map(\.video.id)))

        let restoredIDs = restored.restoredIDs.filter { !known.contains($0) }
        Task { @MainActor [weak self] in
            await self?.reconcile(restoredIDs: restoredIDs)
        }
    }

    /// Files that data protection keeps closed until the first unlock after a restart can be opened again when the
    /// device is unlocked, and an app that was started in the background before that finds its list closed. The list
    /// is read again then, and when the app comes to the foreground.
    private func observeProtectedData() {
#if canImport(UIKit) && !os(watchOS)
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadIfUnreadable() }
            }
            notificationObservers.add(token)
        }
#endif
    }

    // MARK: - Options

    /// The qualities the sheet offers for this video, with size estimates (video plus audio bytes) where YouTube
    /// states them. Empty when nothing can be downloaded (live streams, no H.264/AAC formats).
    public func availableOptions(for info: StreamInfo) -> [DownloadOption] {
        guard !info.isLive else { return [] }
        return FormatSelector.options(from: info.formats)
    }

    // MARK: - Commands

    /// Adds a download at the front of the list and starts it. A failed or paused one for the same video and
    /// quality starts again; one that is queued, running or finished is left alone (a finished one whose file has
    /// disappeared is downloaded again).
    ///
    /// A quality is a request, not a file: "720p" of a video that stops at 144p is the 144p file, which is also what
    /// "144p" gives. Once the streams are known (YouTube has been asked), an item that would fetch the same video and
    /// audio streams as another item of that video that has not failed is removed from the list again instead of
    /// downloading them twice. An original that is paused starts again, since a download of it was asked for.
    public func enqueue(video: VideoSummary, quality: DownloadQuality) {
        // A list that was closed at launch may be readable by now; a video that is already downloaded should be found.
        reloadIfUnreadable()
        let id = Self.itemID(video: video, quality: quality)
        if let item = items.first(where: { $0.id == id }) {
            switch item.state {
            case .failed, .paused:
                start(id)
            case .completed:
                if fileURL(for: item) == nil { start(id) }
            case .queued, .downloading, .merging:
                break
            }
            return
        }
        items.insert(DownloadItem(id: id, video: video, quality: quality, state: .queued), at: 0)
        saveItems()
        start(id)
    }

    /// Stops a download that has not finished and removes it from the list. Finished downloads are not affected.
    public func cancel(id: String) {
        guard let item = items.first(where: { $0.id == id }), item.state != .completed else { return }
        teardown(id)
        items.removeAll { $0.id == id }
        saveItems()
        removeExtrasIfUnused(videoID: item.video.id)
    }

    /// Removes the item and its file, stopping the download first if it is still running.
    public func delete(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        teardown(id)
        if let url = Self.finishedFile(of: item, in: rootDirectory) {
            try? FileManager.default.removeItem(at: url)
        }
        items.remove(at: index)
        saveItems()
        removeExtrasIfUnused(videoID: item.video.id)
    }

    /// Starts a failed or paused download again. YouTube is asked for fresh stream URLs; parts that were already
    /// fetched are kept when the streams are the same.
    public func retry(id: String) {
        guard let item = items.first(where: { $0.id == id }), item.state == .failed || item.state == .paused else { return }
        start(id)
    }

    public func completedItem(videoID: String) -> DownloadItem? {
        items.first { $0.video.id == videoID && $0.state == .completed }
    }

    // MARK: - Extras

    /// What the downloads of this video kept (SponsorBlock segments, chapters, captions: see `DownloadExtras`); nil when
    /// nothing was kept, which is the case for downloads made before this existed. Read off the main actor.
    public func extras(forVideoID videoID: String) async -> DownloadExtras? {
        await extrasStore.loadOffMainActor(videoID: videoID)
    }

    /// Keeps `extras` with the downloads of the video, over what is kept already (`DownloadExtras.merging`): the parts
    /// that are nil change nothing. For the player, which asks the live services while a download plays and has an
    /// answer then; that is how downloads made before the extras were kept get them. Does nothing for a video without a
    /// download.
    public func saveExtras(_ extras: DownloadExtras, forVideoID videoID: String) {
        guard !extras.isEmpty, items.contains(where: { $0.video.id == videoID }) else { return }
        extrasStore.merge(extras, videoID: videoID)
    }

    /// Deletes the extras of a video once none of its downloads is left in the list (there is one file per video, shared
    /// by its qualities).
    private func removeExtrasIfUnused(videoID: String) {
        guard !items.contains(where: { $0.video.id == videoID }) else { return }
        extrasStore.remove(videoID: videoID)
    }

    /// Asks the provider for the extras of the video that is about to download, for at most `extrasTimeout`; nil when
    /// there is no provider, nothing is known, or time ran out.
    private func fetchExtras(for info: StreamInfo) async -> DownloadExtras? {
        guard let provider = extrasProvider else { return nil }
        let extras = await TimeBox.run(tuning.extrasTimeout) { await provider.extras(for: info) }
        guard let extras, !extras.isEmpty else { return nil }
        return extras
    }

    /// The download that a row of the quality sheet stands for: the item of this video whose rendition is the one the row
    /// names, whatever it was asked for as (a download asked for as "up to 720p" of a video that stops at 144p is the
    /// 144p row's download). When several qualify, the one that works wins: finished, then running, then paused, then
    /// failed.
    public func item(for option: DownloadOption, videoID: String) -> DownloadItem? {
        func rank(_ state: DownloadState) -> Int {
            switch state {
            case .completed: return 0
            case .queued, .downloading, .merging: return 1
            case .paused: return 2
            case .failed: return 3
            }
        }
        return items
            .filter { $0.video.id == videoID && $0.effectiveQuality == option.quality }
            .min { rank($0.state) < rank($1.state) }
    }

    /// The file of a finished item, resolved against the downloads root; nil while it has no file (or its file was
    /// deleted from outside the app).
    public func fileURL(for item: DownloadItem) -> URL? {
        Self.finishedFile(of: item, in: rootDirectory)
    }

    /// Total size of the finished downloads. It does not count what downloads that are not finished have fetched; that is
    /// `diskUsage()`.
    public var bytesOnDisk: Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + ($1.bytesTotal ?? $1.bytesDownloaded) }
    }

    /// Everything the downloads take on disk, in bytes: the finished files, and what downloads that are not finished
    /// have fetched so far, whether they are running, paused, or failed with their parts kept for a retry. This is the
    /// number to show as "space used". Measured on disk, off the main actor, so ask for it from a task, not from a
    /// view's body.
    public func diskUsage() async -> Int64 {
        await DownloadAssembler.diskUsage(under: rootDirectory)
    }

    /// Called from the app delegate when iOS relaunches the app for finished background transfers. `completionHandler`
    /// is kept until the session has delivered all its events; for any other session it is called at once.
    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        engine.registerBackgroundCompletion(identifier: identifier, handler: completionHandler)
    }

    // MARK: - Starting

    private static func itemID(video: VideoSummary, quality: DownloadQuality) -> String {
        "\(video.id)-\(quality.key)"
    }

    /// The height of the video rendition `plan` fetches, as the quality sheet names it; nil for audio only.
    private static func renditionHeight(of plan: DownloadJobPlan) -> Int? {
        plan.video.flatMap(FormatSelector.resolution(of:))
    }

    /// Begins (or begins again) the item: resolve fresh stream URLs, plan, prepare the directory, start the tasks.
    /// `refreshingLinks` is the item's own restart after its stream addresses stopped working (see `refreshLinks`).
    private func start(_ id: String, refreshingLinks: Bool = false) {
        if let previous = starts.removeValue(forKey: id) { previous.task.cancel() }
        if let stale = jobs.removeValue(forKey: id) { stale.assembly?.cancel() }
        reservedNames.removeValue(forKey: id)
        // It picks its streams again, from fresh stream info.
        chosenStreams.removeValue(forKey: id)
        // A start the person asked for gets an automatic refresh of its own.
        if !refreshingLinks { refreshedLinks.remove(id) }

        update(id) { item in
            item.state = .queued
            if !refreshingLinks {
                // A refresh picks up where the item was, so its bar does not drop to zero for a moment.
                item.progress = 0
                item.bytesDownloaded = 0
                item.bytesTotal = nil
            }
            item.relativeFilePath = nil
            item.errorMessage = nil
        }
        let generation = UUID()
        // The start runs on time borrowed from the system, asked for here with the request: a download is started with a
        // tap, and the phone is often locked or left right after it, so that iOS suspends the app moments later. The chunk
        // tasks, which the background session carries on with, only exist once the start has got through its lookups (the
        // stream info, the free space and, for a first start, the extras of the video, which can take up to `extrasTimeout`).
        // Without the borrowed time the download would wait for the person to come back to the app. A restart after the
        // stream addresses went stale (`refreshLinks`) needs it as much: the phone has just left the Wi-Fi they were made
        // for. It ends with `run`: the chunk tasks are created, or the item failed, was cancelled or was dropped.
        let borrowedTime = tuning.backgroundTime(refreshingLinks ? "No Slop refresh links" : "No Slop start")
        let task = Task { [weak self] in
            defer { borrowedTime.end() }
            guard let self else { return }
            // A restart after the addresses went stale has asked for the extras at its first start already.
            await run(id, generation: generation, fetchesExtras: !refreshingLinks)
        }
        starts[id] = DownloadStart(generation: generation, task: task)
    }

    /// The stream addresses of a running item stopped working: starts it over with fresh ones, once. The chunks that
    /// are on disk stay, so only the missing ones are fetched again.
    private func refreshLinks(of id: String) {
        teardown(id, keepingWork: true)
        refreshedLinks.insert(id)
        start(id, refreshingLinks: true)
    }

    private func run(_ id: String, generation: UUID, fetchesExtras: Bool) async {
        var keepWork = false
        do {
            guard let item = items.first(where: { $0.id == id }) else { return }
            let info: StreamInfo
            do {
                info = try await streams.streamInfo(videoID: item.video.id)
            } catch {
                // Offline or throttled: what an interrupted earlier attempt already fetched stays for the next retry.
                keepWork = Self.isTransient(error)
                throw error
            }
            try ensureStarting(id, generation)

            let plan = try Self.makePlan(for: item, info: info, tuning: tuning)

            // Asked for as another quality, but the very same streams are already downloaded or on their way: there
            // is nothing to fetch. Nothing suspends between this check and the claim below, so two requests that
            // resolve at the same time cannot both get through.
            let chosen = DownloadStreams(plan)
            if let original = existingDownload(fetching: chosen, besides: item, info: info) {
                dropDuplicate(id, of: original)
                return
            }
            chosenStreams[id] = chosen

            // Whatever an earlier attempt left running must be gone before its directory is touched.
            engine.cancelTasks(itemID: id)
            await engine.cancelInheritedTasks(itemID: id)
            try ensureStarting(id, generation)
            let present = try await DownloadAssembler.prepare(plan: plan, workspace: workspace)
            try ensureStarting(id, generation)

            // Fetching what is missing takes room, and so does the merge at the end: it writes a second copy before the
            // streams are removed. Better to say so now than after gigabytes have arrived (maybe over mobile data) and the
            // device is full. What is on disk already is not asked for again, and the parts stay for the next try.
            let needed = DownloadSpace.needed(totalBytes: plan.totalBytes, presentBytes: present.bytes)
            if let free = await DownloadAssembler.freeSpace(at: rootDirectory, using: tuning.availableCapacity), free < needed {
                throw DownloadFailure.notEnoughSpace(needed: needed, free: free)
            }
            try ensureStarting(id, generation)

            // The extras of the video are fetched now, while there is a connection for sure: chunks can finish with the
            // app suspended or relaunched, and the download is played on a plane. Before the first chunk is requested, so
            // that nothing depends on the app still running when the last one arrives. A failure, or the time-box running
            // out, only means that the video plays without them.
            if fetchesExtras {
                let extras = await fetchExtras(for: info)
                try ensureStarting(id, generation)
                if let extras { extrasStore.merge(extras, videoID: item.video.id) }
            }

            starts[id] = nil
            let job = DownloadJob(plan: plan, generation: generation, present: present)
            jobs[id] = job
            update(id) { item in
                item.state = .downloading
                item.renditionHeight = Self.renditionHeight(of: plan)
                item.bytesTotal = plan.totalBytes
                item.bytesDownloaded = present.bytes
                item.progress = plan.totalBytes > 0 ? Double(present.bytes) / Double(plan.totalBytes) : 0
            }
            if job.isComplete {
                beginAssembly(id)
            } else {
                await schedule(job.missingChunks(), id: id, generation: generation)
            }
        } catch is CancellationError {
            // Cancelled, deleted or started again: whoever did that has taken care of the item. A directory this
            // attempt created after that point is nobody's, unless a newer attempt is already using it.
            if starts[id] == nil, jobs[id] == nil { workspace.discard(itemID: id) }
        } catch {
            guard starts[id]?.generation == generation || jobs[id]?.generation == generation else { return }
            fail(id, error: error, keepingWork: keepWork)
        }
    }

    /// True for failures that say nothing about the video itself: no connection, a throttled or busy server.
    private static func isTransient(_ error: any Error) -> Bool {
        if error is URLError { return true }
        switch error as? NoSlopError {
        case .network, .botCheck, .cancelled: return true
        case .http(let status): return status >= 500 || status == 429
        default: return false
        }
    }

    private func ensureStarting(_ id: String, _ generation: UUID) throws {
        guard starts[id]?.generation == generation else { throw CancellationError() }
    }

    /// Starts the chunk tasks in small batches so a download of thousands of chunks never holds the main thread.
    private func schedule(_ chunks: [DownloadChunk], id: String, generation: UUID) async {
        var index = 0
        while index < chunks.count {
            guard jobs[id]?.generation == generation else { return }
            let end = min(index + 25, chunks.count)
            engine.start(Array(chunks[index..<end]))
            index = end
            if index < chunks.count { await Task.yield() }
        }
    }

    /// Picks the formats and works out everything the download needs to know up front.
    static func makePlan(for item: DownloadItem, info: StreamInfo, tuning: DownloadTuning) throws -> DownloadJobPlan {
        guard !info.isLive else { throw DownloadFailure.liveStream }
        guard let selected = FormatSelector.select(from: info.formats, quality: item.quality) else {
            throw DownloadFailure.noDownloadableFormat
        }
        guard let audio = Self.withKnownLength(selected.audio) else { throw DownloadFailure.unknownSize }
        var video: StreamFormat?
        if let chosen = selected.video {
            guard let sized = Self.withKnownLength(chosen) else { throw DownloadFailure.unknownSize }
            video = sized
        }
        // Thousands of chunks are fine; a value that implies millions is a broken response.
        let limit: Int64 = 64 * 1_073_741_824
        guard (audio.contentLength ?? 0) <= limit, (video?.contentLength ?? 0) <= limit else { throw DownloadFailure.tooLarge }

        let reference = video ?? audio
        let fromFormat = reference.approxDurationMs.map { Double($0) / 1000 } ?? 0
        let duration = fromFormat > 0 ? fromFormat : Double(max(0, info.lengthSeconds))
        let title = item.video.title.isEmpty ? info.title : item.video.title

        return DownloadJobPlan(
            itemID: item.id,
            videoID: item.video.id,
            title: title,
            video: video,
            audio: audio,
            durationSeconds: duration,
            chunkSize: tuning.chunkSize,
            fileExtension: video == nil ? "m4a" : "mp4"
        )
    }

    /// The format with its size set: from `contentLength`, else from the `clen` query item googlevideo URLs carry.
    private static func withKnownLength(_ format: StreamFormat) -> StreamFormat? {
        var format = format
        if let length = format.contentLength, length > 0 { return format }
        guard let components = URLComponents(url: format.url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "clen" })?.value,
              let length = Int64(text), length > 0
        else { return nil }
        format.contentLength = length
        return format
    }

    // MARK: - Equal streams

    /// Another item of the same video that has not failed and fetches (or fetched) exactly `streams`.
    private func existingDownload(fetching streams: DownloadStreams, besides item: DownloadItem, info: StreamInfo) -> DownloadItem? {
        items.first { other in
            other.id != item.id
                && other.video.id == item.video.id
                && fetchedStreams(of: other, matching: info) == streams
        }
    }

    /// The streams of an item that has not failed. nil when they are not known: the item is still asking YouTube for
    /// its streams (it will compare itself with the item that is being checked when its turn comes), it failed, or its
    /// file is gone.
    private func fetchedStreams(of item: DownloadItem, matching info: StreamInfo) -> DownloadStreams? {
        switch item.state {
        case .failed:
            return nil
        case .queued, .downloading, .merging:
            return chosenStreams[item.id]
        case .paused:
            return chosenStreams[item.id]
                ?? workspace.loadPlan(for: item.id).map(DownloadStreams.init)
                ?? streamsToday(of: item, info: info)
        case .completed:
            guard fileURL(for: item) != nil else { return nil }
            return chosenStreams[item.id] ?? streamsToday(of: item, info: info)
        }
    }

    /// What the item's quality picks from the formats YouTube offers now. A download of an earlier launch kept its
    /// file but not the itags of its streams; itags name fixed renditions, so this is what it got.
    private func streamsToday(of item: DownloadItem, info: StreamInfo) -> DownloadStreams? {
        FormatSelector.select(from: info.formats, quality: item.quality).map(DownloadStreams.init)
    }

    /// The item asks for streams `original` has: it leaves the list instead of fetching them a second time.
    private func dropDuplicate(_ id: String, of original: DownloadItem) {
        cancel(id: id)
        // Someone asked for this video: an original that is only paused picks up where it stopped.
        if original.state == .paused { start(original.id) }
    }

    // MARK: - Events

    /// Applies what the session delegate reported. Internal so tests can play the part of a relaunched session.
    func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let itemID, let inFlight):
            guard ensureJob(itemID), jobs[itemID]?.assembly == nil else { return }
            jobs[itemID]?.inFlightBytes = inFlight
            publishProgress(itemID)

        case .chunkFinished(let descriptor, let bytes, let inFlight):
            let itemID = descriptor.itemID
            guard ensureJob(itemID), var job = jobs[itemID], job.assembly == nil, job.plan.contains(descriptor) else { return }
            if job.done.insert(descriptor).inserted { job.doneBytes += bytes }
            job.inFlightBytes = inFlight
            jobs[itemID] = job
            publishProgress(itemID)
            if job.isComplete { beginAssembly(itemID) }

        case .chunkFailed(let descriptor, let failure, let inFlight):
            let itemID = descriptor.itemID
            guard ensureJob(itemID), var job = jobs[itemID], job.assembly == nil,
                  let chunk = job.plan.chunk(for: descriptor), !job.done.contains(descriptor)
            else { return }
            job.inFlightBytes = inFlight
            jobs[itemID] = job

            // An address that no longer works answers every chunk the same way (a phone that moves from its Wi-Fi to
            // the mobile network makes all of them 403), and asking it again changes nothing: ask YouTube for new ones,
            // once, and carry on with the chunks that are missing.
            if failure.isDeadLink, !refreshedLinks.contains(itemID) {
                refreshLinks(of: itemID)
                return
            }

            let used = job.retries[descriptor, default: 0]
            guard failure != .outOfSpace, used < tuning.maxChunkRetries else {
                // What was fetched stays: the retry gets fresh addresses and fetches only what is missing.
                fail(itemID, error: failure, keepingWork: true)
                return
            }
            job.retries[descriptor] = used + 1
            jobs[itemID] = job
            retryChunk(chunk, attempt: used + 1, generation: job.generation)
        }
    }

    /// Starts the chunk's task again after a pause that grows with each attempt.
    private func retryChunk(_ chunk: DownloadChunk, attempt: Int, generation: UUID) {
        let delay = tuning.retryDelay * attempt
        Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, jobs[chunk.descriptor.itemID]?.generation == generation else { return }
            engine.start([chunk])
        }
    }

    private func publishProgress(_ itemID: String) {
        guard let job = jobs[itemID] else { return }
        let total = job.plan.totalBytes
        guard total > 0 else { return }
        let downloaded = min(total, job.doneBytes + job.inFlightBytes)
        update(itemID, persist: false) { item in
            guard item.state == .downloading else { return }
            // Never backwards: a chunk that starts over drops its in-flight bytes.
            let bytes = max(item.bytesDownloaded, downloaded)
            item.bytesDownloaded = bytes
            item.progress = min(1, Double(bytes) / Double(total))
        }
    }

    // MARK: - Resuming

    /// Makes sure there is a job for an item that events arrive for. After a relaunch the first chunk to finish can
    /// be delivered before (or without) the reconciliation having run, so the job is rebuilt from the plan and the
    /// parts on disk. False when nothing is waiting for this item.
    private func ensureJob(_ itemID: String) -> Bool {
        jobs[itemID] != nil || restoreJob(itemID)
    }

    @discardableResult
    private func restoreJob(_ itemID: String) -> Bool {
        guard jobs[itemID] == nil, starts[itemID] == nil,
              let item = items.first(where: { $0.id == itemID }),
              item.state == .downloading || item.state == .merging || item.state == .paused,
              let plan = workspace.loadPlan(for: itemID), plan.itemID == itemID
        else { return false }

        let present = DownloadAssembler.present(in: plan, workspace: workspace)
        jobs[itemID] = DownloadJob(plan: plan, generation: UUID(), present: present)
        chosenStreams[itemID] = DownloadStreams(plan)
        update(itemID) { item in
            item.state = .downloading
            item.errorMessage = nil
            item.renditionHeight = Self.renditionHeight(of: plan)
            item.bytesTotal = plan.totalBytes
            item.bytesDownloaded = max(item.bytesDownloaded, present.bytes)
            item.progress = plan.totalBytes > 0 ? min(1, Double(item.bytesDownloaded) / Double(plan.totalBytes)) : 0
        }
        return true
    }

    /// After a launch: asks the session what it kept. Items it still has tasks for continue; items whose parts are
    /// all on disk finish merging without any network; the rest stay paused for the user to retry.
    private func reconcile(restoredIDs: [String]) async {
        let live = await engine.liveChunks()
        let liveIDs = Set(live.map(\.itemID))

        for id in restoredIDs {
            guard let item = items.first(where: { $0.id == id }), item.state == .paused,
                  jobs[id] == nil, starts[id] == nil
            else { continue }

            if liveIDs.contains(id) {
                guard restoreJob(id), let job = jobs[id] else {
                    await engine.cancelInheritedTasks(itemID: id)
                    continue
                }
                let missing = job.missingChunks().filter { !live.contains($0.descriptor) }
                if job.isComplete {
                    beginAssembly(id)
                } else if !missing.isEmpty {
                    await schedule(missing, id: id, generation: job.generation)
                }
            } else if let plan = workspace.loadPlan(for: id) {
                let present = await scan(plan)
                // Events may have taken the item over while the directory was being read.
                guard items.first(where: { $0.id == id })?.state == .paused, jobs[id] == nil, starts[id] == nil else { continue }
                if present.chunks.count == plan.chunkCount {
                    if restoreJob(id) { beginAssembly(id) }
                } else if plan.totalBytes > 0 {
                    // A paused item shows how much of it is on disk, not what the last save happened to say.
                    update(id) { item in
                        item.renditionHeight = Self.renditionHeight(of: plan)
                        item.bytesTotal = plan.totalBytes
                        item.bytesDownloaded = present.bytes
                        item.progress = min(1, Double(present.bytes) / Double(plan.totalBytes))
                    }
                }
            }
        }

        // Tasks nobody here knows about would download for nothing.
        for id in liveIDs where !items.contains(where: { $0.id == id }) {
            await engine.cancelInheritedTasks(itemID: id)
        }
    }

    /// Which chunks of `plan` are on disk, read off the main actor (a long video has thousands of them).
    private func scan(_ plan: DownloadJobPlan) async -> DownloadAssembler.Present {
        let workspace = workspace
        return await Task.detached { DownloadAssembler.present(in: plan, workspace: workspace) }.value
    }

    // MARK: - Merging

    private func beginAssembly(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), var job = jobs[id], job.assembly == nil else { return }
        let plan = job.plan
        let workspace = workspace
        let mux = tuning.mux
        let backgroundTime = tuning.backgroundTime
        let destination = reserveDestination(for: item, plan: plan)
        let generation = job.generation

        job.destination = destination
        job.assembly = Task { [weak self] in
            // A download that finishes while the app is suspended is merged right then, on borrowed time.
            let extraTime = backgroundTime("No Slop merge")
            defer { extraTime.end() }
            do {
                let size = try await DownloadAssembler.assemble(plan: plan, workspace: workspace, destination: destination, mux: mux)
                self?.assemblyFinished(id, generation: generation, destination: destination, size: size)
            } catch {
                self?.assemblyFailed(
                    id, generation: generation, destination: destination, error: error, backgroundTimeRanOut: extraTime.expired
                )
            }
        }
        jobs[id] = job
        update(id) { item in
            item.state = .merging
            item.progress = 1
            item.bytesDownloaded = plan.totalBytes
            item.errorMessage = nil
        }
    }

    private func assemblyFinished(_ id: String, generation: UUID, destination: URL, size: Int64) {
        guard jobs[id]?.generation == generation else {
            // Cancelled or deleted while merging: the new file belongs to nobody.
            try? FileManager.default.removeItem(at: destination)
            return
        }
        jobs.removeValue(forKey: id)
        reservedNames.removeValue(forKey: id)
        refreshedLinks.remove(id)
        workspace.discard(itemID: id)
        update(id) { item in
            item.state = .completed
            item.progress = 1
            item.bytesDownloaded = size
            item.bytesTotal = size
            item.relativeFilePath = destination.lastPathComponent
            item.errorMessage = nil
        }
    }

    private func assemblyFailed(_ id: String, generation: UUID, destination: URL, error: any Error, backgroundTimeRanOut: Bool) {
        guard jobs[id]?.generation == generation else { return }
        if error is CancellationError { return }
        try? FileManager.default.removeItem(at: destination)
        fail(id, error: error, keepingWork: Self.keepsStreams(afterMergeFailure: error, backgroundTimeRanOut: backgroundTimeRanOut))
    }

    /// Whether the downloaded streams are worth keeping after the merge failed with `error`. They are, unless the merge
    /// showed the files themselves to be bad (a stream that cannot be read, has no track, or is empty): then a retry
    /// has to download them again. A failure that says nothing about the files (the export was interrupted, the disk was
    /// full or could not be written, a part went missing) keeps them, so the retry only merges again. So does any
    /// failure after iOS ended the extra background time: the app was about to be suspended in the middle of the merge.
    nonisolated static func keepsStreams(afterMergeFailure error: any Error, backgroundTimeRanOut: Bool) -> Bool {
        backgroundTimeRanOut || DownloadFailure.from(error).keepsDownloadedData
    }

    /// A file name for the finished download: "<title> [<id>].mp4", then with the quality, then numbered, so that two
    /// qualities of one video (or two videos with one title) never overwrite each other.
    private func reserveDestination(for item: DownloadItem, plan: DownloadJobPlan) -> URL {
        var claimed = Set(items.filter { $0.id != item.id }.compactMap { $0.relativeFilePath?.lowercased() })
        for (otherID, name) in reservedNames where otherID != item.id { claimed.insert(name) }
        let root = rootDirectory
        let destination = DownloadFileNaming.destination(
            in: root,
            baseName: DownloadFileNaming.baseName(title: plan.title, videoID: plan.videoID),
            fileExtension: plan.fileExtension,
            qualityLabel: item.qualityLabel
        ) { name in
            claimed.contains(name.lowercased()) || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        reservedNames[item.id] = destination.lastPathComponent.lowercased()
        return destination
    }

    // MARK: - Failing and stopping

    /// Stops everything for the item, removes its work directory (unless `keepingWork`) and shows why it failed.
    /// A full disk, or a merge the system interrupted, is not the download's fault: what was fetched stays, and a
    /// retry after making room carries on.
    private func fail(_ id: String, error: any Error, keepingWork: Bool = false) {
        teardown(id, keepingWork: keepingWork || (error as? DownloadFailure)?.keepsDownloadedData == true)
        let message = Self.message(for: error)
        update(id) { item in
            item.state = .failed
            item.progress = 0
            item.bytesDownloaded = 0
            item.errorMessage = message
        }
    }

    /// Cancels the tasks, the merge and any pending start of the item, and removes its work directory (unless
    /// `keepingWork`).
    private func teardown(_ id: String, keepingWork: Bool = false) {
        if let pending = starts.removeValue(forKey: id) { pending.task.cancel() }
        if let job = jobs.removeValue(forKey: id) {
            job.assembly?.cancel()
            if let destination = job.destination { try? FileManager.default.removeItem(at: destination) }
        }
        reservedNames.removeValue(forKey: id)
        chosenStreams.removeValue(forKey: id)
        refreshedLinks.remove(id)
        engine.cancelTasks(itemID: id)
        let engine = engine
        Task { await engine.cancelInheritedTasks(itemID: id) }
        if !keepingWork { workspace.discard(itemID: id) }
    }

    private static func message(for error: any Error) -> String {
        if let text = (error as? any LocalizedError)?.errorDescription, !text.isEmpty { return text }
        return DownloadFailure.from(error).errorDescription ?? error.localizedDescription
    }

    // MARK: - Items

    private func update(_ id: String, persist: Bool = true, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        if persist { saveItems() }
    }

    private func saveItems() {
        store.save(items)
    }

    /// The file of a completed item, if it is inside `root` and still exists.
    nonisolated private static func finishedFile(of item: DownloadItem, in root: URL) -> URL? {
        guard item.state == .completed, let relativeFilePath = item.relativeFilePath, !relativeFilePath.isEmpty else { return nil }
        let url = root.appendingPathComponent(relativeFilePath)
        // downloads.json is a file a person can edit: "../../x" must not point outside the downloads folder.
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}

// MARK: - Notifications

#if canImport(UIKit) && !os(watchOS)
/// Holds the manager's notification observers and removes them when the manager goes away.
private final class NotificationObservers: @unchecked Sendable {
    // Only touched on the main thread while the manager is created, and when it is released.
    private var tokens: [any NSObjectProtocol] = []

    func add(_ token: any NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
#endif

// MARK: - Background time

/// Running time borrowed from the system for a stretch of work: held from `BackgroundTime.init` until `end()`.
@MainActor
protocol BackgroundTimeHolding: AnyObject, Sendable {
    /// True once iOS said the time is up: the app is about to be suspended.
    var expired: Bool { get }
    /// Gives the time back. Does nothing the second time.
    func end()
}

/// Asks for the running time of a named stretch of work (`DownloadTuning.backgroundTime`).
typealias BackgroundTimeSource = @MainActor @Sendable (_ name: String) -> any BackgroundTimeHolding

#if canImport(UIKit) && !os(watchOS)
/// Asks iOS for a little more running time while the start of a download, a merge or a refresh of stream addresses is in
/// progress, so that a download that is started or completes while the app is in the background is carried on before the
/// app is suspended again.
@MainActor
final class BackgroundTime: BackgroundTimeHolding {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    /// True once iOS said the time is up: the app is about to be suspended, so whatever fails after that did not fail
    /// because of the files.
    private(set) var expired = false

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.expired = true
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#else
@MainActor
final class BackgroundTime: BackgroundTimeHolding {
    let expired = false

    init(name: String) {}
    func end() {}
}
#endif

// MARK: - Runtime state

/// Which streams a download fetches: the itags of its video (none for audio only) and of its audio. Two downloads of
/// one video with the same streams are the same file, whatever quality they were asked for as.
private struct DownloadStreams: Hashable {
    var video: Int?
    var audio: Int

    init(_ plan: DownloadJobPlan) {
        video = plan.video?.itag
        audio = plan.audio.itag
    }

    init(_ selected: SelectedFormats) {
        video = selected.video?.itag
        audio = selected.audio.itag
    }
}

/// An item that is resolving its URLs and preparing its directory.
private struct DownloadStart {
    var generation: UUID
    var task: Task<Void, Never>
}

/// An item whose chunk tasks exist.
private struct DownloadJob {
    var plan: DownloadJobPlan
    /// Tells this attempt from an earlier one of the same item.
    var generation: UUID
    var done: Set<DownloadTaskDescriptor>
    var doneBytes: Int64
    /// What the running chunks have written, as last reported.
    var inFlightBytes: Int64 = 0
    var retries: [DownloadTaskDescriptor: Int] = [:]
    var assembly: Task<Void, Never>?
    var destination: URL?
    let chunkCount: Int

    init(plan: DownloadJobPlan, generation: UUID, present: DownloadAssembler.Present) {
        self.plan = plan
        self.generation = generation
        self.done = present.chunks
        self.doneBytes = present.bytes
        self.chunkCount = plan.chunkCount
    }

    var isComplete: Bool { done.count >= chunkCount }

    func missingChunks() -> [DownloadChunk] {
        plan.chunks().filter { !done.contains($0.descriptor) }
    }
}

// MARK: - File names

enum DownloadFileNaming {
    static let maxTitleLength = 80
    /// A file name may be 255 bytes; 80 characters of emoji or CJK can be 320.
    private static let maxTitleBytes = 200

    /// Replaces `/ : \ ? % * | " < >` with "-" and control characters (new lines, tabs, NUL) with a space.
    static func replaceForbidden(_ text: String) -> String {
        let forbidden: Set<Character> = ["/", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"]
        return String(text.map { character -> Character in
            if forbidden.contains(character) { return "-" }
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return " " }
            return character
        })
    }

    /// A title that is safe as part of a file name: forbidden characters replaced, trimmed, no leading dot (the
    /// file would be hidden), no trailing dot, at most 80 characters.
    static func sanitizedTitle(_ title: String) -> String {
        var text = replaceForbidden(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingDots = text.prefix { $0 == "." }.count
        text = String(repeating: "-", count: leadingDots) + text.dropFirst(leadingDots)
        text = String(text.prefix(maxTitleLength))
        while text.utf8.count > maxTitleBytes { text.removeLast() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return text.isEmpty ? "Video" : text
    }

    /// "<sanitized title> [<video id>]"
    static func baseName(title: String, videoID: String) -> String {
        let id = replaceForbidden(videoID).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(sanitizedTitle(title)) [\(id)]"
    }

    /// `<baseName>.<ext>`; when `isTaken` says that name is in use, `<baseName> (<quality>).<ext>`, then
    /// `<baseName> (<quality>) 2.<ext>` and so on.
    static func destination(
        in directory: URL,
        baseName: String,
        fileExtension: String,
        qualityLabel: String,
        isTaken: (String) -> Bool
    ) -> URL {
        func name(_ stem: String) -> String { "\(stem).\(fileExtension)" }
        if !isTaken(name(baseName)) { return directory.appendingPathComponent(name(baseName)) }
        let withQuality = "\(baseName) (\(qualityLabel))"
        if !isTaken(name(withQuality)) { return directory.appendingPathComponent(name(withQuality)) }
        for number in 2..<10_000 where !isTaken(name("\(withQuality) \(number)")) {
            return directory.appendingPathComponent(name("\(withQuality) \(number)"))
        }
        return directory.appendingPathComponent(name("\(withQuality) \(UUID().uuidString)"))
    }
}

// MARK: - Persistence

/// `downloads.json`: the list of items as a JSON array. Missing keys decode to defaults, an element that cannot be
/// read is skipped (and the file kept as `downloads.json.corrupt`), and a file that is not a list at all is moved
/// aside instead of deleted.
///
/// A file that exists but cannot be read (no permission, data protection before the first unlock, an I/O error) says
/// nothing about its content, which may be perfectly good: `load` reports it as `.unreadable`, the file stays where it
/// is, and `save` refuses to write over it for the rest of the process, until a load of it succeeds. Otherwise a launch
/// while the device is locked would replace the list of downloads with a new, nearly empty one. (`JSONFileStore` does
/// the same for the library.) Only a file that is not there at all is a first launch.
struct DownloadItemStore: Sendable {
    let fileURL: URL
    private let read: @Sendable (URL) throws -> Data

    init(fileURL: URL) {
        self.init(fileURL: fileURL, read: { try Data(contentsOf: $0) })
    }

    /// Tests inject the reader to make reading fail the way a device can.
    init(fileURL: URL, read: @escaping @Sendable (URL) throws -> Data) {
        self.fileURL = fileURL
        self.read = read
    }

    enum Contents: Equatable {
        /// The items; none when there is no file yet (first launch) or the file was not a list.
        case items([DownloadItem])
        /// The file is there but the system would not give its content.
        case unreadable
    }

    /// The files (by path) that exist but could not be read. Process-wide on purpose: whoever created the store that saw
    /// the failure, no store in this process may write over such a file until one of them has read it.
    private static let unreadableFiles = Mutex<Set<String>>([])

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func isUnreadable(_ url: URL) -> Bool {
        unreadableFiles.withLock { $0.contains(key(for: url)) }
    }

    private func markReadable() {
        Self.unreadableFiles.withLock { _ = $0.remove(Self.key(for: fileURL)) }
    }

    private struct Lossy<Element: Decodable>: Decodable {
        let value: Element?

        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    private struct Envelope: Decodable {
        let items: [Lossy<DownloadItem>]
    }

    func load() -> Contents {
        let data: Data
        do {
            data = try read(fileURL)
            markReadable()
        } catch {
            if JSONFileStore.isMissing(error) {
                markReadable()
                return .items([])
            }
            Self.unreadableFiles.withLock { _ = $0.insert(Self.key(for: fileURL)) }
            return .unreadable
        }
        let decoder = Self.makeDecoder()

        let elements: [Lossy<DownloadItem>]
        if let array = try? decoder.decode([Lossy<DownloadItem>].self, from: data) {
            elements = array
        } else if let envelope = try? decoder.decode(Envelope.self, from: data) {
            elements = envelope.items
        } else {
            moveAside()
            return .items([])
        }

        let items = elements.compactMap(\.value)
        if items.count < elements.count { keepCopyOfUnreadableFile() }
        return .items(items)
    }

    /// Writes the list, unless the file exists and could not be read (see the type's documentation).
    func save(_ items: [DownloadItem]) {
        guard !Self.isUnreadable(fileURL) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // The list in memory is still right; the next change tries again.
        }
    }

    /// Dates as written by `JSONEncoder`'s default (seconds since 2001) or as ISO 8601 text.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date \(text)")
        }
        return decoder
    }

    private var corruptURL: URL { fileURL.appendingPathExtension("corrupt") }

    private func moveAside() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: corruptURL)
        try? fileManager.moveItem(at: fileURL, to: corruptURL)
    }

    private func keepCopyOfUnreadableFile() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: corruptURL)
        try? fileManager.copyItem(at: fileURL, to: corruptURL)
    }
}
