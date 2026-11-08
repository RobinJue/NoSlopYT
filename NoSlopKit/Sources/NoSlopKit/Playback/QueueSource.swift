import Foundation

/// The rest of a play queue that has not been loaded yet: the tail of a list that arrives in pages (a playlist), as the
/// token of its next page and the way to fetch it.
///
/// "Play all" and a tap on a row queue the videos that are loaded, and a long playlist has loaded only its first page
/// (YouTube sends about 100 at a time, the Data API 50). The player keeps a source next to that queue, takes the next
/// page from it when the queue runs low (`needsRefill`) and when it runs out, and so plays a playlist of 250 videos to
/// its end.
///
/// A source never refers to the screen it came from. Its closures capture what they need to load and to filter (the
/// app environment), not a view model: the screen is popped long before a long queue is over.
///
/// - Every video is handed out once. `knownIDs` are the ones the queue already has (or the list had, filtered or not),
///   and what a page brings is added to them whether the filter lets it through or not, so a video that was hidden once
///   is not a new video when it comes back on a later page.
/// - A page the filter empties does not end the queue: `next()` goes on with the next page, at most `maxEmptyPages` in
///   a row.
/// - A token that does not advance ends the list, so a service that repeats it cannot be asked for ever.
@MainActor
public final class QueueSource {
    /// Fetches the page behind a continuation token.
    public typealias Fetch = @MainActor (String) async throws -> Page<VideoSummary>
    /// Removes what the viewer does not want to see. It runs for every page, so a filter that changed meanwhile (a
    /// channel blocked while the queue plays) counts from the next page on.
    public typealias Filter = @MainActor ([VideoSummary]) -> [VideoSummary]

    /// The queue asks for more when this many videos or fewer are left behind the one that plays.
    public static let lowWater = 2
    /// Pages in a row that the filter may empty before `next()` gives up for now. The list is not over then
    /// (`hasMore`), and the next call looks at the pages after those.
    public static let maxEmptyPages = 10

    /// The token of the next page; nil at the end of the list.
    public private(set) var continuation: String?
    /// A call of `next()` is waiting for a page.
    public private(set) var isFetching = false
    /// How many videos the whole list has, when the list says so (a playlist's "51 videos"); nil when unknown.
    public let expectedTotal: Int?

    private var known: Set<String>
    private let fetch: Fetch
    private let filter: Filter

    /// - Parameters:
    ///   - continuation: the token of the first page the queue does not have; nil when the list is over.
    ///   - knownIDs: the videos the queue already has, so that none is queued twice.
    ///   - fetch: loads the page behind a token.
    ///   - filter: the viewer's filters, applied to each page.
    ///   - expectedTotal: the size the list states for itself, for the position text while pages are still to come.
    public init(
        continuation: String?,
        knownIDs: Set<String> = [],
        expectedTotal: Int? = nil,
        fetch: @escaping Fetch,
        filter: @escaping Filter = { $0 }
    ) {
        self.continuation = continuation
        self.known = knownIDs
        self.expectedTotal = expectedTotal
        self.fetch = fetch
        self.filter = filter
    }

    /// There is a page behind the last one handed out.
    public var hasMore: Bool {
        continuation != nil
    }

    /// The queue, with `queued` videos behind the one that plays, should ask for the next page now.
    public func needsRefill(queued: Int) -> Bool {
        hasMore && queued <= Self.lowWater
    }

    /// The next videos to queue: the next page that has any, after the filter and without those that came before.
    ///
    /// Empty at the end of the list (`hasMore` is false then), when `maxEmptyPages` pages in a row had nothing to
    /// show (`hasMore` stays true), and for a call made while another one is waiting for its page: that call gets the
    /// page, and a second one must not fetch the same token again.
    ///
    /// - Throws: what the fetch throws, and `CancellationError` when the calling task was cancelled. The source stays
    ///   where it was then, so a later call tries the same page again and nothing is lost.
    public func next() async throws -> [VideoSummary] {
        guard !isFetching else { return [] }
        isFetching = true
        defer { isFetching = false }

        var emptyPages = 0
        while let token = continuation, emptyPages < Self.maxEmptyPages {
            let page = try await fetch(token)
            // A caller that was cancelled does not want the page, and must not use it up either.
            try Task.checkCancellation()
            continuation = page.continuation == token ? nil : page.continuation
            let fresh = page.items.filter { known.insert($0.id).inserted }
            let wanted = filter(fresh)
            if !wanted.isEmpty { return wanted }
            emptyPages += 1
        }
        return []
    }
}
