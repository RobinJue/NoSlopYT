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
/// Changes are written in the background: the first change after a write starts a 0.5 s timer, and everything
/// that changed until it fires goes to disk together, encoded and written off the main thread. Writes happen in
/// the order they were started. `flush()` writes immediately and returns once the data is on disk, so call it
/// when the app goes to the background; changes made in the last half second before the process is killed are lost.
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
    /// The history by video id, so that looking up the progress of a thumbnail does not scan up to 5000 entries.
    /// Always holds exactly the entries of `history`.
    @ObservationIgnored private var historyByID: [String: HistoryEntry] = [:]
    @ObservationIgnored private var dirty: Set<LibraryFile> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerGeneration = 0
    /// The most recent background write; each new write waits for the one before it.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    /// Loads the five files from `directory` (created on the first write).
    public convenience init(directory: URL) {
        self.init(directory: directory, saveDelay: .milliseconds(500), now: { Date() })
    }

    /// Tests choose the write delay and the clock.
    init(directory: URL, saveDelay: Duration, now: @escaping @Sendable () -> Date) {
        let files = JSONFileStore(directory: directory)
        self.files = files
        self.saveDelay = saveDelay
        self.now = now

        subscriptions = Self.unique(files.loadList(LibraryFile.subscriptions.rawValue), by: \SubscribedChannel.id)
        history = Array(Self.unique(files.loadList(LibraryFile.history.rawValue), by: \HistoryEntry.id).prefix(Self.historyLimit))
        historyByID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        watchLater = Self.unique(files.loadList(LibraryFile.watchLater.rawValue), by: \VideoSummary.id)
        playlists = Self.unique(files.loadList(LibraryFile.playlists.rawValue), by: \LocalPlaylist.id)
        searchHistory = Self.cleaned(files.loadList(LibraryFile.searchHistory.rawValue))
    }

    // MARK: Subscriptions

    public func isSubscribed(channelID: String) -> Bool {
        subscriptions.contains { $0.id == channelID }
    }

    /// Adds the channel, or replaces the existing entry for the same channel id (keeping its position and, when the
    /// new entry has none, its subscription date).
    public func subscribe(_ channel: SubscribedChannel) {
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
        subscriptions.removeAll { $0.id == channelID }
        markDirty(.subscriptions)
    }

    /// Keeps the `.local` subscriptions, replaces the `.google` ones with `channels`;
    /// a channel that is in both ends up as the incoming `.google` one.
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
    public func convertGoogleSubscriptionsToLocal() {
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
        let entry = HistoryEntry(
            video: video,
            lastWatchedAt: now(),
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
            watchLater.insert(video, at: 0)
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
        playlists[index].videos.append(video)
        playlists[index].updatedAt = now()
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
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
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
