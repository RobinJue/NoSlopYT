import Foundation
import NoSlopKit
import Observation

/// What the watch page knows about one video: the details from YouTube, the "Up next" list, the first comments for
/// the teaser, and the like state of a signed-in account. Loading is done by the view's `.task`, never by `init`.
@MainActor
@Observable
final class WatchDetailsViewModel {
    enum Phase {
        case loading
        case loaded
        case failed(Error)
    }

    /// The video the page was opened for. It may be a bare id (empty title) when it came from a link.
    let video: VideoSummary

    private(set) var phase: Phase = .loading
    private(set) var details: VideoDetails?
    /// The "Up next" list: the related videos through the viewer's filters as they are now.
    private(set) var related: [VideoSummary] = []
    private(set) var isLoadingMoreRelated = false
    private(set) var commentsFirstPage: CommentsPage?

    /// The account's rating of the video; nil while signed out or not known yet.
    private(set) var rating: VideoRating?
    private(set) var isRating = false
    /// A message to show when liking failed.
    var ratingFailure: String?

    private var relatedContinuation: String?
    /// Every related video that has arrived, before the viewer's filters: without repeats and without this video.
    /// `related` is this list through the filters. Keeping both lets a change of the filters act on the page at once (a
    /// channel blocked takes its videos out, one unblocked brings them back) without asking YouTube again, and lets the
    /// cache replay the page through the filters of the day instead of the ones of the visit that stored it.
    private var arrivedRelated: [VideoSummary] = []
    /// What YouTube had when the rating was loaded, so the shown like count can follow the user's own change.
    private var ratingBaseline: VideoRating?

    init(video: VideoSummary) {
        self.video = video
    }

    // MARK: Derived

    /// `video` completed with what the details know: the title and channel of a bare id, the views and age.
    var summary: VideoSummary {
        var result = video
        guard let details else { return result }
        if result.title.isEmpty { result.title = details.title }
        if let channel {
            result.channel = channel
        }
        if result.viewCount == nil && result.viewCountText == nil {
            result.viewCount = details.viewCount
            result.viewCountText = details.viewCountText
        }
        if result.publishedText == nil {
            result.publishedText = details.relativeDateText
        }
        // The details are newer than the card the page was opened from: a broadcast saved while it was live is an
        // ordinary video now, and saving it again must not write the old flag back.
        result.isLive = details.isLive
        return result
    }

    /// The uploader, with the avatar from whichever source has one.
    var channel: ChannelRef? {
        let fromDetails = details.map(\.channel).flatMap { $0.id.isEmpty ? nil : $0 }
        let fromVideo = video.channel
        guard var result = fromDetails ?? fromVideo else { return nil }
        if result.avatarURL == nil {
            result.avatarURL = fromVideo?.avatarURL ?? fromDetails?.avatarURL
        }
        return result
    }

    var isLive: Bool {
        details?.isLive ?? video.isLive
    }

    /// "23,500,582 views · Nov 10, 2014"
    var statsLine: String {
        var parts: [String] = []
        if let views = firstNonEmpty(details?.viewCountText, details?.shortViewCountText, video.viewCountText) {
            parts.append(views)
        }
        if let date = firstNonEmpty(details?.dateText, details?.relativeDateText, video.publishedText) {
            parts.append(date)
        }
        return parts.joined(separator: " · ")
    }

    /// The text of the Like chip: YouTube's own count, moved by one when the user's rating differs from the loaded one.
    var likeCountLabel: String? {
        guard let details else { return nil }
        let delta = (rating == .like ? 1 : 0) - (ratingBaseline == .like ? 1 : 0)
        if delta == 0 {
            return firstNonEmpty(details.likeCountText) ?? details.likeCount.map(Self.compactCount)
        }
        guard let base = details.likeCount else { return details.likeCountText }
        return Self.compactCount(max(0, base + delta))
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func compactCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    // MARK: Loading

    /// Shows the cached page right away, or asks YouTube; then loads the first comments for the teaser.
    func load(using env: AppEnvironment) async {
        if let cached = WatchDetailsCache.shared.entry(for: video.id) {
            showCached(cached, using: env)
            // A page that the player stored while it was minimized has no teaser yet (see `loadForPlayer`), and neither
            // has one whose teaser could not be loaded then.
            if cached.commentsFirstPage == nil, cached.details.commentsContinuation != nil {
                await loadCommentsTeaser(using: env)
            }
            return
        }

        phase = .loading
        do {
            let details = try await env.youTube.videoDetails(id: video.id)
            guard !Task.isCancelled else { return }
            apply(details, arrivedRelated: details.related, relatedContinuation: details.relatedContinuation, using: env)
            publishToPlayer(env)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error)
            return
        }

        await loadCommentsTeaser(using: env)
    }

    /// What the player needs from the details when no watch page is on screen to hand it over (the player is minimized,
    /// or the app is in the background): the chapters for its seek bar and the up-next list for autoplay, from the
    /// cache or from YouTube, through the viewer's filters. Without it, a video that autoplay starts has no chapters,
    /// and autoplay only goes on with what was left of the list of the video before, until that runs out.
    ///
    /// The comments teaser is left out: nobody sees it. The page that opens later loads it (`load`).
    func loadForPlayer(using env: AppEnvironment) async {
        if let cached = WatchDetailsCache.shared.entry(for: video.id) {
            showCached(cached, using: env)
            return
        }
        do {
            let details = try await env.youTube.videoDetails(id: video.id)
            guard !Task.isCancelled else { return }
            apply(details, arrivedRelated: details.related, relatedContinuation: details.relatedContinuation, using: env)
            publishToPlayer(env)
            storeInCache()
        } catch {
            // The player plays on with what it has; autoplay carries on with what is left of the list it was given.
        }
    }

    /// The first comments, for the teaser. They are a bonus: without them the card just shows the comment count.
    private func loadCommentsTeaser(using env: AppEnvironment) async {
        if let token = details?.commentsContinuation {
            let page = try? await env.youTube.comments(continuation: token)
            guard !Task.isCancelled else { return }
            commentsFirstPage = page
        }
        storeInCache()
    }

    /// "Retry" after an error: forget what was cached and ask again.
    func reload(using env: AppEnvironment) async {
        WatchDetailsCache.shared.removeEntry(for: video.id)
        details = nil
        await load(using: env)
    }

    /// A page of an earlier visit, or one the player loaded, through the viewer's filters as they are now.
    private func showCached(_ cached: WatchDetailsCache.Entry, using env: AppEnvironment) {
        apply(cached.details, arrivedRelated: cached.arrivedRelated, relatedContinuation: cached.relatedContinuation, using: env)
        commentsFirstPage = cached.commentsFirstPage
        publishToPlayer(env)
    }

    /// `arrivedRelated` is every related video that has arrived, before the viewer's filters (see the property).
    private func apply(
        _ details: VideoDetails,
        arrivedRelated: [VideoSummary],
        relatedContinuation: String?,
        using env: AppEnvironment
    ) {
        self.details = details
        self.arrivedRelated = Self.unique(arrivedRelated, excluding: [video.id])
        self.related = env.contentFilter.filter(self.arrivedRelated)
        self.relatedContinuation = relatedContinuation
        phase = .loaded
    }

    /// The viewer's filters changed (a channel was blocked from a row of this very list, or a setting was toggled):
    /// shows the related videos through them at once, and hands the player the new list, which is the one autoplay
    /// chooses from. The cache keeps the list before the filters, so there is nothing to store.
    func filtersChanged(using env: AppEnvironment) {
        guard details != nil else { return }
        let wanted = env.contentFilter.filter(arrivedRelated)
        // Not a new value when nothing changed, so the page is not drawn again for a setting that is not about the feed.
        guard wanted.map(\.id) != related.map(\.id) else { return }
        related = wanted
        publishToPlayer(env)
    }

    /// Hands the player what it needs from the page: what it knows about the video itself (the title, channel, views and
    /// age of a video that was opened from a bare link), the chapters for the seek bar and the autoplay candidates.
    /// Only for the video that is playing, so a slow answer for an earlier video never lands on the current one.
    private func publishToPlayer(_ env: AppEnvironment) {
        guard let details, env.player.currentVideo?.id == video.id else { return }
        env.player.complete(with: details.summary)
        env.player.setChapters(details.chapters)
        env.player.setUpNext(related)
    }

    private func storeInCache() {
        guard let details else { return }
        WatchDetailsCache.shared.store(
            .init(
                details: details,
                arrivedRelated: arrivedRelated,
                relatedContinuation: relatedContinuation,
                commentsFirstPage: commentsFirstPage,
                storedAt: Date()
            ),
            for: video.id
        )
    }

    // MARK: Related videos

    /// Called as a row appears: loads the next page of related videos once one of the last few rows is on screen.
    func loadMoreRelatedIfNeeded(currentID: String, using env: AppEnvironment) async {
        guard relatedContinuation != nil, !isLoadingMoreRelated,
              related.suffix(5).contains(where: { $0.id == currentID }) else { return }

        isLoadingMoreRelated = true
        defer { isLoadingMoreRelated = false }

        // A page can be empty after filtering (Shorts, blocked channels, repeats); keep going a few pages so the
        // list does not end while YouTube still has more.
        var attempts = 0
        while attempts < 4, let token = relatedContinuation {
            attempts += 1
            do {
                let page = try await env.youTube.moreRelated(continuation: token)
                guard !Task.isCancelled else { return }
                // Every video that arrived stays known, shown or not: one the filters hid is not new when it comes
                // back, and one they let through later is already here.
                arrivedRelated += Self.unique(page.items, excluding: Set(arrivedRelated.map(\.id) + [video.id]))
                let shown = env.contentFilter.filter(arrivedRelated)
                let gained = shown.count > related.count
                related = shown
                relatedContinuation = page.continuation == token ? nil : page.continuation
                if gained { break }
            } catch {
                // Keep the list; reaching its end again tries once more.
                return
            }
        }
        publishToPlayer(env)
        storeInCache()
    }

    private static func unique(_ videos: [VideoSummary], excluding known: Set<String>) -> [VideoSummary] {
        var seen = known
        return videos.filter { seen.insert($0.id).inserted }
    }

    // MARK: Rating

    /// Loads the rating when signed in; signed out (or after sign-out) clears it.
    func loadRating(using env: AppEnvironment) async {
        guard env.googleAccount != nil else {
            rating = nil
            ratingBaseline = nil
            return
        }
        do {
            let value = try await env.account.rating(videoID: video.id)
            guard !Task.isCancelled else { return }
            rating = value
            ratingBaseline = value
        } catch {
            // Unknown rating: liking still works, the count just is not adjusted.
        }
    }

    /// Likes the video, or takes the like back. Shown at once, and undone when YouTube refuses.
    func toggleLike(using env: AppEnvironment) async {
        guard env.googleAccount != nil, !isRating else { return }
        let before = rating
        let next: VideoRating = before == .like ? VideoRating.none : .like
        rating = next
        isRating = true
        defer { isRating = false }
        do {
            try await env.account.rate(videoID: video.id, rating: next)
        } catch {
            rating = before
            ratingFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Cache

/// The last few watch pages, so minimizing the player and opening it again does not reload the page.
@MainActor
final class WatchDetailsCache {
    static let shared = WatchDetailsCache()

    struct Entry {
        var details: VideoDetails
        /// The related videos that had arrived, before the viewer's filters: they are applied when the page is shown.
        var arrivedRelated: [VideoSummary]
        var relatedContinuation: String?
        var commentsFirstPage: CommentsPage?
        var storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity = 12
    private let timeToLive: TimeInterval = 10 * 60

    func entry(for id: String) -> Entry? {
        guard let entry = entries[id] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < timeToLive else {
            removeEntry(for: id)
            return nil
        }
        return entry
    }

    func store(_ entry: Entry, for id: String) {
        entries[id] = entry
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }

    func removeEntry(for id: String) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }
}
