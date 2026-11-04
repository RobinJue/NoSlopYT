import Foundation
import Observation

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
        beforeWrite: (@Sendable () -> Void)? = nil
    ) {
        let files = JSONFileStore(directory: directory)
        self.files = files
        self.saveDelay = saveDelay
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

    /// Writes everything that changed and returns once it (and every earlier write) is on disk.
    public func flush() async {
        timerGeneration += 1
        timer?.cancel()
        timer = nil
        startWrite()
        await lastWrite?.value
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
    /// - Returns: whether everything that changed is on disk.
    @discardableResult
    public func flushNow(timeout: TimeInterval = 2) -> Bool {
        timerGeneration += 1
        timer?.cancel()
        timer = nil
        guard writesInFlight.wait(timeout: .now() + timeout) == .success else { return false }
        // Nothing runs in the background now, and nothing can start one: starting is the main actor's, and this is it.
        let snapshots = dirty.map { snapshot(of: $0) }
        dirty.removeAll()
        for snapshot in snapshots {
            snapshot.write(to: files)
        }
        return true
    }

    private func markDirty(_ file: LibraryFile) {
        dirty.insert(file)
        guard timer == nil else { return }
        timerGeneration += 1
        let generation = timerGeneration
        timer = Task { [weak self, saveDelay] in
            do { try await Task.sleep(for: saveDelay) } catch { return }
            self?.timerFired(generation)
        }
    }

    private func timerFired(_ generation: Int) {
        // A flush (or a newer timer) has taken over since this timer was started.
        guard generation == timerGeneration else { return }
        timer = nil
        startWrite()
    }

    /// Takes a copy of every collection that changed and writes the copies in the background, after the previous write.
    private func startWrite() {
        guard !dirty.isEmpty else { return }
        let snapshots = dirty.map { snapshot(of: $0) }
        dirty.removeAll()
        let previous = lastWrite
        let files = files
        let beforeWrite = beforeWrite
        let writesInFlight = writesInFlight
        writesInFlight.enter()
        lastWrite = Task.detached(priority: .utility) {
            defer { writesInFlight.leave() }
            await previous?.value
            beforeWrite?()
            for snapshot in snapshots {
                snapshot.write(to: files)
            }
        }
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
private enum LibraryFile: String, Sendable {
    case subscriptions = "subscriptions.json"
    case history = "history.json"
    case watchLater = "watch-later.json"
    case playlists = "playlists.json"
    case searchHistory = "search-history.json"
}

/// A copy of one collection, ready to be encoded and written away from the main actor.
private enum Snapshot: Sendable {
    case subscriptions([SubscribedChannel])
    case history([HistoryEntry])
    case watchLater([VideoSummary])
    case playlists([LocalPlaylist])
    case searchHistory([String])

    func write(to store: JSONFileStore) {
        switch self {
        case .subscriptions(let value): store.save(value, to: LibraryFile.subscriptions.rawValue)
        case .history(let value): store.save(value, to: LibraryFile.history.rawValue)
        case .watchLater(let value): store.save(value, to: LibraryFile.watchLater.rawValue)
        case .playlists(let value): store.save(value, to: LibraryFile.playlists.rawValue)
        case .searchHistory(let value): store.save(value, to: LibraryFile.searchHistory.rawValue)
        }
    }
}
