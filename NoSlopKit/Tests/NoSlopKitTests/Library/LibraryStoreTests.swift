import Foundation
import Observation
import Testing
@testable import NoSlopKit

/// Set from an observation callback, read by the test.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var isSet: Bool {
        lock.withLock { changed }
    }

    func set() {
        lock.withLock { changed = true }
    }
}

// Whole seconds survive the ISO 8601 round trip exactly, so persisted values compare equal after a reload.
private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makeVideo(_ id: String, channelID: String? = nil, publishedAt: Date? = nil) -> VideoSummary {
    VideoSummary(
        id: id,
        title: "Video \(id)",
        channel: channelID.map { ChannelRef(id: $0, name: "Channel \($0)") },
        publishedAt: publishedAt
    )
}

private func makeChannel(_ id: String, source: SubscriptionSource = .local) -> SubscribedChannel {
    SubscribedChannel(id: id, name: "Channel \(id)", source: source)
}

/// Polls `condition` every 20 ms until it holds or `timeout` passes. The timeout is generous because the write that
/// is waited for runs at utility priority, which a machine busy with other work (parallel test runs) can starve for
/// seconds; a passing test never waits that long.
@MainActor
private func eventually(timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - LibraryStore

@MainActor
@Suite final class LibraryStoreTests {
    /// A directory of its own per test (Swift Testing creates one suite instance per test); removed afterwards.
    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(saveDelay: Duration = .milliseconds(500)) -> LibraryStore {
        LibraryStore(directory: directory, saveDelay: saveDelay, now: { referenceDate })
    }

    private func url(_ file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    private func exists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: url(file).path)
    }

    private func write(_ text: String, to file: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url(file))
    }

    // MARK: From the plan

    @Test func subscriptionsPersist() async {
        let store = makeStore()
        store.subscribe(SubscribedChannel(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"))
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.isSubscribed(channelID: "UCSMOQeBJ2RAnuFungnQOxLg"))
        #expect(reloaded.subscriptions.map(\.name) == ["Blender"])
    }

    @Test func replaceGoogleSubscriptionsKeepsLocal() {
        let store = makeStore()
        store.subscribe(makeChannel("A"))
        store.subscribe(makeChannel("B", source: .google(subscriptionID: "sub-B")))
        store.subscribe(makeChannel("D"))

        store.replaceGoogleSubscriptions([
            makeChannel("C", source: .google(subscriptionID: "sub-C")),
            makeChannel("A", source: .google(subscriptionID: "sub-A")),
        ])

        #expect(Set(store.subscriptions.map(\.id)) == ["A", "C", "D"])
        #expect(store.subscriptions.first { $0.id == "A" }?.source == .google(subscriptionID: "sub-A"))
        #expect(store.subscriptions.first { $0.id == "C" }?.source == .google(subscriptionID: "sub-C"))
        #expect(store.subscriptions.first { $0.id == "D" }?.source == .local)
        #expect(!store.isSubscribed(channelID: "B"))
    }

    @Test func convertGoogleToLocal() {
        let store = makeStore()
        store.subscribe(makeChannel("A"))
        store.subscribe(makeChannel("B", source: .google(subscriptionID: "sub-B")))
        store.subscribe(makeChannel("C", source: .google(subscriptionID: "sub-C")))
        let idsBefore = store.subscriptions.map(\.id)

        store.convertGoogleSubscriptionsToLocal()

        #expect(store.subscriptions.map(\.id) == idsBefore)
        #expect(store.subscriptions.allSatisfy { $0.source == .local })
    }

    @Test func recordProgressMovesToFront() {
        let store = makeStore()
        store.recordProgress(video: makeVideo("v1"), seconds: 10, duration: 100)
        store.recordProgress(video: makeVideo("v2"), seconds: 20, duration: 200)
        store.recordProgress(video: makeVideo("v1"), seconds: 55, duration: nil)

        #expect(store.history.map(\.id) == ["v1", "v2"])
        #expect(store.history.first?.progressSeconds == 55)
        // A later save that does not know the duration keeps the one learned earlier.
        #expect(store.history.first?.durationSeconds == 100)
        #expect(store.progress(for: "v1")?.progressSeconds == 55)
        #expect(store.progress(for: "v2")?.durationSeconds == 200)
        #expect(store.progress(for: "unknown") == nil)
    }

    @Test func historyCappedAt5000() {
        let store = makeStore()
        for index in 0...5000 {
            store.recordProgress(video: makeVideo("v\(index)"), seconds: 1, duration: nil)
        }
        #expect(store.history.count == 5000)
        #expect(store.history.first?.id == "v5000")
        #expect(store.history.last?.id == "v1")
        #expect(store.progress(for: "v0") == nil)
    }

    @Test func progressLookupAlwaysMatchesTheHistory() async {
        let store = makeStore()
        let ids = (0..<40).map { "v\($0)" }
        // A fixed pseudo-random sequence of operations (a linear congruential generator keeps the test repeatable).
        var state: UInt64 = 12_345
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        func lookupMatchesHistory() -> Bool {
            ids.allSatisfy { id in store.progress(for: id) == store.history.first { $0.id == id } }
                && store.history.allSatisfy { store.progress(for: $0.id) == $0 }
        }

        for step in 0..<1500 {
            let id = ids[next(ids.count)]
            switch next(10) {
            case 0: store.removeFromHistory(videoID: id)
            case 1 where step % 300 == 0: store.clearHistory()
            default: store.recordProgress(video: makeVideo(id), seconds: Double(step), duration: next(2) == 0 ? 600 : nil)
            }
            #expect(lookupMatchesHistory(), "after step \(step)")
        }

        await store.flush()
        let reloaded = makeStore()
        #expect(reloaded.history == store.history)
        #expect(ids.allSatisfy { reloaded.progress(for: $0) == store.progress(for: $0) })
    }

    @Test func theCapForgetsDroppedVideosInTheLookupToo() {
        let store = makeStore()
        for index in 0..<5003 {
            store.recordProgress(video: makeVideo("v\(index)"), seconds: 1, duration: nil)
        }
        #expect(store.history.count == 5000)
        #expect(store.progress(for: "v0") == nil && store.progress(for: "v2") == nil)
        #expect(store.progress(for: "v3")?.id == "v3")
        #expect(store.progress(for: "v5002") == store.history.first)

        // Watching a video again after it was dropped starts a fresh entry at the front.
        store.recordProgress(video: makeVideo("v0"), seconds: 7, duration: nil)
        #expect(store.history.count == 5000)
        #expect(store.history.first?.id == "v0")
        #expect(store.progress(for: "v0")?.progressSeconds == 7)
        #expect(store.progress(for: "v3") == nil, "the next oldest entry made room")
    }

    @Test func watchingAnOlderVideoAgainMovesItToTheFront() {
        let store = makeStore()
        for id in ["a", "b", "c", "d"] {
            store.recordProgress(video: makeVideo(id), seconds: 1, duration: 100)
        }
        store.recordProgress(video: makeVideo("b"), seconds: 50, duration: nil)

        #expect(store.history.map(\.id) == ["b", "d", "c", "a"])
        #expect(store.progress(for: "b")?.progressSeconds == 50)
        #expect(store.progress(for: "b")?.durationSeconds == 100)
        #expect(store.history.count == 4)
    }

    @Test func searchHistoryDedupesCaseInsensitivelyCappedAt50() {
        let store = makeStore()
        store.recordSearch("Blender")
        store.recordSearch("blender donut")
        store.recordSearch("BLENDER")
        #expect(store.searchHistory == ["BLENDER", "blender donut"])

        store.recordSearch("   ")
        store.recordSearch("  padded  ")
        #expect(store.searchHistory == ["padded", "BLENDER", "blender donut"])

        for index in 0..<60 {
            store.recordSearch("query \(index)")
        }
        #expect(store.searchHistory.count == 50)
        #expect(store.searchHistory.first == "query 59")
        #expect(store.searchHistory.last == "query 10")

        store.clearSearchHistory()
        #expect(store.searchHistory.isEmpty)
    }

    @Test func playlistsCRUD() async {
        let store = makeStore()
        let faves = store.createPlaylist(title: "Faves")
        #expect(faves.title == "Faves")

        store.add(makeVideo("v1"), toPlaylist: faves.id)
        store.add(makeVideo("v2"), toPlaylist: faves.id)
        store.add(makeVideo("v1"), toPlaylist: faves.id)
        #expect(store.playlists.first?.videos.map(\.id) == ["v1", "v2"])

        store.remove(videoID: "v1", fromPlaylist: faves.id)
        store.renamePlaylist(faves.id, title: "Best")
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.playlists.map(\.title) == ["Best"])
        #expect(reloaded.playlists.first?.id == faves.id)
        #expect(reloaded.playlists.first?.videos.map(\.id) == ["v2"])

        reloaded.deletePlaylist(faves.id)
        #expect(reloaded.playlists.isEmpty)
        await reloaded.flush()
        #expect(makeStore().playlists.isEmpty)
    }

    /// Review Focus #5 (testCorruptLibraryFileIsMovedAside): an undecodable file is renamed, never deleted, and
    /// everything readable is kept.
    @Test func corruptLibraryFileIsMovedAside() async throws {
        let first = makeStore()
        first.subscribe(makeChannel("UCkept"))
        await first.flush()
        try write("{garbage", to: "history.json")

        let store = makeStore()

        #expect(store.history.isEmpty)
        #expect(exists("history.json.corrupt"))
        #expect(try Data(contentsOf: url("history.json.corrupt")) == Data("{garbage".utf8))
        #expect(!exists("history.json"))
        #expect(store.isSubscribed(channelID: "UCkept"))

        // The store keeps working and writes a fresh file next to the preserved one.
        store.recordProgress(video: makeVideo("v1"), seconds: 40, duration: 100)
        await store.flush()
        #expect(exists("history.json"))
        #expect(exists("history.json.corrupt"))
        #expect(makeStore().history.map(\.id) == ["v1"])
    }

    // MARK: Persistence behaviour

    @Test func everythingPersistsAcrossInstances() async {
        let store = makeStore()
        store.subscribe(SubscribedChannel(
            id: "UC1",
            name: "One",
            avatarURL: URL(string: "https://example.com/a.jpg"),
            source: .google(subscriptionID: "sub-1"),
            subscribedAt: referenceDate
        ))
        store.recordProgress(video: makeVideo("v1", channelID: "UC1", publishedAt: referenceDate), seconds: 61.5, duration: 600)
        store.toggleWatchLater(makeVideo("w1"))
        let playlist = store.createPlaylist(title: "Faves")
        store.add(makeVideo("p1"), toPlaylist: playlist.id)
        store.recordSearch("blender")
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.subscriptions == store.subscriptions)
        #expect(reloaded.history == store.history)
        #expect(reloaded.watchLater == store.watchLater)
        #expect(reloaded.playlists == store.playlists)
        #expect(reloaded.searchHistory == ["blender"])
        #expect(reloaded.history.first?.lastWatchedAt == referenceDate)
        #expect(reloaded.progress(for: "v1") == store.history.first)
    }

    @Test func changesAreObservableForTheViews() {
        let store = makeStore()
        /// Whether `change` notifies someone who has read `read`.
        func notified(reading read: () -> Void, after change: () -> Void) -> Bool {
            let flag = ChangeFlag()
            withObservationTracking { read() } onChange: { flag.set() }
            change()
            return flag.isSet
        }

        let subscribed = notified(reading: { _ = store.subscriptions }, after: { store.subscribe(makeChannel("A")) })
        let recorded = notified(reading: { _ = store.history }, after: { store.recordProgress(video: makeVideo("v1"), seconds: 1, duration: nil) })
        // Screens ask for the progress of one thumbnail; that read has to see later progress saves.
        let progressed = notified(reading: { _ = store.progress(for: "v1") }, after: { store.recordProgress(video: makeVideo("v1"), seconds: 5, duration: nil) })
        let unknownVideo = notified(reading: { _ = store.progress(for: "v9") }, after: { store.recordProgress(video: makeVideo("v9"), seconds: 5, duration: nil) })
        // The playing video is updated in place; that is a change too.
        let updated = notified(reading: { _ = store.history }, after: { store.recordProgress(video: makeVideo("v1"), seconds: 9, duration: nil) })
        let saved = notified(reading: { _ = store.watchLater }, after: { store.toggleWatchLater(makeVideo("w")) })
        let created = notified(reading: { _ = store.playlists }, after: { store.createPlaylist(title: "P") })
        let searched = notified(reading: { _ = store.searchHistory }, after: { store.recordSearch("q") })

        #expect(subscribed && recorded && progressed && unknownVideo && updated && saved && created && searched)
    }

    @Test func flushWritesOnlyWhatChanged() async {
        let store = makeStore()
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        store.subscribe(makeChannel("A"))
        await store.flush()
        #expect(exists("subscriptions.json"))
        #expect(!exists("history.json"))
        #expect(!exists("watch-later.json"))
        #expect(!exists("playlists.json"))
        #expect(!exists("search-history.json"))
    }

    @Test func writesAreCoalescedInTheBackgroundWithoutFlush() async {
        let store = makeStore(saveDelay: .milliseconds(40))
        store.subscribe(makeChannel("A"))
        // Nothing has been able to run yet: the write happens on a timer, not inside the mutation.
        #expect(!exists("subscriptions.json"))

        let written = await eventually { exists("subscriptions.json") }
        #expect(written)
        await store.flush()
        #expect(makeStore().isSubscribed(channelID: "A"))
    }

    @Test func manyQuickChangesEndUpAsTheLastState() async {
        let store = makeStore()
        for index in 0..<200 {
            store.recordSearch("q\(index)")
            store.recordProgress(video: makeVideo("v\(index % 7)"), seconds: Double(index), duration: nil)
        }
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.searchHistory.first == "q199")
        #expect(reloaded.searchHistory.count == 50)
        #expect(reloaded.history.count == 7)
        #expect(reloaded.history.first?.id == "v\(199 % 7)")
        #expect(reloaded.history.first?.progressSeconds == 199)
    }

    @Test func backgroundWritesThatOverlapStillEndWithTheLatestState() async {
        // A 1 ms timer lets many writes start while earlier ones may still be running.
        let store = makeStore(saveDelay: .milliseconds(1))
        for index in 0..<60 {
            store.recordSearch("q\(index)")
            store.recordProgress(video: makeVideo("v\(index % 5)"), seconds: Double(index), duration: nil)
            try? await Task.sleep(for: .milliseconds(2))
        }
        await store.flush()

        let reloaded = makeStore()
        #expect(reloaded.searchHistory.first == "q59")
        #expect(reloaded.searchHistory.count == 50)
        #expect(reloaded.history.first?.id == "v4")
        #expect(reloaded.history.first?.progressSeconds == 59)
        #expect(reloaded.history.count == 5)
    }

    @Test func clearedAndRemovedHistoryStaysGone() async {
        let store = makeStore()
        store.recordProgress(video: makeVideo("v1"), seconds: 5, duration: nil)
        store.recordProgress(video: makeVideo("v2"), seconds: 5, duration: nil)
        store.recordProgress(video: makeVideo("v3"), seconds: 5, duration: nil)
        store.removeFromHistory(videoID: "v2")
        await store.flush()
        #expect(makeStore().history.map(\.id) == ["v3", "v1"])

        store.clearHistory()
        await store.flush()
        #expect(makeStore().history.isEmpty)
    }

    @Test func watchLaterTogglesAndKeepsNewestFirst() async {
        let store = makeStore()
        store.toggleWatchLater(makeVideo("a"))
        store.toggleWatchLater(makeVideo("b"))
        #expect(store.watchLater.map(\.id) == ["b", "a"])
        #expect(store.isInWatchLater("a"))

        store.toggleWatchLater(makeVideo("a"))
        #expect(!store.isInWatchLater("a"))
        #expect(store.watchLater.map(\.id) == ["b"])

        await store.flush()
        #expect(makeStore().watchLater.map(\.id) == ["b"])
    }

    @Test func subscribeReplacesTheSameChannelInPlaceAndStampsTheDate() {
        let store = makeStore()
        store.subscribe(makeChannel("A"))
        store.subscribe(makeChannel("B"))
        store.subscribe(SubscribedChannel(id: "A", name: "Renamed", source: .google(subscriptionID: "sub-A")))

        #expect(store.subscriptions.map(\.id) == ["A", "B"])
        #expect(store.subscriptions.first?.name == "Renamed")
        #expect(store.subscriptions.first?.source == .google(subscriptionID: "sub-A"))
        #expect(store.subscriptions.first?.subscribedAt == referenceDate)

        store.unsubscribe(channelID: "A")
        store.unsubscribe(channelID: "not subscribed")
        #expect(store.subscriptions.map(\.id) == ["B"])
    }

    @Test func replaceGoogleSubscriptionsDropsDuplicatesAndKeepsKnownDates() {
        let store = makeStore()
        store.subscribe(SubscribedChannel(id: "A", name: "A", source: .google(subscriptionID: "old"), subscribedAt: referenceDate))

        store.replaceGoogleSubscriptions([
            makeChannel("A", source: .google(subscriptionID: "new")),
            makeChannel("A", source: .google(subscriptionID: "duplicate")),
        ])

        #expect(store.subscriptions.count == 1)
        #expect(store.subscriptions.first?.source == .google(subscriptionID: "new"))
        #expect(store.subscriptions.first?.subscribedAt == referenceDate)
    }

    @Test func playlistTitlesAreTrimmedAndNeverEmpty() {
        let store = makeStore()
        let untitled = store.createPlaylist(title: "   ")
        let padded = store.createPlaylist(title: "  Mix  ")
        #expect(untitled.title == "Untitled playlist")
        #expect(padded.title == "Mix")

        store.renamePlaylist(padded.id, title: "   ")
        #expect(store.playlists.last?.title == "Mix")
        store.renamePlaylist(UUID(), title: "Nope")
        store.add(makeVideo("v1"), toPlaylist: UUID())
        #expect(store.playlists.count == 2)
    }

    @Test func nonFiniteProgressNeverBreaksPersistence() async {
        let store = makeStore()
        store.recordProgress(video: makeVideo("v1"), seconds: .infinity, duration: .nan)
        store.recordProgress(video: makeVideo("v2"), seconds: .nan, duration: -5)
        store.recordProgress(video: makeVideo("v3"), seconds: -3, duration: 0)
        #expect(store.history.map(\.progressSeconds) == [0, 0, 0])
        #expect(store.history.allSatisfy { $0.durationSeconds == nil })

        await store.flush()
        #expect(makeStore().history.map(\.id) == ["v3", "v2", "v1"])
    }

    // MARK: Old and damaged files

    @Test func olderFilesWithMissingKeysStillLoad() throws {
        try write(#"[{"video":{"id":"abc"}}]"#, to: "history.json")
        try write(#"[{"id":"UC1"}]"#, to: "subscriptions.json")
        try write(#"[{"id":"w1"}]"#, to: "watch-later.json")
        try write(#"[{"id":"D3B0C6E0-8C8D-4B7E-9D55-0A0F6C1B2A11","title":"Old"}]"#, to: "playlists.json")
        try write(#"["blender"]"#, to: "search-history.json")

        let store = makeStore()

        #expect(store.history.map(\.id) == ["abc"])
        #expect(store.history.first?.progressSeconds == 0)
        #expect(store.subscriptions.map(\.id) == ["UC1"])
        #expect(store.subscriptions.first?.source == .local)
        #expect(store.watchLater.map(\.id) == ["w1"])
        #expect(store.playlists.map(\.title) == ["Old"])
        #expect(store.searchHistory == ["blender"])
        #expect(!exists("history.json.corrupt"))
    }

    /// Review Focus #5: "a truncated file". A real library file cut in half, as a crash during a non-atomic write or a
    /// full disk could leave it.
    @Test func aTruncatedFileIsMovedAsideWithAllItsBytes() async throws {
        let first = makeStore()
        for index in 0..<20 {
            first.recordProgress(video: makeVideo("v\(index)", channelID: "UC1"), seconds: 90, duration: 300)
        }
        first.toggleWatchLater(makeVideo("w1"))
        await first.flush()
        let whole = try Data(contentsOf: url("history.json"))
        let truncated = whole.prefix(whole.count / 2)
        try truncated.write(to: url("history.json"))

        let store = makeStore()

        #expect(store.history.isEmpty)
        #expect(try Data(contentsOf: url("history.json.corrupt")) == truncated)
        #expect(!exists("history.json"))
        #expect(store.watchLater.map(\.id) == ["w1"], "the other files are still read")
    }

    @Test func oneUnreadableEntryDoesNotCostTheOthers() async throws {
        let original = #"[{"id":"A","name":"first"},{"name":"has no id"},{"id":"C","name":"third"}]"#
        try write(original, to: "subscriptions.json")
        try write(#"[{"video":{"id":"v1"}},{"video":"not a video"},{"video":{"id":"v3"}}]"#, to: "history.json")
        try write(#"["blender", 42, "donut"]"#, to: "search-history.json")

        let store = makeStore()

        #expect(store.subscriptions.map(\.id) == ["A", "C"])
        #expect(store.history.map(\.id) == ["v1", "v3"])
        #expect(store.searchHistory == ["blender", "donut"])
        // The original, damaged entries included, is kept next to the clean file that replaces it.
        #expect(try Data(contentsOf: url("subscriptions.json.corrupt")) == Data(original.utf8))
        #expect(exists("history.json.corrupt") && exists("search-history.json.corrupt"))
        #expect(exists("subscriptions.json"), "the readable entries are written back to a clean file right away")

        store.subscribe(makeChannel("D"))
        await store.flush()
        #expect(makeStore().subscriptions.map(\.id) == ["A", "C", "D"])
        #expect(!exists("watch-later.json.corrupt"), "untouched files are not renamed")
    }

    /// Review Focus #5 ("everything readable kept"): the readable entries of a partly damaged file must still be
    /// there on the launch after the one that found the damage, even when nothing was changed in between. Without
    /// the write-back the next launch would find no file at all and start with an empty library, while the entries
    /// sat unused in the `.corrupt` copy.
    @Test func entriesRecoveredFromADamagedFileSurviveAnUntouchedRestart() throws {
        let original = #"[{"id":"A","name":"first"},{"name":"has no id"},{"id":"C","name":"third"}]"#
        try write(original, to: "subscriptions.json")
        try write(#"[{"video":{"id":"v1"}},{"video":"not a video"},{"video":{"id":"v3"}}]"#, to: "history.json")
        try write(#"["blender", 42, "donut"]"#, to: "search-history.json")

        _ = makeStore()   // the launch that finds the damage; the viewer changes nothing
        let second = makeStore()

        #expect(second.subscriptions.map(\.id) == ["A", "C"])
        #expect(second.history.map(\.id) == ["v1", "v3"])
        #expect(second.searchHistory == ["blender", "donut"])
        #expect(try Data(contentsOf: url("subscriptions.json.corrupt")) == Data(original.utf8), "the damaged original is not touched again")
    }

    @Test func aFileWithNothingReadableIsNotReplacedByAnEmptyOne() throws {
        try write(#"[{"name":"no id"},7,"text"]"#, to: "subscriptions.json")

        let store = makeStore()

        #expect(store.subscriptions.isEmpty)
        #expect(exists("subscriptions.json.corrupt"))
        #expect(!exists("subscriptions.json"), "there is nothing to write back")
    }

    @Test func everyFileIsCheckedOnItsOwn() throws {
        try write("{garbage", to: "subscriptions.json")
        try write("[", to: "watch-later.json")
        try write("not json", to: "playlists.json")
        try write(#"{"a":1}"#, to: "search-history.json")
        try write(#"[{"video":{"id":"fine"}}]"#, to: "history.json")

        let store = makeStore()

        #expect(store.subscriptions.isEmpty && store.watchLater.isEmpty && store.playlists.isEmpty && store.searchHistory.isEmpty)
        #expect(store.history.map(\.id) == ["fine"])
        for file in ["subscriptions.json", "watch-later.json", "playlists.json", "search-history.json"] {
            #expect(exists(file + ".corrupt"), "\(file) should have been moved aside")
            #expect(!exists(file), "\(file) should be gone from its original place")
        }
        #expect(!exists("history.json.corrupt"))
    }

    @Test func duplicatesInAFileAreDroppedOnLoad() throws {
        try write(#"[{"id":"A","name":"first"},{"id":"B"},{"id":"A","name":"second"}]"#, to: "subscriptions.json")
        try write(#"[{"video":{"id":"v1"}},{"video":{"id":"v2"}},{"video":{"id":"v1"}}]"#, to: "history.json")
        try write(#"["Blender","blender","Other"]"#, to: "search-history.json")

        let store = makeStore()

        #expect(store.subscriptions.map(\.name) == ["first", ""])
        #expect(store.history.map(\.id) == ["v1", "v2"])
        #expect(store.searchHistory == ["Blender", "Other"])
    }

    @Test func oversizedFilesAreCappedOnLoad() throws {
        let entries = (0..<5100).map { #"{"video":{"id":"v\#($0)"}}"# }.joined(separator: ",")
        try write("[" + entries + "]", to: "history.json")
        let queries = (0..<80).map { "\"q\($0)\"" }.joined(separator: ",")
        try write("[" + queries + "]", to: "search-history.json")

        let store = makeStore()

        #expect(store.history.count == 5000)
        #expect(store.history.first?.id == "v0")
        #expect(store.history.last?.id == "v4999")
        #expect(store.searchHistory.count == 50)
        #expect(store.searchHistory.first == "q0")
    }

    // MARK: What was only true on the day a video was saved
    //
    // The store keeps a video as it was when it was saved and is read months later: "3 days ago" has to become a
    // date, and a stream that was live or a premiere that was upcoming is neither by then. (The rules are pinned in
    // LibraryVideoTests; here they are shown to apply wherever a video enters the library.)

    private func stale(_ id: String = "a") -> VideoSummary {
        VideoSummary(
            id: id, title: "A", channel: ChannelRef(id: "UC1", name: "Chan"), viewCountText: "1,204 watching",
            publishedText: "3 days ago", isLive: true
        )
    }

    private func expectKeptWithADate(_ video: VideoSummary?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(video?.publishedText == nil, sourceLocation: sourceLocation)
        #expect(video?.publishedAt == referenceDate.addingTimeInterval(-3 * 86_400), sourceLocation: sourceLocation)
        #expect(video?.isLive == false, sourceLocation: sourceLocation)
        #expect(video?.viewCountText == nil, sourceLocation: sourceLocation)
        #expect(video?.viewCount == nil, sourceLocation: sourceLocation)
        #expect(video?.channel == ChannelRef(id: "UC1", name: "Chan"), sourceLocation: sourceLocation)
    }

    @Test func watchLaterKeepsADateInsteadOfTheRelativeAge() {
        let store = makeStore()
        store.toggleWatchLater(stale())
        expectKeptWithADate(store.watchLater.first)
    }

    @Test func aPlaylistKeepsADateInsteadOfTheRelativeAge() {
        let store = makeStore()
        let playlist = store.createPlaylist(title: "P")
        store.add(stale(), toPlaylist: playlist.id)
        expectKeptWithADate(store.playlists.first?.videos.first)
    }

    @Test func theHistoryKeepsADateInsteadOfTheRelativeAge() {
        let store = makeStore()
        store.recordProgress(video: stale(), seconds: 10, duration: 100)
        expectKeptWithADate(store.history.first?.video)
        expectKeptWithADate(store.progress(for: "a")?.video)

        // The player reports every few seconds, each time with the video as it was opened.
        store.recordProgress(video: stale(), seconds: 20, duration: 100)
        expectKeptWithADate(store.history.first?.video)
        #expect(store.history.count == 1)
    }

    @Test func aPremiereThatWasUpcomingIsNotUpcomingAnyMoreOnceSaved() {
        let premiere = VideoSummary(
            id: "p", title: "Premiere", viewCountText: "12 waiting", publishedText: "Scheduled for 11/3/26, 8:00 PM", isUpcoming: true
        )
        let store = makeStore()
        store.toggleWatchLater(premiere)
        let playlist = store.createPlaylist(title: "P")
        store.add(premiere, toPlaylist: playlist.id)
        store.recordProgress(video: premiere, seconds: 5, duration: nil)

        for kept in [store.watchLater.first, store.playlists.first?.videos.first, store.history.first?.video] {
            #expect(kept?.isUpcoming == false)
            #expect(kept?.viewCountText == nil)
            #expect(kept?.publishedText == nil)
            #expect(kept?.publishedAt == nil, "a date that cannot be read leaves no age")
        }
    }

    @Test func aVideoWithADateOrNoAgeIsKeptAsItIs() {
        let rss = VideoSummary(id: "r", title: "RSS", viewCountText: "1.2M views", publishedAt: referenceDate.addingTimeInterval(-9 * 86_400))
        let plain = VideoSummary(id: "n", title: "Plain", viewCount: 5, viewCountText: "5 views")
        let store = makeStore()
        store.toggleWatchLater(rss)
        store.toggleWatchLater(plain)
        #expect(store.watchLater == [plain, rss])
    }

    @Test func whatWasKeptSurvivesARestart() async {
        let store = makeStore()
        store.toggleWatchLater(stale("w"))
        let playlist = store.createPlaylist(title: "P")
        store.add(stale("p"), toPlaylist: playlist.id)
        store.recordProgress(video: stale("h"), seconds: 10, duration: 100)
        await store.flush()

        let reloaded = makeStore()
        expectKeptWithADate(reloaded.watchLater.first)
        expectKeptWithADate(reloaded.playlists.first?.videos.first)
        expectKeptWithADate(reloaded.history.first?.video)
    }

    @Test func entriesAlreadyOnDiskAreCorrectedWhenTheLibraryLoads() async throws {
        // Written by an earlier build, months ago: the stale texts are in the files.
        let video = #"{"id":"%@","title":"T","viewCountText":"1,204 watching","publishedText":"3 days ago","isLive":true,"isMembersOnly":true}"#
        let oldPremiere = #"{"id":"u","title":"U","viewCountText":"12 waiting","publishedText":"Scheduled for 11/3/26, 8:00 PM","isUpcoming":true}"#
        let german = #"{"id":"g","title":"G","viewCountText":"9,8 Tsd. Aufrufe","publishedText":"vor 3 Tagen"}"#
        // The history knows when each video was watched: 5 days before the (fixed) "now" of these tests.
        let watched = "2027-01-10T08:00:00Z"
        let watchedAt = referenceDate.addingTimeInterval(-5 * 86_400)
        try write(
            #"[{"video":\#(String(format: video, "h")),"lastWatchedAt":"\#(watched)","progressSeconds":42,"durationSeconds":100}]"#,
            to: "history.json"
        )
        try write("[\(String(format: video, "w")),\(oldPremiere),\(german)]", to: "watch-later.json")
        try write(
            #"[{"id":"D3B0C6E0-8C8D-4B7E-9D55-0A0F6C1B2A11","title":"P","createdAt":"\#(watched)","updatedAt":"\#(watched)","videos":[\#(String(format: video, "p"))]}]"#,
            to: "playlists.json"
        )
        let before = try Data(contentsOf: url("history.json"))

        let store = makeStore()

        // History: counted back from the day it was watched. Everything else about the entry is as it was.
        let entry = try #require(store.history.first)
        #expect(entry.video.publishedAt == watchedAt.addingTimeInterval(-3 * 86_400))
        #expect(entry.video.publishedText == nil)
        #expect(!entry.video.isLive)
        #expect(entry.video.viewCountText == nil)
        #expect(entry.video.isMembersOnly)
        #expect(entry.lastWatchedAt == watchedAt)
        #expect(entry.progressSeconds == 42)
        #expect(entry.durationSeconds == 100)
        #expect(store.progress(for: "h")?.video.publishedAt == entry.video.publishedAt)

        // Watch Later and the playlists have no date of saving: no age rather than a wrong one.
        let later = store.watchLater
        #expect(later.map(\.id) == ["w", "u", "g"])
        #expect(later.allSatisfy { $0.publishedText == nil && $0.publishedAt == nil && !$0.isLive && !$0.isUpcoming })
        #expect(later[0].viewCountText == nil && later[0].isMembersOnly)
        #expect(later[1].viewCountText == nil)
        #expect(later[2].viewCountText == "9,8 Tsd. Aufrufe", "an ordinary video keeps its views")
        let inPlaylist = try #require(store.playlists.first?.videos.first)
        #expect(inPlaylist.id == "p" && inPlaylist.publishedText == nil && inPlaylist.publishedAt == nil && !inPlaylist.isLive)

        // Reading does not rewrite the files; the corrected data is written with the next change.
        await store.flush()
        #expect(try Data(contentsOf: url("history.json")) == before)
        #expect(!exists("history.json.corrupt") && !exists("watch-later.json.corrupt") && !exists("playlists.json.corrupt"))
    }
}

// MARK: - JSONFileStore

@Suite final class LibraryStoreJSONFileTests {
    private struct Sample: Codable, Equatable {
        var name: String
        var date: Date
        var number: Double
    }

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopLibraryStoreJSONFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    private func exists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: url(file).path)
    }

    private func write(_ text: String, to file: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url(file))
    }

    @Test func missingFileGivesTheDefaultAndCreatesNothing() {
        let store = JSONFileStore(directory: directory)
        let fallback: [Int] = [1, 2]
        #expect(store.load("nothing.json", default: fallback) == fallback)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func saveCreatesTheDirectoryAndRoundTrips() {
        let store = JSONFileStore(directory: directory.appendingPathComponent("a/b", isDirectory: true))
        let samples = [Sample(name: "x", date: referenceDate, number: 1.5), Sample(name: "y", date: referenceDate + 60, number: -2)]
        store.save(samples, to: "samples.json")

        #expect(store.load("samples.json", default: [Sample]()) == samples)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("a/b").path)) ?? []
        #expect(leftovers == ["samples.json"], "an atomic write must not leave temporary files behind")
    }

    @Test func savedDatesAreISO8601AndReadableByAStandardDecoder() throws {
        let store = JSONFileStore(directory: directory)
        let sample = Sample(name: "x", date: referenceDate, number: 1)
        store.save([sample], to: "samples.json")

        let data = try Data(contentsOf: url("samples.json"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"\(ISO8601DateFormatter().string(from: referenceDate))\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([Sample].self, from: data) == [sample])
    }

    @Test func loadAcceptsFractionalSecondsOffsetsAndNumericDates() throws {
        try write(#"[{"name":"fraction","date":"2027-01-15T08:00:00.250Z","number":1}]"#, to: "fraction.json")
        try write(#"[{"name":"offset","date":"2027-01-15T09:00:00+01:00","number":1}]"#, to: "offset.json")
        try write(#"[{"name":"number","date":123456.5,"number":1}]"#, to: "number.json")
        let store = JSONFileStore(directory: directory)

        #expect(store.load("fraction.json", default: [Sample]()).first?.date == referenceDate + 0.25)
        #expect(store.load("offset.json", default: [Sample]()).first?.date == referenceDate)
        #expect(store.load("number.json", default: [Sample]()).first?.date == Date(timeIntervalSinceReferenceDate: 123_456.5))
    }

    @Test func anUndecodableFileIsMovedAsideNotDeleted() throws {
        try write("{garbage", to: "samples.json")
        let store = JSONFileStore(directory: directory)

        #expect(store.load("samples.json", default: [Sample]()).isEmpty)
        #expect(!exists("samples.json"))
        #expect(try Data(contentsOf: url("samples.json.corrupt")) == Data("{garbage".utf8))
    }

    @Test func aWrongShapeAndAnEmptyFileAreCorruptToo() throws {
        try write(#"{"a":1}"#, to: "shape.json")
        try write("", to: "empty.json")
        let store = JSONFileStore(directory: directory)

        let fallback: [Int] = [9]
        #expect(store.load("shape.json", default: fallback) == fallback)
        #expect(store.load("empty.json", default: fallback) == fallback)
        #expect(exists("shape.json.corrupt") && !exists("shape.json"))
        #expect(exists("empty.json.corrupt") && !exists("empty.json"))
    }

    @Test func aNewerCorruptFileReplacesAnOlderOne() throws {
        let store = JSONFileStore(directory: directory)
        try write("first damage", to: "samples.json")
        _ = store.load("samples.json", default: [Sample]())
        try write("second damage", to: "samples.json")
        _ = store.load("samples.json", default: [Sample]())

        #expect(try Data(contentsOf: url("samples.json.corrupt")) == Data("second damage".utf8))
        #expect(!exists("samples.json"))
    }

    @Test func loadListKeepsTheReadableEntriesAndMovesTheOriginalAside() throws {
        let original = #"[{"name":"ok","date":"2027-01-15T08:00:00Z","number":1},{"name":"broken"},7,{"name":"fine","date":"2027-01-15T08:00:00Z","number":2}]"#
        try write(original, to: "samples.json")
        let store = JSONFileStore(directory: directory)

        let samples: [Sample] = store.loadList("samples.json")

        #expect(samples.map(\.name) == ["ok", "fine"])
        #expect(try Data(contentsOf: url("samples.json.corrupt")) == Data(original.utf8))

        // The readable entries are written straight back, so a second load finds a healthy file with the same content
        // and leaves the preserved original alone.
        #expect(exists("samples.json"))
        let again: [Sample] = store.loadList("samples.json")
        #expect(again == samples)
        #expect(try Data(contentsOf: url("samples.json.corrupt")) == Data(original.utf8))
    }

    @Test func loadListLeavesAHealthyFileAlone() throws {
        let store = JSONFileStore(directory: directory)
        let samples = [Sample(name: "x", date: referenceDate, number: 1)]
        store.save(samples, to: "samples.json")

        let loaded: [Sample] = store.loadList("samples.json")

        #expect(loaded == samples)
        #expect(exists("samples.json") && !exists("samples.json.corrupt"))
    }

    @Test func loadListWithoutAFileOrWithoutAListGivesNothing() throws {
        let store = JSONFileStore(directory: directory)
        #expect((store.loadList("missing.json") as [Sample]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try write(#"{"not":"a list"}"#, to: "object.json")
        try write("{garbage", to: "garbage.json")
        #expect((store.loadList("object.json") as [Sample]).isEmpty)
        #expect((store.loadList("garbage.json") as [Sample]).isEmpty)
        #expect(exists("object.json.corrupt") && exists("garbage.json.corrupt"))
    }

    // MARK: A file that cannot be read is not a damaged file

    @Test func aFileThatCannotBeReadIsLeftWhereItIs() throws {
        // A directory where the file should be: it exists but cannot be read as data. That says nothing about content.
        try FileManager.default.createDirectory(at: url("samples.json"), withIntermediateDirectories: true)
        let store = JSONFileStore(directory: directory)

        let fallback: [Int] = [7]
        #expect(store.load("samples.json", default: fallback) == fallback)
        #expect((store.loadList("samples.json") as [Int]).isEmpty)
        store.save([1, 2], to: "samples.json")

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url("samples.json").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(!exists("samples.json.corrupt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["samples.json"], "no temporary file is left behind")
    }

    /// A reader that can be told to fail, for a store that has to survive what a locked or failing device does.
    private final class SwitchableReader: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: (any Error)?

        init(failingWith failure: (any Error)?) {
            self.failure = failure
        }

        func fail(with failure: (any Error)?) {
            lock.withLock { self.failure = failure }
        }

        func read(_ url: URL) throws -> Data {
            if let failure = lock.withLock({ failure }) { throw failure }
            return try Data(contentsOf: url)
        }
    }

    struct ReadFailure: Sendable, CustomTestStringConvertible {
        var name: String
        var error: any Error
        var testDescription: String { name }
    }

    private static let readFailures: [ReadFailure] = [
        ReadFailure(name: "no permission", error: CocoaError(.fileReadNoPermission)),
        ReadFailure(name: "unknown read error", error: CocoaError(.fileReadUnknown)),
        ReadFailure(name: "I/O error", error: POSIXError(.EIO)),
        // What an iPhone reports for a protected file before the first unlock: no permission, caused by EPERM.
        ReadFailure(
            name: "data protection",
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            ])
        ),
        ReadFailure(name: "some other error", error: NoSlopError.network("weird")),
    ]

    @Test(arguments: readFailures)
    func aReadFailureNeitherMovesTheFileNorLetsAnythingOverwriteIt(_ failure: ReadFailure) throws {
        let original = "[1,2,3]"
        try write(original, to: "samples.json")
        let reader = SwitchableReader(failingWith: failure.error)
        let store = JSONFileStore(directory: directory, read: { try reader.read($0) })

        // The default comes back, whichever way the file is loaded.
        let fallback: [Int] = [9]
        #expect(store.load("samples.json", default: fallback) == fallback)
        #expect((store.loadList("samples.json") as [Int]).isEmpty)

        // The file is neither moved aside nor replaced, however often the app saves meanwhile.
        store.save([4, 5, 6], to: "samples.json")
        store.save([7], to: "samples.json")
        #expect(!exists("samples.json.corrupt"))
        #expect(try Data(contentsOf: url("samples.json")) == Data(original.utf8))

        // Files that could be read are not affected.
        store.save([1], to: "other.json")
        #expect(exists("other.json"))

        // Once a load of the file succeeds, saving works again.
        reader.fail(with: nil)
        #expect(store.load("samples.json", default: fallback) == [1, 2, 3])
        store.save([4, 5, 6], to: "samples.json")
        #expect(store.load("samples.json", default: fallback) == [4, 5, 6])
        #expect(!exists("samples.json.corrupt"))
    }

    @Test func theProtectionLastsUntilALoadOfThatFileSucceedsWhicheverStoreDoesIt() throws {
        try write("[1,2,3]", to: "samples.json")
        let failing = JSONFileStore(directory: directory, read: { _ in throw CocoaError(.fileReadNoPermission) })
        _ = failing.load("samples.json", default: [Int]())

        // A store that never loaded the file is just as unable to overwrite it.
        let other = JSONFileStore(directory: directory)
        other.save([0], to: "samples.json")
        #expect(try Data(contentsOf: url("samples.json")) == Data("[1,2,3]".utf8))

        // A successful load of another file does not lift it.
        try write("[5]", to: "elsewhere.json")
        #expect(other.load("elsewhere.json", default: [Int]()) == [5])
        other.save([0], to: "samples.json")
        #expect(try Data(contentsOf: url("samples.json")) == Data("[1,2,3]".utf8))

        // A successful load of this one does.
        #expect(other.load("samples.json", default: [Int]()) == [1, 2, 3])
        other.save([0], to: "samples.json")
        #expect(other.load("samples.json", default: [Int]()) == [0])
    }

    struct MissingFileError: Sendable, CustomTestStringConvertible {
        var name: String
        var error: any Error
        var testDescription: String { name }
    }

    @Test(arguments: [
        MissingFileError(name: "no such file to read", error: CocoaError(.fileReadNoSuchFile)),
        MissingFileError(name: "no such file", error: CocoaError(.fileNoSuchFile)),
        MissingFileError(name: "ENOENT", error: POSIXError(.ENOENT)),
        MissingFileError(
            name: "ENOENT underneath",
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            ])
        ),
    ])
    func aFileThatIsNotThereIsNotAReadFailure(_ missing: MissingFileError) throws {
        let store = JSONFileStore(directory: directory, read: { _ in throw missing.error })
        let fallback: [Int] = [9]
        #expect(store.load("samples.json", default: fallback) == fallback)
        #expect((store.loadList("samples.json") as [Int]).isEmpty)

        // Nothing to protect: the first save creates the file.
        store.save([1], to: "samples.json")
        #expect(exists("samples.json"))
        #expect(!exists("samples.json.corrupt"))
    }

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func aFileWithoutReadPermissionIsNotMovedAsideOrReplaced() throws {
        let original = "[1,2,3]"
        try write(original, to: "samples.json")
        let path = url("samples.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        let store = JSONFileStore(directory: directory)

        let fallback: [Int] = [9]
        #expect(store.load("samples.json", default: fallback) == fallback)
        store.save([4, 5, 6], to: "samples.json")
        #expect(!exists("samples.json.corrupt"))
        #expect(exists("samples.json"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try Data(contentsOf: url("samples.json")) == Data(original.utf8), "the file kept its content")
        #expect(store.load("samples.json", default: fallback) == [1, 2, 3])
    }

    @Test func aDecodingFailureStillMovesTheFileAsideEvenAfterReadFailuresElsewhere() throws {
        try write("[1,2,3]", to: "unreadable.json")
        try write("{garbage", to: "damaged.json")
        let store = JSONFileStore(directory: directory, read: { url in
            if url.lastPathComponent == "unreadable.json" { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })

        #expect(store.load("unreadable.json", default: [Int]()).isEmpty)
        #expect(store.load("damaged.json", default: [Int]()).isEmpty)

        #expect(exists("unreadable.json") && !exists("unreadable.json.corrupt"))
        #expect(!exists("damaged.json") && exists("damaged.json.corrupt"))
    }
}
