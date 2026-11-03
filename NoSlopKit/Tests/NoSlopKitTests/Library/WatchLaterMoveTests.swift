import Foundation
import Observation
import Testing
@testable import NoSlopKit
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Set from an observation callback, read by the test.
private final class MoveChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var isSet: Bool {
        lock.withLock { changed }
    }

    func set() {
        lock.withLock { changed = true }
    }
}

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makeVideo(_ id: String) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)", channel: ChannelRef(id: "UC\(id)", name: "Channel \(id)"))
}

// MARK: - LibraryStore.moveWatchLater

@MainActor
@Suite final class WatchLaterMoveTests {
    /// A directory of its own per test (Swift Testing creates one suite instance per test); removed afterwards.
    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopWatchLaterMoveTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore {
        LibraryStore(directory: directory, saveDelay: .milliseconds(500), now: { referenceDate })
    }

    /// A store whose Watch Later list reads exactly `ids`, first to last (`toggleWatchLater` adds on top).
    private func makeStore(watchLater ids: [String]) -> LibraryStore {
        let store = makeStore()
        for id in ids.reversed() {
            store.toggleWatchLater(makeVideo(id))
        }
        return store
    }

    private var watchLaterFile: URL {
        directory.appendingPathComponent("watch-later.json")
    }

    private func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        let store = makeStore(watchLater: ids)
        store.moveWatchLater(fromOffsets: source, toOffset: destination)
        return store.watchLater.map(\.id)
    }

    // MARK: Order

    @Test func movesOneVideoTowardTheEnd() {
        // The destination is where the video would be inserted in the list as it is now: before "D".
        #expect(moved(["A", "B", "C", "D", "E"], from: [0], to: 3) == ["B", "C", "A", "D", "E"])
        #expect(moved(["A", "B", "C", "D", "E"], from: [1], to: 4) == ["A", "C", "D", "B", "E"])
    }

    @Test func movesOneVideoTowardTheStart() {
        #expect(moved(["A", "B", "C", "D", "E"], from: [3], to: 1) == ["A", "D", "B", "C", "E"])
        #expect(moved(["A", "B", "C", "D", "E"], from: [2], to: 0) == ["C", "A", "B", "D", "E"])
    }

    @Test func movingToTheEndMakesTheVideoLast() {
        #expect(moved(["A", "B", "C", "D", "E"], from: [1], to: 5) == ["A", "C", "D", "E", "B"])
        #expect(moved(["A", "B", "C", "D", "E"], from: [0], to: 5) == ["B", "C", "D", "E", "A"])
    }

    @Test func movingToTheStartMakesTheVideoFirst() {
        #expect(moved(["A", "B", "C", "D", "E"], from: [4], to: 0) == ["E", "A", "B", "C", "D"])
    }

    @Test func severalVideosMoveTogetherAndKeepTheirOrder() {
        #expect(moved(["A", "B", "C", "D", "E"], from: [0, 2], to: 4) == ["B", "D", "A", "C", "E"])
        #expect(moved(["A", "B", "C", "D", "E"], from: [1, 3], to: 0) == ["B", "D", "A", "C", "E"])
        #expect(moved(["A", "B", "C", "D", "E"], from: [0, 4], to: 2) == ["B", "A", "E", "C", "D"])
        #expect(moved(["A", "B", "C", "D", "E"], from: [1, 2], to: 5) == ["A", "D", "E", "B", "C"])
    }

    @Test func aVideoDroppedNextToItselfStaysWhereItIs() {
        for destination in [2, 3] {
            #expect(moved(["A", "B", "C", "D", "E"], from: [2], to: destination) == ["A", "B", "C", "D", "E"])
        }
    }

    @Test func movingEverythingChangesNothing() {
        for destination in 0...3 {
            #expect(moved(["A", "B", "C"], from: [0, 1, 2], to: destination) == ["A", "B", "C"])
        }
    }

    @Test func aTwoVideoListCanBeSwapped() {
        #expect(moved(["A", "B"], from: [0], to: 2) == ["B", "A"])
        #expect(moved(["A", "B"], from: [1], to: 0) == ["B", "A"])
    }

    @Test func theVideosThemselvesAreKept() {
        let store = makeStore(watchLater: ["A", "B", "C"])
        let before = store.watchLater
        store.moveWatchLater(fromOffsets: [2], toOffset: 0)
        #expect(store.watchLater == [before[2], before[0], before[1]])
        #expect(store.isInWatchLater("A") && store.isInWatchLater("B") && store.isInWatchLater("C"))
    }

    // MARK: Never traps

    @Test func offsetsOutsideTheListAreIgnored() {
        #expect(moved(["A", "B", "C"], from: [2, 9], to: 0) == ["C", "A", "B"])
        #expect(moved(["A", "B", "C"], from: [1, 3, 40], to: 3) == ["A", "C", "B"])
        #expect(moved(["A", "B", "C"], from: [3, 40], to: 0) == ["A", "B", "C"])
        #expect(moved(["A", "B", "C"], from: [1_000_000], to: 0) == ["A", "B", "C"])
    }

    @Test func aDestinationOutsideTheListIsLimitedToItsEnds() {
        #expect(moved(["A", "B", "C"], from: [1], to: -5) == ["B", "A", "C"])
        #expect(moved(["A", "B", "C"], from: [1], to: 99) == ["A", "C", "B"])
        #expect(moved(["A", "B", "C"], from: [0, 1], to: Int.max) == ["C", "A", "B"])
        #expect(moved(["A", "B", "C"], from: [2], to: Int.min) == ["C", "A", "B"])
    }

    @Test func anEmptySelectionOrAnEmptyListDoesNothing() {
        #expect(moved(["A", "B", "C"], from: [], to: 1) == ["A", "B", "C"])
        #expect(moved([], from: [0], to: 0) == [])
        #expect(moved([], from: [], to: 3) == [])
    }

    #if canImport(SwiftUI)
    /// `onMove` hands the store what `Array.move(fromOffsets:toOffset:)` understands; the two must agree on every
    /// selection of a five-video list and every destination from the start to the end.
    @Test func agreesWithArrayMoveForEverySelectionAndDestination() {
        let ids = ["A", "B", "C", "D", "E"]
        for mask in 1..<(1 << ids.count) {
            let source = IndexSet(ids.indices.filter { mask & (1 << $0) != 0 })
            for destination in 0...ids.count {
                var expected = ids
                expected.move(fromOffsets: source, toOffset: destination)
                #expect(
                    moved(ids, from: source, to: destination) == expected,
                    "moving \(Array(source)) to \(destination)"
                )
            }
        }
    }
    #endif

    // MARK: Persistence and observation

    @Test func theNewOrderIsWrittenToDisk() async {
        let store = makeStore(watchLater: ["A", "B", "C", "D"])
        store.moveWatchLater(fromOffsets: [3], toOffset: 1)
        #expect(store.watchLater.map(\.id) == ["A", "D", "B", "C"])
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.watchLater.map(\.id) == ["A", "D", "B", "C"])
        #expect(reloaded.watchLater == store.watchLater)
    }

    @Test func aMoveThatChangesNothingWritesNothing() async throws {
        let store = makeStore(watchLater: ["A", "B", "C"])
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: watchLaterFile.path))
        try FileManager.default.removeItem(at: watchLaterFile)

        store.moveWatchLater(fromOffsets: [1], toOffset: 1)
        store.moveWatchLater(fromOffsets: [1], toOffset: 2)
        store.moveWatchLater(fromOffsets: [], toOffset: 0)
        store.moveWatchLater(fromOffsets: [7], toOffset: 0)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: watchLaterFile.path), "nothing changed, so nothing is written")

        store.moveWatchLater(fromOffsets: [0], toOffset: 3)
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: watchLaterFile.path))
        #expect(makeStore().watchLater.map(\.id) == ["B", "C", "A"])
    }

    @Test func aMoveIsObservedByTheScreenShowingTheList() {
        let store = makeStore(watchLater: ["A", "B", "C"])
        let flag = MoveChangeFlag()
        withObservationTracking {
            _ = store.watchLater
        } onChange: {
            flag.set()
        }
        store.moveWatchLater(fromOffsets: [0], toOffset: 3)
        #expect(flag.isSet)
    }

    @Test func aMoveThatChangesNothingIsNotObserved() {
        let store = makeStore(watchLater: ["A", "B", "C"])
        let flag = MoveChangeFlag()
        withObservationTracking {
            _ = store.watchLater
        } onChange: {
            flag.set()
        }
        store.moveWatchLater(fromOffsets: [1], toOffset: 1)
        store.moveWatchLater(fromOffsets: [], toOffset: 0)
        #expect(!flag.isSet)
    }

    @Test func addingAndRemovingStillWorkAfterAMove() {
        let store = makeStore(watchLater: ["A", "B", "C"])
        store.moveWatchLater(fromOffsets: [0], toOffset: 3)
        store.toggleWatchLater(makeVideo("Z"))
        #expect(store.watchLater.map(\.id) == ["Z", "B", "C", "A"])
        store.toggleWatchLater(makeVideo("C"))
        #expect(store.watchLater.map(\.id) == ["Z", "B", "A"])
    }
}
