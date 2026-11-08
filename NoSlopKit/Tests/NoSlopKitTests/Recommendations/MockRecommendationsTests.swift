import Foundation
import Testing
@testable import NoSlopKit

@Suite struct MockRecommendationsTests {
    @Test func theMockConnectFinishesAfterItsDelay() async throws {
        let auth = MockRecommendationsAuth(connected: false, delay: .milliseconds(40))
        #expect(await auth.currentAccount() == nil)
        #expect(await auth.secondsLeft() == nil)

        let prompt = try await auth.beginSignIn()
        #expect(prompt.userCode == "MOCK-CODE")
        #expect(prompt.verificationURL.absoluteString == "https://www.google.com/device?user_code=MOCK-CODE")
        #expect(prompt.expiresAt > Date())
        #expect(await auth.currentAccount() == nil, "approval has not happened yet")

        let started = ContinuousClock.now
        let account = try await auth.completeSignIn(prompt)
        #expect(ContinuousClock.now - started >= .milliseconds(35))
        #expect(account.name == "Mock Account")
        #expect(await auth.currentAccount()?.name == "Mock Account")
        #expect(await auth.secondsLeft() != nil)
    }

    @Test func aFailingMockConnectEndsWithItsSentenceAndStaysDisconnected() async throws {
        let auth = MockRecommendationsAuth(connected: false, delay: .milliseconds(10), failure: "The code expired. Start again.")
        let prompt = try await auth.beginSignIn()
        await #expect(throws: NoSlopError.oauth("The code expired. Start again.")) { _ = try await auth.completeSignIn(prompt) }
        #expect(await auth.currentAccount() == nil)
    }

    @Test func theMockCanStartConnectedAndDisconnects() async {
        let auth = MockRecommendationsAuth(connected: true)
        #expect(await auth.currentAccount()?.name == "Mock Account")
        #expect(await auth.disconnect().revoked)
        #expect(await auth.currentAccount() == nil)
    }

    @Test func aCancelledMockConnectThrowsCancellation() async throws {
        let auth = MockRecommendationsAuth(connected: false, delay: .seconds(30))
        let prompt = try await auth.beginSignIn()
        let task = Task { try await auth.completeSignIn(prompt) }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(await auth.currentAccount() == nil)
    }

    @Test func pageOneHoldsTheFourSpecialVideosAllInCardIDs() async throws {
        let mock = MockRecommendations()
        let page = try await mock.homePage(continuation: nil)
        #expect(page.loggedIn == true)
        #expect(page.continuation != nil)
        #expect(page.videos.contains { $0.isShort })
        #expect(page.videos.contains { $0.isMembersOnly })
        #expect(page.videos.contains { $0.isLive })
        #expect(page.videos.contains { $0.channel?.name == "Blocked Example" })
        #expect(page.cardIDs == Set(page.videos.map(\.id)))
        #expect(page.report.usedYouTube)
        #expect(Set(page.videos.map(\.id)).count == page.videos.count)
    }

    @Test func pageTwoFollowsAndEnds() async throws {
        let mock = MockRecommendations()
        let first = try await mock.homePage(continuation: nil)
        let second = try await mock.homePage(continuation: first.continuation)
        #expect(!second.videos.isEmpty)
        #expect(second.continuation == nil)
        #expect(Set(first.videos.map(\.id)).isDisjoint(with: second.videos.map(\.id)))
    }

    @Test func cardActionsAreRecordedAndShowInTheDiagnostics() async throws {
        let mock = MockRecommendations()
        try await mock.notInterested(videoID: "v1")
        let done = try await mock.dontRecommendChannel(videoID: "v2", channelID: "UC2", channelName: "Two")
        #expect(done)
        #expect(await mock.recordedActions == [
            MockRecommendations.Action(kind: "notInterested", videoID: "v1", channelID: nil),
            MockRecommendations.Action(kind: "dontRecommendChannel", videoID: "v2", channelID: "UC2"),
        ])
        let diagnostics = await mock.diagnostics()
        #expect(diagnostics.lastCardAction?.kind == "dontRecommendChannel")
        #expect(diagnostics.lastCardAction?.accepted == true)
        await mock.clearAccountData()
        #expect(await mock.recordedActions.isEmpty)
        #expect(await mock.diagnostics().lastCardAction == nil)
    }

    @Test func theMockWatchReporterRecordsEvents() async {
        let reporter = MockWatchReporter()
        let viewing = WatchViewing(id: UUID(), videoID: "v1", lengthSeconds: 120)
        await reporter.record(.qualified(position: 31), for: viewing)
        await reporter.record(.ended(position: 120, finished: true), for: viewing)
        #expect(await reporter.recordedEvents.count == 2)
        #expect(await reporter.isPaused() == false)
        #expect(await reporter.outcome()?.status.contains("ended") == true)
        await reporter.clearAccountData()
        #expect(await reporter.recordedEvents.isEmpty)
        #expect(await reporter.outcome() == nil)
    }

    @Test func thePlaceholdersAreInertOrNotConnected() async {
        let none = UnavailableRecommendations()
        await #expect(throws: NoSlopError.recommendationsNotConnected) { _ = try await none.homePage(continuation: nil) }
        await #expect(throws: NoSlopError.recommendationsNotConnected) { try await none.notInterested(videoID: "v") }
        #expect(await none.diagnostics() == RecommendationsDiagnostics())
        let reporter = NoWatchReporter()
        #expect(await reporter.outcome() == nil)
        #expect(await reporter.isPaused() == false)
    }

    @Test func diagnosticsRoundTripAsJSONWithoutSecrets() throws {
        var d = RecommendationsDiagnostics()
        d.lastHome = HomeLoadReport(
            recipe: "tv-default", status: 200, loggedIn: true, videos: 12, shorts: 2, skipped: ["ads": 3], unknown: [:],
            usedYouTube: true, at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        d.pausedReporting = true
        d.tokenSecondsLeft = 3000
        let data = try JSONEncoder().encode(d)
        #expect(try JSONDecoder().decode(RecommendationsDiagnostics.self, from: data) == d)
    }
}
