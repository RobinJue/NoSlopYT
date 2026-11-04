import Foundation
import Testing
@testable import NoSlopKit

// The sync of the account's subscriptions into the library: a list that was fetched while the viewer changed
// something must not overwrite the change (concurrency-5).

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func google(_ id: String) -> SubscribedChannel {
    SubscribedChannel(id: id, name: "Channel \(id)", source: .google(subscriptionID: "sub-\(id)"))
}

private func local(_ id: String) -> SubscribedChannel {
    SubscribedChannel(id: id, name: "Channel \(id)", source: .local)
}

/// Hands out scripted answers, one per call, and runs a side effect first: the viewer's change while the request is
/// on its way. Counts the calls.
@MainActor
private final class ScriptedFetch {
    struct Step {
        var whileFetching: @MainActor () -> Void = {}
        var answer: Result<[SubscribedChannel], any Error>
    }

    private var steps: [Step]
    private(set) var calls = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func callAsFunction() async throws -> [SubscribedChannel] {
        calls += 1
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        await Task.yield()  // a real request suspends here, and the main actor does other work meanwhile
        step.whileFetching()
        return try step.answer.get()
    }
}

@MainActor
@Suite final class LibrarySubscriptionSyncTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoSlopSyncTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore {
        LibraryStore(directory: directory, saveDelay: .milliseconds(500), now: { referenceDate })
    }

    private func sources(_ store: LibraryStore) -> [String: SubscriptionSource] {
        Dictionary(store.subscriptions.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: The revision

    @Test func theRevisionCountsTheViewersChangesAndNotTheSyncs() {
        let store = makeStore()
        #expect(store.subscriptionRevision == 0)

        store.subscribe(google("A"))
        #expect(store.subscriptionRevision == 1)
        store.subscribe(google("A"))  // the same channel again is still a change of the entry
        #expect(store.subscriptionRevision == 2)

        store.unsubscribe(channelID: "A")
        #expect(store.subscriptionRevision == 3)
        store.unsubscribe(channelID: "A")  // nothing to unsubscribe from: nothing changed
        #expect(store.subscriptionRevision == 3)

        store.replaceGoogleSubscriptions([google("B")])  // a sync must not make a second sync retry
        #expect(store.subscriptionRevision == 3)

        store.convertGoogleSubscriptionsToLocal()
        #expect(store.subscriptionRevision == 4)
        store.convertGoogleSubscriptionsToLocal()  // a sign-out counts even when there was nothing to convert
        #expect(store.subscriptionRevision == 5)
    }

    // MARK: Syncing

    @Test func aListThatNothingOvertookIsApplied() async throws {
        let store = makeStore()
        store.subscribe(local("L"))
        store.subscribe(google("A"))
        let fetch = ScriptedFetch([.init(answer: .success([google("A"), google("B")]))])

        let applied = try await store.syncGoogleSubscriptions(fetching: { try await fetch() })

        #expect(applied)
        #expect(fetch.calls == 1)
        #expect(sources(store) == ["A": .google(subscriptionID: "sub-A"), "B": .google(subscriptionID: "sub-B"), "L": .local])
    }

    @Test func aSubscribeWhileTheListWasOnItsWayIsKept() async throws {
        let store = makeStore()
        store.subscribe(google("A"))
        let fetch = ScriptedFetch([
            // The stale list does not know about N, which the viewer subscribes to meanwhile.
            .init(whileFetching: { store.subscribe(google("N")) }, answer: .success([google("A")])),
            .init(answer: .success([google("A"), google("N")])),
        ])

        let applied = try await store.syncGoogleSubscriptions(fetching: { try await fetch() })

        #expect(applied)
        #expect(fetch.calls == 2, "the stale list was thrown away and the account asked again")
        #expect(store.isSubscribed(channelID: "N"))
        #expect(sources(store)["N"] == .google(subscriptionID: "sub-N"))
        #expect(store.isSubscribed(channelID: "A"))
    }

    @Test func anUnsubscribeWhileTheListWasOnItsWayIsKept() async throws {
        let store = makeStore()
        store.subscribe(google("A"))
        store.subscribe(google("B"))
        let fetch = ScriptedFetch([
            // The stale list still has A, which the viewer unsubscribes from meanwhile.
            .init(whileFetching: { store.unsubscribe(channelID: "A") }, answer: .success([google("A"), google("B")])),
            .init(answer: .success([google("B")])),
        ])

        try await store.syncGoogleSubscriptions(fetching: { try await fetch() })

        #expect(!store.isSubscribed(channelID: "A"), "an unsubscribed channel must not come back with its old subscription id")
        #expect(store.isSubscribed(channelID: "B"))
        #expect(fetch.calls == 2)
    }

    @Test func aSyncThatIsOvertakenEveryTimeGivesUpAfterThreeAttempts() async throws {
        let store = makeStore()
        store.subscribe(local("L"))
        var counter = 0
        let fetch = ScriptedFetch([
            .init(
                whileFetching: {
                    counter += 1
                    store.subscribe(google("N\(counter)"))
                },
                answer: .success([google("STALE")])
            ),
        ])

        let applied = try await store.syncGoogleSubscriptions(fetching: { try await fetch() })

        #expect(!applied)
        #expect(fetch.calls == LibraryStore.subscriptionSyncAttempts)
        #expect(LibraryStore.subscriptionSyncAttempts == 3)
        // Nothing stale was applied; the viewer's own changes are all there. The next sync catches up.
        #expect(!store.isSubscribed(channelID: "STALE"))
        #expect(Set(store.subscriptions.map(\.id)) == ["L", "N1", "N2", "N3"])
    }

    @Test func aSyncThatWasInFlightWhenTheViewerSignedOutDoesNotBringTheAccountBack() async throws {
        let store = makeStore()  // nothing from the account yet: the very first sync after launch
        store.subscribe(local("L"))
        let fetch = ScriptedFetch([
            .init(whileFetching: { store.convertGoogleSubscriptionsToLocal() }, answer: .success([google("A")])),
            .init(answer: .failure(NoSlopError.notSignedIn)),  // the credentials are gone: the account cannot be asked
        ])

        await #expect(throws: NoSlopError.notSignedIn) {
            try await store.syncGoogleSubscriptions(fetching: { try await fetch() })
        }

        #expect(!store.isSubscribed(channelID: "A"), "the list of a session that has ended is not applied")
        #expect(sources(store) == ["L": .local])
    }

    @Test func aFailedFetchLeavesTheLibraryAlone() async throws {
        let store = makeStore()
        store.subscribe(local("L"))
        store.subscribe(google("A"))
        let before = store.subscriptions
        let fetch = ScriptedFetch([.init(answer: .failure(NoSlopError.network("offline")))])

        await #expect(throws: NoSlopError.network("offline")) {
            try await store.syncGoogleSubscriptions(fetching: { try await fetch() })
        }

        #expect(store.subscriptions == before)
        #expect(fetch.calls == 1, "a failure is not retried here: the caller decides what it means")
    }

    @Test func aListThatIsEmptyRemovesTheGoogleSubscriptionsAndKeepsTheLocalOnes() async throws {
        let store = makeStore()
        store.subscribe(local("L"))
        store.subscribe(google("A"))
        let fetch = ScriptedFetch([.init(answer: .success([]))])

        try await store.syncGoogleSubscriptions(fetching: { try await fetch() })

        #expect(sources(store) == ["L": .local])
    }
}
