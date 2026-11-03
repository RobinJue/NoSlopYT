import Foundation
import NoSlopKit
import Observation

/// A list that loads in pages (search results, a channel tab, a playlist): what is loaded, the token for the next
/// page, and whether the next page is on its way or failed.
///
/// - Items are de-duplicated by id (YouTube repeats items across continuation pages, and `ForEach` needs unique ids).
/// - The caller's `filter` runs on every page. A page the filter empties does not stall the list: loading goes on
///   with the next page, up to `maxEmptyPages` in a row. Then the list is `isPaused` and waits for a nudge: the user
///   scrolling to the end of it, or the screen's "Keep looking" / "Show more" button (both call `loadMore`).
/// - Loading runs in a task of the list's own, so a screen that disappears and returns does not restart it. `reset`
///   and `removeAll` start a new epoch: an answer that arrives for an older one is dropped.
@MainActor
@Observable
final class FeedPages<Item: Identifiable & Sendable> {
    /// Fetches the page behind a continuation token.
    typealias Fetch = @MainActor (String) async throws -> Page<Item>
    /// Removes what the user does not want to see (the app's content filter).
    typealias Filter = @MainActor ([Item]) -> [Item]

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
        seen = []
        items = []
        continuation = page.continuation
        append(filter(page.items))
    }

    /// Empties the list (a new search is starting, or the screen reloads).
    func removeAll() {
        cancelLoading()
        seen = []
        items = []
        continuation = nil
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
                let added = append(filter(page.items))
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

    /// Appends the items that are new and returns how many there were.
    @discardableResult
    private func append(_ newItems: [Item]) -> Int {
        var added = 0
        for item in newItems where seen.insert(item.id).inserted {
            items.append(item)
            added += 1
        }
        return added
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
