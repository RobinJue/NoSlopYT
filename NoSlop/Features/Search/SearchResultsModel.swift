import Foundation
import NoSlopKit
import Observation

/// One search and its results: the first page, the pages that follow, the filter, and what went wrong.
///
/// Shared by the Search tab (`SearchView`) and the pushed results screen (`SearchResultsView`). Searches run in a
/// task of the model's own, so a screen that disappears and returns does not restart them; a newer search (another
/// query or filter) cancels the older one and its late answer is ignored (`generation`).
@MainActor
@Observable
final class SearchResultsModel {
    enum Phase {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    private(set) var query = ""
    private(set) var filter = SearchFilter()
    private(set) var phase: Phase = .idle
    /// The results, page by page.
    let list = FeedPages<SearchItem>()

    /// There is a search to show (one was started and not cleared).
    var hasSearch: Bool { !query.isEmpty }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // MARK: Searching

    /// Starts a search, replacing the current one. `filter` nil keeps the current filter.
    func search(_ newQuery: String, filter newFilter: SearchFilter? = nil, using env: AppEnvironment) {
        searchTask?.cancel()
        generation += 1
        let thisGeneration = generation
        query = newQuery
        if let newFilter { filter = newFilter.normalized }
        list.removeAll()
        phase = .loading

        let currentFilter = filter
        searchTask = Task { [weak self] in
            do {
                let page = try await env.youTube.search(query: newQuery, filter: currentFilter)
                guard let self, self.generation == thisGeneration else { return }
                self.searchTask = nil
                let contentFilter = env.contentFilter
                self.list.reset(with: page) { contentFilter.filter($0) }
                self.phase = .loaded
                // A first page that the filters emptied still has more behind it.
                if self.list.items.isEmpty { self.loadMore(using: env) }
            } catch {
                guard let self, self.generation == thisGeneration else { return }
                self.searchTask = nil
                self.phase = FeedError.isCancellation(error) ? .idle : .failed(error)
            }
        }
    }

    /// For a screen that shows `query` and may appear more than once: searches the first time only.
    func loadIfNeeded(query: String, using env: AppEnvironment) {
        if self.query == query {
            switch phase {
            case .loading, .loaded: return
            case .idle, .failed: break
            }
        }
        search(query, using: env)
    }

    /// Runs the same search again (the Retry button).
    func retry(using env: AppEnvironment) {
        guard hasSearch else { return }
        search(query, using: env)
    }

    /// Pull to refresh: runs the search again and suspends until the first page is there.
    func refresh(using env: AppEnvironment) async {
        guard hasSearch else { return }
        search(query, using: env)
        await searchTask?.value
    }

    /// Changes the filter and searches again, unless nothing changed.
    func apply(filter newFilter: SearchFilter, using env: AppEnvironment) {
        let normalized = newFilter.normalized
        guard hasSearch, normalized != filter else {
            filter = normalized
            return
        }
        search(query, filter: normalized, using: env)
    }

    /// Forgets the search (the field was cleared).
    func clear() {
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        query = ""
        list.removeAll()
        phase = .idle
    }

    // MARK: Paging

    /// Called as rows appear: requests the next page when `item` is one of the last few rows.
    func rowAppeared(_ item: SearchItem, using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.rowAppeared(item, fetch: fetch(env), filter: contentFilter(env))
    }

    func loadMore(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.loadMore(fetch: fetch(env), filter: contentFilter(env))
    }

    func retryLoadMore(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.retryLoadMore(fetch: fetch(env), filter: contentFilter(env))
    }

    /// The feed filters changed (the user blocked a channel, or toggled a setting): applies them to the results that
    /// are on screen, right away.
    func filtersChanged(using env: AppEnvironment) {
        guard case .loaded = phase else { return }
        list.refilter(fetch: fetch(env), filter: contentFilter(env))
    }

    private func fetch(_ env: AppEnvironment) -> FeedPages<SearchItem>.Fetch {
        { token in try await env.youTube.searchMore(continuation: token) }
    }

    /// Built per page, so it follows settings changed in the meantime.
    private func contentFilter(_ env: AppEnvironment) -> FeedPages<SearchItem>.Filter {
        { items in env.contentFilter.filter(items) }
    }
}
