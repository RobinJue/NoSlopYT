import Foundation
import NoSlopKit
import Observation

/// Loads the on-device "For you" feed for `HomeView`: the "Continue watching" row and the vertical feed.
///
/// Home never shows an error: the feed service has no failure path (it returns what it could build), and a failed
/// refresh of the subscription uploads keeps what is cached. A feed with nothing in it is an empty state.
///
/// Loads run in a task of their own, not in the view's `.task`, so leaving the screen (opening a video, switching
/// tab) does not cancel a load half-way and does not restart it when the screen comes back.
@MainActor
@Observable
final class HomeViewModel {
    enum Phase: Equatable {
        /// Nothing requested yet.
        case idle
        /// A load is running (the screen may already have content from an earlier one).
        case loading
        case loaded
    }

    private(set) var phase: Phase = .idle
    /// "Continue watching", after the user's filters.
    private(set) var continueWatching: [HistoryEntry] = []
    /// The feed, after the user's filters.
    private(set) var forYou: [VideoSummary] = []

    var hasContent: Bool { !continueWatching.isEmpty || !forYou.isEmpty }

    /// What the feed service built, before the user's filters. `applyFilter` runs them on it again when they change,
    /// so a channel the user blocks leaves the screen at once.
    @ObservationIgnored private var built = HomeFeed.empty

    /// What the loaded feed was built from. When it differs on a later visit the feed is rebuilt. The feed filters are
    /// not part of it: they are applied to the built feed (`applyFilter`), whenever they change.
    private struct Signature: Equatable {
        var subscriptionIDs: [String]
        var historyCount: Int
        /// Changes whenever progress is recorded, so finishing or starting a video refreshes "Continue watching".
        var lastWatchedAt: Date?

        init(_ env: AppEnvironment) {
            subscriptionIDs = env.library.subscriptions.map(\.id)
            historyCount = env.library.history.count
            lastWatchedAt = env.library.history.first?.lastWatchedAt
        }
    }

    /// A feed older than this is rebuilt the next time Home appears, even when nothing else changed.
    #if DEBUG
    private static var maxAge: TimeInterval { DebugLaunchHooks.feedMaxAge ?? 15 * 60 }
    #else
    private static let maxAge: TimeInterval = 15 * 60
    #endif

    @ObservationIgnored private var loadedSignature: Signature?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    // MARK: Loading

    /// Builds the feed when there is none yet, when it is older than 15 minutes, or when the history or the
    /// subscriptions changed since it was built. Otherwise it only runs the feed filters again, which may have changed.
    /// Returns immediately.
    func loadIfNeeded(using env: AppEnvironment) {
        guard loadTask == nil else { return }
        if phase == .loaded, let loadedAt, loadedSignature == Signature(env),
           Date().timeIntervalSince(loadedAt) < Self.maxAge {
            applyFilter(using: env)
            return
        }
        start(using: env, forceRefresh: false)
    }

    /// Pull to refresh: fetches fresh subscription uploads and rebuilds the feed. Suspends until it is done.
    func refresh(using env: AppEnvironment) async {
        // A load already in flight is as fresh as a new one would be.
        if let running = loadTask {
            await running.value
            return
        }
        await start(using: env, forceRefresh: true).value
    }

    /// Runs the user's filters on the feed already built (cheap; no network). Call it when they change: the user
    /// blocked a channel, or turned a setting on or off.
    func applyFilter(using env: AppEnvironment) {
        let filter = env.contentFilter
        let resumable = built.continueWatching.filter { filter.allows($0.video) }.uniqued()
        let feed = filter.filter(built.forYou).uniqued()
        // Not new values when nothing changed, so the screen is not redrawn for a setting that is not about the feed.
        if resumable.map(\.id) != continueWatching.map(\.id) { continueWatching = resumable }
        if feed.map(\.id) != forYou.map(\.id) { forYou = feed }
    }

    @discardableResult
    private func start(using env: AppEnvironment, forceRefresh: Bool) -> Task<Void, Never> {
        let task = Task { [weak self] in
            await self?.run(using: env, forceRefresh: forceRefresh)
            self?.loadTask = nil
        }
        loadTask = task
        return task
    }

    private func run(using env: AppEnvironment, forceRefresh: Bool) async {
        generation += 1
        let thisGeneration = generation
        let signature = Signature(env)
        phase = .loading
        #if DEBUG
        FeedLog.info("home run force=\(forceRefresh) hasContent=\(hasContent)")
        #endif

        let history = env.library.history
        let subscriptions = env.library.subscriptions
        let subscribedIDs = Set(subscriptions.map(\.id))

        var uploads = await env.subscriptionFeed.cachedFeed()
        if forceRefresh || (uploads.isEmpty && !subscriptions.isEmpty) {
            // A feed that cannot be fetched (offline, rate limited) leaves the cached uploads in place.
            if let fresh = try? await env.subscriptionFeed.feed(channels: subscriptions, forceRefresh: forceRefresh) {
                uploads = fresh
            }
        }
        // The cache may still hold uploads of a channel that was unsubscribed in the meantime.
        uploads = uploads.filter { video in video.channel.map { subscribedIDs.contains($0.id) } ?? true }

        let feed = await env.homeFeed.homeFeed(history: history, subscriptionVideos: uploads)

        guard !Task.isCancelled, thisGeneration == generation else {
            // Superseded or cancelled: leave the state the screen already had.
            if phase == .loading { phase = loadedAt == nil ? .idle : .loaded }
            return
        }
        built = feed
        applyFilter(using: env)
        loadedSignature = signature
        loadedAt = Date()
        phase = .loaded
        #if DEBUG
        FeedLog.info("home published continue=\(continueWatching.count) forYou=\(forYou.count) first \(forYou.first?.id ?? "-")")
        #endif
    }
}
