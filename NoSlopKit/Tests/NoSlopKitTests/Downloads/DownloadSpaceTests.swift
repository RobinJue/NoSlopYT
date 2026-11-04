import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

// A download that cannot fit is refused before anything is fetched, with the numbers, instead of filling the device and
// failing at the very end. It needs its own size to fetch and, at the end, room for the second copy the merge writes.

@Suite struct DownloadSpaceNeedTests {
    private let size: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }

    @Test func aDownloadNeedsItsSizeAndTheCopyTheMergeWritesPlusAMargin() {
        let margin = DownloadSpace.margin
        #expect(margin == 64 * 1_048_576)
        // Nothing on disk yet: twice the streams.
        #expect(DownloadSpace.needed(totalBytes: 312_773, presentBytes: 0) == 2 * 312_773 + margin)
        // Part of it is on disk already (and paid for): only the rest, and the copy.
        #expect(DownloadSpace.needed(totalBytes: 312_773, presentBytes: 217_495) == 2 * 312_773 - 217_495 + margin)
        // Everything is on disk, only the merge is left: one more copy.
        #expect(DownloadSpace.needed(totalBytes: 312_773, presentBytes: 312_773) == 312_773 + margin)
        // A 3 GB video.
        #expect(DownloadSpace.needed(totalBytes: 3_000_000_000, presentBytes: 0) == 6_000_000_000 + margin)
        // Never less than the margin, whatever the numbers.
        #expect(DownloadSpace.needed(totalBytes: 0, presentBytes: 0) == margin)
        #expect(DownloadSpace.needed(totalBytes: 100, presentBytes: 5_000) == margin)
    }

    @Test func theMessageSaysHowMuchIsNeededAndHowMuchIsFree() {
        let failure = DownloadFailure.notEnoughSpace(needed: 6_442_450_944, free: 2_147_483_648)
        #expect(failure.errorDescription == "There isn't enough free space: this needs about \(size(6_442_450_944)) to finish, \(size(2_147_483_648)) is free.")
        // The plain full-disk message is unchanged.
        #expect(DownloadFailure.outOfSpace.errorDescription == "There isn't enough free space on this device.")
    }

    @Test func bothFiguresComeEarlyInTheMessage() throws {
        // The message is shown in a caption beside the thumbnail and the Retry button, a column that holds twenty-odd
        // characters per line. The rows show it in full, but a column this narrow wraps it to many lines, so the figures
        // stay near the front: they are what the person needs, and the last thing that should ever be cut off.
        let cases: [(needed: Int64, free: Int64)] = [
            (6_442_450_944, 2_147_483_648),         // 6.44 GB needed, 2.15 GB free
            (67_108_864 + 100, 1_000),              // just the margin and a little more, next to nothing free
            (275_000_000_000, 100_000_000_000),     // the widest figures: about the most a download can need (two 64 GiB streams, plus the merge's copy)
        ]
        for (needed, free) in cases {
            let message = try #require(DownloadFailure.notEnoughSpace(needed: needed, free: free).errorDescription)
            let start = message.prefix(80)
            #expect(start.contains(size(needed)), "the figure for what is needed is early in \"\(message)\"")
            #expect(start.contains(size(free)), "the figure for what is free is early in \"\(message)\"")
        }
    }

    @Test func aDownloadThatDoesNotFitKeepsWhatIsOnDisk() {
        #expect(DownloadFailure.notEnoughSpace(needed: 10, free: 5).keepsDownloadedData)
        #expect(!DownloadFailure.notEnoughSpace(needed: 10, free: 5).isDeadLink)
    }

    @Test func theSystemSaysHowMuchRoomThereIsOnTheVolume() {
        let free = DownloadAssembler.availableCapacity(at: FileManager.default.temporaryDirectory)
        #expect((free ?? 0) > 0)
        // A place that is not there has no answer, and no answer lets the download go ahead.
        #expect(DownloadAssembler.availableCapacity(at: URL(fileURLWithPath: "/no/such/folder/\(UUID().uuidString)")) == nil)
    }
}

/// A free-space reading a test can change while a manager runs.
private final class DownloadTestCapacity: Sendable {
    private let free: Mutex<Int64?>

    init(_ free: Int64?) {
        self.free = Mutex(free)
    }

    func set(_ value: Int64?) { free.withLock { $0 = value } }
    var value: Int64? { free.withLock { $0 } }
}

@MainActor
@Suite(.limitsMediaExports) struct DownloadSpaceTests {
    /// Both zoo streams: the 195_278-byte video and the 117_495-byte audio.
    private static let total = ZooFixture.videoBytes + ZooFixture.audioBytes
    private static let needed = DownloadSpace.needed(totalBytes: total, presentBytes: 0)

    private func partFiles(in work: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasSuffix(".part") }
    }

    private func tuning(capacity: DownloadTestCapacity) -> DownloadTuning {
        var tuning = DownloadTuning.testing
        tuning.availableCapacity = { _ in capacity.value }
        return tuning
    }

    // MARK: Refused

    @Test func aDownloadThatCannotFitIsRefusedBeforeAnythingIsFetched() async throws {
        let harness = try DownloadHarness.zoo(tuning: tuning(capacity: DownloadTestCapacity(1_000)))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })

        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == DownloadFailure.notEnoughSpace(needed: Self.needed, free: 1_000).errorDescription)
        #expect(item.errorMessage?.contains(ByteCountFormatter.string(fromByteCount: 1_000, countStyle: .file)) == true, "it says how much is free")
        #expect(harness.server.requests.isEmpty, "nothing was requested from YouTube's servers")
        #expect(partFiles(in: harness.workDirectory(for: ZooFixture.itemID)).isEmpty)
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".m4a") }.isEmpty)
        #expect(harness.resolver.callCount == 1)
    }

    @Test func oneByteLessThanItNeedsIsRefusedAndExactlyEnoughIsAccepted() async throws {
        let capacity = DownloadTestCapacity(Self.needed - 1)
        let harness = try DownloadHarness.zoo(tuning: tuning(capacity: capacity))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)
        #expect(harness.server.requests.isEmpty)

        capacity.set(Self.needed)
        harness.manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(harness.exists(try #require(harness.manager.fileURL(for: item))))
    }

    @Test func aDownloadWithPlentyOfRoomJustRuns() async throws {
        let harness = try DownloadHarness.zoo(tuning: tuning(capacity: DownloadTestCapacity(Int64.max)))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed)
    }

    @Test func aVolumeThatDoesNotSayHowMuchRoomThereIsDoesNotStopTheDownload() async throws {
        let harness = try DownloadHarness.zoo(tuning: tuning(capacity: DownloadTestCapacity(nil)))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed)
    }

    // MARK: A retry is not asked for what it already holds

    @Test func aRetryIsOnlyAskedForRoomForWhatIsStillMissing() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        // 217_495 of the 312_773 bytes are on disk: all of the audio and the video's first chunk.
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])
        let present: Int64 = 217_495
        let neededForTheRest = DownloadSpace.needed(totalBytes: Self.total, presentBytes: present)
        #expect(neededForTheRest == 2 * Self.total - present + DownloadSpace.margin)
        #expect(neededForTheRest < Self.needed, "less than a download from scratch")

        let capacity = DownloadTestCapacity(neededForTheRest - 1)
        var tuning = tuning(capacity: capacity)
        tuning.chunkSize = 100_000
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: tuning)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })
        let work = DownloadWorkspace(root: root).directory(for: ZooFixture.itemID)

        // One byte short: refused, and what is on disk stays.
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .failed)
        #expect(manager.items.first?.errorMessage == DownloadFailure.notEnoughSpace(needed: neededForTheRest, free: neededForTheRest - 1).errorDescription)
        #expect(server.requests.isEmpty)
        #expect(partFiles(in: work).sorted() == ["audio.0.part", "audio.1.part", "video.0.part"])

        // Exactly enough for the rest (far less than a download from scratch): accepted, and only the rest is fetched.
        capacity.set(neededForTheRest)
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .completed, "\(manager.items.first?.errorMessage ?? "")")
        #expect(server.requests == [DownloadStubServer.LoggedRequest(path: "/video.mp4", range: 100_000...195_277)])
    }

    @Test func aRetryThatOnlyHasToMergeNeedsRoomForOneMoreCopy() async throws {
        let capacity = DownloadTestCapacity(Int64.max)
        let merges = DownloadTestCounter()
        var tuning = tuning(capacity: capacity)
        tuning.mux = { video, audio, duration, output in
            merges.increment()
            // The first merge is cut short by the system, which keeps the downloaded streams.
            if merges.value == 1 { throw DownloadFailure.mergeInterrupted }
            try await MediaMuxer.mux(videoFile: video, audioFile: audio, durationSeconds: duration, output: output)
        }
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)
        let work = harness.workDirectory(for: ZooFixture.itemID)
        let requestsBefore = harness.server.requests.count

        // Everything is on disk, only the merge is left: it writes one more copy.
        let mergeOnly = DownloadSpace.needed(totalBytes: Self.total, presentBytes: Self.total)
        #expect(mergeOnly == Self.total + DownloadSpace.margin)
        capacity.set(mergeOnly - 1)
        harness.manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)
        #expect(harness.manager.items.first?.errorMessage == DownloadFailure.notEnoughSpace(needed: mergeOnly, free: mergeOnly - 1).errorDescription)
        #expect(merges.value == 1, "the merge was not even tried")
        #expect(harness.exists(work.appendingPathComponent("video.mp4")) && harness.exists(work.appendingPathComponent("audio.m4a")), "the streams stay")

        capacity.set(mergeOnly)
        harness.manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed, "\(harness.manager.items.first?.errorMessage ?? "")")
        #expect(merges.value == 2)
        #expect(harness.server.requests.count == requestsBefore, "nothing was fetched again")
    }
}
