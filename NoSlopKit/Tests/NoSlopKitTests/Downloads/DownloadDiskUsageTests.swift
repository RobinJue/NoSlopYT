import Foundation
import Testing
@testable import NoSlopKit

// "Space used" has to be the space the downloads really take: the finished files, and also what downloads that are not
// finished have fetched (running, paused, or failed with their parts kept on purpose). `bytesOnDisk` only knows the
// finished ones, so a failed download that holds a gigabyte of parts used to show as zero.

@MainActor
@Suite(.limitsMediaExports) struct DownloadDiskUsageTests {
    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    @Test func nothingDownloadedTakesNoSpace() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        #expect(await harness.manager.diskUsage() == 0)
    }

    @Test func aFinishedDownloadTakesTheSizeOfItsFile() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed)

        // The work directory of the finished item is on its way to the trash, which is not counted; downloads.json is
        // the list, not a download.
        let usage = await harness.manager.diskUsage()
        #expect(usage == (item.bytesTotal ?? -1))
        #expect(usage == harness.manager.bytesOnDisk)
        #expect(usage == (try fileSize(try #require(harness.manager.fileURL(for: item)))))
    }

    @Test func partsOfUnfinishedDownloadsAreCounted() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        // All of the audio (117_495 bytes) and the first 100_000 bytes of the video are on disk; the item is paused.
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])
        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        let work = DownloadWorkspace(root: root).directory(for: ZooFixture.itemID)
        let planSize = try fileSize(work.appendingPathComponent("job.json"))
        #expect(manager.bytesOnDisk == 0, "no download is finished")
        #expect(await manager.diskUsage() == 217_495 + planSize)
    }

    @Test func theTrashTheListAndTheSavedCopyOfADamagedListAreNotDownloads() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)

        // A finished file in the folder, and things around it that are not downloads.
        try Data(count: 3_000).write(to: root.appendingPathComponent("Some video [aaaaaaaaaaa].mp4"))
        try Data(count: 50_000).write(to: root.appendingPathComponent("downloads.json"))
        try Data(count: 50_000).write(to: root.appendingPathComponent("downloads.json.corrupt"))
        let trash = root.appendingPathComponent(".work/.trash/leftover", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: trash.appendingPathComponent("video.0.part"))
        // A work directory is counted, all the way down.
        let work = root.appendingPathComponent(".work/bbbbbbbbbbb-720", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data(count: 2_000).write(to: work.appendingPathComponent("video.0.part"))
        try Data(count: 500).write(to: work.appendingPathComponent("job.json"))

        #expect(await manager.diskUsage() == 3_000 + 2_000 + 500)
    }

    @Test func aFileThatIsNotThereAnyMoreIsNotAProblem() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        try Data(count: 4_000).write(to: root.appendingPathComponent("A [aaaaaaaaaaa].mp4"))
        // A link whose target went away (what a file deleted from outside the app, mid-walk, looks like).
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("gone.mp4"), withDestinationURL: root.appendingPathComponent("does-not-exist.mp4")
        )
        #expect(await manager.diskUsage() == 4_000)
    }
}
