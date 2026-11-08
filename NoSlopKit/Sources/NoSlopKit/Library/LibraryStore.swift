import Foundation
import Observation
import Synchronization

/// Everything the user keeps on the device: subscriptions, watch history with progress, Watch Later,
/// local playlists and recent searches.
///
/// ## Persistence
/// Each collection lives in a JSON file of its own in `directory` (`subscriptions.json`, `history.json`,
/// `watch-later.json`, `playlists.json`, `search-history.json`). The files are read once in `init`, on the main
/// actor, because a screen that opens right away must already see the data. A file that cannot be decoded is
/// renamed `<file>.corrupt` (see `JSONFileStore`) and that collection starts empty; the other files are unaffected.
/// If only some entries of a list cannot be read, the others are kept and written back to a clean file at once (the
/// original, damaged entries included, still goes to `.corrupt`).
///
/// A file that exists but cannot be read (the phone was restarted and not unlocked yet: iOS can start the app in the
/// background for a finished download before that) is not decoded, not moved aside and not written to; that collection
/// starts empty. `reloadIfUnreadable()` reads those files again once they can be read (the app calls it when the
/// protected data becomes available and when it becomes active) and merges what changed in memory meanwhile into what is
/// on disk; until then the changes live in memory only, and a launch that ends before it loses them.
///
/// ## What is kept of a video
/// A video is stored as it was when it was saved (Watch Later, a playlist) or watched (the history), minus what was
/// only true on that day: the relative age becomes a date, a stream that was live or a premiere that was upcoming is
/// neither any more, and the count of people watching or waiting is dropped (`VideoSummary.forLibrary`).
///
/// Changes are written in the background: the first change after a write starts a 0.5 s timer, and everything
/// that changed until it fires goes to disk together, encoded and written off the main thread. Writes happen in
/// the order they were started. `flush()` writes immediately and returns once the data is on disk, so call it
/// when the app goes to the background. `flushNow()` does the same without an `await`, blocking the caller for a
/// moment, for the one place where nothing can be awaited: the notice that the process is about to end. A process that
/// is killed without any notice loses the changes of the last half second.
///
/// A write that fails (the disk is full) is not forgotten: the collection stays marked as changed, is written again
/// with the next write or flush, and meanwhile on a timer with a growing pause (`retryDelay`, doubling up to a minute).
/// A collection whose file was refused as unreadable is not retried on the timer (that lasts until
/// `reloadIfUnreadable()` has read it), but it stays marked, so `flush()` and `flushNow()` say it is not on disk.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var subscriptions: [SubscribedChannel] = []
    /// Most recent first.
    public private(set) var history: [HistoryEntry] = []
    public private(set) var watchLater: [VideoSummary] = []
    public private(set) var playlists: [LocalPlaylist] = []
    /// Most recent first.
    public private(set) var searchHistory: [String] = []

    private static let historyLimit = 5000
    private static let searchHistoryLimit = 50

    private let files: JSONFileStore
    private let saveDelay: Duration
    private let now: @Sendable () -> Date

    // Bookkeeping that no view observes.
    /// Counts the changes made to the subscriptions by the viewer (subscribe, unsubscribe) and by a sign-out, but not
    /// the replacement of the Google ones by a sync. A sync reads it before it asks the account for its list and again
    /// when the list arrives (`syncGoogleSubscriptions`).
    @ObservationIgnored public private(set) var subscriptionRevision = 0
    /// The history by video id, so that looking up the progress of a thumbnail does not scan up to 5000 entries.
    /// Always holds exactly the entries of `history`.
    @ObservationIgnored private var historyByID: [String: HistoryEntry] = [:]
    @ObservationIgnored private var dirty: Set<LibraryFile> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerGeneration = 0
    /// The pending timer is a pause before trying a failed write again, not the usual delay after a change.
    @ObservationIgnored private var timerIsRetry = false
    /// Failed writes in a row since the last good one; the pause before the next try grows with it.
    @ObservationIgnored private var failedRounds = 0
    @ObservationIgnored private let retryDelay: Duration
    /// What the background writes report to the main actor, without the main actor: `flushNow` waits for them on the
    /// main thread, so they must never need it before they are counted as finished.
    @ObservationIgnored private let writeOutcomes = WriteLog()
    /// The files that came back unreadable when they were read (see `reloadIfUnreadable`).
    @ObservationIgnored private var unreadable: Set<LibraryFile> = []
    /// The most recent background write; each new write waits for the one before it.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    /// The background writes that were started and have not finished. `flushNow` waits on it; nothing else does.
    @ObservationIgnored private let writesInFlight = DispatchGroup()
    /// Runs in each background write before it touches a file. Tests slow a write down with it.
    @ObservationIgnored private let beforeWrite: (@Sendable () -> Void)?

    /// Loads the five files from `directory` (created on the first write).
    public convenience init(directory: URL) {
        self.init(directory: directory, saveDelay: .milliseconds(500), now: { Date() })
    }

    /// Tests choose the write delay and the clock, and can make the background writes slow.
    init(
        directory: URL,
        saveDelay: Duration,
        now: @escaping @Sendable () -> Date,
        beforeWrite: (@Sendable () -> Void)? = nil,
        retryDelay: Duration = .seconds(5)
    ) {
        let files = JSONFileStore(directory: directory)
        self.files = files
        self.saveDelay = saveDelay
        self.retryDelay = retryDelay
        self.now = now
        self.beforeWrite = beforeWrite

        subscriptions = Self.unique(files.loadList(LibraryFile.subscriptions.rawValue), by: \SubscribedChannel.id)
        // Videos that earlier builds stored with text that was only true on the day (see `VideoSummary.forLibrary`) are
        // corrected as they are read; the files are not rewritten for it. A history entry knows the day: it was
        // watched. Watch Later and the playlists keep no date per video, so their relative ages cannot be counted back
        // and are dropped.
        history = Array(Self.unique(files.loadList(LibraryFile.history.rawValue), by: \HistoryEntry.id).prefix(Self.historyLimit))
            .map { entry in
                var entry = entry
                entry.video = entry.video.forLibrary(savedAt: entry.lastWatchedAt)
                return entry
            }
        historyByID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        watchLater = Self.unique(files.loadList(LibraryFile.watchLater.rawValue), by: \VideoSummary.id)
            .map { $0.forLibrary(savedAt: nil) }
        playlists = Self.unique(files.loadList(LibraryFile.playlists.rawValue), by: \LocalPlaylist.id)
            .map { playlist in
                var playlist = playlist
                playlist.videos = playlist.videos.map { $0.forLibrary(savedAt: nil) }
                return playlist
            }
        searchHistory = Self.cleaned(files.loadList(LibraryFile.searchHistory.rawValue))
        unreadable = Set(LibraryFile.allCases.filter { files.isUnreadable($0.rawValue) })
    }

    // MARK: Files that could not be read

    /// Whether some file came back unreadable at launch and has not been read since.
    public var hasUnreadableFiles: Bool { !unreadable.isEmpty }

    /// Reads again the files that could not be read at launch, now that they may be: the device has been unlocked.
    /// Does nothing (and is cheap) when every file was read.
    ///
    /// What was changed in memory meanwhile is newer than the file and is kept: subscriptions, Watch Later and playlists
    /// are merged by id with the memory's entries first; for a video in both histories the newer entry wins (the
    /// stored duration is kept when the newer one has none); the searches of memory come before the stored ones. A merged
    /// collection that had content in memory is marked as changed, so the merge is written. A file that still cannot be
    /// read stays as it is and is tried again at the next call.
    public func reloadIfUnreadable() {
        for file in LibraryFile.allCases where unreadable.contains(file) {
            switch file {
            case .subscriptions:
                let stored = Self.unique(files.loadList(file.rawValue) as [SubscribedChannel], by: \.id)
                guard !files.isUnreadable(file.rawValue) else { continue }
                let known = Set(subscriptions.map(\.id))
                let added = stored.filter { !known.contains($0.id) }
                let hadContent = !subscriptions.isEmpty
                subscriptions += added
                if !added.isEmpty { subscriptionRevision += 1 }
                if hadContent { markDirty(file) }
            case .history:
                let stored = Self.unique(files.loadList(file.rawValue) as [HistoryEntry], by: \.id).map { entry in
                    var entry = entry
                    entry.video = entry.video.forLibrary(savedAt: entry.lastWatchedAt)
                    return entry
                }
                guard !files.isUnreadable(file.rawValue) else { continue }
                let hadContent = !history.isEmpty
                mergeHistory(stored)
                if hadContent { markDirty(file) }
            case .watchLater:
                let stored = Self.unique(files.loadList(file.rawValue) as [VideoSummary], by: \.id)
                guard !files.isUnreadable(file.rawValue) else { continue }
                let known = Set(watchLater.map(\.id))
                let hadContent = !watchLater.isEmpty
                watchLater += stored.filter { !known.contains($0.id) }.map { $0.forLibrary(savedAt: nil) }
                if hadContent { markDirty(file) }
            case .playlists:
                let stored = Self.unique(files.loadList(file.rawValue) as [LocalPlaylist], by: \.id)
                guard !files.isUnreadable(file.rawValue) else { continue }
                let known = Set(playlists.map(\.id))
                let hadContent = !playlists.isEmpty
                playlists += stored.filter { !known.contains($0.id) }.map { playlist in
                    var playlist = playlist
                    playlist.videos = playlist.videos.map { $0.forLibrary(savedAt: nil) }
                    return playlist
                }
                if hadContent { markDirty(file) }
            case .searchHistory:
                let stored: [String] = files.loadList(file.rawValue)
                guard !files.isUnreadable(file.rawValue) else { continue }
                let hadContent = !searchHistory.isEmpty
                searchHistory = Self.cleaned(searchHistory + stored)
                if hadContent { markDirty(file) }
            }
            unreadable.remove(file)
        }
    }

    /// Merges the stored history into the one in memory: one entry per video, the newer one (the memory's on a tie)
    /// with the duration of the other when it has none, most recent first, at most 5000.
    private func mergeHistory(_ stored: [HistoryEntry]) {
        guard !history.isEmpty else {
            history = Array(stored.prefix(Self.historyLimit))
            historyByID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return
        }
        var best = historyByID
        for entry in stored {
            guard var current = best[entry.id] else {
                best[entry.id] = entry
                continue
            }
            if entry.lastWatchedAt > current.lastWatchedAt {
                var newer = entry
                newer.durationSeconds = newer.durationSeconds ?? current.durationSeconds
                best[entry.id] = newer
            } else if current.durationSeconds == nil, let duration = entry.durationSeconds {
                current.durationSeconds = duration
                best[entry.id] = current
            }
        }
        // Memory first, then the stored entries that memory did not have; a stable sort keeps that order among equal dates.
        let order = history.map(\.id) + stored.map(\.id).filter { historyByID[$0] == nil }
        let merged = order.compactMap { best[$0] }.enumerated()
            .sorted { ($0.element.lastWatchedAt, $1.offset) > ($1.element.lastWatchedAt, $0.offset) }
            .map(\.element)
        history = Array(merged.prefix(Self.historyLimit))
        historyByID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Subscriptions

    public func isSubscribed(channelID: String) -> Bool {
        subscriptions.contains { $0.id == channelID }
    }

    /// Adds the channel, or replaces the existing entry for the same channel id (keeping its position and, when the
    /// new entry has none, its subscription date).
    public func subscribe(_ channel: SubscribedChannel) {
        subscriptionRevision += 1
        var channel = channel
        if let index = subscriptions.firstIndex(where: { $0.id == channel.id }) {
            channel.subscribedAt = channel.subscribedAt ?? subscriptions[index].subscribedAt ?? now()
            subscriptions[index] = channel
        } else {
            channel.subscribedAt = channel.subscribedAt ?? now()
            subscriptions.append(channel)
        }
        markDirty(.subscriptions)
    }

    public func unsubscribe(channelID: String) {
        guard isSubscribed(channelID: channelID) else { return }
        subscriptionRevision += 1
        subscriptions.removeAll { $0.id == channelID }
        markDirty(.subscriptions)
    }

    /// How many times `syncGoogleSubscriptions` asks the account again when the viewer changed something meanwhile.
    public static let subscriptionSyncAttempts = 3

    /// Brings the `.google` subscriptions in line with the account: asks `fetch` for the account's list and
    /// `replaceGoogleSubscriptions` with it.
    ///
    /// Fetching takes several round trips for a few hundred subscriptions, and the viewer can subscribe or unsubscribe
    /// meanwhile (or sign out): a list that was read before such a change would undo it, so a channel just subscribed
    /// to would disappear, and one just left would come back with its old subscription id. A list that the viewer's
    /// changes overtook is therefore thrown away and `fetch` is asked again, up to `subscriptionSyncAttempts` times in
    /// all. Returns whether a list was applied; when every attempt was overtaken nothing is, and the next sync (the
    /// next launch, a pull to refresh) catches up. A change that is only in flight when the list is applied is safe:
    /// its own update of the library lands afterwards.
    ///
    /// - Throws: whatever `fetch` throws; the library is left as it was then.
    @discardableResult
    public func syncGoogleSubscriptions(fetching fetch: @MainActor () async throws -> [SubscribedChannel]) async throws -> Bool {
        for _ in 0..<Self.subscriptionSyncAttempts {
            let revision = subscriptionRevision
            let fetched = try await fetch()
            guard revision == subscriptionRevision else { continue }
            replaceGoogleSubscriptions(fetched)
            return true
        }
        return false
    }

    /// Keeps the `.local` subscriptions, replaces the `.google` ones with `channels`;
    /// a channel that is in both ends up as the incoming `.google` one. A sync should go through
    /// `syncGoogleSubscriptions`, which sees to it that `channels` is not out of date.
    public func replaceGoogleSubscriptions(_ channels: [SubscribedChannel]) {
        var incoming = Self.unique(channels, by: \.id)
        let knownDates = Dictionary(
            subscriptions.compactMap { subscription in subscription.subscribedAt.map { (subscription.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        for index in incoming.indices where incoming[index].subscribedAt == nil {
            incoming[index].subscribedAt = knownDates[incoming[index].id]
        }

        let incomingIDs = Set(incoming.map(\.id))
        let keptLocal = subscriptions.filter { subscription in
            if case .local = subscription.source { return !incomingIDs.contains(subscription.id) }
            return false
        }
        subscriptions = incoming + keptLocal
        markDirty(.subscriptions)
    }

    /// After sign-out: every Google-sourced subscription becomes a local one with the same id.
    ///
    /// Counts as a change even when there was nothing to convert: a sync that is in flight when the viewer signs out
    /// must not bring the account's subscriptions back, whether or not it had brought any yet.
    public func convertGoogleSubscriptionsToLocal() {
        subscriptionRevision += 1
        var changed = false
        for index in subscriptions.indices {
            if case .google = subscriptions[index].source {
                subscriptions[index].source = .local
                changed = true
            }
        }
        if changed { markDirty(.subscriptions) }
    }

    // MARK: History

    /// Moves the video to the front of the history with the new progress. A duration that is not known (nil, zero,
    /// not a number) keeps the one learned earlier; the history keeps at most 5000 videos.
    public func recordProgress(video: VideoSummary, seconds: Double, duration: Double?) {
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let previous = historyByID[video.id]
        let watchedAt = now()
        let entry = HistoryEntry(
            video: video.forLibrary(savedAt: watchedAt),
            lastWatchedAt: watchedAt,
            progressSeconds: seconds,
            durationSeconds: duration ?? previous?.durationSeconds
        )
        if previous != nil, history.first?.id == video.id {
            // The video that is playing: updated in place, this runs every few seconds.
            history[0] = entry
        } else {
            if previous != nil, let index = history.firstIndex(where: { $0.id == video.id }) {
                history.remove(at: index)
            }
            history.insert(entry, at: 0)
            if history.count > Self.historyLimit {
                for dropped in history.suffix(history.count - Self.historyLimit) {
                    historyByID[dropped.id] = nil
                }
                history.removeLast(history.count - Self.historyLimit)
            }
        }
        historyByID[video.id] = entry
        markDirty(.history)
    }

    /// The history entry of the video, if it was watched. Constant time: screens call this for every thumbnail.
    public func progress(for videoID: String) -> HistoryEntry? {
        // Reading the index must count as reading `history` for the views that call this.
        access(keyPath: \.history)
        return historyByID[videoID]
    }

    public func removeFromHistory(videoID: String) {
        guard historyByID[videoID] != nil else { return }
        history.removeAll { $0.id == videoID }
        historyByID[videoID] = nil
        markDirty(.history)
    }

    public func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        historyByID.removeAll()
        markDirty(.history)
    }

    // MARK: Watch Later

    public func isInWatchLater(_ videoID: String) -> Bool {
        watchLater.contains { $0.id == videoID }
    }

    /// Adds the video at the top, or removes it when it is already there.
    public func toggleWatchLater(_ video: VideoSummary) {
        if let index = watchLater.firstIndex(where: { $0.id == video.id }) {
            watchLater.remove(at: index)
        } else {
            watchLater.insert(video.forLibrary(savedAt: now()), at: 0)
        }
        markDirty(.watchLater)
    }

    /// Moves the videos at the offsets `source` so that they sit before the video that is at `destination` now (at
    /// the end for `watchLater.count`), keeping their order among themselves. This is what
    /// `Array.move(fromOffsets:toOffset:)` does, and what a SwiftUI `onMove` hands over. Offsets outside the list are
    /// ignored and `destination` is limited to `0...watchLater.count`, so no input can trap; a move that leaves the
    /// order as it is changes (and writes) nothing.
    public func moveWatchLater(fromOffsets source: IndexSet, toOffset destination: Int) {
        let count = watchLater.count
        // An `IndexSet` holds no negative numbers, so only the upper end needs checking.
        let moving = source.filter { $0 < count }
        guard !moving.isEmpty else { return }

        let target = min(max(destination, 0), count)
        let movingOffsets = Set(moving)
        var reordered = watchLater.enumerated().filter { !movingOffsets.contains($0.offset) }.map(\.element)
        // `target` counts the videos that are moving; once they are out of the list it is that many places earlier.
        reordered.insert(contentsOf: moving.map { watchLater[$0] }, at: target - moving.filter { $0 < target }.count)

        guard reordered.map(\.id) != watchLater.map(\.id) else { return }
        watchLater = reordered
        markDirty(.watchLater)
    }

    // MARK: Local playlists

    @discardableResult
    public func createPlaylist(title: String) -> LocalPlaylist {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = now()
        let playlist = LocalPlaylist(
            title: trimmed.isEmpty ? "Untitled playlist" : trimmed,
            createdAt: date,
            updatedAt: date
        )
        playlists.append(playlist)
        markDirty(.playlists)
        return playlist
    }

    public func renamePlaylist(_ id: UUID, title: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[index].title = trimmed
        playlists[index].updatedAt = now()
        markDirty(.playlists)
    }

    public func deletePlaylist(_ id: UUID) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        playlists.removeAll { $0.id == id }
        markDirty(.playlists)
    }

    /// Appends the video unless the playlist already contains it.
    public func add(_ video: VideoSummary, toPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              !playlists[index].videos.contains(where: { $0.id == video.id }) else { return }
        let savedAt = now()
        playlists[index].videos.append(video.forLibrary(savedAt: savedAt))
        playlists[index].updatedAt = savedAt
        markDirty(.playlists)
    }

    public func remove(videoID: String, fromPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].videos.contains(where: { $0.id == videoID }) else { return }
        playlists[index].videos.removeAll { $0.id == videoID }
        playlists[index].updatedAt = now()
        markDirty(.playlists)
    }

    // MARK: Search history

    /// Moves the query to the front; duplicates are detected case-insensitively; at most 50 are kept.
    public func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = Self.searchKey(trimmed)
        searchHistory.removeAll { Self.searchKey($0) == key }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > Self.searchHistoryLimit {
            searchHistory.removeLast(searchHistory.count - Self.searchHistoryLimit)
        }
        markDirty(.searchHistory)
    }

    public func clearSearchHistory() {
        guard !searchHistory.isEmpty else { return }
        searchHistory.removeAll()
        markDirty(.searchHistory)
    }

    // MARK: Persistence

    /// Writes everything that changed and returns once that write (and every earlier one) has finished.
    ///
    /// - Returns: whether everything that changed is on disk. False when a write failed (the disk is full) or a file was
    ///   refused as unreadable; the collection stays marked as changed and is tried again (see the type's documentation).
    @discardableResult
    public func flush() async -> Bool {
        cancelTimer()
        startWrite()
        await lastWrite?.value
        reclaimFailedWrites()
        return dirty.isEmpty
    }

    /// Writes everything that changed, on the calling thread, and returns once it is on disk. For the last moment of the
    /// process only: iOS announces it with `UIApplication.willTerminateNotification` and ends the process as soon as the
    /// observers return, so an `await` (`flush()`) never gets to finish there and the half-second timer never fires.
    /// Everywhere else use `flush()`: this blocks the thread it is called on.
    ///
    /// A background write that is already running is waited for first, for at most `timeout` seconds. Otherwise it
    /// could finish after the write below and put the older content back on top of the newer. If it does not finish in
    /// time (the disk hangs) nothing is written, and the call returns false: the changes stay marked as changed. The
    /// wait cannot deadlock, because the background writes never need the main actor.
    ///
    /// A write that failed earlier in the background is tried again here. A collection whose write fails (or is refused)
    /// stays marked as changed.
    ///
    /// - Returns: whether everything that changed is on disk.
    @discardableResult
    public func flushNow(timeout: TimeInterval = 2) -> Bool {
        cancelTimer()
        guard writesInFlight.wait(timeout: .now() + timeout) == .success else { return false }
        // Nothing runs in the background now, and nothing can start one: starting is the main actor's, and this is it.
        reclaimFailedWrites()
        let snapshots = dirty.map { snapshot(of: $0) }
        dirty.removeAll()
        var allWritten = true
        for snapshot in snapshots where !snapshot.write(to: files) {
            dirty.insert(snapshot.file)
            allWritten = false
        }
        return allWritten
    }

    private func markDirty(_ file: LibraryFile) {
        dirty.insert(file)
        // A pause before trying a failed write again does not hold up a change the viewer just made.
        guard timer == nil || timerIsRetry else { return }
        armTimer(after: saveDelay, isRetry: false)
    }

    private func armTimer(after delay: Duration, isRetry: Bool) {
        timer?.cancel()
        timerGeneration += 1
        timerIsRetry = isRetry
        let generation = timerGeneration
        timer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.timerFired(generation)
        }
    }

    private func cancelTimer() {
        timerGeneration += 1
        timer?.cancel()
        timer = nil
        timerIsRetry = false
    }

    private func timerFired(_ generation: Int) {
        // A flush (or a newer timer) has taken over since this timer was started.
        guard generation == timerGeneration else { return }
        timer = nil
        timerIsRetry = false
        startWrite()
    }

    /// Marks again as changed the collections whose write failed or was refused in the background, and arms the timer
    /// for a new try with a pause that doubles from `retryDelay` up to a minute and starts over after a good write. A
    /// refused file is not tried on the timer: it is unreadable until `reloadIfUnreadable` has read it.
    private func reclaimFailedWrites() {
        let outcome = writeOutcomes.take()
        guard !outcome.failed.isEmpty else {
            if outcome.cleanWrites > 0 { failedRounds = 0 }
            return
        }
        dirty.formUnion(outcome.failed)
        guard outcome.failed.contains(where: { !files.isUnreadable($0.rawValue) }), timer == nil else { return }
        let pause = min(retryDelay * (1 << min(failedRounds, 10)), .seconds(60))
        failedRounds += 1
        armTimer(after: pause, isRetry: true)
    }

    /// Takes a copy of every collection that changed and writes the copies in the background, after the previous write.
    private func startWrite() {
        reclaimFailedWrites()
        guard !dirty.isEmpty else { return }
        let snapshots = dirty.map { snapshot(of: $0) }
        dirty.removeAll()
        let previous = lastWrite
        let files = files
        let beforeWrite = beforeWrite
        let writesInFlight = writesInFlight
        let outcomes = writeOutcomes
        writesInFlight.enter()
        lastWrite = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            beforeWrite?()
            var failed: Set<LibraryFile> = []
            for snapshot in snapshots where !snapshot.write(to: files) {
                failed.insert(snapshot.file)
            }
            outcomes.record(failed: failed)
            // Finished as far as `flushNow` (which waits for this on the main thread) is concerned. Nothing above or
            // below needs the main actor before this point.
            writesInFlight.leave()
            if !failed.isEmpty {
                // Not awaited by anyone: a later write waits for this task, and must not wait for the main actor.
                Task { @MainActor [weak self] in self?.writesFailed() }
            }
        }
    }

    /// A background write reported a failure: the collection is marked as changed again and a new try is scheduled.
    private func writesFailed() {
        reclaimFailedWrites()
    }

    private func snapshot(of file: LibraryFile) -> Snapshot {
        switch file {
        case .subscriptions: .subscriptions(subscriptions)
        case .history: .history(history)
        case .watchLater: .watchLater(watchLater)
        case .playlists: .playlists(playlists)
        case .searchHistory: .searchHistory(searchHistory)
        }
    }

    // MARK: Helpers

    /// The elements with a repeated id removed; the first one wins.
    private static func unique<Element, ID: Hashable>(_ elements: [Element], by id: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        return elements.filter { seen.insert(id($0)).inserted }
    }

    /// A stored search list as the app would have written it: trimmed, no blanks, no repeats, at most 50.
    private static func cleaned(_ queries: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(searchKey(trimmed)).inserted else { continue }
            result.append(trimmed)
            if result.count == searchHistoryLimit { break }
        }
        return result
    }

    private static func searchKey(_ query: String) -> String {
        query.folding(options: .caseInsensitive, locale: nil)
    }
}

// MARK: - Files

/// The files of a `LibraryStore`, named as on disk.
private enum LibraryFile: String, Sendable, CaseIterable {
    case subscriptions = "subscriptions.json"
    case history = "history.json"
    case watchLater = "watch-later.json"
    case playlists = "playlists.json"
    case searchHistory = "search-history.json"
}

/// A copy of one collection, ready to be encoded and written away from the main actor.
private struct WriteOutcomes: Sendable {
    /// The collections whose last background write failed or was refused, not yet taken back by the main actor.
    var failed: Set<LibraryFile> = []
    /// Background writes that wrote everything they had since the main actor last looked.
    var cleanWrites = 0
}

/// What the background writes report: kept under a lock so that reporting never needs the main actor.
private final class WriteLog: Sendable {
    private let outcomes = Mutex(WriteOutcomes())

    func record(failed: Set<LibraryFile>) {
        outcomes.withLock { outcomes in
            if failed.isEmpty {
                outcomes.cleanWrites += 1
            } else {
                outcomes.failed.formUnion(failed)
            }
        }
    }

    /// What was reported since the last call.
    func take() -> WriteOutcomes {
        outcomes.withLock { outcomes in
            defer { outcomes = WriteOutcomes() }
            return outcomes
        }
    }
}

private enum Snapshot: Sendable {
    case subscriptions([SubscribedChannel])
    case history([HistoryEntry])
    case watchLater([VideoSummary])
    case playlists([LocalPlaylist])
    case searchHistory([String])

    var file: LibraryFile {
        switch self {
        case .subscriptions: .subscriptions
        case .history: .history
        case .watchLater: .watchLater
        case .playlists: .playlists
        case .searchHistory: .searchHistory
        }
    }

    /// Whether the content is on disk afterwards.
    func write(to store: JSONFileStore) -> Bool {
        switch self {
        case .subscriptions(let value): store.save(value, to: file.rawValue)
        case .history(let value): store.save(value, to: file.rawValue)
        case .watchLater(let value): store.save(value, to: file.rawValue)
        case .playlists(let value): store.save(value, to: file.rawValue)
        case .searchHistory(let value): store.save(value, to: file.rawValue)
        }
    }
}
