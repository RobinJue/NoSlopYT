import Foundation
import Observation

/// A paged list of videos from the signed-in account (the liked videos, the items of a playlist), shown through the
/// viewer's feed filters: the first page, more as the list scrolls, pull to refresh.
///
/// - The page source and the filter come with each call as a `Loader`, so the model needs no services of its own and a
///   screen can create it before the environment is known.
/// - Every video that arrives is kept, in order, whether or not the filter lets it through. `videos` is what the filter
///   shows. `refilter` shows what has arrived through a changed filter (the viewer blocked a channel, a setting was
///   toggled), so rows go away, or come back, at once and nothing is fetched again. Nothing is deduplicated: a
///   playlist may hold a video twice, and then it is listed twice.
/// - A page that adds no row (the filter hid all of it, or it held nothing but private and deleted videos) does not end
///   the list: loading goes on with the next page, up to `maxEmptyPages` in a row. Then the list `isPaused` and waits
///   for a nudge: `loadMore` ("Keep looking", "Show more", or the viewer scrolling to the end of the list).
/// - Every reload starts a new generation, and an answer that arrives for an older one is dropped.
@MainActor
@Observable
public final class AccountVideosModel {
    public enum Phase {
        case loading
        case loaded
        case failed(any Error)
    }

    /// Fetches one page; the argument is the token of the page (nil for the first).
    public typealias PageSource = @MainActor (String?) async throws -> Page<VideoSummary>
    /// Removes what the viewer does not want to see (the app's content filter).
    public typealias Filter = @MainActor ([VideoSummary]) -> [VideoSummary]

    /// Where the pages come from, and what is left out of them.
    public struct Loader {
        public var source: PageSource
        public var filter: Filter

        public init(source: @escaping PageSource, filter: @escaping Filter = { $0 }) {
            self.source = source
            self.filter = filter
        }
    }

    /// Pages in a row that the filter may empty before loading pauses.
    public static let maxEmptyPages = 3
    /// How many rows from the end of the list a row must be before the next page is requested.
    public static let prefetchDistance = 5

    /// What is on screen: the videos that arrived, after the filter.
    public private(set) var videos: [VideoSummary] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    /// Why the last attempt to load more failed; `loadMore` (the retry) clears it.
    public private(set) var loadMoreError: (any Error)?
    /// Loading stopped before the end of the list without failing: the filter hid `maxEmptyPages` pages in a row, or a
    /// request was cancelled from outside. Nothing is loading, so a screen with no rows must not show a spinner for it;
    /// it offers to keep looking instead. `loadMore` goes on from here.
    public private(set) var isPaused = false
    /// How many of the videos that arrived the filter hides.
    public private(set) var hiddenCount = 0

    private var continuation: String?
    /// Every video that arrived, in order, filtered or not.
    @ObservationIgnored private var arrived: [VideoSummary] = []
    /// Bumped on every reload, so a slow answer for an older request is dropped.
    @ObservationIgnored private var generation = 0

    public init() {}

    /// There is a page behind the last one that arrived.
    public var hasMore: Bool { continuation != nil }
    public var loadMoreFailed: Bool { loadMoreError != nil }

    // MARK: Loading

    /// The load a screen starts when it appears. It does nothing while there is a list on screen (even one that the
    /// filter hides entirely), so a screen that comes back (another tab and back) keeps the pages the viewer scrolled
    /// through instead of starting over from page one. A list with nothing in it has nothing to lose (and no pull to
    /// refresh), so it asks again. Pull to refresh and the error state's "Retry" call `reload`.
    public func loadIfNeeded(using loader: Loader) async {
        if case .loaded = phase, !arrived.isEmpty { return }
        await reload(using: loader)
    }

    /// Loads (or reloads) the first page. A reload that fails keeps the list that is already there.
    public func reload(using loader: Loader) async {
        generation += 1
        let current = generation
        isLoadingMore = false  // a load for an older generation no longer counts
        if arrived.isEmpty {
            phase = .loading
        }

        let page: Page<VideoSummary>
        do {
            page = try await loader.source(nil)
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            if arrived.isEmpty {
                phase = .failed(error)
            }
            return
        }
        guard current == generation, !Task.isCancelled else { return }

        arrived = page.items
        continuation = page.continuation
        loadMoreError = nil
        isPaused = false
        publish(using: loader)
        phase = .loaded

        // A first page that the filter emptied still has more behind it.
        if videos.isEmpty {
            await loadMore(using: loader)
        }
    }

    /// Called as a row appears: loads the next page once one of the last few rows is on screen.
    public func loadMoreIfNeeded(at index: Int, using loader: Loader) async {
        guard continuation != nil, !isLoadingMore, loadMoreError == nil, index >= videos.count - Self.prefetchDistance else { return }
        await loadMore(using: loader)
    }

    /// Loads the next page, and goes on while the pages add no row, `maxEmptyPages` of them in a row at most. Also the
    /// action of the "Retry" after a failed page and of "Keep looking" after a pause.
    public func loadMore(using loader: Loader) async {
        guard continuation != nil, !isLoadingMore else { return }
        let current = generation
        isLoadingMore = true
        isPaused = false
        loadMoreError = nil
        defer {
            if current == generation { isLoadingMore = false }
        }

        var emptyPages = 0
        while current == generation, let token = continuation {
            let page: Page<VideoSummary>
            do {
                page = try await loader.source(token)
            } catch {
                guard current == generation else { return }
                if Task.isCancelled || Self.isCancellation(error) {
                    isPaused = continuation != nil
                } else {
                    loadMoreError = error
                }
                return
            }
            guard current == generation else { return }
            if Task.isCancelled {
                isPaused = continuation != nil
                return
            }

            // A token that does not advance ends the list, so a service that repeats it cannot loop us forever.
            continuation = page.continuation == token ? nil : page.continuation
            let added = loader.filter(page.items).count
            arrived += page.items
            publish(using: loader)
            if added > 0 { return }

            emptyPages += 1
            if emptyPages >= Self.maxEmptyPages {
                isPaused = continuation != nil
                return
            }
        }
    }

    // MARK: Playing the list

    /// The rest of the list behind what has arrived, as the source of a play queue ("Play all", a tap on a row): the page
    /// the list would load next and the pages after it, which the player asks for as the queue runs low. Nil when the
    /// list is loaded to its end.
    ///
    /// The source knows every video that arrived, shown or hidden by the list's filter, so a video the filter hid once is
    /// not new when it comes round on a later page. `fetch` and `filter` are the caller's: the model is gone when its
    /// screen is popped, long before a long queue is over, so a source must not refer to it (or to the screen).
    public func queueSource(fetch: @escaping QueueSource.Fetch, filter: @escaping QueueSource.Filter) -> QueueSource? {
        guard let token = continuation else { return nil }
        return QueueSource(continuation: token, knownIDs: Set(arrived.map(\.id)), fetch: fetch, filter: filter)
    }

    // MARK: Filtering

    /// The filter changed: shows what has arrived through it. What it hides now goes away at once and what it lets
    /// through now comes back. A list whose last rows this takes away, with more pages behind it, goes on loading.
    public func refilter(using loader: Loader) async {
        guard case .loaded = phase else { return }
        let hadRows = !videos.isEmpty
        publish(using: loader)
        if hadRows, videos.isEmpty {
            await loadMore(using: loader)
        }
    }

    /// Shows `arrived` through the filter.
    private func publish(using loader: Loader) {
        let shown = loader.filter(arrived)
        // Not a new value when nothing changed, so a screen is not redrawn for a setting that is not about the list.
        if shown != videos { videos = shown }
        let hidden = arrived.count - shown.count
        if hidden != hiddenCount { hiddenCount = hidden }
    }

    /// A load that was cancelled (the screen went away, a newer request replaced it) is not an error to show.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let known = error as? NoSlopError, known == .cancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
