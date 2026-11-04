import Foundation
import NoSlopKit
import Observation

/// Loads the on-device "For you" feed for `HomeView`: the "Continue watching" row and the vertical feed.
///
/// Home never shows an error screen: the feed service has no failure path (it returns what it could build), and a failed
/// refresh of the subscription uploads keeps what is cached. A feed with nothing in it is an empty state. What needs no
/// network ("Continue watching" is the history) is on screen before the feed is built, and when YouTube could not be
/// asked for related videos an empty feed says so (`relatedUnavailable`) instead of calling itself complete.
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
    /// The last feed that was built could not ask YouTube for related videos (see `HomeFeed.relatedUnavailable`): when
    /// `forYou` is empty it is empty for that reason, not because there is nothing more to suggest.
    private(set) var relatedUnavailable = false

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
    /// When the loaded feed was built from fresh data; nil when it could not be (see `publish`), so that the next visit
    /// tries again.
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The load in `loadTask` asked for fresh uploads (a pull to refresh), as opposed to making do with the cache.
    @ObservationIgnored private var loadIsForced = false
    /// The subscriptions the last run started from, to see whether they changed while it ran.
    @ObservationIgnored private var ranWithSubscriptionIDs: Set<String> = []
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
    ///
    /// A load that is already running is joined only when it asked for fresh uploads itself. One that did not (the
    /// first load of the day, which shows the feed from disk) is waited for, and the pull then makes its own: joining it
    /// would swallow the pull, and no upload would ever be fetched for it.
    func refresh(using env: AppEnvironment) async {
        while let running = loadTask {
            let wasForced = loadIsForced
            await running.value
            if wasForced { return }
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
        loadIsForced = forceRefresh
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(using: env, forceRefresh: forceRefresh)
            // The subscriptions may have changed while the feed was loading (the viewer unsubscribed in Manage and came
            // back, or the account sync of the launch finished). `loadIfNeeded` returned at once because this load was
            // running, so look again here: the follow-up only fetches what the feed service has not got.
            while !Task.isCancelled, Set(env.library.subscriptions.map(\.id)) != self.ranWithSubscriptionIDs {
                self.loadIsForced = false
                await self.run(using: env, forceRefresh: false)
            }
            self.loadTask = nil
        }
        loadTask = task
        return task
    }

    private func run(using env: AppEnvironment, forceRefresh: Bool) async {
        generation += 1
        let thisGeneration = generation
        phase = .loading
        #if DEBUG
        FeedLog.info("home run force=\(forceRefresh) hasContent=\(hasContent)")
        #endif

        // What needs no network goes on screen first: "Continue watching" is the history, and the screen would otherwise
        // wait for the feed service, which waits for YouTube (up to 12 s). The feed itself is published once it is built,
        // so that uploads from the cache are not swapped in and out underneath the viewer.
        if !hasContent {
            built = HomeFeed(continueWatching: HomeFeed.continueWatching(in: env.library.history))
            applyFilter(using: env)
        }

        // A pull to refresh also brings in what was subscribed to elsewhere (on youtube.com, in another app) while the
        // app sat in the background: the Google subscriptions are synced first, so that the feed is built from the list as
        // it is now. A sync that fails keeps the list as it was.
        if forceRefresh {
            await env.refreshAccount()
        }

        let signature = Signature(env)
        ranWithSubscriptionIDs = Set(signature.subscriptionIDs)
        let history = env.library.history
        let subscriptions = env.library.subscriptions
        let subscribedIDs = Set(subscriptions.map(\.id))

        var uploads = await env.subscriptionFeed.cachedFeed()
        // Asked for on a pull to refresh, and when there is nothing from an earlier session to start from. Otherwise the
        // feed is built from the uploads on disk and they are refreshed afterwards (below).
        let mustFetch = forceRefresh || (uploads.isEmpty && !subscriptions.isEmpty)
        var uploadsFailed = false
        if mustFetch {
            do {
                uploads = try await env.subscriptionFeed.feed(channels: subscriptions, forceRefresh: forceRefresh)
            } catch {
                // A feed that cannot be fetched (offline, rate limited) leaves the cached uploads in place.
                uploadsFailed = !FeedError.isCancellation(error)
            }
        }
        uploads = Self.limited(uploads, to: subscribedIDs)

        let feed = await env.homeFeed.homeFeed(history: history, subscriptionVideos: uploads)

        guard !Task.isCancelled, thisGeneration == generation else {
            // Superseded or cancelled: leave the state the screen already had.
            if phase == .loading { phase = loadedAt == nil ? .idle : .loaded }
            return
        }
        publish(feed, signature: signature, uploadsFailed: uploadsFailed, using: env)

        // The feed was built from the uploads on disk, which may be days old (Home is the first screen, and nothing else
        // refreshes them unless the Subscriptions tab is opened): ask for fresh ones now, without holding the screen
        // back, and build the feed again when they are not the same. The feed service remembers every channel for 15
        // minutes, so this costs a request only for the channels that are due.
        guard !mustFetch, !subscriptions.isEmpty else { return }
        let fresh = try? await env.subscriptionFeed.feed(channels: subscriptions, forceRefresh: false)
        guard !Task.isCancelled, thisGeneration == generation else { return }
        guard let fresh else {
            // Not fetched: the next visit tries again.
            loadedAt = nil
            return
        }
        let freshUploads = Self.limited(fresh, to: subscribedIDs)
        guard freshUploads.map(\.id) != uploads.map(\.id) else { return }
        let rebuilt = await env.homeFeed.homeFeed(history: history, subscriptionVideos: freshUploads)
        guard !Task.isCancelled, thisGeneration == generation else { return }
        publish(rebuilt, signature: signature, uploadsFailed: false, using: env)
    }

    /// Puts a built feed on screen. One that could not be built from fresh data (the uploads could not be fetched, or
    /// YouTube could not be asked for related videos) is not stamped with a time, so that the next visit tries again
    /// instead of waiting 15 minutes.
    private func publish(_ feed: HomeFeed, signature: Signature, uploadsFailed: Bool, using env: AppEnvironment) {
        built = feed
        if relatedUnavailable != feed.relatedUnavailable { relatedUnavailable = feed.relatedUnavailable }
        applyFilter(using: env)
        loadedSignature = signature
        loadedAt = uploadsFailed || feed.relatedUnavailable ? nil : Date()
        phase = .loaded
        #if DEBUG
        FeedLog.info(
            "home published continue=\(continueWatching.count) forYou=\(forYou.count) first \(forYou.first?.id ?? "-") "
                + "unavailable=\(feed.relatedUnavailable)"
        )
        #endif
    }

    /// Drops uploads of channels that are no longer subscribed (a cache can be older than an unsubscribe).
    private static func limited(_ uploads: [VideoSummary], to channelIDs: Set<String>) -> [VideoSummary] {
        uploads.filter { video in video.channel.map { channelIDs.contains($0.id) } ?? true }
    }
}
