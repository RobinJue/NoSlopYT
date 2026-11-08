import Foundation
import NoSlopKit
import Observation

/// Loads the "For you" feed for `HomeView`: the "Continue watching" row and the vertical feed. The feed is YouTube's own
/// Home when the recommendations connection is on and good enough (`HomeSourceDecision`), else the mix made on the device.
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
    /// The feed, after the user's filters: YouTube's Home while it is shown, else the mix made on the device.
    var forYou: [VideoSummary] { showsYouTube ? youTubePages.items : deviceFeed }
    /// The on-device feed, after the user's filters.
    private var deviceFeed: [VideoSummary] = []
    /// YouTube's Home is on screen (its pages are in `youTubePages`).
    private(set) var showsYouTube = false
    /// YouTube's Home was asked for and did not make it: the device mix is shown instead, and says so.
    private(set) var youTubeFellBack = false
    /// YouTube's Home, page after page, through the same filter as every other paged list.
    let youTubePages = FeedPages<VideoSummary>()
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
        /// YouTube's Home is wanted (connected, and the switch is on), and which connection it was asked through.
        var wantsYouTube: Bool
        var revision: Int
        /// The feed that was built is YouTube's. Its own history and subscriptions are not what it was built from.
        var shownYouTube: Bool
        var subscriptionIDs: [String]
        var historyCount: Int
        /// Changes whenever progress is recorded, so finishing or starting a video rebuilds the feed; the "Continue watching"
        /// row then takes the new entries (`applyFilter` compares entries, not ids).
        var lastWatchedAt: Date?

        init(_ env: AppEnvironment, shownYouTube: Bool) {
            wantsYouTube = HomeViewModel.wantsYouTube(env)
            revision = env.recommendationsRevision
            self.shownYouTube = shownYouTube
            // YouTube's Home is not rebuilt for history changes: only its Continue watching row follows them.
            subscriptionIDs = shownYouTube ? [] : env.library.subscriptions.map(\.id)
            historyCount = shownYouTube ? 0 : env.library.history.count
            lastWatchedAt = shownYouTube ? nil : env.library.history.first?.lastWatchedAt
        }

        func isSameSource(as other: Signature) -> Bool {
            wantsYouTube == other.wantsYouTube && revision == other.revision
        }
    }

    /// Connected and the switch is on.
    private static func wantsYouTube(_ env: AppEnvironment) -> Bool {
        env.recommendationsAccount != nil && env.settings.showYouTubeHome
    }

    /// A feed older than this is rebuilt the next time Home appears, even when nothing else changed.
    #if DEBUG
    private static var maxAge: TimeInterval { DebugLaunchHooks.feedMaxAge ?? 15 * 60 }
    #else
    private static let maxAge: TimeInterval = 15 * 60
    #endif

    /// YouTube's Home is kept this long (a pull to refresh, a connect or a disconnect load it again at once).
    private static let youTubeMaxAge: TimeInterval = 20 * 60
    /// How long YouTube gets, in all, to deliver the pages the decision needs.
    private static let youTubeBudget: TimeInterval = 8

    @ObservationIgnored private var loadedSignature: Signature?
    /// What the running load started from: a connection that changes meanwhile makes it load again when it is done.
    @ObservationIgnored private var runningSignature: Signature?
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
        if phase == .loaded, let loadedAt, let loadedSignature,
           loadedSignature == Signature(env, shownYouTube: loadedSignature.shownYouTube),
           Date().timeIntervalSince(loadedAt) < (loadedSignature.shownYouTube ? Self.youTubeMaxAge : Self.maxAge) {
            applyFilter(using: env)
            return
        }
        start(using: env, forceRefresh: false)
    }

    /// Pull to refresh (and Retry): fetches fresh subscription uploads and rebuilds the feed. Suspends until it is done.
    ///
    /// A load that is already running is joined only when it asked for fresh uploads itself. One that did not (the
    /// first load of the day, which shows the feed from disk) is waited for, and the pull then makes its own: joining it
    /// would swallow the pull, and no upload would ever be fetched for it.
    ///
    /// When the viewer is signed in, the Google account is looked at once more afterwards. The feed service looks up the
    /// durations of the uploads through the account and keeps quiet about a session that ended meanwhile, so nothing else
    /// would notice before the next call to the account. The automatic loads do not do this.
    func refresh(using env: AppEnvironment) async {
        while let running = loadTask {
            let wasForced = loadIsForced
            await running.value
            if wasForced { return }
        }
        await start(using: env, forceRefresh: true).value
        if env.googleAccount != nil {
            await env.reconcileGoogleAccount()
        }
    }

    /// A card was sent "Not interested": takes it off the screen at once.
    func cardDismissed(using env: AppEnvironment) {
        guard showsYouTube else { return }
        youTubePages.refilter(fetch: youTubeFetch(using: env), filter: youTubeFilter(using: env))
    }

    /// Runs the user's filters on the feed already built (cheap; no network). Call it when they change: the user
    /// blocked a channel, or turned a setting on or off.
    func applyFilter(using env: AppEnvironment) {
        let filter = env.contentFilter
        if showsYouTube {
            // YouTube's Home: Continue watching comes from the history as it is now; the pages are filtered again.
            let resumable = HomeFeed.continueWatching(in: env.library.history).filter { filter.allows($0.video) }.uniqued()
            if resumable != continueWatching { continueWatching = resumable }
            youTubePages.refilter(fetch: youTubeFetch(using: env), filter: youTubeFilter(using: env))
            return
        }
        let resumable = built.continueWatching.filter { filter.allows($0.video) }.uniqued()
        let feed = filter.filter(built.forYou).uniqued()
        // Not new values when nothing changed, so the screen is not redrawn for a setting that is not about the feed.
        // "Nothing changed" means the same entries, not only the same ids: the first card says how much is left of its
        // video, and that changes while the viewer watches. The Up next row only has ids to compare (its bars are live).
        if resumable != continueWatching { continueWatching = resumable }
        if feed.map(\.id) != deviceFeed.map(\.id) { deviceFeed = feed }
    }

    /// The connection or the "Show YouTube's Home" switch may have changed (connected, disconnected, switched, the
    /// account read at launch): loads again from the right source. A load that is running looks again when it is done.
    func sourceMayHaveChanged(using env: AppEnvironment) {
        if showsYouTube, !Self.wantsYouTube(env) {
            // Disconnected or switched off: nothing of YouTube's stays on screen.
            showsYouTube = false
            youTubePages.removeAll()
        }
        guard loadTask == nil, let loadedSignature else { return }
        guard !loadedSignature.isSameSource(as: Signature(env, shownYouTube: loadedSignature.shownYouTube)) else { return }
        start(using: env, forceRefresh: false)
    }

    // MARK: YouTube's Home paging

    func rowAppeared(_ video: VideoSummary, using env: AppEnvironment) {
        guard showsYouTube else { return }
        youTubePages.rowAppeared(video, fetch: youTubeFetch(using: env), filter: youTubeFilter(using: env))
    }

    func loadMore(using env: AppEnvironment) {
        guard showsYouTube else { return }
        youTubePages.loadMore(fetch: youTubeFetch(using: env), filter: youTubeFilter(using: env))
    }

    func retryLoadMore(using env: AppEnvironment) {
        guard showsYouTube else { return }
        youTubePages.retryLoadMore(fetch: youTubeFetch(using: env), filter: youTubeFilter(using: env))
    }

    private func youTubeFetch(using env: AppEnvironment) -> FeedPages<VideoSummary>.Fetch {
        { token in
            let page = try await env.recommendations.homePage(continuation: token)
            env.recommendationCardIDs.formUnion(page.cardIDs)
            return Page(items: page.videos, continuation: page.continuation)
        }
    }

    /// The user's filters, and what Home already shows elsewhere (Continue watching) or the viewer has finished.
    private func youTubeFilter(using env: AppEnvironment) -> FeedPages<VideoSummary>.Filter {
        let filter = env.contentFilter
        let excluded = Self.excludedIDs(env.library.history).union(HomeCardDismissals.shared.ids)
        return { videos in videos.filter { filter.allows($0) && !excluded.contains($0.id) } }
    }

    private static func excludedIDs(_ history: [HistoryEntry]) -> Set<String> {
        var ids = Set(HomeFeed.continueWatching(in: history).map(\.id))
        ids.formUnion(history.lazy.filter(\.isFinished).map(\.id))
        return ids
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
            while !Task.isCancelled, self.needsAnotherRun(using: env) {
                self.loadIsForced = false
                await self.run(using: env, forceRefresh: false)
            }
            self.loadTask = nil
        }
        loadTask = task
        return task
    }

    /// The subscriptions or the YouTube connection changed while a load ran.
    private func needsAnotherRun(using env: AppEnvironment) -> Bool {
        if Set(env.library.subscriptions.map(\.id)) != ranWithSubscriptionIDs { return true }
        guard let runningSignature else { return false }
        return !runningSignature.isSameSource(as: Signature(env, shownYouTube: runningSignature.shownYouTube))
    }

    private func run(using env: AppEnvironment, forceRefresh: Bool) async {
        generation += 1
        let thisGeneration = generation
        phase = .loading
        runningSignature = Signature(env, shownYouTube: false)
        ranWithSubscriptionIDs = Set(env.library.subscriptions.map(\.id))
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

        // YouTube's own Home first, when it is wanted: Continue watching is already on screen. Whatever it cannot do, the
        // on-device mix below takes over.
        if Self.wantsYouTube(env) {
            switch await loadYouTube(using: env, generation: thisGeneration) {
            case .shown:
                return
            case .superseded:
                if phase == .loading { phase = loadedAt == nil ? .idle : .loaded }
                return
            case .fellBack:
                break
            }
        } else if youTubeFellBack {
            youTubeFellBack = false
        }

        // A pull to refresh also brings in what was subscribed to elsewhere (on youtube.com, in another app) while the
        // app sat in the background: the Google subscriptions are synced first, so that the feed is built from the list as
        // it is now. A sync that fails keeps the list as it was.
        if forceRefresh {
            await env.refreshAccount()
        }

        let signature = Signature(env, shownYouTube: false)
        runningSignature = signature
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
        showsYouTube = false
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

    private enum YouTubeOutcome {
        /// YouTube's Home is on screen.
        case shown
        /// It was asked for and did not make it: the on-device mix goes on screen with a notice.
        case fellBack
        /// A newer load, or a change of the connection, took over meanwhile; nothing was published.
        case superseded
    }

    /// Asks YouTube for up to `HomeSourceDecision.maximumPages` pages, within `youTubeBudget`, stopping as soon as the
    /// decision says it has enough, and publishes them or reports why not. The result goes to the Diagnostics screen.
    private func loadYouTube(using env: AppEnvironment, generation thisGeneration: Int) async -> YouTubeOutcome {
        let started = Signature(env, shownYouTube: true)
        let filter = env.contentFilter
        let excluded = Self.excludedIDs(env.library.history)
        let service = env.recommendations
        let deadline = Date().addingTimeInterval(Self.youTubeBudget)
        var pages: [TVHomePage] = []
        var decision = HomeSourceDecision.Result(useYouTube: false, videos: [], continuation: nil)
        var token: String?
        while pages.count < HomeSourceDecision.maximumPages {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                #if DEBUG
                if !DebugLaunchHooks.mockConnection.isOnline { throw NoSlopError.network("The mock connection is off.") }
                #endif
                let next = token
                pages.append(try await Self.within(remaining) { try await service.homePage(continuation: next) })
            } catch {
                // Any failure ends the attempt; the pages that did arrive are still judged.
                break
            }
            decision = HomeSourceDecision.decide(pages: pages, filter: { filter.allows($0) }, excluded: excluded)
            if decision.useYouTube || pages[0].loggedIn != true { break }
            guard let next = pages.last?.continuation else { break }
            token = next
        }
        guard !Task.isCancelled, thisGeneration == generation else { return .superseded }
        // Disconnected, or switched off, while the pages were on their way: nothing of them is shown.
        guard Self.wantsYouTube(env), env.recommendationsRevision == started.revision else { return .superseded }

        if decision.useYouTube {
            env.recommendationCardIDs = pages.reduce(into: Set<String>()) { $0.formUnion($1.cardIDs) }
            built = HomeFeed(continueWatching: HomeFeed.continueWatching(in: env.library.history))
            showsYouTube = true
            youTubeFellBack = false
            relatedUnavailable = false
            youTubePages.reset(
                with: Page(items: decision.videos, continuation: decision.continuation),
                filter: youTubeFilter(using: env)
            )
            applyFilter(using: env)
            loadedSignature = started
            runningSignature = started
            loadedAt = Date()
            phase = .loaded
        } else {
            env.recommendationCardIDs = []
            showsYouTube = false
            youTubePages.removeAll()
            youTubeFellBack = true
        }
        await env.refreshRecommendationsDiagnostics()
        // The service reports whether it accepted the reply; whether Home used it is decided here.
        env.recommendationsDiagnostics.lastHome?.usedYouTube = decision.useYouTube
        // YouTube's Home really was the source: the watch reports that were kept are sent now.
        if decision.useYouTube { env.replayWatchReports() }
        #if DEBUG
        FeedLog.info("home youtube used=\(decision.useYouTube) pages=\(pages.count) videos=\(decision.videos.count)")
        #endif
        return decision.useYouTube ? .shown : .fellBack
    }

    /// Runs `operation`, and gives up on it (cancelling it) after `seconds`.
    private nonisolated static func within<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw NoSlopError.network("YouTube's Home took too long.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw NoSlopError.cancelled }
            return first
        }
    }

    /// Drops uploads of channels that are no longer subscribed (a cache can be older than an unsubscribe).
    private static func limited(_ uploads: [VideoSummary], to channelIDs: Set<String>) -> [VideoSummary] {
        uploads.filter { video in video.channel.map { channelIDs.contains($0.id) } ?? true }
    }
}
