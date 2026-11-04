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
    private(set) var related: [VideoSummary] = []
    private(set) var isLoadingMoreRelated = false
    private(set) var commentsFirstPage: CommentsPage?

    /// The account's rating of the video; nil while signed out or not known yet.
    private(set) var rating: VideoRating?
    private(set) var isRating = false
    /// A message to show when liking failed.
    var ratingFailure: String?

    private var relatedContinuation: String?
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
            apply(cached.details, related: cached.related, relatedContinuation: cached.relatedContinuation)
            commentsFirstPage = cached.commentsFirstPage
            publishToPlayer(env)
            return
        }

        phase = .loading
        do {
            let details = try await env.youTube.videoDetails(id: video.id)
            guard !Task.isCancelled else { return }
            apply(
                details,
                related: env.contentFilter.filter(details.related),
                relatedContinuation: details.relatedContinuation
            )
            publishToPlayer(env)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error)
            return
        }

        // The teaser is a bonus: without it the card just shows the comment count.
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

    private func apply(_ details: VideoDetails, related: [VideoSummary], relatedContinuation: String?) {
        self.details = details
        self.related = Self.unique(related, excluding: [video.id])
        self.relatedContinuation = relatedContinuation
        phase = .loaded
    }

    /// Hands the player what it needs from the page: chapters for the seek bar and the autoplay candidates.
    /// Only for the video that is playing, so a slow answer for an earlier video never lands on the current one.
    private func publishToPlayer(_ env: AppEnvironment) {
        guard let details, env.player.currentVideo?.id == video.id else { return }
        env.player.setChapters(details.chapters)
        env.player.setUpNext(related)
    }

    private func storeInCache() {
        guard let details else { return }
        WatchDetailsCache.shared.store(
            .init(
                details: details,
                related: related,
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
                let known = Set(related.map(\.id) + [video.id])
                let fresh = Self.unique(env.contentFilter.filter(page.items), excluding: known)
                related += fresh
                relatedContinuation = page.continuation == token ? nil : page.continuation
                if !fresh.isEmpty { break }
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
        var related: [VideoSummary]
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
