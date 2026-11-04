import Foundation
import Testing
@testable import NoSlopKit

@Suite struct PlayerFailureAdviceTests {
    // MARK: A video that cannot be had

    @Test func aVideoYouTubeSaysIsGoneHasNoRetry() {
        #expect(!PlayerFailureAdvice.isWorthRetrying(NoSlopError.unavailable(reason: "This video isn't available anymore")))
    }

    @Test(arguments: [
        "Video unavailable",
        "This video is private",
        "Sign in to confirm your age",
        "This video has been removed by the uploader",
        "The uploader has not made this video available in your country",
        "ERROR",
    ])
    func aVideoYouTubeWillNotHandOutHasNoRetry(_ reason: String) {
        // The `player` endpoint reports all of these as `unplayable`; asking again gets the same verdict. Whatever the
        // list the video came from knew about it (a pasted link knows nothing): the verdict is the error's.
        #expect(!PlayerFailureAdvice.isWorthRetrying(NoSlopError.unplayable(reason: reason)))
    }

    // MARK: A video that is not playable yet

    @Test(arguments: [
        "This live event will begin in 2 hours.",
        "Premieres in 3 minutes",
        "No playable streams were returned for this video.",
    ])
    func aVideoThatIsNotPlayableYetKeepsRetryBecauseAskingAgainCanEndDifferently(_ reason: String) {
        #expect(PlayerFailureAdvice.isWorthRetrying(NoSlopError.notPlayableYet(reason: reason)))
    }

    @Test func aLiveEventThatHasNotBegunKeepsRetryAlsoForAVideoOpenedFromALink() throws {
        // A link, a share link or `noslop://watch` opens the video as `VideoSummary(id:title:"")`, without the live and
        // upcoming flags, and so does a copy from History, Watch Later or a playlist (the library keeps no flags). The
        // answer of YouTube's `player` endpoint is all there is to decide on.
        let response: JSON = [
            "playabilityStatus": [
                "status": "LIVE_STREAM_OFFLINE",
                "reason": "This live event will begin in 2 hours.",
            ],
        ]
        let error = try #require(throws: NoSlopError.self) {
            try PlayerResponseParser.parse(response, now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        #expect(error.errorDescription == "This live event will begin in 2 hours.", "the viewer reads YouTube's own words")
        #expect(PlayerFailureAdvice.isWorthRetrying(error))
    }

    @Test(arguments: ["UNPLAYABLE", "ERROR", "LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED"])
    func theVerdictsOfThePlayerEndpointAreStillPermanent(_ status: String) throws {
        let response: JSON = ["playabilityStatus": ["status": .string(status), "reason": "Nope."]]
        let error = try #require(throws: NoSlopError.self) {
            try PlayerResponseParser.parse(response, now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        #expect(!PlayerFailureAdvice.isWorthRetrying(error), "\(status)")
    }

    // MARK: Everything that can pass

    @Test(arguments: [
        NoSlopError.network("offline"),
        NoSlopError.http(status: 503),
        NoSlopError.http(status: 429),
        NoSlopError.botCheck,
        NoSlopError.decoding("odd response"),
        NoSlopError.cancelled,
    ])
    func whatCanPassKeepsRetry(_ error: NoSlopError) {
        #expect(PlayerFailureAdvice.isWorthRetrying(error))
    }

    @Test func errorsThatAreNotYouTubesKeepRetry() {
        #expect(PlayerFailureAdvice.isWorthRetrying(URLError(.notConnectedToInternet)))
        #expect(PlayerFailureAdvice.isWorthRetrying(URLError(.timedOut)))
        #expect(PlayerFailureAdvice.isWorthRetrying(CancellationError()))
    }

    // MARK: A stream that failed while playing

    @Test func aStreamThatCannotBeDecodedHasNoRetryBecauseFreshAddressesWouldNotHelp() {
        #expect(!PlayerFailureAdvice.isWorthRetrying(PlaybackFailure.decode, isPlayingOffline: false))
    }

    @Test func aDownloadThatCannotBeDecodedKeepsRetryBecauseRetryStreamsTheVideoInstead() {
        // The retry of a download that cannot be played swaps the source: it streams the video (`forceStreaming`). That
        // is no repeat of what failed, and a damaged file is otherwise a video that can never be watched again.
        #expect(PlayerFailureAdvice.isWorthRetrying(PlaybackFailure.decode, isPlayingOffline: true))
    }

    @Test(arguments: [PlaybackFailure.forbidden, .httpStatus(500), .httpStatus(404), .network, .unknown], [false, true])
    func everyOtherFailureWhilePlayingKeepsRetry(_ failure: PlaybackFailure, isPlayingOffline: Bool) {
        #expect(PlayerFailureAdvice.isWorthRetrying(failure, isPlayingOffline: isPlayingOffline))
    }

    @Test func theMessageForAnUndecodableStreamSendsTheViewerToYouTube() {
        // The error screen of a stream has no Retry for it, so its text must not tell the viewer to try again.
        #expect(!PlaybackFailure.decode.message.lowercased().contains("try again"))
        #expect(PlaybackFailure.decode.message.contains("YouTube"))
    }
}
