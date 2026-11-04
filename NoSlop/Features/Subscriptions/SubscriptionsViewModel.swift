import Foundation
import NoSlopKit
import Observation

/// Loads the chronological feed of uploads from the subscribed channels for `SubscriptionsView`.
///
/// The feed on disk is shown first (instant start), then refreshed. A refresh that fails keeps the feed that is on
/// screen and reports `refreshFailure`; only a screen with nothing to show becomes `.failed`.
@MainActor
@Observable
final class SubscriptionsViewModel {
    enum Phase {
        case idle
        /// First load, nothing to show yet.
        case loading
        case loaded
        /// First load failed and there is no cached feed to fall back on.
        case failed(Error)
    }

    private(set) var phase: Phase = .idle
    /// The feed after the user's filters, newest first.
    private(set) var videos: [VideoSummary] = []
    /// The channels in the order of their latest upload, for the avatar strip (channels without uploads follow).
    private(set) var channelOrder: [String] = []
    /// Set when a refresh failed while an older feed is on screen.
    private(set) var refreshFailure: Error?
    /// The feed has uploads, but the filters (Shorts, watched, blocked words) hide all of them.
    var isFilteredEmpty: Bool { videos.isEmpty && !unfiltered.isEmpty }
    var hasNoUploads: Bool { unfiltered.isEmpty }

    /// The feed before the user's filters.
    private var unfiltered: [VideoSummary] = []
    @ObservationIgnored private var loadedChannelIDs: [String]?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// A feed older than this is refreshed (not forced: the feed service decides what is still fresh) the next time
    /// the screen appears.
    #if DEBUG
    private static var maxAge: TimeInterval { DebugLaunchHooks.feedMaxAge ?? 10 * 60 }
    #else
    private static let maxAge: TimeInterval = 10 * 60
    #endif

    // MARK: Loading

    /// Loads the feed the first time, again when the subscriptions changed, and quietly when it is old. Otherwise it
    /// only re-applies the filters (the history or the settings may have changed). Returns immediately.
    func loadIfNeeded(using env: AppEnvironment) {
        guard loadTask == nil else { return }
        let channelIDs = env.library.subscriptions.map(\.id)
        if case .loaded = phase, loadedChannelIDs == channelIDs {
            if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge {
                applyFilter(using: env)
                return
            }
        }
        start(using: env, forceRefresh: false)
    }

    /// Pull to refresh: asks for fresh uploads. Suspends until the feed is loaded or has failed.
    func refresh(using env: AppEnvironment) async {
        if let running = loadTask {
            await running.value
            return
        }
        await start(using: env, forceRefresh: true).value
    }

    /// Re-applies the filters to the feed already loaded (cheap; no network).
    func applyFilter(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        let filtered = env.contentFilter.filter(unfiltered, context: .subscriptions)
        // Not a new value when nothing changed, so the screen is not redrawn for a setting that is not about the feed.
        if filtered.map(\.id) != videos.map(\.id) { videos = filtered }
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
        let channels = env.library.subscriptions
        let channelIDs = channels.map(\.id)
        loadedChannelIDs = channelIDs
        #if DEBUG
        FeedLog.info("subscriptions run force=\(forceRefresh) channels=\(channelIDs.count)")
        #endif

        guard !channels.isEmpty else {
            unfiltered = []
            videos = []
            channelOrder = []
            refreshFailure = nil
            loadedAt = Date()
            phase = .loaded
            return
        }

        // Nothing on screen yet: show the feed from the last session while the new one loads.
        if unfiltered.isEmpty {
            let cached = Self.limited(await env.subscriptionFeed.cachedFeed(), to: Set(channelIDs))
            if !cached.isEmpty {
                show(cached, using: env)
                phase = .loaded
            } else if case .loaded = phase {
                // Already loaded (an empty feed): keep it on screen while refreshing.
            } else {
                phase = .loading
            }
        }

        do {
            let fresh = try await env.subscriptionFeed.feed(channels: channels, forceRefresh: forceRefresh)
            show(Self.limited(fresh, to: Set(channelIDs)), using: env)
            refreshFailure = nil
            loadedAt = Date()
            phase = .loaded
            #if DEBUG
            FeedLog.info("subscriptions published videos=\(videos.count) channelOrder=\(channelOrder.count)")
            #endif
        } catch {
            if FeedError.isCancellation(error) {
                if case .loading = phase { phase = .idle }
                return
            }
            // Try again at the next visit rather than waiting 10 minutes on a feed that failed.
            loadedAt = nil
            if unfiltered.isEmpty {
                phase = .failed(error)
            } else {
                refreshFailure = error
                phase = .loaded
            }
        }
    }

    private func show(_ feed: [VideoSummary], using env: AppEnvironment) {
        // Every video once, whatever a cache on disk holds, so `ForEach` never meets an id twice.
        let feed = feed.uniqued()
        unfiltered = feed
        videos = env.contentFilter.filter(feed, context: .subscriptions)
        var seen = Set<String>()
        channelOrder = feed.compactMap { $0.channel?.id }.filter { seen.insert($0).inserted }
    }

    /// Drops uploads of channels that are no longer subscribed (a cached feed can be older than an unsubscribe).
    private static func limited(_ feed: [VideoSummary], to channelIDs: Set<String>) -> [VideoSummary] {
        feed.filter { video in video.channel.map { channelIDs.contains($0.id) } ?? true }
    }
}
