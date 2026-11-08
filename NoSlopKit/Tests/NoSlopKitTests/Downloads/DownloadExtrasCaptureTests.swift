import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

// A download keeps the SponsorBlock segments, the chapters and the captions of its video, fetched when the download
// starts, so that it plays offline with auto-skip, chapter marks and captions. These tests drive `DownloadManager`
// against the fake googlevideo of `DownloadManagerTests`. The merge of the finished streams is replaced by a stub: nothing
// here is about the media, and exports are slow.

/// A provider that answers with a closure, and keeps what it was asked.
private final class StubExtras: DownloadExtrasProviding, Sendable {
    private let asked = Mutex<[StreamInfo]>([])
    private let answer: @Sendable (_ call: Int, _ info: StreamInfo) async -> DownloadExtras

    init(_ answer: @escaping @Sendable (_ call: Int, _ info: StreamInfo) async -> DownloadExtras) {
        self.answer = answer
    }

    var requests: [StreamInfo] { asked.withLock { $0 } }

    func extras(for info: StreamInfo) async -> DownloadExtras {
        let call = asked.withLock { asked -> Int in
            asked.append(info)
            return asked.count
        }
        return await answer(call, info)
    }
}

/// A number that a closure running anywhere records and the test reads.
private final class RecordedCount: Sendable {
    private let stored = Mutex<Int?>(nil)

    func record(_ count: Int) {
        stored.withLock { $0 = count }
    }

    var value: Int? { stored.withLock { $0 } }
}

/// The phone's connection, for sources that fail without it.
private final class Connection: Sendable {
    private let online = Mutex(true)

    func set(_ isOnline: Bool) {
        online.withLock { $0 = isOnline }
    }

    func require() throws {
        if !online.withLock({ $0 }) { throw NoSlopError.network("offline") }
    }
}

/// The running time a download borrows from the system, as the manager asked for it (`DownloadTuning.backgroundTime`):
/// what was begun, in order, and what is held right now.
private final class BorrowedTimeLog: Sendable {
    private struct State {
        var began: [String] = []
        var held: [String] = []
    }

    private let state = Mutex(State())

    var began: [String] { state.withLock { $0.began } }
    var held: [String] { state.withLock { $0.held } }

    fileprivate func begin(_ name: String) {
        state.withLock { state in
            state.began.append(name)
            state.held.append(name)
        }
    }

    fileprivate func end(_ name: String) {
        state.withLock { state in
            if let index = state.held.firstIndex(of: name) { state.held.remove(at: index) }
        }
    }

    /// What replaces `DownloadTuning.backgroundTime`.
    var source: BackgroundTimeSource {
        { [self] name in RecordedTime(name: name, log: self) }
    }
}

/// One stretch of borrowed time. Like the system's, it can be ended any number of times and counts once.
@MainActor
private final class RecordedTime: BackgroundTimeHolding {
    let expired = false
    private let name: String
    private let log: BorrowedTimeLog
    private var isHeld = true

    init(name: String, log: BorrowedTimeLog) {
        self.name = name
        self.log = log
        log.begin(name)
    }

    func end() {
        guard isHeld else { return }
        isHeld = false
        log.end(name)
    }
}

/// One download test's directory, fake server, resolver and managers over the same downloads folder.
@MainActor
private struct CaptureRig {
    let directory: DownloadTestDirectory
    let server: DownloadStubServer
    let resolver: DownloadStubResolver
    let root: URL

    /// The zoo video; `captions` are the tracks its stream info lists, and with `twoRenditions` it has a 360p next to the
    /// 144p (two qualities that are two downloads).
    static func zoo(captions: [CaptionTrack] = [], twoRenditions: Bool = false, lookupFails: Bool = false) throws -> CaptureRig {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        try ZooFixture.serveFixtures(on: server)
        if twoRenditions { server.serve("/video-360.mp4", data: try Fixture.data("zoo_video_144p.mp4")) }
        let resolver = DownloadStubResolver { _, _ in
            if lookupFails { throw NoSlopError.network("offline") }
            var info = twoRenditions
                ? ZooFixture.streamInfo(formats: [
                    ZooFixture.video(at: server.url("/video.mp4")),
                    ZooFixture.video360(at: server.url("/video-360.mp4")),
                    ZooFixture.audio(at: server.url("/audio.m4a")),
                ])
                : ZooFixture.streamInfo(server: server)
            info.captions = captions
            return info
        }
        return CaptureRig(
            directory: directory, server: server, resolver: resolver,
            root: directory.url.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    /// A manager over the downloads folder. Starting another one over the same folder is what a relaunch of the app is.
    func manager(
        extras: (any DownloadExtrasProviding)?,
        extrasTimeout: Duration = .seconds(8),
        borrowedTime: BorrowedTimeLog? = nil,
        mergeObserver: (@Sendable () -> Void)? = nil
    ) -> DownloadManager {
        var tuning = DownloadTuning.testing
        tuning.extrasMergeObserver = mergeObserver
        tuning.extrasTimeout = extrasTimeout
        tuning.mux = { _, _, _, output in try Data("muxed".utf8).write(to: output) }
        if let borrowedTime { tuning.backgroundTime = borrowedTime.source }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        return DownloadManager(rootDirectory: root, streams: resolver, sessionConfiguration: configuration, tuning: tuning, extras: extras)
    }

    var extrasFolder: URL { root.appendingPathComponent(".extras", isDirectory: true) }

    func sidecar(_ videoID: String = ZooFixture.videoID) -> URL {
        DownloadExtrasStore(root: root).fileURL(forVideoID: videoID)
    }

    func sidecarExists(_ videoID: String = ZooFixture.videoID) -> Bool {
        FileManager.default.fileExists(atPath: sidecar(videoID).path)
    }

    /// What the Files app lists: the root without its hidden entries.
    var visibleListing: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func cleanUp() {
        directory.remove()
    }
}

@MainActor
@Suite struct DownloadExtrasCaptureTests {
    private let quality144 = DownloadQuality.video(maxHeight: 144)

    private func complete(_ manager: DownloadManager, _ id: String = ZooFixture.itemID) async -> Bool {
        await awaitDownloadCondition { downloadIsSettled(manager, id) } && manager.items.first { $0.id == id }?.state == .completed
    }

    // MARK: Kept when the download starts

    @Test func aDownloadKeepsTheExtrasOfItsVideoOutOfTheFilesApp() async throws {
        let rig = try CaptureRig.zoo(captions: [ExtrasSample.english])
        defer { rig.cleanUp() }
        let provider = StubExtras { _, _ in ExtrasSample.all }
        let manager = rig.manager(extras: provider)

        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))

        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == ExtrasSample.all)
        #expect(rig.sidecarExists())
        #expect(rig.sidecar().deletingLastPathComponent().lastPathComponent == ".extras")
        #expect(rig.visibleListing == ["Me at the zoo [jNQXAC9IVRw].mp4", "downloads.json"], "the Files app lists the video and nothing of this")

        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.videoID == ZooFixture.videoID)
        #expect(provider.requests.first?.captions == [ExtrasSample.english], "asked with the stream info the download resolved")

        let list = try String(contentsOf: rig.root.appendingPathComponent("downloads.json"), encoding: .utf8)
        #expect(!list.contains("Introduction") && !list.contains("seg-sponsor"), "downloads.json is rewritten whole on every change: none of it goes in there")
    }

    @Test func theExtrasAreThereBeforeAnyChunkIsRequested() async throws {
        // The fetch comes first, so a download that finishes while the app is suspended or relaunched offline has them.
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let requestsWhenAsked = RecordedCount()
        let server = rig.server
        let provider = StubExtras { _, _ in
            requestsWhenAsked.record(server.requests.count)
            return ExtrasSample.all
        }
        let manager = rig.manager(extras: provider)
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))
        #expect(requestsWhenAsked.value == 0)
        #expect(!server.requests.isEmpty)
    }

    @Test func theExtrasSurviveARestartAndAnOfflineStartAndGoWithTheDownload() async throws {
        let rig = try CaptureRig.zoo(captions: [ExtrasSample.english])
        defer { rig.cleanUp() }
        let connection = Connection()
        let captions = ExtrasStubCaptions()
        captions.serve(ExtrasSample.english, ExtrasSample.englishCues)
        let fetcher = DownloadExtrasFetcher(
            segments: { _ in
                try connection.require()
                return [
                    SponsorSegment(id: "s1", category: .sponsor, start: 30, end: 45),
                    SponsorSegment(id: "s2", category: .selfpromo, start: 120, end: 130),
                ]
            },
            chapters: { _ in
                try connection.require()
                return ExtrasSample.chapters
            },
            captions: captions,
            preferredCaptionLanguage: { nil },
            deviceLanguage: "en",
            timeout: .seconds(30)
        )

        // Downloaded on Wi-Fi.
        do {
            let manager = rig.manager(extras: fetcher)
            manager.enqueue(video: ZooFixture.summary, quality: quality144)
            #expect(await complete(manager))
        }

        // Then the airplane: every source fails now, and the app is started again.
        connection.set(false)
        captions.fail(ExtrasSample.english)
        let relaunched = rig.manager(extras: fetcher)
        #expect(relaunched.completedItem(videoID: ZooFixture.videoID) != nil)

        let extras = try #require(await relaunched.extras(forVideoID: ZooFixture.videoID))
        #expect(extras.segments?.map(\.id) == ["s1", "s2"])
        #expect(extras.segments?.map(\.start) == [30, 120])
        #expect(extras.chapters?.count == 3)
        #expect(extras.chapters?.map(\.title) == ["Introduction", "The main part", "Wrap-up"])
        #expect(extras.captionTracks == [ExtrasSample.english])
        #expect(extras.cues(for: ExtrasSample.english) == ExtrasSample.englishCues)

        // Deleting the download takes the extras with it.
        relaunched.delete(id: ZooFixture.itemID)
        #expect(await relaunched.extras(forVideoID: ZooFixture.videoID) == nil, "the removal is done once the extras are asked for")
        #expect(!rig.sidecarExists())
    }

    @Test func aDownloadStartedWithSponsorBlockSwitchedOffNeverAsksItAndKeepsTheRest() async throws {
        let rig = try CaptureRig.zoo(captions: [ExtrasSample.english])
        defer { rig.cleanUp() }
        let captions = ExtrasStubCaptions()
        captions.serve(ExtrasSample.english, ExtrasSample.englishCues)
        let sponsorBlockRequests = DownloadTestCounter()
        let fetcher = DownloadExtrasFetcher(
            segments: { _ in
                sponsorBlockRequests.increment()
                return ExtrasSample.segments
            },
            chapters: { _ in ExtrasSample.chapters },
            captions: captions,
            preferredCaptionLanguage: { nil },
            sponsorBlockEnabled: { false },
            deviceLanguage: "en",
            timeout: .seconds(30)
        )
        let manager = rig.manager(extras: fetcher)

        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))

        #expect(sponsorBlockRequests.value == 0, "the viewer switched SponsorBlock off: nothing is sent to it")
        let extras = try #require(await manager.extras(forVideoID: ZooFixture.videoID))
        #expect(extras.segments == nil, "not known: the player asks live if the switch is turned on later")
        #expect(extras.chapters == ExtrasSample.chapters)
        #expect(extras.cues(for: ExtrasSample.english) == ExtrasSample.englishCues)
    }

    @Test func aDownloadWithoutAProviderKeepsNothing() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let manager = rig.manager(extras: nil)
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))
        #expect(!FileManager.default.fileExists(atPath: rig.extrasFolder.path))
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil)
    }

    @Test func aProviderWithNothingToKeepWritesNothing() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let manager = rig.manager(extras: StubExtras { _, _ in DownloadExtras() })
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))
        #expect(!FileManager.default.fileExists(atPath: rig.extrasFolder.path))
    }

    // MARK: Never a reason to fail or to wait

    @Test func aProviderThatNeverAnswersHoldsTheDownloadUpForTheTimeBoxAtMostAndKeepsNothing() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let gate = DownloadTestGate()
        defer { gate.release() }
        let provider = StubExtras { _, _ in
            await gate.opened()
            return ExtrasSample.all
        }
        let manager = rig.manager(extras: provider, extrasTimeout: .milliseconds(200))

        let clock = ContinuousClock()
        let started = clock.now
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager), "\(manager.items.first?.errorMessage ?? "")")
        let waited = clock.now - started

        #expect(waited >= .milliseconds(200), "it did wait for the time box: \(waited)")
        #expect(waited < .seconds(60), "and not for ever: \(waited)")
        #expect(provider.requests.count == 1)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil)
        #expect(!rig.sidecarExists())
    }

    @Test func extrasThatAreTooLateAreNotWrittenAfterTheDownloadMovedOn() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let gate = DownloadTestGate()
        let provider = StubExtras { _, _ in
            await gate.opened()
            return ExtrasSample.all
        }
        let manager = rig.manager(extras: provider, extrasTimeout: .milliseconds(100))
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))
        gate.release()
        // The answer comes after the time box ended: nobody is waiting for it any more.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!rig.sidecarExists())
    }

    // MARK: Borrowed background time

    // A download is started with a tap and then the phone is locked, or another app comes up. iOS suspends the app moments
    // later, and the chunk tasks only exist once the first start has got to the end of its lookups: until then nothing
    // downloads, whatever the background session would do. So that whole stretch, the wait for the extras included, runs on
    // time borrowed from the system.

    @Test func theTimeIsBorrowedWithTheTapAndCoversTheWaitForTheExtras() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let time = BorrowedTimeLog()
        let gate = DownloadTestGate()
        defer { gate.release() }
        let provider = StubExtras { _, _ in
            await gate.opened()
            return ExtrasSample.all
        }
        let manager = rig.manager(extras: provider, borrowedTime: time)

        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(time.held == ["No Slop start"], "held from the tap on, while the app still is in the foreground")

        // The extras are being waited for: nothing has been requested from the server yet, which is why this stretch is the
        // one that cannot be left to the background session.
        #expect(await awaitDownloadCondition { provider.requests.count == 1 })
        #expect(time.held == ["No Slop start"], "and still held while the extras are waited for")
        #expect(rig.server.requests.isEmpty, "no chunk task exists yet")

        gate.release()
        #expect(await complete(manager))
        #expect(await awaitDownloadCondition { time.held.isEmpty }, "everything given back: \(time.held)")
        #expect(time.began.first == "No Slop start")
    }

    @Test func theTimeIsGivenBackWhenTheLookupFails() async throws {
        let rig = try CaptureRig.zoo(lookupFails: true)
        defer { rig.cleanUp() }
        let time = BorrowedTimeLog()
        let manager = rig.manager(extras: StubExtras { _, _ in ExtrasSample.all }, borrowedTime: time)

        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(time.held == ["No Slop start"])
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .failed)
        #expect(await awaitDownloadCondition { time.held.isEmpty }, "\(time.held)")
        #expect(time.began == ["No Slop start"])
    }

    @Test func theTimeIsGivenBackWhenTheDownloadIsCancelledDuringTheWaitForTheExtras() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let time = BorrowedTimeLog()
        let gate = DownloadTestGate()
        defer { gate.release() }
        let provider = StubExtras { _, _ in
            await gate.opened()
            return ExtrasSample.all
        }
        let manager = rig.manager(extras: provider, borrowedTime: time)
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await awaitDownloadCondition { provider.requests.count == 1 })
        #expect(time.held == ["No Slop start"])

        manager.cancel(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { time.held.isEmpty }, "\(time.held)")
        #expect(time.began == ["No Slop start"])
        #expect(manager.items.isEmpty)
    }

    @Test func aRequestThatTurnsOutToBeTheSameDownloadGivesItsTimeBackToo() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let time = BorrowedTimeLog()
        let manager = rig.manager(extras: StubExtras { _, _ in ExtrasSample.all }, borrowedTime: time)
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 360))
        #expect(time.held == ["No Slop start", "No Slop start"], "each request borrows for its own start")

        #expect(await awaitDownloadCondition { manager.items.count == 1 && downloadIsSettled(manager, manager.items[0].id) })
        #expect(manager.items.first?.state == .completed)
        #expect(await awaitDownloadCondition { time.held.isEmpty }, "\(time.held)")
        #expect(time.began.filter { $0 == "No Slop start" }.count == 2)
    }

    @Test func aRestartWithFreshLinksBorrowsTimeOfItsOwnAndGivesEverythingBack() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        rig.server.fail("/video.mp4", with: .status(403), times: 1)
        let time = BorrowedTimeLog()
        let manager = rig.manager(extras: StubExtras { _, _ in ExtrasSample.all }, borrowedTime: time)

        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager), "\(manager.items.first?.errorMessage ?? "")")
        #expect(await awaitDownloadCondition { time.held.isEmpty }, "\(time.held)")
        #expect(time.began == ["No Slop start", "No Slop refresh links", "No Slop merge"])
    }

    // MARK: One file per video

    @Test func theQualitiesOfAVideoShareOneFileThatLaterAnswersAddTo() async throws {
        let rig = try CaptureRig.zoo(twoRenditions: true)
        defer { rig.cleanUp() }
        // Whichever download asks first gets the segments, the other one the chapters.
        let provider = StubExtras { call, _ in
            call == 1 ? DownloadExtras(segments: ExtrasSample.segments) : DownloadExtras(chapters: ExtrasSample.chapters)
        }
        let manager = rig.manager(extras: provider)
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 360))
        #expect(await awaitDownloadCondition { manager.items.count == 2 && manager.items.allSatisfy { $0.state == .completed || $0.state == .failed } })
        #expect(manager.items.allSatisfy { $0.state == .completed })

        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.extrasFolder.path)) ?? []) == ["jNQXAC9IVRw.json"])
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == DownloadExtras(segments: ExtrasSample.segments, chapters: ExtrasSample.chapters))

        // Still wanted by the other quality.
        manager.delete(id: "jNQXAC9IVRw-144")
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) != nil)
        #expect(rig.sidecarExists())
        // Not wanted by anyone any more.
        manager.delete(id: "jNQXAC9IVRw-360")
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil)
        #expect(!rig.sidecarExists())
    }

    @Test func aRequestThatTurnsOutToBeTheSameDownloadDoesNotAskAgain() async throws {
        // The plain zoo video stops at 144p, so "360p" is the same streams: one download, one question.
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let provider = StubExtras { _, _ in ExtrasSample.all }
        let manager = rig.manager(extras: provider)
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 360))
        #expect(await awaitDownloadCondition { manager.items.count == 1 && downloadIsSettled(manager, manager.items[0].id) })
        #expect(manager.items.first?.state == .completed)
        #expect(provider.requests.count == 1)
        #expect(rig.sidecarExists(), "the download that stayed owns it")
    }

    @Test func aRestartWithFreshLinksDoesNotAskForTheExtrasAgain() async throws {
        // The address of the video stops working (a phone that left its Wi-Fi): the download starts over once with fresh
        // addresses, from the chunks that are on disk. It asked for the extras at its first start; asking again would hold
        // the restart up for up to the time box, on borrowed background time.
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        rig.server.fail("/video.mp4", with: .status(403), times: 1)   // one dead address: the links are refreshed once
        let provider = StubExtras { _, _ in ExtrasSample.all }
        let manager = rig.manager(extras: provider)

        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager), "\(manager.items.first?.errorMessage ?? "")")

        #expect(rig.resolver.callCount == 2, "the links were refreshed (without this the test would pass for nothing)")
        #expect(provider.requests.count == 1, "and the restart did not ask for the extras again")
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == ExtrasSample.all)
    }

    @Test func cancellingADownloadThatHasNotFinishedRemovesItsExtras() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        rig.server.setDelay(60)   // the chunks never arrive in this test: the download stays in flight
        let manager = rig.manager(extras: StubExtras { _, _ in ExtrasSample.all })
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await awaitDownloadCondition { rig.sidecarExists() && manager.items.first?.state == .downloading })

        manager.cancel(id: ZooFixture.itemID)
        #expect(manager.items.isEmpty)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil, "the removal is done once the extras are asked for")
        #expect(!rig.sidecarExists())
    }

    // MARK: Keeping more later (what the player learns while a download plays online)

    @Test func theExtrasOfADownloadMadeBeforeTheyWereKeptCanBeAddedLater() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let manager = rig.manager(extras: nil)
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil, "made before: nothing kept")

        manager.saveExtras(DownloadExtras(segments: ExtrasSample.segments), forVideoID: ZooFixture.videoID)
        manager.saveExtras(DownloadExtras(chapters: ExtrasSample.chapters), forVideoID: ZooFixture.videoID)
        manager.saveExtras(DownloadExtras(), forVideoID: ZooFixture.videoID)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == DownloadExtras(segments: ExtrasSample.segments, chapters: ExtrasSample.chapters))

        // A later answer for the same part replaces it.
        manager.saveExtras(DownloadExtras(segments: []), forVideoID: ZooFixture.videoID)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == DownloadExtras(segments: [], chapters: ExtrasSample.chapters))
    }

    @Test func keepingMoreRunsOffTheMainThread() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let ranOnMain = Mutex<[Bool]>([])
        let manager = rig.manager(extras: nil, mergeObserver: { ranOnMain.withLock { $0.append(Thread.isMainThread) } })
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))

        manager.saveExtras(DownloadExtras(chapters: ExtrasSample.chapters), forVideoID: ZooFixture.videoID)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == DownloadExtras(chapters: ExtrasSample.chapters))
        #expect(ranOnMain.withLock { $0 } == [false])
    }

    @Test func manySavesInARowAreAllKept() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let manager = rig.manager(extras: nil)
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))

        var languages: [String] = []
        for index in 0..<30 {
            switch index % 3 {
            case 0: manager.saveExtras(DownloadExtras(segments: ExtrasSample.segments), forVideoID: ZooFixture.videoID)
            case 1: manager.saveExtras(DownloadExtras(chapters: ExtrasSample.chapters), forVideoID: ZooFixture.videoID)
            default:
                let language = "l\(index)"
                languages.append(language)
                let track = CaptionTrack(languageCode: language, name: language, baseURL: URL(string: "https://example.com/\(language)")!)
                manager.saveExtras(DownloadExtras(captions: [StoredCaptions(track: track, cues: ExtrasSample.englishCues)]), forVideoID: ZooFixture.videoID)
            }
        }
        let kept = try #require(await manager.extras(forVideoID: ZooFixture.videoID))
        #expect(kept.segments == ExtrasSample.segments)
        #expect(kept.chapters == ExtrasSample.chapters)
        #expect(Set(kept.captionTracks.map(\.languageCode)) == Set(languages), "no save was lost to another")
    }

    @Test func aSaveFollowedByTheRemovalLeavesNoFile() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let manager = rig.manager(extras: nil)
        manager.enqueue(video: ZooFixture.summary, quality: quality144)
        #expect(await complete(manager))

        manager.saveExtras(ExtrasSample.all, forVideoID: ZooFixture.videoID)
        manager.delete(id: ZooFixture.itemID)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil)
        #expect(!rig.sidecarExists())
    }

    @Test func nothingIsKeptForAVideoThatHasNoDownload() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        let manager = rig.manager(extras: nil)
        manager.saveExtras(ExtrasSample.all, forVideoID: "aqz-KE-bpKQ")
        #expect(await manager.extras(forVideoID: "aqz-KE-bpKQ") == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.extrasFolder.path))
    }

    // MARK: What is left on disk

    /// A finished download of the zoo video on disk, as an earlier run of the app left it.
    private func leaveFinishedDownload(in rig: CaptureRig) throws {
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        let fileName = "Me at the zoo [jNQXAC9IVRw].mp4"
        try Data("muxed".utf8).write(to: rig.root.appendingPathComponent(fileName))
        let item = DownloadItem(
            id: ZooFixture.itemID, video: ZooFixture.summary, quality: .video(maxHeight: 144), state: .completed,
            progress: 1, bytesDownloaded: 5, bytesTotal: 5, relativeFilePath: fileName
        )
        try JSONEncoder().encode([item]).write(to: rig.root.appendingPathComponent("downloads.json"))
    }

    @Test func downloadsFromBeforeLoadAndHaveNoExtras() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        try leaveFinishedDownload(in: rig)
        let manager = rig.manager(extras: nil)
        #expect(manager.completedItem(videoID: ZooFixture.videoID)?.id == ZooFixture.itemID)
        #expect(manager.fileURL(for: try #require(manager.completedItem(videoID: ZooFixture.videoID))) != nil)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.extrasFolder.path), "starting up creates nothing")
    }

    @Test func extrasOfAVideoWhoseDownloadIsGoneAreRemovedWhenTheAppStarts() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        try leaveFinishedDownload(in: rig)
        let store = DownloadExtrasStore(root: rig.root)
        store.merge(ExtrasSample.all, videoID: ZooFixture.videoID)
        store.merge(ExtrasSample.all, videoID: "removed-while-the-app-was-ending")

        let manager = rig.manager(extras: nil)
        #expect(await manager.extras(forVideoID: ZooFixture.videoID) == ExtrasSample.all)
        #expect(!rig.sidecarExists("removed-while-the-app-was-ending"))
    }

    @Test func aDownloadsListThatCouldNotBeReadLeavesTheExtrasAlone() async throws {
        let rig = try CaptureRig.zoo()
        defer { rig.cleanUp() }
        try leaveFinishedDownload(in: rig)
        DownloadExtrasStore(root: rig.root).merge(ExtrasSample.all, videoID: ZooFixture.videoID)
        // The list exists but the system will not hand it out (data protection before the first unlock): a directory in its
        // place reads like that. Nothing is known about what is downloaded, so nothing may be deleted as an orphan.
        let list = rig.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: list)
        try FileManager.default.createDirectory(at: list, withIntermediateDirectories: true)

        let manager = rig.manager(extras: nil)
        #expect(manager.items.isEmpty)
        #expect(rig.sidecarExists())
    }
}
