import Foundation
import Testing
@testable import NoSlopKit

private func video(_ id: String, channel: String = "UCok") -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)", channel: ChannelRef(id: channel, name: "Channel \(channel)"))
}

/// The videos "<prefix><n>" for every n in `range`.
private func videos(_ prefix: String, _ range: Range<Int>, channel: String = "UCok") -> [VideoSummary] {
    range.map { video("\(prefix)\($0)", channel: channel) }
}

private func ids(_ videos: [VideoSummary]) -> [String] {
    videos.map(\.id)
}

/// Lets the other tasks on the main actor run until `condition` holds. Gives up after a while, so that a test whose
/// condition never comes true fails instead of hanging the run.
@MainActor
private func yield(until condition: () -> Bool) async {
    var turns = 0
    while !condition(), turns < 2_000 {
        await Task.yield()
        turns += 1
    }
}

/// A list behind continuation tokens, and a record of the fetches made. A token it does not know is the end.
@MainActor
private final class PagedList {
    private let pages: [String: Page<VideoSummary>]
    private(set) var fetched: [String] = []

    init(_ pages: [String: Page<VideoSummary>]) {
        self.pages = pages
    }

    func fetch(_ token: String) async throws -> Page<VideoSummary> {
        fetched.append(token)
        return pages[token] ?? Page()
    }
}

/// Holds a fetch until the test lets it go.
@MainActor
private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
@Suite struct QueueSourceTests {
    /// 250 videos in three pages of 100, 100 and 50, the way a long playlist arrives.
    private func longPlaylist() -> PagedList {
        PagedList([
            "p1": Page(items: videos("v", 0..<100), continuation: "p2"),
            "p2": Page(items: videos("v", 100..<200), continuation: "p3"),
            "p3": Page(items: videos("v", 200..<250), continuation: nil),
        ])
    }

    /// Plays a queue the way the player does: the first video starts, the source is asked for more whenever it
    /// `needsRefill` after that, and also when the queue is empty at the end of a video. Returns the ids in the order
    /// they started.
    private func play(queue initial: [VideoSummary], from source: QueueSource) async throws -> [String] {
        var queue = initial
        var played: [String] = []
        while true {
            if queue.isEmpty {
                guard source.hasMore else { break }
                let page = try await source.next()
                if page.isEmpty { break }
                queue += page
            }
            played.append(queue.removeFirst().id)
            if source.needsRefill(queued: queue.count) {
                queue += try await source.next()
            }
        }
        return played
    }

    // MARK: Paging through a long list

    @Test func aPlaylistOfThreePagesPlaysToItsEnd() async throws {
        let list = longPlaylist()
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        let played = try await play(queue: [], from: source)

        #expect(played == (0..<250).map { "v\($0)" })
        #expect(Set(played).count == 250)
        #expect(list.fetched == ["p1", "p2", "p3"])
        #expect(!source.hasMore)
    }

    @Test func theLoadedPageStaysInTheQueueAndTheRestFollowsWhenItRunsLow() async throws {
        // What "Play all" does with 100 loaded videos of 250: the queue holds the loaded ones, the source the rest.
        let list = longPlaylist()
        let loaded = videos("v", 0..<100)
        let source = QueueSource(continuation: "p2", knownIDs: Set(ids(loaded)), fetch: { try await list.fetch($0) })

        let played = try await play(queue: loaded, from: source)

        #expect(played == (0..<250).map { "v\($0)" })
        #expect(list.fetched == ["p2", "p3"])
    }

    @Test func theSourceIsAskedOnlyWhenTheQueueRunsLow() async throws {
        let list = longPlaylist()
        let source = QueueSource(continuation: "p2", fetch: { try await list.fetch($0) })

        #expect(QueueSource.lowWater == 2)
        #expect(!source.needsRefill(queued: 3))
        #expect(source.needsRefill(queued: 2))
        #expect(source.needsRefill(queued: 1))
        #expect(source.needsRefill(queued: 0))
        #expect(list.fetched.isEmpty)
    }

    @Test func aSourceAtTheEndNeedsNothing() async throws {
        let list = PagedList([:])
        let finished = QueueSource(continuation: nil, fetch: { try await list.fetch($0) })

        #expect(!finished.hasMore)
        #expect(!finished.needsRefill(queued: 0))
        #expect(try await finished.next().isEmpty)
        #expect(list.fetched.isEmpty)
    }

    @Test func theLastPageEndsTheSource() async throws {
        let list = PagedList(["p1": Page(items: videos("v", 0..<3), continuation: nil)])
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        #expect(ids(try await source.next()) == ["v0", "v1", "v2"])
        #expect(!source.hasMore)
        #expect(!source.needsRefill(queued: 0))
        #expect(try await source.next().isEmpty)
        #expect(list.fetched == ["p1"])
    }

    // MARK: What is queued

    @Test func videosTheLoadedListAlreadyHeldAreNotQueuedAgain() async throws {
        // YouTube repeats a video across a page boundary now and then; the loaded list had v8 and v9 (and v7, which
        // the filter hid).
        let list = PagedList([
            "p2": Page(items: [video("v7"), video("v8"), video("v9"), video("v10"), video("v11")], continuation: nil),
        ])
        let source = QueueSource(continuation: "p2", knownIDs: ["v7", "v8", "v9"], fetch: { try await list.fetch($0) })

        #expect(ids(try await source.next()) == ["v10", "v11"])
    }

    @Test func aVideoThatArrivedOnAnEarlierPageIsNotQueuedAgain() async throws {
        let list = PagedList([
            "p1": Page(items: [video("a"), video("b")], continuation: "p2"),
            "p2": Page(items: [video("b"), video("c"), video("a")], continuation: nil),
        ])
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        #expect(ids(try await source.next()) == ["a", "b"])
        #expect(ids(try await source.next()) == ["c"])
    }

    @Test func aVideoRepeatedInsideOnePageIsQueuedOnce() async throws {
        let list = PagedList(["p1": Page(items: [video("a"), video("b"), video("a")], continuation: nil)])
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        #expect(ids(try await source.next()) == ["a", "b"])
    }

    @Test func videosTheFilterHidesAreNeverQueued() async throws {
        let list = PagedList([
            "p1": Page(items: [video("a"), video("x1", channel: "UCbad"), video("b")], continuation: "p2"),
            "p2": Page(items: [video("x2", channel: "UCbad"), video("c")], continuation: nil),
        ])
        let source = QueueSource(
            continuation: "p1",
            fetch: { try await list.fetch($0) },
            filter: { $0.filter { $0.channel?.id != "UCbad" } }
        )

        let played = try await play(queue: [], from: source)

        #expect(played == ["a", "b", "c"])
    }

    @Test func aPageTheFilterEmptiesIsSkippedInTheSameCall() async throws {
        let list = PagedList([
            "p1": Page(items: [video("x1", channel: "UCbad"), video("x2", channel: "UCbad")], continuation: "p2"),
            "p2": Page(items: [video("x3", channel: "UCbad")], continuation: "p3"),
            "p3": Page(items: [video("a"), video("b")], continuation: nil),
        ])
        let source = QueueSource(
            continuation: "p1",
            fetch: { try await list.fetch($0) },
            filter: { $0.filter { $0.channel?.id != "UCbad" } }
        )

        #expect(ids(try await source.next()) == ["a", "b"])
        #expect(list.fetched == ["p1", "p2", "p3"])
    }

    @Test func aHiddenVideoStaysHiddenWhenItComesBackOnALaterPage() async throws {
        // Seen once, hidden once: a later copy is not a new video.
        var hidden = true
        let list = PagedList([
            "p1": Page(items: [video("a"), video("s")], continuation: "p2"),
            "p2": Page(items: [video("s"), video("b")], continuation: nil),
        ])
        let source = QueueSource(
            continuation: "p1",
            fetch: { try await list.fetch($0) },
            filter: { page in page.filter { !(hidden && $0.id == "s") } }
        )

        #expect(ids(try await source.next()) == ["a"])
        hidden = false
        #expect(ids(try await source.next()) == ["b"])
    }

    @Test func theFilterIsAskedForEveryPageSoAChangeMeanwhileCounts() async throws {
        var blocked: Set<String> = []
        let list = PagedList([
            "p1": Page(items: [video("a", channel: "UCa"), video("b", channel: "UCb")], continuation: "p2"),
            "p2": Page(items: [video("c", channel: "UCa"), video("d", channel: "UCb")], continuation: nil),
        ])
        let source = QueueSource(
            continuation: "p1",
            fetch: { try await list.fetch($0) },
            filter: { page in page.filter { !blocked.contains($0.channel?.id ?? "") } }
        )

        #expect(ids(try await source.next()) == ["a", "b"])
        blocked = ["UCa"]
        #expect(ids(try await source.next()) == ["d"])
    }

    // MARK: Where the list ends

    @Test func aTokenThatDoesNotAdvanceEndsTheList() async throws {
        // A service that answers every token with the same one would otherwise be asked for ever.
        let list = PagedList(["p1": Page(items: videos("v", 0..<3), continuation: "p1")])
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        #expect(ids(try await source.next()) == ["v0", "v1", "v2"])
        #expect(!source.hasMore)
        #expect(try await source.next().isEmpty)
        #expect(list.fetched == ["p1"])
    }

    @Test func aPageThatRepeatsEarlierVideosAndTheSameTokenEndsTheListWithNothing() async throws {
        let list = PagedList(["p1": Page(items: videos("v", 0..<3), continuation: "p1")])
        let source = QueueSource(
            continuation: "p1",
            knownIDs: ["v0", "v1", "v2"],
            fetch: { try await list.fetch($0) }
        )

        #expect(try await source.next().isEmpty)
        #expect(!source.hasMore)
        #expect(list.fetched == ["p1"])
    }

    @Test func anEmptyPageWithoutATokenEndsTheList() async throws {
        let list = PagedList(["p1": Page(items: [], continuation: nil)])
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        #expect(try await source.next().isEmpty)
        #expect(!source.hasMore)
    }

    @Test func anEmptyPageWithAnotherTokenGoesOnToTheNextPage() async throws {
        let list = PagedList([
            "p1": Page(items: [], continuation: "p2"),
            "p2": Page(items: [video("a")], continuation: nil),
        ])
        let source = QueueSource(continuation: "p1", fetch: { try await list.fetch($0) })

        #expect(ids(try await source.next()) == ["a"])
        #expect(list.fetched == ["p1", "p2"])
    }

    @Test func aListOfHiddenPagesIsGivenUpOnForNowAndGoesOnWhereItStopped() async throws {
        // Page n holds only videos of a blocked channel and points to page n + 1, for ever.
        let list = PagedListThatNeverEnds()
        let source = QueueSource(
            continuation: "h0",
            fetch: { try await list.fetch($0) },
            filter: { $0.filter { $0.channel?.id != "UCbad" } }
        )

        #expect(try await source.next().isEmpty)
        #expect(list.fetched.count == QueueSource.maxEmptyPages)
        // The list is not over: asking again looks at the pages after those.
        #expect(source.hasMore)
        #expect(try await source.next().isEmpty)
        #expect(list.fetched.count == 2 * QueueSource.maxEmptyPages)
        #expect(list.fetched.last == "h\(2 * QueueSource.maxEmptyPages - 1)")
    }

    // MARK: Failures and cancellation

    @Test func aFailedFetchThrowsAndTheNextCallTriesTheSamePageAgain() async throws {
        var failures = 1
        let list = PagedList(["p1": Page(items: [video("a")], continuation: nil)])
        let source = QueueSource(continuation: "p1", fetch: { token in
            if failures > 0 {
                failures -= 1
                throw NoSlopError.network("offline")
            }
            return try await list.fetch(token)
        })

        await #expect(throws: NoSlopError.network("offline")) { try await source.next() }
        #expect(source.continuation == "p1")
        #expect(source.hasMore)
        #expect(!source.isFetching)

        #expect(ids(try await source.next()) == ["a"])
    }

    @Test func aFailureAfterAnEmptyPageKeepsThePlaceReached() async throws {
        var calls = 0
        let list = PagedList(["p2": Page(items: [video("a")], continuation: nil)])
        let source = QueueSource(
            continuation: "p1",
            fetch: { token in
                calls += 1
                if token == "p1" { return Page(items: [video("x", channel: "UCbad")], continuation: "p2") }
                if calls == 2 { throw NoSlopError.network("offline") }
                return try await list.fetch(token)
            },
            filter: { $0.filter { $0.channel?.id != "UCbad" } }
        )

        await #expect(throws: NoSlopError.network("offline")) { try await source.next() }
        // The hidden page was dealt with; the next call starts behind it.
        #expect(source.continuation == "p2")
        #expect(ids(try await source.next()) == ["a"])
    }

    @Test func aCancelledCallLeavesTheSourceWhereItWas() async throws {
        var calls = 0
        let source = QueueSource(continuation: "p1", fetch: { _ in
            calls += 1
            if calls == 1 {
                // Waits until the test cancels the call.
                try await Task.sleep(for: .seconds(60))
            }
            return Page(items: [video("a")], continuation: nil)
        })

        let call = Task { try await source.next() }
        await yield(until: { source.isFetching })
        call.cancel()
        let outcome = await call.result

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(source.continuation == "p1")
        #expect(!source.isFetching)
        #expect(ids(try await source.next()) == ["a"])
    }

    @Test func aPageThatArrivesAfterTheCallWasCancelledIsNotConsumed() async throws {
        // A fetch that ignores cancellation and answers anyway: the caller that no longer wants the page must not
        // use it up either, or the viewer's queue would have a hole where it was.
        let gate = Gate()
        var calls = 0
        let source = QueueSource(continuation: "p1", fetch: { _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return Page(items: [video("a")], continuation: nil)
        })

        let call = Task { try await source.next() }
        await yield(until: { source.isFetching })
        call.cancel()
        gate.open()
        let outcome = await call.result

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(source.continuation == "p1")
        #expect(ids(try await source.next()) == ["a"])
        #expect(calls == 2)
    }

    @Test func aSecondCallWhileOneIsRunningFetchesNothingAndTheFirstKeepsItsPage() async throws {
        let gate = Gate()
        var calls = 0
        let source = QueueSource(continuation: "p1", fetch: { _ in
            calls += 1
            await gate.wait()
            return Page(items: [video("a"), video("b")], continuation: "p2")
        })

        let first = Task { try await source.next() }
        await yield(until: { source.isFetching })

        let second = try await source.next()
        #expect(second.isEmpty)
        #expect(source.hasMore)
        #expect(calls == 1)

        gate.open()
        #expect(ids(try await first.value) == ["a", "b"])
        #expect(!source.isFetching)
        #expect(source.continuation == "p2")
    }
}

/// Page n of a list that never ends: videos of a blocked channel, and the token of page n + 1.
@MainActor
private final class PagedListThatNeverEnds {
    private(set) var fetched: [String] = []

    func fetch(_ token: String) async throws -> Page<VideoSummary> {
        fetched.append(token)
        let number = Int(token.dropFirst()) ?? 0
        return Page(items: [video("h\(number)", channel: "UCbad")], continuation: "h\(number + 1)")
    }
}
