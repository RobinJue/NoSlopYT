import Foundation
import Testing
@testable import NoSlopKit

@Suite struct PlayerFailureAdviceTests {
    private let plain = VideoSummary(id: "aqz-KE-bpKQ", title: "Big Buck Bunny")

    // MARK: A video that cannot be had

    @Test func aVideoYouTubeSaysIsGoneHasNoRetry() {
        let error = NoSlopError.unavailable(reason: "This video isn't available anymore")
        #expect(!PlayerFailureAdvice.isWorthRetrying(error, video: plain))
        #expect(!PlayerFailureAdvice.isWorthRetrying(error, video: nil))
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
        // The `player` endpoint reports all of these as `unplayable`; asking again gets the same verdict.
        let error = NoSlopError.unplayable(reason: reason)
        #expect(!PlayerFailureAdvice.isWorthRetrying(error, video: plain))
        #expect(!PlayerFailureAdvice.isWorthRetrying(error, video: nil))
    }

    @Test func aBroadcastThatHasNotStartedYetKeepsRetryBecauseItWillStart() {
        let error = NoSlopError.unplayable(reason: "This live event will begin in 2 hours.")
        var premiere = plain
        premiere.isUpcoming = true
        var live = plain
        live.isLive = true
        #expect(PlayerFailureAdvice.isWorthRetrying(error, video: premiere))
        #expect(PlayerFailureAdvice.isWorthRetrying(error, video: live))
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
        #expect(PlayerFailureAdvice.isWorthRetrying(error, video: plain))
        #expect(PlayerFailureAdvice.isWorthRetrying(error, video: nil))
    }

    @Test func errorsThatAreNotYouTubesKeepRetry() {
        #expect(PlayerFailureAdvice.isWorthRetrying(URLError(.notConnectedToInternet), video: plain))
        #expect(PlayerFailureAdvice.isWorthRetrying(URLError(.timedOut), video: plain))
        #expect(PlayerFailureAdvice.isWorthRetrying(CancellationError(), video: plain))
    }

    // MARK: A stream that failed while playing

    @Test func aStreamThatCannotBeDecodedHasNoRetryBecauseFreshAddressesWouldNotHelp() {
        #expect(!PlayerFailureAdvice.isWorthRetrying(PlaybackFailure.decode))
    }

    @Test(arguments: [PlaybackFailure.forbidden, .httpStatus(500), .httpStatus(404), .network, .unknown])
    func everyOtherFailureWhilePlayingKeepsRetry(_ failure: PlaybackFailure) {
        #expect(PlayerFailureAdvice.isWorthRetrying(failure))
    }

    @Test func theMessageForAnUndecodableStreamSendsTheViewerToYouTube() {
        // The error screen has no Retry for it, so its text must not tell the viewer to try again.
        #expect(!PlaybackFailure.decode.message.lowercased().contains("try again"))
        #expect(PlaybackFailure.decode.message.contains("YouTube"))
    }
}
