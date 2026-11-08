import Foundation
import Testing
@testable import NoSlopKit

/// Every value here is made up (names start with tvsynthetic_).
private final class FakeTokens: TVTokenProviding, @unchecked Sendable {
    func accessToken() async throws -> String { "tvsynthetic_token" }
    func refreshAfterUnauthorized() async throws -> String { "tvsynthetic_token" }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

private struct Rig {
    let http = MockHTTPClient()
    let queue: PendingWatchReports
    let reporter: TVWatchReporter
    let clock = Clock()
    let enabled = Switch()

    init(file: String = UUID().uuidString) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tvsynthetic-\(file).json")
        try? FileManager.default.removeItem(at: url)
        let clock = self.clock
        let queue = PendingWatchReports(fileURL: url, now: { clock.now })
        let enabled = self.enabled
        self.queue = queue
        self.reporter = TVWatchReporter(
            client: TVClient(http: http, tokens: FakeTokens()), http: http, queue: queue,
            isEnabled: { enabled.value }, now: { clock.now }
        )
    }

    var homepage: [URLRequest] { http.requests.filter { $0.url?.absoluteString == "https://www.youtube.com/" } }
    var players: [URLRequest] { http.requests.filter { $0.url?.path == "/youtubei/v1/player" } }
    var pings: [URLRequest] { http.requests.filter { $0.url?.path.hasPrefix("/api/stats/") == true } }
}

private func homepageBody(sts: Int = 20758) -> Data { Data(#"{"STS":\#(sts)}"#.utf8) }

private func query(_ request: URLRequest) -> [String: String] {
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
    return Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private func viewing(_ id: String = "tvsyntheticV1", length: Double = 60) -> WatchViewing {
    WatchViewing(id: UUID(), videoID: id, lengthSeconds: length)
}

private func prepare(_ rig: Rig, player: Data? = nil) throws {
    // The home page entry goes last: its match is a prefix of every other URL, and the first matching entry answers.
    rig.http.enqueue("youtubei/v1/player", body: try player ?? Fixture.data("tvsynthetic_player_signed.json"))
    rig.http.enqueue("api/stats/", body: Data())
    rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
}

@Suite struct TVWatchReporterTests {
    @Test func aQualifiedViewingMintsOnceAndPingsInOrder() async throws {
        let rig = Rig()
        try prepare(rig)
        await rig.reporter.record(.qualified(position: 31), for: viewing())

        let urls = rig.http.requests.map { $0.url!.absoluteString }
        #expect(urls.count == 4)
        #expect(urls[0] == "https://www.youtube.com/")
        #expect(urls[1] == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(urls[2].hasPrefix("https://www.youtube.com/api/stats/playback?"))
        #expect(urls[3].hasPrefix("https://www.youtube.com/api/stats/watchtime?"))

        let body = try #require(rig.http.bodyJSON(of: rig.http.requests[1]))
        #expect(body["videoId"]?.string == "tvsyntheticV1")
        #expect(body["racyCheckOk"]?.bool == true)
        #expect(body["contentCheckOk"]?.bool == true)
        #expect(body["playbackContext"]?["contentPlaybackContext"]?["html5Preference"]?.string == "HTML5_PREF_WANTS")
        #expect(body["playbackContext"]?["contentPlaybackContext"]?["signatureTimestamp"]?.int == 20758)
        #expect(body["context"]?["client"]?["clientVersion"]?.string == TVClientConfig.legacyClientVersion)
        #expect(rig.http.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_token")
        #expect(rig.http.requests[0].value(forHTTPHeaderField: "Authorization") == nil)

        let playback = query(rig.http.requests[2])
        let watchtime = query(rig.http.requests[3])
        #expect(playback["cmt"] == "0.000")
        #expect(playback["st"] == nil)
        #expect(playback["docid"] == "tvsyntheticV1")
        #expect(playback["len"] == "60.000")
        #expect(playback["ei"] == "tvsynthetic_ei")
        #expect(watchtime["st"] == "0.000")
        #expect(watchtime["et"] == "31.000")
        #expect(watchtime["cmt"] == "31.000")
        #expect(watchtime["final"] == nil)
        #expect(playback["cpn"] == watchtime["cpn"])
        #expect(playback["cpn"]?.count == 16)
        for ping in [rig.http.requests[2], rig.http.requests[3]] {
            #expect(ping.value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_token")
            #expect(ping.value(forHTTPHeaderField: "User-Agent") == TVClientConfig.legacyUserAgent)
            #expect(ping.value(forHTTPHeaderField: "Referer") == TVClientConfig.referer)
        }
        #expect(rig.queue.all().isEmpty)
        let outcome = await rig.reporter.outcome()
        #expect(outcome?.status == "reported")
        #expect(outcome?.pingStatuses == [200, 200])
        #expect(outcome?.hasEI == true)
    }

    @Test func theStsIsCachedForAnHour() async throws {
        let rig = Rig()
        try prepare(rig)
        await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticA"))
        rig.clock.advance(3000)
        await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticB"))
        #expect(rig.homepage.count == 1)
        #expect(rig.players.count == 2)
        rig.clock.advance(700)
        await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticC"))
        #expect(rig.homepage.count == 2)
    }

    @Test func aRefusalSendsNoPingsAndCountsTowardsThePause() async throws {
        let rig = Rig()
        try prepare(rig, player: Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}"#.utf8))
        for _ in 0..<2 {
            await rig.reporter.record(.qualified(position: 31), for: viewing())
            #expect(await rig.reporter.isPaused() == false)
        }
        await rig.reporter.record(.qualified(position: 31), for: viewing())
        #expect(rig.pings.isEmpty)
        #expect(await rig.reporter.isPaused())
        #expect(await rig.reporter.outcome()?.status == "refused")
        #expect(await rig.reporter.outcome()?.playerStatus == "LOGIN_REQUIRED")

        // Paused: nothing more is sent, the viewing waits in the queue for the next launch.
        let before = rig.http.requests.count
        await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticLater"))
        #expect(rig.http.requests.count == before)
        #expect(rig.queue.all().map(\.videoID) == ["tvsyntheticLater"])
    }

    @Test func aRefusedPingCountsAsARefusal() async throws {
        let rig = Rig()
        rig.http.enqueue("youtubei/v1/player", body: try Fixture.data("tvsynthetic_player_signed.json"))
        rig.http.enqueue("api/stats/", status: 403, body: Data())
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        await rig.reporter.record(.qualified(position: 31), for: viewing())
        #expect(await rig.reporter.outcome()?.status == "refused")
        #expect(await rig.reporter.outcome()?.pingStatuses.first == 403)
        #expect(rig.queue.all().isEmpty)
    }

    @Test func aNetworkErrorKeepsTheEntryForReplay() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticOff"))
        let entries = rig.queue.all()
        #expect(entries.count == 1)
        #expect(entries.first?.videoID == "tvsyntheticOff")
        #expect(entries.first?.position == 31)
        #expect(entries.first?.lengthSeconds == 60)
        #expect(rig.pings.isEmpty)
        #expect(await rig.reporter.isPaused() == false)
        #expect(await rig.reporter.outcome()?.status == "waiting")
    }

    @Test func replayMintsAFreshSessionPerEntry() async throws {
        let rig = Rig()
        rig.queue.add(PendingWatchReport(videoID: "tvsyntheticOne", lengthSeconds: 60, position: 40, createdAt: rig.clock.now))
        rig.queue.add(PendingWatchReport(videoID: "tvsyntheticTwo", lengthSeconds: 100, position: 100, finished: true, createdAt: rig.clock.now))
        try prepare(rig)
        await rig.reporter.replayPending()

        #expect(rig.players.count == 2)
        #expect(rig.queue.all().isEmpty)
        let bodies = rig.players.compactMap { rig.http.bodyJSON(of: $0)?["videoId"]?.string }
        #expect(bodies == ["tvsyntheticOne", "tvsyntheticTwo"])
        let pings = rig.pings
        // First entry: playback + one watchtime from 0 to 40. Second: playback + watchtime + the final one.
        #expect(pings.count == 2 + 3)
        let first = query(pings[1])
        #expect(first["st"] == "0.000" && first["et"] == "40.000" && first["final"] == nil)
        let cpns = [query(pings[0])["cpn"], query(pings[2])["cpn"]]
        #expect(cpns[0] != cpns[1])
        let last = query(pings[4])
        #expect(last["final"] == "1")
        #expect(last["et"] == "100.000")
    }

    @Test func replayKeepsEntriesWhileTheNetworkIsDown() async throws {
        let rig = Rig()
        rig.queue.add(PendingWatchReport(videoID: "tvsyntheticOne", lengthSeconds: 60, position: 40, createdAt: rig.clock.now))
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        await rig.reporter.replayPending()
        #expect(rig.queue.all().count == 1)
    }

    @Test func progressAndClosingReuseTheViewingsTrackingValues() async throws {
        let rig = Rig()
        try prepare(rig)
        let v = viewing(length: 400)
        await rig.reporter.record(.qualified(position: 31), for: v)
        await rig.reporter.record(.progress(position: 280), for: v)
        await rig.reporter.record(.ended(position: 390, finished: true), for: v)

        #expect(rig.players.count == 1)
        let pings = rig.pings
        #expect(pings.count == 5)
        let cpn = query(pings[0])["cpn"]
        #expect(pings.allSatisfy { query($0)["cpn"] == cpn })
        let progress = query(pings[2])
        #expect(progress["st"] == "31.000" && progress["et"] == "280.000" && progress["cmt"] == "280.000")
        let range = query(pings[3])
        #expect(range["st"] == "280.000" && range["et"] == "390.000" && range["final"] == nil)
        let closing = query(pings[4])
        #expect(closing["final"] == "1" && closing["cmt"] == "390.000")
        #expect(closing["ei"] == "tvsynthetic_ei")
    }

    @Test func anEndWithoutProgressSendsOnlyTheFinalPingAfterASeekBack() async throws {
        let rig = Rig()
        try prepare(rig)
        let v = viewing(length: 400)
        await rig.reporter.record(.qualified(position: 100), for: v)
        await rig.reporter.record(.ended(position: 20, finished: false), for: v)
        // Not finished and no forward range: nothing more to say.
        #expect(rig.pings.count == 2)
    }

    @Test func aDifferentViewingNeverReusesTrackingValues() async throws {
        let rig = Rig()
        try prepare(rig)
        let a = viewing("tvsyntheticA")
        let b = viewing("tvsyntheticB")
        await rig.reporter.record(.qualified(position: 31), for: a)
        await rig.reporter.record(.qualified(position: 33), for: b)
        #expect(rig.players.count == 2)
        let cpns = rig.pings.map { query($0)["cpn"] }
        #expect(Set(cpns.compactMap { $0 }).count == 2)
        // A progress report for a viewing that never qualified sends nothing.
        let before = rig.http.requests.count
        await rig.reporter.record(.progress(position: 300), for: viewing("tvsyntheticC"))
        #expect(rig.http.requests.count == before)
        // A second qualified for the same viewing does not report twice.
        await rig.reporter.record(.qualified(position: 40), for: a)
        #expect(rig.players.count == 2)
    }

    @Test func aDisabledReporterSendsNothing() async throws {
        let rig = Rig()
        rig.enabled.value = false
        try prepare(rig)
        await rig.reporter.record(.qualified(position: 31), for: viewing())
        await rig.reporter.record(.ended(position: 50, finished: false), for: viewing())
        await rig.reporter.replayPending()
        #expect(rig.http.requests.isEmpty)
        #expect(rig.queue.all().isEmpty)
    }

    @Test func disconnectDropsThePendingReports() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        let v = viewing()
        await rig.reporter.record(.qualified(position: 31), for: v)
        #expect(rig.queue.all().count == 1)
        await rig.reporter.clearAccountData()
        #expect(rig.queue.all().isEmpty)
        #expect(await rig.reporter.outcome() == nil)
        // The old viewing's later events find nothing to continue.
        let before = rig.http.requests.count
        await rig.reporter.record(.ended(position: 50, finished: false), for: v)
        await rig.reporter.replayPending()
        #expect(rig.http.requests.count == before)
        #expect(rig.queue.all().isEmpty)
    }

    @Test func anEndAfterAFailedStartUpdatesTheQueuedEntry() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        let v = viewing()
        await rig.reporter.record(.qualified(position: 31), for: v)
        await rig.reporter.record(.ended(position: 58, finished: true), for: v)
        let entry = try #require(rig.queue.all().first)
        #expect(entry.position == 58)
        #expect(entry.finished)
    }

    @Test func aViewingWhoseFirstReportFailedIsReplayedAfterItEnds() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("youtubei/v1/player", body: try Fixture.data("tvsynthetic_player_signed.json"))
        rig.http.enqueue("api/stats/", body: Data())
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        let v = viewing()
        await rig.reporter.record(.qualified(position: 31), for: v)
        await rig.reporter.record(.ended(position: 58, finished: true), for: v)
        #expect(rig.queue.all().count == 1)
        #expect(rig.pings.isEmpty)

        await rig.reporter.replayPending()
        let kinds = rig.pings.map { $0.url!.path }
        #expect(kinds == ["/api/stats/playback", "/api/stats/watchtime", "/api/stats/watchtime"])
        #expect(query(rig.pings[2])["final"] == "1")
        #expect(rig.queue.all().isEmpty)
    }

    @Test func aClosingPingLostToTheNetworkIsQueuedForReplay() async throws {
        let rig = Rig()
        rig.http.enqueue("youtubei/v1/player", body: try Fixture.data("tvsynthetic_player_signed.json"))
        rig.http.enqueue("api/stats/", body: Data())
        rig.http.enqueue("api/stats/", body: Data())
        rig.http.enqueueError("api/stats/", NoSlopError.network("offline"))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        let v = viewing()
        await rig.reporter.record(.qualified(position: 31), for: v)
        #expect(rig.queue.all().isEmpty)
        await rig.reporter.record(.ended(position: 58, finished: true), for: v)
        let entry = try #require(rig.queue.all().first)
        #expect(entry.videoID == "tvsyntheticV1")
        #expect(entry.position == 58)
        #expect(entry.finished)
    }

    // MARK: Review fixes

    private func from(_ v: WatchViewing, _ start: Double) -> WatchViewing {
        WatchViewing(id: v.id, videoID: v.videoID, lengthSeconds: v.lengthSeconds, rangeStart: start)
    }

    @Test func aBackgroundFlushKeepsTheViewingOpenForTheRestOfIt() async throws {
        let rig = Rig()
        try prepare(rig)
        let v = viewing(length: 4000)
        await rig.reporter.record(.qualified(position: 31), for: v)
        // The app goes to the background: a flush is a progress event, not an end.
        await rig.reporter.record(.progress(position: 90), for: v)
        await rig.reporter.record(.progress(position: 1200), for: v)
        await rig.reporter.record(.ended(position: 3900, finished: true), for: v)

        #expect(rig.players.count == 1)
        let ranges = rig.pings.dropFirst().map { (query($0)["st"], query($0)["et"], query($0)["final"]) }
        #expect(ranges.map(\.0) == ["0.000", "31.000", "90.000", "1200.000", "3900.000"])
        #expect(ranges.map(\.1) == ["31.000", "90.000", "1200.000", "3900.000", "3900.000"])
        #expect(ranges.last?.2 == "1")
    }

    @Test func aResumedViewingReportsTheStretchThatWasPlayed() async throws {
        let rig = Rig()
        try prepare(rig)
        let v = viewing(length: 3000)
        await rig.reporter.record(.qualified(position: 630), for: from(v, 600))
        let first = query(rig.pings[1])
        #expect(first["st"] == "600.000" && first["et"] == "630.000")

        // A seek forward: the next range starts where playing went on, not at the last report.
        await rig.reporter.record(.progress(position: 1500), for: from(v, 1300))
        let second = query(rig.pings[2])
        #expect(second["st"] == "1300.000" && second["et"] == "1500.000")
        // A seek back is a range of its own.
        await rig.reporter.record(.ended(position: 420, finished: false), for: from(v, 400))
        let third = query(rig.pings[3])
        #expect(third["st"] == "400.000" && third["et"] == "420.000")
    }

    @Test func aReplayedEntryKeepsItsRangeStart() async throws {
        let rig = Rig()
        rig.queue.add(PendingWatchReport(videoID: "tvsyntheticOne", lengthSeconds: 900, position: 640, createdAt: rig.clock.now, rangeStart: 610))
        try prepare(rig)
        await rig.reporter.replayPending()
        let watchtime = query(try #require(rig.pings.last))
        #expect(watchtime["st"] == "610.000" && watchtime["et"] == "640.000")
    }

    @Test func aViewingMintedByAReplayGoesOnWithItsValues() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("youtubei/v1/player", body: try Fixture.data("tvsynthetic_player_signed.json"))
        rig.http.enqueue("api/stats/", body: Data())
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        let v = viewing(length: 400)
        await rig.reporter.record(.qualified(position: 31), for: v)
        #expect(rig.pings.isEmpty)
        await rig.reporter.replayPending()
        #expect(rig.queue.all().isEmpty)
        #expect(rig.pings.count == 2)

        await rig.reporter.record(.progress(position: 280), for: v)
        await rig.reporter.record(.ended(position: 390, finished: true), for: v)
        let pings = rig.pings
        #expect(pings.count == 5)
        let cpn = query(pings[0])["cpn"]
        #expect(pings.allSatisfy { query($0)["cpn"] == cpn })
        #expect(query(pings[4])["final"] == "1")
        // The failed first request and the replay's: no third one for the later events.
        #expect(rig.players.count == 2)
    }

    @Test func serverHiccupsKeepTheReportAndNeverPause() async throws {
        for status in [429, 500, 503] {
            let rig = Rig()
            rig.http.enqueue("youtubei/v1/player", status: status, body: Data())
            rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
            for i in 0..<4 {
                await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticH\(i)"))
            }
            #expect(await rig.reporter.isPaused() == false)
            #expect(rig.queue.all().count == 4)
            #expect(await rig.reporter.outcome()?.status == "waiting")
        }
    }

    @Test func aReplyThatCannotBeReadIsAHiccupToo() async throws {
        let rig = Rig()
        rig.http.enqueue("youtubei/v1/player", body: Data("not json".utf8))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        for i in 0..<3 { await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticD\(i)")) }
        #expect(await rig.reporter.isPaused() == false)
        #expect(rig.queue.all().count == 3)
    }

    @Test func aClientErrorFromTheServerStillCountsAsARefusal() async throws {
        let rig = Rig()
        rig.http.enqueue("youtubei/v1/player", status: 400, body: Data())
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        for i in 0..<3 { await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticE\(i)")) }
        #expect(await rig.reporter.isPaused())
        #expect(rig.queue.all().isEmpty)
    }

    @Test func aPingThatAnswersWithAServerErrorKeepsTheReport() async throws {
        let rig = Rig()
        rig.http.enqueue("youtubei/v1/player", body: try Fixture.data("tvsynthetic_player_signed.json"))
        rig.http.enqueue("api/stats/", status: 503, body: Data())
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        for i in 0..<3 { await rig.reporter.record(.qualified(position: 31), for: viewing("tvsyntheticP\(i)")) }
        #expect(await rig.reporter.isPaused() == false)
        #expect(rig.queue.all().count == 3)
    }

    @Test func aReportThatKeepsFailingOnTheServerIsGivenUpAfterFiveReplays() async throws {
        let rig = Rig()
        rig.http.enqueue("youtubei/v1/player", status: 503, body: Data())
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        rig.queue.add(PendingWatchReport(videoID: "tvsyntheticOne", lengthSeconds: 60, position: 40, createdAt: rig.clock.now))
        for round in 1...5 {
            #expect(rig.queue.all().count == 1, "round \(round)")
            await rig.reporter.replayPending()
        }
        #expect(rig.queue.all().isEmpty)
        #expect(await rig.reporter.isPaused() == false)
    }

    @Test func turningSharingOffDropsTheQueueAndWhatWasWatchedIsNeverSentLater() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        rig.http.enqueue("https://www.youtube.com/", body: homepageBody())
        let v = viewing()
        await rig.reporter.record(.qualified(position: 31), for: v)
        #expect(rig.queue.all().count == 1)

        rig.enabled.value = false
        await rig.reporter.sharingTurnedOff()
        #expect(rig.queue.all().isEmpty)

        rig.enabled.value = true
        try prepare(rig)
        let before = rig.http.requests.count
        await rig.reporter.replayPending()
        await rig.reporter.record(.ended(position: 50, finished: false), for: v)
        #expect(rig.http.requests.count == before)
        #expect(rig.queue.all().isEmpty)
    }

    @Test func aMissingAccountDoesNotDropTheQueue() async throws {
        let rig = Rig()
        rig.queue.add(PendingWatchReport(videoID: "tvsyntheticOne", lengthSeconds: 60, position: 40, createdAt: rig.clock.now))
        rig.enabled.value = false
        await rig.reporter.replayPending()
        #expect(rig.queue.all().count == 1)
    }
}
