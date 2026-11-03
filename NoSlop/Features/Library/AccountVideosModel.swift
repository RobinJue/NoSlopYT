import Foundation
import NoSlopKit
import Observation

/// A paged list of videos from the signed-in account (liked videos, the items of a playlist): the first page, more
/// as the list scrolls, pull to refresh. The page source is passed to each call, so the model needs no services of
/// its own and the screen can create it before the environment is known.
@MainActor
@Observable
final class AccountVideosModel {
    enum Phase {
        case loading
        case loaded
        case failed(Error)
    }

    /// Fetches one page; the argument is the token of the page (nil for the first).
    typealias PageSource = (String?) async throws -> Page<VideoSummary>

    private(set) var videos: [VideoSummary] = []
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false

    private var continuation: String?
    /// Bumped on every reload, so a slow answer for an older request is dropped.
    private var generation = 0

    /// The load a screen starts when it appears. It does nothing while there is a list on screen, so a screen that
    /// comes back (another tab and back) keeps the pages the user scrolled through instead of starting over from page
    /// one. An empty list has nothing to lose (and no pull to refresh), so it asks again. Pull to refresh and the
    /// error state's "Retry" call `reload`.
    func loadIfNeeded(from source: PageSource) async {
        if case .loaded = phase, !videos.isEmpty { return }
        await reload(from: source)
    }

    /// Loads (or reloads) the first page. A reload that fails keeps the list that is already there.
    func reload(from source: PageSource) async {
        generation += 1
        let current = generation
        if videos.isEmpty {
            phase = .loading
        }
        do {
            let page = try await source(nil)
            guard current == generation, !Task.isCancelled else { return }
            videos = page.items
            continuation = page.continuation
            loadMoreFailed = false
            phase = .loaded
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            if videos.isEmpty {
                phase = .failed(error)
            }
        }
    }

    /// Called as a row appears: loads the next page once one of the last few rows is on screen.
    func loadMoreIfNeeded(at index: Int, from source: PageSource) async {
        guard continuation != nil, !isLoadingMore, !loadMoreFailed, index >= videos.count - 5 else { return }
        await loadMore(from: source)
    }

    /// Also the action of the "Retry" row after a failed page.
    func loadMore(from source: PageSource) async {
        guard let token = continuation, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let current = generation
        defer { isLoadingMore = false }
        do {
            let page = try await source(token)
            guard current == generation, !Task.isCancelled else { return }
            videos += page.items
            // A page that brings nothing and the same token again would loop forever.
            continuation = page.items.isEmpty || page.continuation == token ? nil : page.continuation
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            loadMoreFailed = true
        }
    }
}
