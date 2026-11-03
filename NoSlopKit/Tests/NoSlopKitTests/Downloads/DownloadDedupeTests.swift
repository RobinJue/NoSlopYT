import Foundation
import Testing
@testable import NoSlopKit

// A quality is a request, not a file: "720p" of a video that stops at 144p is the 144p file, which "144p" gives too.
// These tests drive `DownloadManager` against the fake googlevideo of `DownloadManagerTests` (same harness, same zoo
// fixtures) and check that one set of streams is downloaded once, however it was asked for.

private let secondVideo = VideoSummary(
    id: "bbbbbbbbbbb", title: "Another zoo", channel: ChannelRef(id: "UC4QobU6STFB0P71PMvOGN5A", name: "jawed"), durationSeconds: 19
)

@MainActor
@Suite(.limitsMediaExports) struct DownloadDedupeTests {
    private let id720 = "jNQXAC9IVRw-720"
    private let id144 = "jNQXAC9IVRw-144"

    /// Waits until every item is settled and the resolver has been asked `calls` times, then a little longer, so a
    /// download that should not have happened has had the time to show itself.
    private func settle(_ harness: DownloadHarness, resolverCalls calls: Int) async -> Bool {
        let manager = harness.manager
        let done = await awaitDownloadCondition {
            harness.resolver.callCount >= calls && manager.items.allSatisfy { downloadIsSettled(manager, $0.id) }
        }
        try? await Task.sleep(for: .milliseconds(150))
        return done && manager.items.allSatisfy { downloadIsSettled(manager, $0.id) }
    }

    private func finishedFiles(_ harness: DownloadHarness) -> [String] {
        harness.rootListing().filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".m4a") }
    }

    // MARK: The reported case

    @Test func aVideoThatStopsAt144pIsDownloadedOnceWhetherAskedForAs720Then144() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        // What the context menu asks for, then what the quality sheet lists.
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        #expect(manager.items.first?.state == .completed)

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(manager.items.map(\.id) == [id144, id720], "listed at once, like any new download")
        #expect(await settle(harness, resolverCalls: 2))

        #expect(manager.items.map(\.id) == [id720], "the second request is dropped once its streams are known")
        let item = try #require(manager.items.first)
        #expect(item.state == .completed)
        #expect(manager.completedItem(videoID: ZooFixture.videoID)?.id == id720)
        #expect(harness.server.requests.count == 2, "one video chunk and one audio chunk, once: \(harness.server.requests)")
        #expect(finishedFiles(harness) == ["Me at the zoo [jNQXAC9IVRw].mp4"])
        #expect(manager.bytesOnDisk == item.bytesTotal)
        #expect(!harness.exists(harness.workDirectory(for: id144)), "the dropped item left no work directory behind")

        // The list on disk has one entry too.
        let reopened = DownloadHarness.newManager(root: harness.root, resolver: harness.resolver, tuning: .testing)
        #expect(reopened.items.map(\.id) == [id720])
    }

    @Test func theOrderOfTheTwoRequestsDoesNotMatter() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id144) })
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await settle(harness, resolverCalls: 2))

        #expect(manager.items.map(\.id) == [id144])
        #expect(manager.items.first?.state == .completed)
        #expect(harness.server.requests.count == 2)
        #expect(finishedFiles(harness).count == 1)
    }

    @Test func requestsThatResolveAtTheSameTimeDownloadOnce() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        // Neither has picked its streams when the other is asked for; exactly one of them must survive, not none and
        // not both.
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(manager.items.count == 2)
        #expect(await settle(harness, resolverCalls: 2))

        #expect(manager.items.count == 1, "left: \(manager.items.map(\.id))")
        #expect([id720, id144].contains(manager.items.first?.id ?? ""))
        #expect(manager.items.first?.state == .completed)
        #expect(harness.server.requests.count == 2, "one video chunk and one audio chunk, once")
        #expect(finishedFiles(harness).count == 1)
    }

    @Test func aRequestForTheStreamsOfADownloadThatIsStillRunningIsDropped() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 40_000
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        server.setDelay(0.5)
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: tuning)
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { manager.items.first?.state == .downloading })

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { manager.items.map(\.id) == [id720] && resolver.callCount == 2 })
        #expect(await settle(harness, resolverCalls: 2))

        #expect(manager.items.map(\.id) == [id720])
        #expect(manager.items.first?.state == .completed)
        #expect(server.requests.count == 5 + 3, "195278 bytes in 40000-byte chunks is 5, 117495 is 3: fetched once")
    }

    // MARK: What is not the same

    @Test func differentRenditionsOfOneVideoAreDifferentDownloads() async throws {
        let harness = try DownloadHarness.zooWithTwoRenditions()
        defer { harness.cleanUp() }
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))   // the 360p rendition
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))   // the 144p rendition
        #expect(await settle(harness, resolverCalls: 2))

        #expect(Set(manager.items.map(\.id)) == [id720, id144])
        #expect(manager.items.allSatisfy { $0.state == .completed })
        let names = manager.items.compactMap(\.relativeFilePath)
        #expect(names.count == 2 && Set(names).count == 2, "two renditions, two files: \(names)")
        #expect(harness.server.requestCount(path: "/video.mp4") == 1)
        #expect(harness.server.requestCount(path: "/video-360.mp4") == 1)
        #expect(harness.server.requestCount(path: "/audio.m4a") == 2, "the audio stream is fetched for each file")
    }

    @Test func qualitiesThatPickTheSameRenditionAreOneDownloadAmongOthers() async throws {
        let harness = try DownloadHarness.zooWithTwoRenditions()
        defer { harness.cleanUp() }
        let manager = harness.manager

        // 720 and 360 both land on the 360p rendition; 144 is the other one.
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 360))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await settle(harness, resolverCalls: 3))

        #expect(Set(manager.items.map(\.id)) == [id720, id144], "left: \(manager.items.map(\.id))")
        #expect(manager.items.allSatisfy { $0.state == .completed })
        #expect(harness.server.requestCount(path: "/video-360.mp4") == 1)
        #expect(harness.server.requestCount(path: "/video.mp4") == 1)
        #expect(finishedFiles(harness).count == 2)
    }

    @Test func audioOnlyIsNotTheSameAsAVideoWithTheSameAudio() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: ZooFixture.summary, quality: .audioOnly)
        #expect(await settle(harness, resolverCalls: 2))

        #expect(Set(manager.items.map(\.id)) == [id144, "jNQXAC9IVRw-audio"])
        #expect(manager.items.allSatisfy { $0.state == .completed })
        #expect(Set(finishedFiles(harness)).count == 2)
        #expect(finishedFiles(harness).contains { $0.hasSuffix(".m4a") } && finishedFiles(harness).contains { $0.hasSuffix(".mp4") })
    }

    @Test func theSameStreamsOfAnotherVideoAreNotADuplicate() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        // itags are the same on every video (160 is always 144p), so only the video id tells the downloads apart.
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: secondVideo, quality: .video(maxHeight: 144))
        #expect(await settle(harness, resolverCalls: 2))

        #expect(Set(manager.items.map(\.id)) == [id144, "bbbbbbbbbbb-144"])
        #expect(manager.items.allSatisfy { $0.state == .completed })
        #expect(Set(finishedFiles(harness)).count == 2)
        #expect(manager.completedItem(videoID: "bbbbbbbbbbb") != nil)
    }

    // MARK: Failed and gone

    @Test func aFailedDownloadDoesNotBlockTheSameStreamsUnderAnotherQuality() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        harness.server.fail("/audio.m4a", with: .status(500))

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        #expect(manager.items.first?.state == .failed)

        harness.server.clearFaults()
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await settle(harness, resolverCalls: 2))

        #expect(manager.items.map(\.id) == [id144, id720])
        #expect(manager.items.first?.state == .completed, "\(manager.items.first?.errorMessage ?? "")")
        #expect(manager.items.last?.state == .failed)
        #expect(manager.completedItem(videoID: ZooFixture.videoID)?.id == id144)
    }

    @Test func retryingAFailedItemWhoseStreamsAreDownloadedElsewhereRemovesIt() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        harness.server.fail("/audio.m4a", with: .status(500))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        #expect(manager.items.first?.state == .failed)

        harness.server.clearFaults()
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await settle(harness, resolverCalls: 2))
        #expect(manager.items.map(\.state) == [.completed, .failed])
        let requestsSoFar = harness.server.requests.count

        // The failed one is the same file as the one that worked: trying it again has nothing left to do.
        manager.retry(id: id720)
        #expect(await settle(harness, resolverCalls: 3))
        #expect(manager.items.map(\.id) == [id144])
        #expect(manager.items.first?.state == .completed)
        #expect(harness.server.requests.count == requestsSoFar, "nothing was fetched for the retry")
    }

    @Test func aFailedItemThatIsAskedForAgainStartsAgain() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        harness.server.fail("/audio.m4a", with: .status(500))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id144) })
        #expect(manager.items.first?.state == .failed)

        harness.server.clearFaults()
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(manager.items.count == 1)
        #expect(await settle(harness, resolverCalls: 2))
        #expect(manager.items.map(\.id) == [id144])
        #expect(manager.items.first?.state == .completed, "\(manager.items.first?.errorMessage ?? "")")
    }

    @Test func aFinishedItemWhoseFileIsGoneDoesNotBlockANewDownload() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        let first = try #require(manager.items.first)
        try FileManager.default.removeItem(at: try #require(manager.fileURL(for: first)))   // removed in the Files app

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await settle(harness, resolverCalls: 2))

        let again = try #require(manager.items.first { $0.id == id144 })
        #expect(again.state == .completed)
        #expect(harness.exists(try #require(manager.fileURL(for: again))), "the file the person asked for is there")
    }

    // MARK: After a relaunch

    @Test func aFinishedDownloadOfAnEarlierLaunchIsRecognised() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, id720) })
        #expect(harness.manager.items.first?.state == .completed)
        let requestsBefore = harness.server.requests.count

        // A new manager knows the finished item from downloads.json only, not which streams it fetched.
        let relaunched = DownloadHarness.newManager(root: harness.root, resolver: harness.resolver, tuning: .testing)
        #expect(relaunched.items.map(\.id) == [id720])
        relaunched.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { relaunched.items.map(\.id) == [id720] && harness.resolver.callCount == 2 })
        try await Task.sleep(for: .milliseconds(150))

        #expect(relaunched.items.map(\.id) == [id720])
        #expect(relaunched.items.first?.state == .completed)
        #expect(harness.server.requests.count == requestsBefore, "nothing was fetched again")
    }

    @Test func aPausedDownloadThatHasTheStreamsIsStartedAgainInsteadOfDownloadingTwice() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // What the last run left behind: a 720p download that was running when the app was killed.
        let interrupted = DownloadItem(
            id: id720, video: ZooFixture.summary, quality: .video(maxHeight: 720), state: .downloading,
            progress: 0.4, bytesDownloaded: 120_000, bytesTotal: 312_773
        )
        try JSONEncoder().encode([interrupted]).write(to: root.appendingPathComponent("downloads.json"))

        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: .testing)
        #expect(manager.items.first?.state == .paused)

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition {
            resolver.callCount >= 2 && manager.items.allSatisfy { downloadIsSettled(manager, $0.id) }
        })
        try await Task.sleep(for: .milliseconds(150))

        // The new request is not a second item; the paused one finished instead.
        #expect(manager.items.map(\.id) == [id720])
        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(server.requests.count == 2, "one video chunk and one audio chunk, once")
        #expect(resolver.callCount == 2)
    }

    // MARK: Asking again

    @Test func askingAgainForAFinishedDownloadDoesNothing() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id144) })
        let finished = try #require(manager.items.first)
        #expect(finished.state == .completed)

        for _ in 0..<3 {
            manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        }
        try await Task.sleep(for: .milliseconds(200))

        #expect(manager.items == [finished], "the same item, untouched")
        #expect(harness.resolver.callCount == 1, "YouTube is not even asked")
        #expect(harness.server.requests.count == 2)
    }

    @Test func askingAgainWhileADownloadRunsDoesNothing() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(manager.items.map(\.id) == [id144])
        #expect(await settle(harness, resolverCalls: 1))

        #expect(manager.items.map(\.id) == [id144])
        #expect(manager.items.first?.state == .completed)
        #expect(harness.resolver.callCount == 1)
        #expect(harness.server.requests.count == 2)
    }

    @Test func audioOnlyAskedForTwiceIsTheSameStreamAndDownloadsOnce() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .audioOnly)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, "jNQXAC9IVRw-audio") })
        manager.enqueue(video: ZooFixture.summary, quality: .audioOnly)
        try await Task.sleep(for: .milliseconds(150))

        #expect(manager.items.map(\.id) == ["jNQXAC9IVRw-audio"])
        #expect(manager.items.first?.state == .completed)
        #expect(harness.server.requestCount(path: "/audio.m4a") == 1)
        #expect(harness.server.requestCount(path: "/video.mp4") == 0)
    }
}
