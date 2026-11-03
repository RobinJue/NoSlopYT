import Foundation
import NoSlopKit
import Observation

/// A list that loads in pages (search results, a channel tab, a playlist): what is loaded, the token for the next
/// page, and whether the next page is on its way or failed.
///
/// - Every id is taken once, whether the filter lets the item through or not. YouTube repeats items across pages (the
///   Shorts shelf of a search's first page comes back as ordinary videos on the second) and `ForEach` needs unique
///   ids; a Short that was hidden on the first page must stay hidden when it returns looking like a video.
/// - The caller's `filter` runs on every page. A page the filter empties does not stall the list: loading goes on
///   with the next page, up to `maxEmptyPages` in a row. Then the list is `isPaused` and waits for a nudge: the user
///   scrolling to the end of it, or the screen's "Keep looking" / "Show more" button (both call `loadMore`).
/// - When the filter changes (the user blocks a channel, a setting is toggled) `refilter` applies the new one to what
///   has arrived, so rows go away, or come back, at once, without fetching anything again.
/// - Loading runs in a task of the list's own, so a screen that disappears and returns does not restart it. `reset`
///   and `removeAll` start a new epoch: an answer that arrives for an older one is dropped.
@MainActor
@Observable
final class FeedPages<Item: Identifiable & Sendable> {
    /// Fetches the page behind a continuation token.
    typealias Fetch = @MainActor (String) async throws -> Page<Item>
    /// Removes what the user does not want to see (the app's content filter).
    typealias Filter = @MainActor ([Item]) -> [Item]

    /// What is on screen: the items that arrived, after the filter.
    private(set) var items: [Item] = []
    /// The token of the next page; nil at the end of the list.
    private(set) var continuation: String?
    private(set) var isLoadingMore = false
    /// Why the last attempt to load more failed; a retry clears it.
    private(set) var loadMoreError: Error?
    /// Paging stopped before the end of the list without failing: the filter hid `maxEmptyPages` pages in a row, or a
    /// request was cancelled from outside. Nothing is loading, so a screen with no rows must not show loading
    /// placeholders for it; it offers to keep looking instead. `loadMore` goes on from here.
    private(set) var isPaused = false

    /// Every distinct item that arrived, in order, whether or not the filter let it through.
    @ObservationIgnored private var arrived: [Item] = []
    /// The ids of `arrived`: an id that came once is not taken again, whatever it looks like the next time.
    @ObservationIgnored private var seen: Set<Item.ID> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0

    /// How many rows from the end a row must be before the next page is requested.
    static var prefetchDistance: Int { 5 }
    /// Pages in a row that the filter may empty before paging pauses.
    static var maxEmptyPages: Int { 3 }

    var hasMore: Bool { continuation != nil }

    // MARK: Replacing the content

    /// Replaces everything with a first page. A page that is still loading is abandoned.
    func reset(with page: Page<Item>, filter: Filter = { $0 }) {
        cancelLoading()
        forgetItems()
        continuation = page.continuation
        append(page.items, filter: filter)
    }

    /// Empties the list (a new search is starting, or the screen reloads).
    func removeAll() {
        cancelLoading()
        forgetItems()
        continuation = nil
    }

    // MARK: Filtering

    /// The filter changed: shows what has arrived through `filter`. What it now hides goes away at once and what it
    /// now lets through comes back. A list whose last rows this takes away, with more pages behind it, goes on loading.
    func refilter(fetch: @escaping Fetch, filter: @escaping Filter) {
        let hadRows = !items.isEmpty
        let wanted = filter(arrived)
        // Not a new value when nothing changed, so the screen is not redrawn for a setting that is not about the feed.
        if wanted.map(\.id) != items.map(\.id) {
            items = wanted
        }
        if hadRows, items.isEmpty {
            loadMore(fetch: fetch, filter: filter)
        }
    }

    // MARK: Paging

    /// Call as a row appears: requests the next page when `item` is one of the last few rows.
    func rowAppeared(_ item: Item, fetch: @escaping Fetch, filter: @escaping Filter) {
        if items.suffix(Self.prefetchDistance).contains(where: { $0.id == item.id }) {
            loadMore(fetch: fetch, filter: filter)
        }
    }

    /// Loads the next page. Does nothing at the end of the list, while a page is loading, or after a failure (which
    /// waits for `retryLoadMore`).
    func loadMore(fetch: @escaping Fetch, filter: @escaping Filter) {
        guard continuation != nil, !isLoadingMore, loadMoreError == nil else { return }
        isPaused = false
        isLoadingMore = true
        let thisEpoch = epoch
        task = Task { [weak self] in
            await self?.run(epoch: thisEpoch, fetch: fetch, filter: filter)
        }
    }

    func retryLoadMore(fetch: @escaping Fetch, filter: @escaping Filter) {
        loadMoreError = nil
        loadMore(fetch: fetch, filter: filter)
    }

    private func run(epoch thisEpoch: Int, fetch: Fetch, filter: Filter) async {
        var emptyPages = 0
        while epoch == thisEpoch, let token = continuation {
            do {
                let page = try await fetch(token)
                guard epoch == thisEpoch else { return }
                // A token that does not advance ends the list, so a service that repeats it cannot loop us forever.
                continuation = page.continuation == token ? nil : page.continuation
                let added = append(page.items, filter: filter)
                emptyPages = added == 0 ? emptyPages + 1 : 0
                if added > 0 { break }
                if emptyPages >= Self.maxEmptyPages {
                    isPaused = continuation != nil
                    break
                }
            } catch {
                guard epoch == thisEpoch else { return }
                if FeedError.isCancellation(error) {
                    isPaused = continuation != nil
                    break
                }
                loadMoreError = error
                isLoadingMore = false
                task = nil
                return
            }
        }
        guard epoch == thisEpoch else { return }
        isLoadingMore = false
        task = nil
    }

    private func cancelLoading() {
        task?.cancel()
        task = nil
        epoch += 1
        isLoadingMore = false
        isPaused = false
        loadMoreError = nil
    }

    private func forgetItems() {
        seen = []
        arrived = []
        items = []
    }

    /// Takes the items of a page whose ids have not arrived before, and returns how many of them the filter let
    /// through (and so how many rows were added).
    @discardableResult
    private func append(_ newItems: [Item], filter: Filter) -> Int {
        let fresh = newItems.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return 0 }
        arrived.append(contentsOf: fresh)
        let wanted = filter(fresh)
        items.append(contentsOf: wanted)
        return wanted.count
    }
}

extension Sequence where Element: Identifiable {
    /// The elements without those whose id came before, in order. For lists built in one go (Home, Subscriptions), so
    /// `ForEach` never meets an id twice whatever a cache or a service hands over.
    func uniqued() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// What the loading code of the browse screens needs to decide about a failure.
enum FeedError {
    /// A cancelled load is not an error to show: the screen went away, or a newer request replaced this one.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let known = error as? NoSlopError, known == .cancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
