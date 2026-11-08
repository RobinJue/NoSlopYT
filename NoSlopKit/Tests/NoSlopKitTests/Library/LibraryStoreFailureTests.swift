import Foundation
import Testing
@testable import NoSlopKit

// Persistence-2 and concurrency-1: a write that fails is not forgotten, and a file that could not be read at launch
// is read again later and merged with what changed meanwhile.

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makeVideo(_ id: String) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)")
}

@MainActor
private func eventually(timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite final class LibraryStoreFailureTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoSlopLibraryFailureTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent(name).path)
            }
        }
        try? fm.removeItem(at: directory)
    }

    private func makeStore(saveDelay: Duration = .seconds(3_600), retryDelay: Duration = .seconds(5)) -> LibraryStore {
        LibraryStore(directory: directory, saveDelay: saveDelay, now: { referenceDate }, retryDelay: retryDelay)
    }

    private func url(_ file: String) -> URL { directory.appendingPathComponent(file) }
    private func exists(_ file: String) -> Bool { FileManager.default.fileExists(atPath: url(file).path) }
    private func setMode(_ mode: Int, _ target: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    }

    // MARK: persistence-2

    @Test(.enabled(if: getuid() != 0, "the root user can write anywhere"))
    func aWriteThatFailsIsReportedAndWrittenAgainAtTheNextFlush() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setMode(0o555, directory)
        let store = makeStore()

        store.toggleWatchLater(makeVideo("a"))
        #expect(!store.flushNow(), "nothing could be written, so not everything is on disk")
        #expect(!exists("watch-later.json"))

        try setMode(0o755, directory)
        #expect(store.flushNow())
        #expect(makeStore().watchLater.map(\.id) == ["a"])
    }

    @Test(.enabled(if: getuid() != 0, "the root user can write anywhere"))
    func aBackgroundWriteThatFailsIsTriedAgainByFlush() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setMode(0o555, directory)
        let store = makeStore()

        store.toggleWatchLater(makeVideo("a"))
        let first = await store.flush()
        #expect(!first)
        #expect(!exists("watch-later.json"))

        try setMode(0o755, directory)
        let second = await store.flush()
        #expect(second)
        #expect(makeStore().watchLater.map(\.id) == ["a"])
    }

    @Test(.enabled(if: getuid() != 0, "the root user can write anywhere"))
    func aFailedWriteIsRetriedByItselfWithoutAnotherChange() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setMode(0o555, directory)
        let store = makeStore(saveDelay: .milliseconds(1), retryDelay: .milliseconds(20))

        store.toggleWatchLater(makeVideo("a"))
        // Let the first try fail (the timer, then the background write), then make room.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!exists("watch-later.json"))
        try setMode(0o755, directory)

        #expect(await eventually { exists("watch-later.json") })
        #expect(makeStore().watchLater.map(\.id) == ["a"])
    }

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func aFileRefusedAsUnreadableIsNotTriedAgainAndFlushSaysSo() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("[]".utf8)
        try original.write(to: url("watch-later.json"))
        try setMode(0o000, url("watch-later.json"))

        let store = makeStore(saveDelay: .milliseconds(1), retryDelay: .milliseconds(10))
        store.toggleWatchLater(makeVideo("a"))
        #expect(!store.flushNow())
        let flushed = await store.flush()
        #expect(!flushed)

        try setMode(0o644, url("watch-later.json"))
        #expect(try Data(contentsOf: url("watch-later.json")) == original)
    }

    // MARK: concurrency-1

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func filesThatCouldNotBeReadAtLaunchAreReadAgainAndMergedWithWhatChangedMeanwhile() async throws {
        let first = makeStore()
        first.subscribe(SubscribedChannel(id: "old", name: "Old"))
        first.recordProgress(video: makeVideo("v1"), seconds: 12, duration: 100)
        first.toggleWatchLater(makeVideo("w1"))
        _ = first.createPlaylist(title: "Mine")
        first.recordSearch("old search")
        await first.flush()
        let names = ["subscriptions.json", "history.json", "watch-later.json", "playlists.json", "search-history.json"]
        let originals = try names.map { try Data(contentsOf: url($0)) }
        for name in names { try setMode(0o000, url(name)) }

        let locked = makeStore()
        #expect(locked.subscriptions.isEmpty && locked.history.isEmpty && locked.watchLater.isEmpty)
        #expect(locked.playlists.isEmpty && locked.searchHistory.isEmpty)
        #expect(locked.hasUnreadableFiles)

        locked.subscribe(SubscribedChannel(id: "new", name: "New"))
        locked.recordProgress(video: makeVideo("v2"), seconds: 5, duration: 50)
        locked.toggleWatchLater(makeVideo("w2"))
        locked.recordSearch("new search")
        #expect(!(await locked.flush()), "the refused files are not on disk")
        for name in names { try setMode(0o644, url(name)) }
        #expect(try names.map { try Data(contentsOf: url($0)) } == originals, "nothing was written over the files")

        locked.reloadIfUnreadable()
        #expect(!locked.hasUnreadableFiles)
        #expect(locked.subscriptions.map(\.id) == ["new", "old"])
        #expect(locked.history.map(\.id) == ["v2", "v1"])
        #expect(locked.progress(for: "v1") != nil)
        #expect(locked.watchLater.map(\.id) == ["w2", "w1"])
        #expect(locked.playlists.map(\.title) == ["Mine"])
        #expect(locked.searchHistory == ["new search", "old search"])

        #expect(await locked.flush())
        let third = makeStore()
        #expect(third.subscriptions.map(\.id) == ["new", "old"])
        #expect(third.history.map(\.id) == ["v2", "v1"])
        #expect(third.watchLater.map(\.id) == ["w2", "w1"])
        #expect(third.playlists.map(\.title) == ["Mine"])
        #expect(third.searchHistory == ["new search", "old search"])

        locked.reloadIfUnreadable()
        #expect(locked.subscriptions.map(\.id) == ["new", "old"], "a second call changes nothing")
        #expect(locked.history.count == 2)
    }

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func aFileThatIsStillLockedStaysUnreadableAndIsTriedAtTheNextCall() async throws {
        let first = makeStore()
        first.subscribe(SubscribedChannel(id: "old", name: "Old"))
        await first.flush()
        try setMode(0o000, url("subscriptions.json"))

        let locked = makeStore()
        locked.subscribe(SubscribedChannel(id: "new", name: "New"))
        locked.reloadIfUnreadable()
        #expect(locked.hasUnreadableFiles)
        #expect(locked.subscriptions.map(\.id) == ["new"])

        try setMode(0o644, url("subscriptions.json"))
        locked.reloadIfUnreadable()
        #expect(!locked.hasUnreadableFiles)
        #expect(locked.subscriptions.map(\.id) == ["new", "old"])
    }

    @Test func aStoreWhoseFilesWereReadHasNothingToReload() async {
        let first = makeStore()
        first.subscribe(SubscribedChannel(id: "old", name: "Old"))
        await first.flush()
        let second = makeStore()
        #expect(!second.hasUnreadableFiles)
        second.reloadIfUnreadable()
        #expect(second.subscriptions.map(\.id) == ["old"])
    }
}
