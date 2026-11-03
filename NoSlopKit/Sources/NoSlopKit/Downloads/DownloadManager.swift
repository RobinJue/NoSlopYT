import Foundation
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Chunked background downloads with duration-clamped muxing, and the list of downloaded videos.
///
/// A download is a list of 10 MiB HTTP Range requests, one URLSession task each, on a background session: they keep
/// going while the app is suspended or killed, and the system relaunches the app to say they are done. Finished
/// chunks land in `<root>/.work/<item id>/`; when all are there the manager concatenates them per stream, muxes video
/// and audio into one file whose tracks are cut to the true duration (see `MediaMuxer`), and moves it into
/// `<root>`. A half-written file is never marked completed: every file appears under its final name only when it is
/// whole.
///
/// Persistence: the list lives in `<root>/downloads.json`. Items that were in flight when the app last ran come
/// back `.paused` (their tasks are gone or unknown); the session is then asked what it kept, and those items pick up
/// where they were. `retry` asks YouTube for fresh stream URLs and reuses parts that are still valid.
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
    /// Items whose chunk tasks exist, by item id.
    @ObservationIgnored private var jobs: [String: DownloadJob] = [:]
    /// Items that are still resolving their stream URLs and preparing their directory.
    @ObservationIgnored private var starts: [String: DownloadStart] = [:]
    /// Lower-cased names of final files that merges in progress will create.
    @ObservationIgnored private var reservedNames: [String: String] = [:]

    /// - Parameter sessionConfiguration: nil means the background configuration with the global session id.
    public convenience init(rootDirectory: URL, streams: any StreamResolving, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.init(rootDirectory: rootDirectory, streams: streams, sessionConfiguration: sessionConfiguration, tuning: .standard)
    }

    init(rootDirectory: URL, streams: any StreamResolving, sessionConfiguration: URLSessionConfiguration?, tuning: DownloadTuning) {
        self.rootDirectory = rootDirectory
        self.streams = streams
        self.tuning = tuning
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
        var loaded = store.load()
        var restoredIDs: [String] = []
        var unfinishedIDs: Set<String> = []
        var changed = false
        for index in loaded.indices {
            switch loaded[index].state {
            case .queued, .downloading, .merging:
                loaded[index].state = .paused
                loaded[index].errorMessage = nil
                restoredIDs.append(loaded[index].id)
                unfinishedIDs.insert(loaded[index].id)
                changed = true
            case .paused:
                restoredIDs.append(loaded[index].id)
                unfinishedIDs.insert(loaded[index].id)
            case .failed:
                // A failed item has a work directory only when its parts were kept on purpose for the next retry.
                unfinishedIDs.insert(loaded[index].id)
            case .completed:
                if Self.finishedFile(of: loaded[index], in: rootDirectory) == nil {
                    loaded[index].state = .failed
                    loaded[index].relativeFilePath = nil
                    loaded[index].progress = 0
                    loaded[index].bytesDownloaded = 0
                    loaded[index].errorMessage = "The downloaded file is missing. Retry to download it again."
                    changed = true
                }
            }
        }
        items = loaded
        if changed { saveItems() }
        workspace.prune(keeping: unfinishedIDs)

        // Events are handled one at a time, in order, on the main actor.
        Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        Task { @MainActor [weak self] in
            await self?.reconcile(restoredIDs: restoredIDs)
        }
    }

    deinit {
        engine.shutdown()
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
    public func enqueue(video: VideoSummary, quality: DownloadQuality) {
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

    /// The file of a finished item, resolved against the downloads root; nil while it has no file (or its file was
    /// deleted from outside the app).
    public func fileURL(for item: DownloadItem) -> URL? {
        Self.finishedFile(of: item, in: rootDirectory)
    }

    /// Total size of the finished downloads.
    public var bytesOnDisk: Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + ($1.bytesTotal ?? $1.bytesDownloaded) }
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

    /// Begins (or begins again) the item: resolve fresh stream URLs, plan, prepare the directory, start the tasks.
    private func start(_ id: String) {
        if let previous = starts.removeValue(forKey: id) { previous.task.cancel() }
        if let stale = jobs.removeValue(forKey: id) { stale.assembly?.cancel() }
        reservedNames.removeValue(forKey: id)

        update(id) { item in
            item.state = .queued
            item.progress = 0
            item.bytesDownloaded = 0
            item.bytesTotal = nil
            item.relativeFilePath = nil
            item.errorMessage = nil
        }
        let generation = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await run(id, generation: generation)
        }
        starts[id] = DownloadStart(generation: generation, task: task)
    }

    private func run(_ id: String, generation: UUID) async {
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

            // Whatever an earlier attempt left running must be gone before its directory is touched.
            engine.cancelTasks(itemID: id)
            await engine.cancelInheritedTasks(itemID: id)
            try ensureStarting(id, generation)
            let present = try await DownloadAssembler.prepare(plan: plan, workspace: workspace)
            try ensureStarting(id, generation)

            starts[id] = nil
            let job = DownloadJob(plan: plan, generation: generation, present: present)
            jobs[id] = job
            update(id) { item in
                item.state = .downloading
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
            let used = job.retries[descriptor, default: 0]
            guard failure != .outOfSpace, used < tuning.maxChunkRetries else {
                jobs[itemID] = job
                fail(itemID, error: failure)
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
        update(itemID) { item in
            item.state = .downloading
            item.errorMessage = nil
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
        let destination = reserveDestination(for: item, plan: plan)
        let generation = job.generation

        job.destination = destination
        job.assembly = Task { [weak self] in
            // A download that finishes while the app is suspended is merged right then, on borrowed time.
            let extraTime = MergeBackgroundTime(name: "No Slop merge")
            defer { extraTime.end() }
            do {
                let size = try await DownloadAssembler.assemble(plan: plan, workspace: workspace, destination: destination)
                self?.assemblyFinished(id, generation: generation, destination: destination, size: size)
            } catch {
                self?.assemblyFailed(id, generation: generation, destination: destination, error: error)
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

    private func assemblyFailed(_ id: String, generation: UUID, destination: URL, error: any Error) {
        guard jobs[id]?.generation == generation else { return }
        if error is CancellationError { return }
        try? FileManager.default.removeItem(at: destination)
        fail(id, error: error)
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
            qualityLabel: item.quality.label
        ) { name in
            claimed.contains(name.lowercased()) || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        reservedNames[item.id] = destination.lastPathComponent.lowercased()
        return destination
    }

    // MARK: - Failing and stopping

    /// Stops everything for the item, removes its work directory (unless `keepingWork`) and shows why it failed.
    /// A full disk is not the download's fault: what was fetched stays, and a retry after making room carries on.
    private func fail(_ id: String, error: any Error, keepingWork: Bool = false) {
        teardown(id, keepingWork: keepingWork || (error as? DownloadFailure) == .outOfSpace)
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

// MARK: - Background time

#if canImport(UIKit) && !os(watchOS)
/// Asks iOS for a little more running time while a merge is in progress, so a download that completes while the
/// app is in the background is finished before the app is suspended again.
@MainActor
private final class MergeBackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
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
private final class MergeBackgroundTime {
    init(name: String) {}
    func end() {}
}
#endif

// MARK: - Runtime state

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
struct DownloadItemStore: Sendable {
    let fileURL: URL

    private struct Lossy<Element: Decodable>: Decodable {
        let value: Element?

        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    private struct Envelope: Decodable {
        let items: [Lossy<DownloadItem>]
    }

    func load() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.makeDecoder()

        let elements: [Lossy<DownloadItem>]
        if let array = try? decoder.decode([Lossy<DownloadItem>].self, from: data) {
            elements = array
        } else if let envelope = try? decoder.decode(Envelope.self, from: data) {
            elements = envelope.items
        } else {
            moveAside()
            return []
        }

        let items = elements.compactMap(\.value)
        if items.count < elements.count { keepCopyOfUnreadableFile() }
        return items
    }

    func save(_ items: [DownloadItem]) {
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
