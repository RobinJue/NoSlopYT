import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

// A download that fails keeps what it fetched, and a stream address that stops working is replaced once without
// anyone having to tap Retry. These tests drive `DownloadManager` against the fake googlevideo of `DownloadManagerTests`.

@MainActor
@Suite(.limitsMediaExports) struct DownloadRecoveryTests {
    private static var chunked: DownloadTuning {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        return tuning
    }

    /// The video's second chunk: the only one a download restored by `leaveInterruptedDownload` still has to fetch.
    private static let lastVideoChunk = DownloadStubServer.LoggedRequest(path: "/video.mp4", range: 100_000...195_277)

    private func exists(_ name: String, in work: URL) -> Bool {
        FileManager.default.fileExists(atPath: work.appendingPathComponent(name).path)
    }

    // MARK: A failed chunk keeps the parts that were fetched

    @Test(arguments: [404, 429, 500, 503])
    func partsOfAFailedChunkDownloadAreKeptForTheRetry(status: Int) async throws {
        var tuning = Self.chunked
        tuning.retryDelay = .seconds(60)   // the failing video chunks wait for their retry: the job stays open
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        // A server that is busy or does not have it: asking the same address again is all there is to do.
        harness.server.fail("/video.mp4", with: .status(status))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        let work = harness.workDirectory(for: ZooFixture.itemID)
        #expect(await awaitDownloadCondition {
            harness.manager.items.first?.state == .downloading && exists("audio.0.part", in: work) && exists("audio.1.part", in: work)
        })

        // The chunk has failed once already, with the server's answer; two more failures use up its retries. (More are
        // sent than needed: the ones that come after the item has failed are ignored.)
        let video = DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .video, chunkIndex: 0)
        for _ in 0..<3 { harness.manager.handle(.chunkFailed(video, .http(status: status), inFlightBytes: 0)) }

        let failed = try #require(harness.manager.items.first)
        #expect(failed.state == .failed)
        #expect(failed.errorMessage == DownloadFailure.http(status: status).errorDescription)
        #expect(exists("job.json", in: work), "the plan stays")
        #expect(exists("audio.0.part", in: work) && exists("audio.1.part", in: work), "so do the parts")
        #expect(harness.resolver.callCount == 1, "\(status) is not a dead address: YouTube is not asked for a new one")

        // The server is fine again: the retry asks YouTube for fresh addresses and fetches only what is missing.
        harness.server.clearFaults()
        let before = harness.server.requests.count
        harness.manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(harness.resolver.callCount == 2)
        let fetched = harness.server.requests.dropFirst(before)
        #expect(fetched.allSatisfy { $0.path == "/video.mp4" }, "the audio was not downloaded again: \(Array(fetched))")
        #expect(Set(fetched.compactMap(\.range)) == [0...99_999, 100_000...195_277])
    }

    // MARK: An address that stopped working is replaced once

    /// Everything but the video's second chunk is on disk and paused, as after an interruption.
    private func interruptedDownload(
        in directory: DownloadTestDirectory,
        server: DownloadStubServer,
        resolver: DownloadStubResolver
    ) throws -> (manager: DownloadManager, work: URL) {
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try DownloadHarness.leaveInterruptedDownload(
            in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1]
        )
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: Self.chunked)
        return (manager, DownloadWorkspace(root: root).directory(for: ZooFixture.itemID))
    }

    @Test(arguments: [403, 410])
    func anAddressThatStoppedWorkingIsAskedForAgainAndTheDownloadCarriesOn(status: Int) async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        server.fail("/video.mp4", rangeStart: 100_000, with: .status(status), times: 1)
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let (manager, _) = try interruptedDownload(in: directory, server: server, resolver: resolver)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(resolver.callCount == 2, "the retry's own lookup, then one more when the address turned out to be dead")
        #expect(server.requests == [Self.lastVideoChunk, Self.lastVideoChunk], "refused once, then fetched with the new address; nothing else")
        let media = try await mediaDurationAndTracks(of: try #require(manager.fileURL(for: item)))
        #expect(abs(media.seconds - 18.93) < 0.05)
    }

    @Test func aSecondDeadAddressFailsTheItemAndKeepsTheParts() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        server.fail("/video.mp4", rangeStart: 100_000, with: .status(403))
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let (manager, work) = try interruptedDownload(in: directory, server: server, resolver: resolver)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "YouTube refused the download (HTTP 403). Retry to get a fresh link.")
        #expect(resolver.callCount == 2, "one automatic look-up, not a loop of them")
        // The request that found the address dead, the one with the new address, and its two retries.
        #expect(server.requests == Array(repeating: Self.lastVideoChunk, count: 4))
        #expect(["job.json", "audio.0.part", "audio.1.part", "video.0.part"].allSatisfy { exists($0, in: work) }, "the parts stay")

        // A retry by hand gets an automatic look-up of its own again.
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .failed)
        #expect(resolver.callCount == 4, "the retry's lookup and one more for the dead address")

        // Once the address works, the retry fetches the one chunk that is missing, and no more.
        server.clearFaults()
        let before = server.requests.count
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .completed, "\(manager.items.first?.errorMessage ?? "")")
        #expect(Array(server.requests.dropFirst(before)) == [Self.lastVideoChunk])
    }

    @Test func aNewAddressThatCannotBeFetchedFailsTheItemButKeepsTheParts() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        server.fail("/video.mp4", rangeStart: 100_000, with: .status(403))
        // The phone is offline by the time the second lookup is made.
        let resolver = DownloadStubResolver { _, call in
            if call >= 2 { throw NoSlopError.network("offline") }
            return ZooFixture.streamInfo(server: server)
        }
        let (manager, work) = try interruptedDownload(in: directory, server: server, resolver: resolver)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "Can't reach YouTube. Check your connection.")
        #expect(["job.json", "audio.0.part", "audio.1.part", "video.0.part"].allSatisfy { exists($0, in: work) }, "the parts stay")
    }

    // MARK: A lookup that fails keeps the parts, unless YouTube ruled on the video

    nonisolated private static let lookupFailures: [NoSlopError] = [
        .decoding("Invalid JSON"),
        .notPlayableYet(reason: "No playable streams were returned for this video."),
        .http(status: 400),
        .http(status: 403),
        .network("offline"),
    ]

    @Test(arguments: lookupFailures)
    func aRetryWhoseLookupFailsWithoutAVerdictKeepsTheParts(error: NoSlopError) async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let failing = Mutex(true)
        let resolver = DownloadStubResolver { _, _ in
            let stillFailing = failing.withLock { $0 }
            if stillFailing { throw error }
            return ZooFixture.streamInfo(server: server)
        }
        let (manager, work) = try interruptedDownload(in: directory, server: server, resolver: resolver)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == error.errorDescription)
        #expect(["job.json", "audio.0.part", "audio.1.part", "video.0.part"].allSatisfy { exists($0, in: work) }, "the parts stay")

        // The way is clear again: the retry fetches only what is missing.
        failing.withLock { $0 = false }
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .completed, "\(manager.items.first?.errorMessage ?? "")")
        #expect(server.requests == [Self.lastVideoChunk])
    }

    @Test func aVerdictOfYouTubeStillDiscardsTheParts() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let resolver = DownloadStubResolver { _, _ in throw NoSlopError.unplayable(reason: "This video is private.") }
        let (manager, work) = try interruptedDownload(in: directory, server: server, resolver: resolver)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        #expect(manager.items.first?.state == .failed)
        #expect(["job.json", "audio.0.part", "audio.1.part", "video.0.part"].allSatisfy { !exists($0, in: work) }, "nothing is left to resume")
    }

    @Test func aNewAddressThatAnswersWithAnHTTPErrorKeepsTheParts() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        server.fail("/video.mp4", rangeStart: 100_000, with: .status(403))
        let resolver = DownloadStubResolver { _, call in
            if call >= 2 { throw NoSlopError.http(status: 400) }
            return ZooFixture.streamInfo(server: server)
        }
        let (manager, work) = try interruptedDownload(in: directory, server: server, resolver: resolver)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        #expect(manager.items.first?.state == .failed)
        #expect(["job.json", "audio.0.part", "audio.1.part", "video.0.part"].allSatisfy { exists($0, in: work) }, "the parts stay")
    }

    // MARK: A plan that cannot be written keeps the parts

    @Test func aPlanThatCannotBeWrittenOnAFullDeviceKeepsTheParts() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let full = Mutex(true)
        var tuning = Self.chunked
        tuning.savePlan = { workspace, plan in
            let isFull = full.withLock { $0 }
            if isFull { throw CocoaError(.fileWriteOutOfSpace) }
            try workspace.savePlan(plan)
        }
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try DownloadHarness.leaveInterruptedDownload(
            in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1]
        )
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: tuning)
        let work = DownloadWorkspace(root: root).directory(for: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "There isn't enough free space on this device.")
        #expect(["job.json", "audio.0.part", "audio.1.part", "video.0.part"].allSatisfy { exists($0, in: work) }, "the parts stay")

        full.withLock { $0 = false }
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .completed, "\(manager.items.first?.errorMessage ?? "")")
        #expect(server.requests == [Self.lastVideoChunk])
    }
}
