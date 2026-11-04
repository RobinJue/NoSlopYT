import Testing
@testable import NoSlopKit

@Suite struct PlaybackIntentTests {
    private func wants(
        rate: Float,
        reason: PlaybackIntent.RateChangeReason?,
        wasWanted: Bool,
        isSettled: Bool = true
    ) -> Bool {
        PlaybackIntent.wantsPlayback(afterRateChangeTo: rate, reason: reason, wasWanted: wasWanted, isSettled: isSettled)
    }

    // MARK: Someone set the rate

    @Test func aPauseSomeoneAskedForClearsTheWish() {
        // The pause button of the Picture in Picture window or the remote of an AirPlay receiver.
        #expect(wants(rate: 0, reason: .setRateCalled, wasWanted: true) == false)
        #expect(wants(rate: 0, reason: .setRateCalled, wasWanted: false) == false)
    }

    @Test func aPlaySomeoneAskedForSetsTheWish() {
        #expect(wants(rate: 1, reason: .setRateCalled, wasWanted: false) == true)
        #expect(wants(rate: 1, reason: .setRateCalled, wasWanted: true) == true)
    }

    @Test func anyRunningRateIsAPlay() {
        for rate: Float in [0.25, 0.5, 1, 1.5, 2, 4, -1] {
            #expect(wants(rate: rate, reason: .setRateCalled, wasWanted: false) == true, "rate \(rate)")
        }
    }

    // MARK: The system stopped it

    @Test func aPauseTheSystemMadeLeavesTheWish() {
        // A phone call or Siri, and the app going to the background: the viewer did not ask for either.
        for reason in [PlaybackIntent.RateChangeReason.audioSessionInterrupted, .appBackgrounded] {
            #expect(wants(rate: 0, reason: reason, wasWanted: true) == true, "\(reason)")
            #expect(wants(rate: 0, reason: reason, wasWanted: false) == false, "\(reason)")
        }
    }

    @Test func aFailedRateChangeLeavesTheWish() {
        #expect(wants(rate: 0, reason: .setRateFailed, wasWanted: true) == true)
        #expect(wants(rate: 0, reason: .setRateFailed, wasWanted: false) == false)
    }

    @Test func aRateChangeWithoutAReasonLeavesTheWish() {
        // For example the end of the video.
        #expect(wants(rate: 0, reason: nil, wasWanted: true) == true)
        #expect(wants(rate: 1, reason: nil, wasWanted: false) == false)
    }

    @Test func theSystemStartingPlaybackIsNotAWishEither() {
        for reason in [PlaybackIntent.RateChangeReason.audioSessionInterrupted, .appBackgrounded, .setRateFailed] {
            #expect(wants(rate: 1, reason: reason, wasWanted: false) == false, "\(reason)")
        }
    }

    // MARK: Not settled

    @Test func nothingCountsWhileThePlayerIsNotSettled() {
        // Loading, recovering, ended or failed: the controller's own pause() of the old item arrives here too.
        #expect(wants(rate: 0, reason: .setRateCalled, wasWanted: true, isSettled: false) == true)
        #expect(wants(rate: 1, reason: .setRateCalled, wasWanted: false, isSettled: false) == false)
    }
}
