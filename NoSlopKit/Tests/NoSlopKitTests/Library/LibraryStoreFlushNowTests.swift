import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

// `flushNow` is the one synchronous, bounded write of the library: the app calls it when iOS announces that the process
// is about to end (`UIApplication.willTerminateNotification`), where an `await` never gets to finish.

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makeVideo(_ id: String) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)")
}

/// The first background write waits for the test: it reports that it started (`hasStarted`) and then sits until
/// `release()`; the writes after it go through. Blocks a thread of the writer, never the main actor, and gives up by
/// itself after a while so that a failing test cannot hang the run.
private final class HeldWrite: Sendable {
    private let writes = Mutex(0)
    private let gate = DispatchSemaphore(value: 0)

    var hasStarted: Bool { writes.withLock { $0 > 0 } }

    func hold() {
        let number = writes.withLock { count -> Int in
            count += 1
            return count
        }
        if number == 1 { _ = gate.wait(timeout: .now() + 30) }
    }

    func release() {
        gate.signal()
    }
}

/// Polls `condition` every 5 ms until it holds or `timeout` passes.
@MainActor
private func eventually(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite final class LibraryStoreFlushNowTests {
    /// A directory of its own per test; removed afterwards.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoSlopLibraryFlushNowTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A store whose timer would fire in an hour unless `saveDelay` says otherwise.
    private func makeStore(saveDelay: Duration = .seconds(3_600), beforeWrite: (@Sendable () -> Void)? = nil) -> LibraryStore {
        LibraryStore(directory: directory, saveDelay: saveDelay, now: { referenceDate }, beforeWrite: beforeWrite)
    }

    private func exists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)
    }

    // MARK: What it writes

    @Test func theWatchPositionIsOnDiskWhenItReturnsAndNothingWasAwaited() {
        let store = makeStore()
        store.recordProgress(video: makeVideo("a"), seconds: 42, duration: 100)
        #expect(!exists("history.json"), "the timer is an hour away: nothing has been written yet")

        #expect(store.flushNow())

        // A new store reads its files in `init`, so this is what the next launch sees.
        let reloaded = makeStore()
        #expect(reloaded.progress(for: "a")?.progressSeconds == 42)
        #expect(reloaded.progress(for: "a")?.durationSeconds == 100)
    }

    @Test func everyCollectionThatChangedIsWritten() {
        let store = makeStore()
        store.recordProgress(video: makeVideo("a"), seconds: 5, duration: 60)
        store.toggleWatchLater(makeVideo("b"))
        store.recordSearch("blender")
        store.subscribe(SubscribedChannel(id: "UC1", name: "Channel"))

        #expect(store.flushNow())

        #expect(exists("history.json") && exists("watch-later.json") && exists("search-history.json") && exists("subscriptions.json"))
        #expect(!exists("playlists.json"), "what did not change is not written")
        let reloaded = makeStore()
        #expect(reloaded.history.map(\.id) == ["a"])
        #expect(reloaded.watchLater.map(\.id) == ["b"])
        #expect(reloaded.searchHistory == ["blender"])
        #expect(reloaded.subscriptions.map(\.id) == ["UC1"])
    }

    @Test func nothingChangedMeansNothingIsWritten() {
        let store = makeStore()
        #expect(store.flushNow())
        #expect(!exists("history.json"))
        #expect(!FileManager.default.fileExists(atPath: directory.path), "not even the folder")
    }

    @Test func theTimerHasNothingLeftToWriteAfterwards() async throws {
        let store = makeStore(saveDelay: .milliseconds(20))
        store.recordProgress(video: makeVideo("a"), seconds: 7, duration: 60)
        #expect(store.flushNow())
        let written = try Data(contentsOf: directory.appendingPathComponent("history.json"))

        // The timer that the change armed would have fired by now; it must neither write again nor undo anything.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try Data(contentsOf: directory.appendingPathComponent("history.json")) == written)
        #expect(makeStore().progress(for: "a")?.progressSeconds == 7)
    }

    @Test func theAsyncFlushStillWorksAfterwards() async {
        let store = makeStore()
        store.recordProgress(video: makeVideo("a"), seconds: 1, duration: 60)
        #expect(store.flushNow())
        store.recordProgress(video: makeVideo("a"), seconds: 2, duration: 60)
        await store.flush()
        #expect(makeStore().progress(for: "a")?.progressSeconds == 2)
    }

    // MARK: Writes that are already running

    @Test func aWriteInFlightIsWaitedForSoItCannotPutOldContentBackOverTheNewFile() async {
        // The first background write is slow. It was started with position 10 and would land after the position of 42
        // if flushNow did not wait for it.
        let slow = HeldWrite()
        let store = makeStore(saveDelay: .milliseconds(1), beforeWrite: { slow.hold() })
        store.recordProgress(video: makeVideo("a"), seconds: 10, duration: 100)
        #expect(await eventually { slow.hasStarted })

        store.recordProgress(video: makeVideo("a"), seconds: 42, duration: 100)
        // The write finishes a moment from now, well inside the time flushNow is willing to wait.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { slow.release() }
        #expect(store.flushNow(timeout: 20))

        #expect(makeStore().progress(for: "a")?.progressSeconds == 42)
        // And it stays that way: once every background write has finished, the file still says 42.
        await store.flush()
        #expect(makeStore().progress(for: "a")?.progressSeconds == 42)
    }

    @Test func aWriteThatHangsDoesNotHoldItUpPastTheTimeout() async {
        let hung = HeldWrite()
        defer { hung.release() }
        let store = makeStore(saveDelay: .milliseconds(1), beforeWrite: { hung.hold() })
        store.recordProgress(video: makeVideo("a"), seconds: 10, duration: 100)
        #expect(await eventually { hung.hasStarted })
        store.recordProgress(video: makeVideo("b"), seconds: 20, duration: 100)

        let clock = ContinuousClock()
        let started = clock.now
        let finished = store.flushNow(timeout: 0.3)
        let waited = clock.now - started

        #expect(!finished, "it says that it could not write")
        #expect(waited >= .milliseconds(250), "it did wait for the write: \(waited)")
        #expect(waited < .seconds(10), "and then gave up: \(waited)")
        #expect(!exists("history.json"), "it does not write behind a write it could not wait for: the old content could land on top")

        // What it did not write is still to be written: the async flush picks it up once the write gets going again.
        hung.release()
        await store.flush()
        let reloaded = makeStore()
        #expect(Set(reloaded.history.map(\.id)) == ["a", "b"])
        #expect(reloaded.progress(for: "b")?.progressSeconds == 20)
    }
}
