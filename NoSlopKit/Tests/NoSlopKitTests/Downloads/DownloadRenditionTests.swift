import Foundation
import Testing
@testable import NoSlopKit

// A quality is a request, not a file: "720p" of a video that stops at 144p is the 144p file. The item keeps what was
// asked for (`quality`, which names its id and decides what a retry picks) and records what it really fetched
// (`renditionHeight`), so the Downloads list says "144p" and the quality sheet finds the download in its 144p row.

@Suite struct DownloadItemRenditionModelTests {
    private let video = VideoSummary(id: "abc", title: "T")

    @Test func anItemWithoutARenditionIsLabelledWithWhatWasAskedFor() {
        let item = DownloadItem(id: "abc-720", video: video, quality: .video(maxHeight: 720))
        #expect(item.renditionHeight == nil)
        #expect(item.qualityLabel == "720p")
        #expect(item.effectiveQuality == .video(maxHeight: 720))

        let audio = DownloadItem(id: "abc-audio", video: video, quality: .audioOnly)
        #expect(audio.qualityLabel == "Audio only")
        #expect(audio.effectiveQuality == .audioOnly)
    }

    @Test func anItemWithARenditionIsLabelledWithTheRenditionItFetched() {
        let item = DownloadItem(id: "abc-720", video: video, quality: .video(maxHeight: 720), renditionHeight: 144)
        #expect(item.quality == .video(maxHeight: 720), "what was asked for is kept")
        #expect(item.qualityLabel == "144p")
        #expect(item.effectiveQuality == .video(maxHeight: 144))
        #expect(item.id == "abc-720", "the id does not change")
    }

    @Test func theRenditionSurvivesTheJSONOnDisk() throws {
        let item = DownloadItem(id: "abc-720", video: video, quality: .video(maxHeight: 720), state: .completed, renditionHeight: 480)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: data)
        #expect(decoded == item)
        #expect(decoded.renditionHeight == 480)
    }

    @Test func aListSavedBeforeTheRenditionWasRecordedStillLoads() throws {
        // What an older build wrote: no renditionHeight key.
        let quality = String(decoding: try JSONEncoder().encode(DownloadQuality.video(maxHeight: 720)), as: UTF8.self)
        let json = #"{"id":"abc-720","video":{"id":"abc","title":"T"},"quality":\#(quality),"state":"completed","progress":1,"bytesDownloaded":10,"bytesTotal":10,"relativeFilePath":"T [abc].mp4"}"#
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: Data(json.utf8))
        #expect(decoded.renditionHeight == nil)
        #expect(decoded.qualityLabel == "720p", "the label falls back to the request")
        #expect(decoded.effectiveQuality == .video(maxHeight: 720))
        #expect(decoded.state == .completed)
    }
}

@MainActor
@Suite(.limitsMediaExports) struct DownloadRenditionTests {
    private let id720 = "jNQXAC9IVRw-720"

    private func option(_ quality: DownloadQuality) -> DownloadOption {
        DownloadOption(quality: quality, label: quality.label)
    }

    // MARK: What the manager records

    @Test func aDownloadAskedFor720OfAVideoThatStopsAt144pIsThe144pDownload() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, id720) })

        let item = try #require(harness.manager.items.first)
        #expect(item.id == id720, "the id still says what was asked for")
        #expect(item.state == .completed)
        #expect(item.quality == .video(maxHeight: 720), "so does the quality: a retry picks within it")
        #expect(item.renditionHeight == 144)
        #expect(item.qualityLabel == "144p")
        #expect(item.effectiveQuality == .video(maxHeight: 144))

        // It is on disk like that.
        let reopened = DownloadHarness.newManager(root: harness.root, resolver: harness.resolver, tuning: .testing)
        #expect(reopened.items.first?.renditionHeight == 144)
        #expect(reopened.items.first?.qualityLabel == "144p")
    }

    @Test func audioOnlyHasNoRendition() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .audioOnly)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, "jNQXAC9IVRw-audio") })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed)
        #expect(item.renditionHeight == nil)
        #expect(item.qualityLabel == "Audio only")
    }

    @Test func aPausedDownloadOfAnOlderBuildLearnsItsRenditionFromItsPlan() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        // The plan on disk names the 144p stream; the item, saved by an older build, does not say so.
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])
        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })
        #expect(await awaitDownloadCondition { manager.items.first?.renditionHeight == 144 })
        #expect(manager.items.first?.qualityLabel == "144p")
    }

    @Test func theCollisionNameUsesTheRealHeight() async throws {
        // The 360p rendition is asked for as "up to 720p"; the 144p one as "up to 144p". Whichever finishes second gets
        // the quality in its file name, and that is the quality it is, not the one it was asked for.
        let harness = try DownloadHarness.zooWithTwoRenditions()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { harness.manager.items.allSatisfy { $0.state == .completed || $0.state == .failed } })

        let names = harness.manager.items.compactMap(\.relativeFilePath)
        #expect(harness.manager.items.allSatisfy { $0.state == .completed })
        #expect(Set(names).count == 2)
        #expect(!names.contains { $0.contains("720p") }, "no file is named for a quality it is not: \(names)")
        #expect(names.contains { $0.hasSuffix("(144p).mp4") || $0.hasSuffix("(360p).mp4") }, "\(names)")
    }

    // MARK: What the quality sheet finds

    @Test func theSheetFindsTheDownloadOfItsRowWhateverItWasAskedFor() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        // Before anything is downloaded, no row has a download.
        #expect(manager.item(for: option(.video(maxHeight: 144)), videoID: ZooFixture.videoID) == nil)

        // "Download up to 720p" from the context menu; the sheet then offers 144p, the only rendition there is.
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        let found = manager.item(for: option(.video(maxHeight: 144)), videoID: ZooFixture.videoID)
        #expect(found?.id == id720, "the 144p row shows the download as it is: downloaded")
        #expect(found?.state == .completed)

        // Other rows, other videos and other kinds do not match.
        #expect(manager.item(for: option(.video(maxHeight: 360)), videoID: ZooFixture.videoID) == nil)
        #expect(manager.item(for: option(.audioOnly), videoID: ZooFixture.videoID) == nil)
        #expect(manager.item(for: option(.video(maxHeight: 144)), videoID: "bbbbbbbbbbb") == nil)

        // Asking for 144p now is a request for what is already there: it is dropped once the streams are known.
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { manager.items.map(\.id) == [id720] && harness.resolver.callCount == 2 })
        #expect(manager.items.map(\.id) == [id720])
        #expect(manager.item(for: option(.video(maxHeight: 144)), videoID: ZooFixture.videoID)?.id == id720)
    }

    @Test func audioOnlyIsFoundByItsOwnRow() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .audioOnly)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, "jNQXAC9IVRw-audio") })
        #expect(harness.manager.item(for: option(.audioOnly), videoID: ZooFixture.videoID)?.id == "jNQXAC9IVRw-audio")
        #expect(harness.manager.item(for: option(.video(maxHeight: 144)), videoID: ZooFixture.videoID) == nil)
    }

    @Test func aDownloadThatIsNotFailedWinsOverOneThatIs() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager
        // 720 fails (its audio is refused); 144 then succeeds. Both name the 144p rendition by now.
        harness.server.fail("/audio.m4a", with: .status(500))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, id720) })
        #expect(manager.items.first?.state == .failed)
        harness.server.clearFaults()
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, "jNQXAC9IVRw-144") && harness.resolver.callCount == 2 })
        #expect(manager.items.map(\.state) == [.completed, .failed])

        let found = manager.item(for: option(.video(maxHeight: 144)), videoID: ZooFixture.videoID)
        #expect(found?.state == .completed, "the row shows the download that works, not the one that failed")
        #expect(found?.id == "jNQXAC9IVRw-144")
    }
}
