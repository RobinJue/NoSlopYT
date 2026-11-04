import Foundation
import Testing
@testable import NoSlopKit

// The liked videos and the YouTube playlists of the account go through the viewer's feed filters like every other list
// (google-4): what the filter hides stays hidden while paging goes on, and a changed filter applies at once.

private func video(_ id: String, channel: String? = nil) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)", channel: channel.map { ChannelRef(id: $0, name: "Channel \($0)") })
}

private func page(_ ids: [String], next: String? = nil, channel: String? = nil) -> Page<VideoSummary> {
    Page(items: ids.map { video($0, channel: channel) }, continuation: next)
}

/// A filter that hides the videos with these ids, and counts how often it ran.
@MainActor
private final class Hiding {
    var hidden: Set<String>
    init(_ hidden: Set<String> = []) { self.hidden = hidden }
    var filter: AccountVideosModel.Filter { { [self] videos in videos.filter { !hidden.contains($0.id) } } }
}

/// Pages by token (the first page has the token "first"), the tokens asked for in order, and failures to throw once.
@MainActor
private final class Pages {
    var pages: [String: Page<VideoSummary>]
    var failures: [String: any Error] = [:]
    private(set) var asked: [String] = []

    init(_ pages: [String: Page<VideoSummary>]) { self.pages = pages }

    func source(_ token: String?) async throws -> Page<VideoSummary> {
        let key = token ?? "first"
        asked.append(key)
        await Task.yield()
        if let failure = failures.removeValue(forKey: key) { throw failure }
        return pages[key] ?? Page()
    }

    func loader(hiding: Hiding = Hiding()) -> AccountVideosModel.Loader {
        AccountVideosModel.Loader(source: { try await self.source($0) }, filter: hiding.filter)
    }
}

/// Holds an answer until the test opens it.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }

    /// Returns once an answer is waiting here. Gives up after a great many turns of the main actor, so a bug fails the
    /// test instead of hanging the run.
    func untilWaiting() async {
        for _ in 0..<100_000 where !isWaiting {
            await Task.yield()
        }
    }
}

@MainActor
private func ids(_ model: AccountVideosModel) -> [String] {
    model.videos.map(\.id)
}

@MainActor
@Suite struct AccountVideosModelTests {
    // MARK: The filter

    @Test func theFirstPageIsShownThroughTheFilter() async {
        let pages = Pages(["first": page(["a", "b", "c"], next: "2")])
        let hiding = Hiding(["b"])
        let model = AccountVideosModel()

        await model.reload(using: pages.loader(hiding: hiding))

        #expect(ids(model) == ["a", "c"])
        #expect(model.hiddenCount == 1)
        #expect(model.hasMore)
        #expect(pages.asked == ["first"])
        if case .loaded = model.phase {} else { Issue.record("expected .loaded, got \(model.phase)") }
    }

    @Test func aChangedFilterAppliesToWhatArrivedWithoutFetchingAnything() async {
        let pages = Pages(["first": page(["a", "b", "c"], next: "2")])
        let hiding = Hiding()
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: hiding)
        await model.reload(using: loader)
        #expect(ids(model) == ["a", "b", "c"])

        hiding.hidden = ["a", "c"]  // the viewer blocked a channel
        await model.refilter(using: loader)
        #expect(ids(model) == ["b"])
        #expect(model.hiddenCount == 2)

        hiding.hidden = []  // ...and unblocked it again: the rows come back, in their place
        await model.refilter(using: loader)
        #expect(ids(model) == ["a", "b", "c"])
        #expect(model.hiddenCount == 0)

        #expect(pages.asked == ["first"], "filtering never asks the account again")
    }

    @Test func everyPageAfterTheFirstIsFilteredToo() async {
        let pages = Pages([
            "first": page(["a", "b"], next: "2"),
            "2": page(["c", "d", "e"], next: "3"),
        ])
        let hiding = Hiding(["d"])
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: hiding)
        await model.reload(using: loader)

        await model.loadMore(using: loader)

        #expect(ids(model) == ["a", "b", "c", "e"])
        #expect(model.hiddenCount == 1)
        hiding.hidden = []
        await model.refilter(using: loader)
        #expect(ids(model) == ["a", "b", "c", "d", "e"], "what was hidden on a later page comes back too")
    }

    @Test func theFilterIsTheViewersContentFilter() async {
        // End to end with the real filter: a Short, a blocked channel and a blocked word are gone from the list.
        var settings = AppSettings()
        settings.blockedChannels = [BlockedChannel(id: "UCblocked", name: "Blocked")]
        settings.blockedKeywords = ["spoiler"]
        let filter = ContentFilter(settings: settings)
        var short = video("short")
        short.isShort = true
        var spoiler = video("spoiler")
        spoiler.title = "Big SPOILER inside"
        let blocked = video("blocked", channel: "UCblocked")
        let pages = Pages(["first": Page(items: [video("fine"), short, blocked, spoiler, video("also-fine")])])
        let model = AccountVideosModel()

        await model.reload(using: .init(source: { try await pages.source($0) }, filter: { filter.filter($0) }))

        #expect(ids(model) == ["fine", "also-fine"])
        #expect(model.hiddenCount == 3)
    }

    // MARK: Paging behind the filter

    @Test func aFirstPageTheFilterEmptiesDoesNotEndTheList() async {
        let pages = Pages([
            "first": page(["s1", "s2"], next: "2"),
            "2": page(["s3"], next: "3"),
            "3": page(["good"], next: "4"),
        ])
        let model = AccountVideosModel()

        await model.reload(using: pages.loader(hiding: Hiding(["s1", "s2", "s3"])))

        #expect(pages.asked == ["first", "2", "3"], "it kept looking until a page had something to show")
        #expect(ids(model) == ["good"])
        #expect(!model.isPaused && !model.isLoadingMore)
        #expect(model.hasMore)
    }

    @Test func loadingPausesAfterThreeEmptyPagesAndGoesOnWhenNudged() async {
        let pages = Pages([
            "first": page(["s1"], next: "2"),
            "2": page(["s2"], next: "3"),
            "3": page(["s3"], next: "4"),
            "4": page(["s4"], next: "5"),
            "5": page(["good"], next: nil),
        ])
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: Hiding(["s1", "s2", "s3", "s4"]))

        await model.reload(using: loader)

        #expect(AccountVideosModel.maxEmptyPages == 3)
        #expect(pages.asked == ["first", "2", "3", "4"], "the first page, then at most three more that add nothing")
        #expect(model.videos.isEmpty)
        #expect(model.isPaused)
        #expect(model.hasMore)
        #expect(!model.isLoadingMore, "nothing is loading, so the screen must not show a spinner")

        await model.loadMore(using: loader)  // "Keep looking"

        #expect(pages.asked.last == "5")
        #expect(ids(model) == ["good"])
        #expect(!model.isPaused)
        #expect(!model.hasMore)
    }

    @Test func aPageOfPrivateAndDeletedVideosIsNotTheEndOfAPlaylist() async {
        // The Data API's playlistItems leave out private and deleted videos: a page can arrive with nothing in it and a
        // token for the next one. The playlist goes on there.
        let pages = Pages([
            "first": page(["a"], next: "2"),
            "2": Page(items: [], continuation: "3"),
            "3": page(["b"], next: nil),
        ])
        let model = AccountVideosModel()
        let loader = pages.loader()
        await model.reload(using: loader)

        await model.loadMore(using: loader)

        #expect(pages.asked == ["first", "2", "3"])
        #expect(ids(model) == ["a", "b"])
        #expect(!model.hasMore)
    }

    @Test func aTokenThatDoesNotAdvanceEndsTheList() async {
        let pages = Pages([
            "first": page(["a"], next: "2"),
            "2": page(["s"], next: "2"),
        ])
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: Hiding(["s"]))
        await model.reload(using: loader)

        await model.loadMore(using: loader)

        #expect(!model.hasMore, "a service that repeats its token cannot make us loop")
        #expect(pages.asked == ["first", "2"])
        #expect(!model.isPaused)
    }

    @Test func aFilterThatTakesAwayTheLastRowsKeepsLookingBehindThem() async {
        let pages = Pages([
            "first": page(["a", "b"], next: "2"),
            "2": page(["c"], next: nil),
        ])
        let hiding = Hiding()
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: hiding)
        await model.reload(using: loader)
        #expect(ids(model) == ["a", "b"])

        hiding.hidden = ["a", "b"]
        await model.refilter(using: loader)

        #expect(pages.asked == ["first", "2"], "the screen is empty and there is more: it asks for the next page")
        #expect(ids(model) == ["c"])
    }

    @Test func rowsNearTheEndOfTheShownListLoadTheNextPage() async {
        let first = (0..<20).map { "v\($0)" }
        let pages = Pages(["first": page(first, next: "2"), "2": page(["late"])])
        let hiding = Hiding(["v0", "v1", "v2", "v3", "v4"])  // 15 rows are shown
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: hiding)
        await model.reload(using: loader)
        #expect(model.videos.count == 15)

        await model.loadMoreIfNeeded(at: 3, using: loader)
        #expect(pages.asked == ["first"], "far from the end")
        await model.loadMoreIfNeeded(at: 9, using: loader)
        #expect(pages.asked == ["first"], "the shown list has 15 rows, so row 9 is still five or more from its end")
        await model.loadMoreIfNeeded(at: 10, using: loader)
        #expect(pages.asked == ["first", "2"])
        #expect(model.videos.last?.id == "late")
    }

    @Test func aVideoListedTwiceStaysListedTwice() async {
        let pages = Pages(["first": page(["a", "b", "a"])])
        let model = AccountVideosModel()

        await model.reload(using: pages.loader())

        #expect(ids(model) == ["a", "b", "a"], "a playlist may hold a video twice")
    }

    // MARK: Failures and stale answers

    @Test func aFirstLoadThatFailsIsAFailureAndRetryingRecovers() async {
        let pages = Pages(["first": page(["a"])])
        pages.failures["first"] = NoSlopError.network("offline")
        let model = AccountVideosModel()
        let loader = pages.loader()

        await model.reload(using: loader)
        if case .failed(let error) = model.phase {
            #expect(error as? NoSlopError == .network("offline"))
        } else {
            Issue.record("expected .failed, got \(model.phase)")
        }

        await model.reload(using: loader)
        if case .loaded = model.phase {} else { Issue.record("expected .loaded, got \(model.phase)") }
        #expect(ids(model) == ["a"])
    }

    @Test func aReloadThatFailsKeepsTheList() async {
        let pages = Pages(["first": page(["a", "b"])])
        let model = AccountVideosModel()
        let loader = pages.loader()
        await model.reload(using: loader)

        pages.failures["first"] = NoSlopError.network("offline")
        await model.reload(using: loader)

        #expect(ids(model) == ["a", "b"])
        if case .loaded = model.phase {} else { Issue.record("expected .loaded, got \(model.phase)") }
    }

    @Test func aPageThatFailsCanBeRetriedAndIsNotRetriedByScrolling() async {
        let first = (0..<10).map { "v\($0)" }
        let pages = Pages(["first": page(first, next: "2"), "2": page(["late"])])
        let model = AccountVideosModel()
        let loader = pages.loader()
        await model.reload(using: loader)

        pages.failures["2"] = NoSlopError.network("offline")
        await model.loadMoreIfNeeded(at: 9, using: loader)
        #expect(model.loadMoreFailed)
        #expect(model.loadMoreError as? NoSlopError == .network("offline"))
        #expect(ids(model).count == 10, "the rows that are there stay")

        await model.loadMoreIfNeeded(at: 9, using: loader)
        #expect(pages.asked == ["first", "2"], "scrolling does not hammer a failing page; the retry button does")

        await model.loadMore(using: loader)
        #expect(!model.loadMoreFailed)
        #expect(model.videos.last?.id == "late")
    }

    @Test func aCancelledPageMakesAPauseNotAnError() async {
        let pages = Pages(["first": page(["a"], next: "2"), "2": page(["b"])])
        let model = AccountVideosModel()
        let loader = pages.loader()
        await model.reload(using: loader)

        pages.failures["2"] = NoSlopError.cancelled
        await model.loadMore(using: loader)

        #expect(!model.loadMoreFailed)
        #expect(model.isPaused, "the screen offers to go on instead of showing \"Cancelled.\"")
        await model.loadMore(using: loader)
        #expect(ids(model) == ["a", "b"])
    }

    @Test func aSlowAnswerForAnOlderReloadIsDropped() async {
        let gate = Gate()
        let slow = AccountVideosModel.Loader(source: { _ in
            await gate.wait()
            return page(["old"])
        })
        let fast = AccountVideosModel.Loader(source: { _ in page(["new"]) })
        let model = AccountVideosModel()

        let older = Task { await model.reload(using: slow) }
        await gate.untilWaiting()
        #expect(gate.isWaiting)
        await model.reload(using: fast)
        #expect(ids(model) == ["new"])

        gate.open()
        await older.value

        #expect(ids(model) == ["new"], "the older answer must not replace the newer list")
    }

    @Test func aPageThatArrivesAfterAReloadIsDropped() async {
        let gate = Gate()
        let source: AccountVideosModel.PageSource = { token in
            if token == "2" {
                await gate.wait()
                return page(["stale"])
            }
            return page(["fresh"], next: "2")
        }
        let loader = AccountVideosModel.Loader(source: source)
        let model = AccountVideosModel()
        await model.reload(using: loader)

        let loading = Task { await model.loadMore(using: loader) }
        await gate.untilWaiting()
        #expect(gate.isWaiting)
        await model.reload(using: AccountVideosModel.Loader(source: { _ in page(["fresh"], next: nil) }))
        gate.open()
        await loading.value

        #expect(ids(model) == ["fresh"])
        #expect(!model.isLoadingMore)
        #expect(!model.hasMore)
    }

    // MARK: Coming back to the screen

    @Test func aScreenThatComesBackKeepsTheListButEmptyOnesAskAgain() async {
        let pages = Pages(["first": page(["a"], next: "2")])
        let model = AccountVideosModel()
        let loader = pages.loader()

        await model.loadIfNeeded(using: loader)
        await model.loadIfNeeded(using: loader)
        #expect(pages.asked == ["first"], "a list on screen is kept")

        let empty = Pages(["first": Page()])
        let emptyModel = AccountVideosModel()
        await emptyModel.loadIfNeeded(using: empty.loader())
        await emptyModel.loadIfNeeded(using: empty.loader())
        #expect(empty.asked == ["first", "first"], "an empty list asks again, there is no pull to refresh to do it")
    }

    @Test func aListTheFilterHidesEntirelyIsStillALoadedList() async {
        let pages = Pages(["first": page(["a", "b"])])
        let model = AccountVideosModel()
        let loader = pages.loader(hiding: Hiding(["a", "b"]))

        await model.loadIfNeeded(using: loader)
        await model.loadIfNeeded(using: loader)

        #expect(pages.asked == ["first"])
        #expect(model.videos.isEmpty)
        #expect(model.hiddenCount == 2, "the screen can say that the filters hid everything instead of \"nothing here\"")
        #expect(!model.hasMore && !model.isPaused)
    }

    // MARK: Playing the list (spec-7)

    /// A fetch for a queue source: the pages by token, and the tokens asked for in order.
    @MainActor
    private final class QueueFetches {
        let pages: [String: Page<VideoSummary>]
        private(set) var asked: [String] = []

        init(_ pages: [String: Page<VideoSummary>]) { self.pages = pages }

        func fetch(_ token: String) async throws -> Page<VideoSummary> {
            asked.append(token)
            return pages[token] ?? Page()
        }
    }

    @Test func theQueueSourceContinuesWhereTheListStopped() async throws {
        // "Play all" on a list that has loaded its first page: the queue gets the rest, page by page.
        let pages = Pages(["first": page(["a", "b", "c"], next: "2")])
        let model = AccountVideosModel()
        await model.reload(using: pages.loader())
        let fetches = QueueFetches(["2": page(["d", "e"], next: "3"), "3": page(["f"])])

        let made = model.queueSource(fetch: { try await fetches.fetch($0) }, filter: { $0 })
        let source = try #require(made)

        #expect(source.continuation == "2")
        #expect(source.hasMore)
        #expect(try await source.next().map(\.id) == ["d", "e"])
        #expect(try await source.next().map(\.id) == ["f"])
        #expect(!source.hasMore)
        #expect(fetches.asked == ["2", "3"])
        #expect(pages.asked == ["first"], "the list itself asked for nothing")
    }

    @Test func theQueueSourceKnowsEveryVideoThatArrivedAlsoTheOnesTheListHides() async throws {
        // "b" was hidden by the list's filter on the first page. When it comes round again on the next page, it is not a
        // new video: nobody saw it, but it arrived.
        let pages = Pages(["first": page(["a", "b", "c"], next: "2")])
        let model = AccountVideosModel()
        await model.reload(using: pages.loader(hiding: Hiding(["b"])))
        #expect(ids(model) == ["a", "c"])
        let fetches = QueueFetches(["2": page(["b", "c", "d"])])

        let made = model.queueSource(fetch: { try await fetches.fetch($0) }, filter: { $0 })
        let source = try #require(made)

        #expect(try await source.next().map(\.id) == ["d"])
    }

    @Test func theQueueSourceAppliesTheFilterItWasGivenToEveryPage() async throws {
        let pages = Pages(["first": page(["a"], next: "2")])
        let model = AccountVideosModel()
        await model.reload(using: pages.loader())
        let fetches = QueueFetches(["2": page(["b", "blocked", "c"], next: "3"), "3": page(["blocked too", "d"])])
        let hidden: Set<String> = ["blocked", "blocked too"]

        let made = model.queueSource(
            fetch: { try await fetches.fetch($0) },
            filter: { videos in videos.filter { !hidden.contains($0.id) } }
        )
        let source = try #require(made)

        #expect(try await source.next().map(\.id) == ["b", "c"])
        #expect(try await source.next().map(\.id) == ["d"])
    }

    @Test func aListLoadedToItsEndHasNothingToQueueBehindIt() async {
        let pages = Pages(["first": page(["a", "b"])])
        let model = AccountVideosModel()
        await model.reload(using: pages.loader())

        let atTheEnd = model.queueSource(fetch: { _ in Page() }, filter: { $0 })
        #expect(atTheEnd == nil)
        // And before anything is loaded.
        let beforeLoading = AccountVideosModel().queueSource(fetch: { _ in Page() }, filter: { $0 })
        #expect(beforeLoading == nil)
    }

    @Test func theQueueSourceStartsAtThePageTheListWouldLoadNext() async throws {
        // The list went on to its second page before the viewer tapped "Play all".
        let pages = Pages([
            "first": page(["a", "b"], next: "2"),
            "2": page(["c", "d"], next: "3"),
        ])
        let model = AccountVideosModel()
        let loader = pages.loader()
        await model.reload(using: loader)
        await model.loadMore(using: loader)
        let fetches = QueueFetches(["3": page(["e"])])

        let made = model.queueSource(fetch: { try await fetches.fetch($0) }, filter: { $0 })
        let source = try #require(made)

        #expect(source.continuation == "3")
        #expect(try await source.next().map(\.id) == ["e"])
        #expect(fetches.asked == ["3"], "nothing the list already has is fetched again")
    }
}
