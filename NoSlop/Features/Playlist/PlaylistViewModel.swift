import Foundation
import NoSlopKit
import Observation

/// Loads a public YouTube playlist for `PlaylistView`: the header (title, owner, count, description) and the first
/// page of videos in one request, then the rest with `playlistMore` as the list scrolls.
///
/// Loads run in tasks of the model's own, so leaving the screen and coming back does not cancel or restart them.
/// Pull to refresh reloads the playlist and keeps the old one on screen until the new one is there.
@MainActor
@Observable
final class PlaylistViewModel {
    enum Phase {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    let playlistID: String
    private(set) var phase: Phase = .idle
    private(set) var info: PlaylistSummary?
    private(set) var details: String?
    /// The videos, page by page, after the user's filters.
    let list = FeedPages<VideoSummary>()

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(playlistID: String) {
        self.playlistID = playlistID
    }

    /// The link to the playlist on YouTube (for sharing and "Open on YouTube").
    var webURL: URL? {
        var components = URLComponents(string: "https://www.youtube.com/playlist")
        components?.queryItems = [URLQueryItem(name: "list", value: playlistID)]
        return components?.url
    }

    // MARK: Loading

    /// Loads the playlist the first time the screen appears. A failed load waits for `retry`.
    func loadIfNeeded(using env: AppEnvironment) {
        guard case .idle = phase else { return }
        load(using: env, showsPlaceholders: true)
    }

    func retry(using env: AppEnvironment) {
        load(using: env, showsPlaceholders: true)
    }

    /// Pull to refresh. Suspends until the playlist is reloaded; a failure keeps what is on screen.
    func refresh(using env: AppEnvironment) async {
        load(using: env, showsPlaceholders: info == nil)
        await loadTask?.value
    }

    private func load(using env: AppEnvironment, showsPlaceholders: Bool) {
        loadTask?.cancel()
        generation += 1
        let thisGeneration = generation
        if showsPlaceholders {
            phase = .loading
            info = nil
            details = nil
            list.removeAll()
        }

        let id = playlistID
        loadTask = Task { [weak self] in
            do {
                let page = try await env.youTube.playlist(id: id)
                guard let self, self.generation == thisGeneration else { return }
                self.loadTask = nil
                self.info = page.info
                self.details = page.description
                self.list.reset(with: page.videos, filter: self.contentFilter(env))
                self.phase = .loaded
                // A first page that the filters emptied still has more behind it.
                if self.list.items.isEmpty { self.loadMore(using: env) }
            } catch {
                guard let self, self.generation == thisGeneration else { return }
                self.loadTask = nil
                if FeedError.isCancellation(error) {
                    if self.info == nil { self.phase = .idle }
                } else if self.info == nil {
                    self.phase = .failed(error)
                }
                // A failed refresh leaves the playlist that is on screen.
            }
        }
    }

    // MARK: Paging

    func rowAppeared(_ video: VideoSummary, using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.rowAppeared(video, fetch: fetch(env), filter: contentFilter(env))
    }

    func loadMore(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.loadMore(fetch: fetch(env), filter: contentFilter(env))
    }

    func retryLoadMore(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.retryLoadMore(fetch: fetch(env), filter: contentFilter(env))
    }

    /// The feed filters changed (the user blocked a channel, or toggled a setting): applies them to the videos that
    /// are on screen, right away.
    func filtersChanged(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.refilter(fetch: fetch(env), filter: contentFilter(env))
    }

    private func fetch(_ env: AppEnvironment) -> FeedPages<VideoSummary>.Fetch {
        { token in try await env.youTube.playlistMore(continuation: token) }
    }

    /// Built per page, so it follows settings changed in the meantime.
    private func contentFilter(_ env: AppEnvironment) -> FeedPages<VideoSummary>.Filter {
        { videos in env.contentFilter.filter(videos) }
    }

    // MARK: Playing

    /// The videos that follow `video` in the list, for the player's queue.
    func videos(after video: VideoSummary) -> [VideoSummary] {
        guard let index = list.items.firstIndex(where: { $0.id == video.id }) else { return [] }
        return Array(list.items.suffix(from: index + 1))
    }
}
