import Foundation
import Observation

/// Everything the user keeps on the device: subscriptions, watch history with progress, Watch Later,
/// local playlists and recent searches.
///
/// STUB (Task 1A). Task 6 owns this file and adds persistence. Until then this is a simple, fully working
/// in-memory implementation (nothing is written to disk, `directory` is ignored) so UI tasks can use it.
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

    public init(directory: URL) {}

    // MARK: Subscriptions

    public func isSubscribed(channelID: String) -> Bool {
        subscriptions.contains { $0.id == channelID }
    }

    /// Adds the channel, or replaces the existing entry for the same channel id.
    public func subscribe(_ channel: SubscribedChannel) {
        var channel = channel
        if channel.subscribedAt == nil { channel.subscribedAt = Date() }
        if let index = subscriptions.firstIndex(where: { $0.id == channel.id }) {
            subscriptions[index] = channel
        } else {
            subscriptions.append(channel)
        }
    }

    public func unsubscribe(channelID: String) {
        subscriptions.removeAll { $0.id == channelID }
    }

    /// Keeps the `.local` subscriptions, replaces the `.google` ones with `channels`;
    /// a channel that is in both ends up as the incoming `.google` one.
    public func replaceGoogleSubscriptions(_ channels: [SubscribedChannel]) {
        let incomingIDs = Set(channels.map(\.id))
        let keptLocal = subscriptions.filter { subscription in
            if case .local = subscription.source { return !incomingIDs.contains(subscription.id) }
            return false
        }
        subscriptions = channels + keptLocal
    }

    /// After sign-out: every Google-sourced subscription becomes a local one with the same id.
    public func convertGoogleSubscriptionsToLocal() {
        subscriptions = subscriptions.map { subscription in
            var converted = subscription
            converted.source = .local
            return converted
        }
    }

    // MARK: History

    /// Moves the video to the front of the history with the new progress.
    public func recordProgress(video: VideoSummary, seconds: Double, duration: Double?) {
        var previous: HistoryEntry?
        if let index = history.firstIndex(where: { $0.id == video.id }) {
            previous = history.remove(at: index)
        }
        history.insert(
            HistoryEntry(
                video: video,
                lastWatchedAt: Date(),
                progressSeconds: max(0, seconds),
                durationSeconds: duration ?? previous?.durationSeconds
            ),
            at: 0
        )
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    public func progress(for videoID: String) -> HistoryEntry? {
        history.first { $0.id == videoID }
    }

    public func removeFromHistory(videoID: String) {
        history.removeAll { $0.id == videoID }
    }

    public func clearHistory() {
        history.removeAll()
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
    }

    // MARK: Local playlists

    @discardableResult
    public func createPlaylist(title: String) -> LocalPlaylist {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = LocalPlaylist(title: trimmed.isEmpty ? "Untitled playlist" : trimmed)
        playlists.append(playlist)
        return playlist
    }

    public func renamePlaylist(_ id: UUID, title: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[index].title = trimmed
        playlists[index].updatedAt = Date()
    }

    public func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    /// Appends the video unless the playlist already contains it.
    public func add(_ video: VideoSummary, toPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              !playlists[index].videos.contains(where: { $0.id == video.id }) else { return }
        playlists[index].videos.append(video)
        playlists[index].updatedAt = Date()
    }

    public func remove(videoID: String, fromPlaylist id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].videos.removeAll { $0.id == videoID }
        playlists[index].updatedAt = Date()
    }

    // MARK: Search history

    /// Moves the query to the front; duplicates are detected case-insensitively; at most 50 are kept.
    public func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > Self.searchHistoryLimit {
            searchHistory.removeLast(searchHistory.count - Self.searchHistoryLimit)
        }
    }

    public func clearSearchHistory() {
        searchHistory.removeAll()
    }

    // MARK: Persistence

    /// Waits until pending writes have reached the disk. The in-memory stub has none.
    public func flush() async {}
}
