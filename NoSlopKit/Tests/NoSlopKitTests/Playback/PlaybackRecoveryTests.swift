import Foundation
import Testing
@testable import NoSlopKit

/// Review Focus 3: resuming a paused video hours later (stream URLs expired) or losing the network mid-play must
/// re-resolve and resume at the same position, or wait for connectivity and retry. The error screen appears only
/// after a second failure.
@Suite struct PlaybackRecoveryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: From the plan

    @Test func expiredURLReResolves() {
        #expect(
            PlaybackRecovery.action(for: .unknown, position: 42, streamExpiresAt: t0, now: t0.addingTimeInterval(10), attempt: 0)
                == .reresolveAndResume(at: 42)
        )
    }

    @Test func forbiddenReResolves() {
        #expect(
            PlaybackRecovery.action(for: .forbidden, position: 10, streamExpiresAt: t0.addingTimeInterval(3600), now: t0, attempt: 0)
                == .reresolveAndResume(at: 10)
        )
    }

    @Test func networkLossWaits() {
        #expect(
            PlaybackRecovery.action(for: .network, position: 5, streamExpiresAt: nil, now: t0, attempt: 0)
                == .waitForNetworkThenRetry(at: 5)
        )
    }

    @Test func secondFailureShowsError() {
        #expect(
            PlaybackRecovery.action(for: .forbidden, position: 5, streamExpiresAt: nil, now: t0, attempt: 2) == .showError
        )
    }

    @Test func decodeErrorShowsError() {
        #expect(PlaybackRecovery.action(for: .decode, position: 0, streamExpiresAt: nil, now: t0, attempt: 0) == .showError)
    }

    // MARK: The error screen comes after a second failure, whatever the cause

    @Test(arguments: [PlaybackFailure.forbidden, .httpStatus(403), .httpStatus(500), .network, .decode, .unknown])
    func anyFailureAfterOneRecoveryShowsError(failure: PlaybackFailure) {
        // `attempt` counts the recoveries already tried: 1 means the retry itself failed.
        #expect(PlaybackRecovery.action(for: failure, position: 30, streamExpiresAt: nil, now: t0, attempt: 1) == .showError)
        #expect(PlaybackRecovery.action(for: failure, position: 30, streamExpiresAt: nil, now: t0, attempt: 5) == .showError)
    }

    @Test func aNegativeAttemptCountsAsTheFirst() {
        #expect(
            PlaybackRecovery.action(for: .forbidden, position: 8, streamExpiresAt: nil, now: t0, attempt: -3)
                == .reresolveAndResume(at: 8)
        )
    }

    // MARK: First failures

    @Test func unknownFailureWithValidURLStillRetriesOnceWithFreshURLs() {
        #expect(
            PlaybackRecovery.action(for: .unknown, position: 77.5, streamExpiresAt: t0.addingTimeInterval(3600), now: t0, attempt: 0)
                == .reresolveAndResume(at: 77.5)
        )
    }

    @Test func unknownFailureWithoutExpiryInformationRetriesOnce() {
        #expect(
            PlaybackRecovery.action(for: .unknown, position: 12, streamExpiresAt: nil, now: t0, attempt: 0)
                == .reresolveAndResume(at: 12)
        )
    }

    @Test func networkLossWithExpiredURLStillWaitsFirst() {
        // Re-resolving needs the network too, so waiting comes first; the caller re-resolves once it is back.
        #expect(
            PlaybackRecovery.action(for: .network, position: 300, streamExpiresAt: t0, now: t0.addingTimeInterval(3 * 3600), attempt: 0)
                == .waitForNetworkThenRetry(at: 300)
        )
    }

    @Test(arguments: [403, 404, 410])
    func clientErrorsMeaningTheLinkIsDeadReResolve(status: Int) {
        #expect(
            PlaybackRecovery.action(for: .httpStatus(status), position: 9, streamExpiresAt: nil, now: t0, attempt: 0)
                == .reresolveAndResume(at: 9)
        )
    }

    @Test(arguments: [408, 429, 500, 502, 503, 504])
    func busyOrTimedOutServersWaitAndRetry(status: Int) {
        #expect(
            PlaybackRecovery.action(for: .httpStatus(status), position: 9, streamExpiresAt: nil, now: t0, attempt: 0)
                == .waitForNetworkThenRetry(at: 9)
        )
    }

    @Test func serverErrorFromAnExpiredLinkReResolvesInsteadOfWaiting() {
        #expect(
            PlaybackRecovery.action(for: .httpStatus(503), position: 9, streamExpiresAt: t0, now: t0.addingTimeInterval(60), attempt: 0)
                == .reresolveAndResume(at: 9)
        )
        // Inside the two-minute margin counts as expired, like `StreamInfo.isExpired`.
        #expect(
            PlaybackRecovery.action(for: .httpStatus(503), position: 9, streamExpiresAt: t0.addingTimeInterval(100), now: t0, attempt: 0)
                == .reresolveAndResume(at: 9)
        )
        // A live link with a busy server waits.
        #expect(
            PlaybackRecovery.action(for: .httpStatus(503), position: 9, streamExpiresAt: t0.addingTimeInterval(3600), now: t0, attempt: 0)
                == .waitForNetworkThenRetry(at: 9)
        )
    }

    @Test func otherHTTPStatusesReResolveOnce() {
        // 400, 401, 416... are not something waiting fixes; fresh URLs are the only cheap thing left to try.
        #expect(
            PlaybackRecovery.action(for: .httpStatus(400), position: 1, streamExpiresAt: nil, now: t0, attempt: 0)
                == .reresolveAndResume(at: 1)
        )
    }

    @Test func formatAndDecodeProblemsNeverRetry() {
        // Re-resolving cannot make an undecodable stream decodable.
        #expect(
            PlaybackRecovery.action(for: .decode, position: 50, streamExpiresAt: t0, now: t0.addingTimeInterval(99_999), attempt: 0)
                == .showError
        )
    }

    // MARK: Classifying what AVFoundation reported

    private func link(_ domain: String, _ code: Int) -> PlaybackFailure.ErrorLink {
        PlaybackFailure.ErrorLink(domain: domain, code: code)
    }

    @Test(arguments: [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020, -1200])
    func urlErrorsAboutTheConnectionAreNetworkFailures(code: Int) {
        #expect(PlaybackFailure.classify(chain: [link("NSURLErrorDomain", code)], httpStatus: nil) == .network)
    }

    @Test func aNetworkErrorBuriedInAnAVFoundationWrapperIsFound() {
        // AVPlayerItem.error is usually AVFoundationErrorDomain -11800 with the real cause underneath.
        let chain = [link("AVFoundationErrorDomain", -11800), link("NSURLErrorDomain", -1009)]
        #expect(PlaybackFailure.classify(chain: chain, httpStatus: nil) == .network)
    }

    @Test func posixAndCFNetworkConnectionErrorsAreNetworkFailures() {
        #expect(PlaybackFailure.classify(chain: [link("NSPOSIXErrorDomain", 57)], httpStatus: nil) == .network)
        #expect(PlaybackFailure.classify(chain: [link("kCFErrorDomainCFNetwork", -1005)], httpStatus: nil) == .network)
    }

    @Test func aStaleHTTPStatusInTheLogNeverHidesALostConnection() {
        let chain = [link("AVFoundationErrorDomain", -11800), link("NSURLErrorDomain", -1005)]
        #expect(PlaybackFailure.classify(chain: chain, httpStatus: 404) == .network)
    }

    @Test func httpStatusFromTheErrorLog() {
        let wrapper = [link("AVFoundationErrorDomain", -11800)]
        #expect(PlaybackFailure.classify(chain: wrapper, httpStatus: 403) == .forbidden)
        #expect(PlaybackFailure.classify(chain: wrapper, httpStatus: 404) == .httpStatus(404))
        #expect(PlaybackFailure.classify(chain: wrapper, httpStatus: 503) == .httpStatus(503))
    }

    @Test func nonErrorStatusesAreIgnored() {
        // The log also carries 0 when there was no HTTP error; 2xx/3xx are not failures.
        #expect(PlaybackFailure.classify(chain: [link("AVFoundationErrorDomain", -11800)], httpStatus: 0) == .unknown)
        #expect(PlaybackFailure.classify(chain: [link("AVFoundationErrorDomain", -11800)], httpStatus: 200) == .unknown)
    }

    @Test func coreMediaForbiddenCode() {
        #expect(PlaybackFailure.classify(chain: [link("CoreMediaErrorDomain", -12660)], httpStatus: nil) == .forbidden)
    }

    @Test func decoderProblemsAreDecodeFailures() {
        #expect(PlaybackFailure.classify(chain: [link("AVFoundationErrorDomain", -11821)], httpStatus: nil) == .decode)  // decodeFailed
        #expect(PlaybackFailure.classify(chain: [link("AVFoundationErrorDomain", -11833)], httpStatus: nil) == .decode)  // decoderNotFound
    }

    @Test func cannotOpenMayJustBeAnExpiredManifestSoItIsNotADecodeFailure() {
        // -11828 "Cannot Open" is what an HTML 403 page in place of a playlist looks like.
        #expect(PlaybackFailure.classify(chain: [link("AVFoundationErrorDomain", -11828)], httpStatus: nil) == .unknown)
    }

    @Test func anythingElseIsUnknown() {
        #expect(PlaybackFailure.classify(chain: [], httpStatus: nil) == .unknown)
        #expect(PlaybackFailure.classify(chain: [link("AVFoundationErrorDomain", -11800)], httpStatus: nil) == .unknown)
        #expect(PlaybackFailure.classify(chain: [link("NSURLErrorDomain", -1002)], httpStatus: nil) == .unknown)  // unsupported URL
    }

    @Test func everyFailureHasAPlainMessage() {
        let all: [PlaybackFailure] = [.forbidden, .httpStatus(500), .network, .decode, .unknown]
        for failure in all {
            #expect(!failure.message.isEmpty)
            #expect(failure.message.allSatisfy { !$0.isNumber })  // never an error code or HTTP status
        }
        #expect(PlaybackFailure.network.message == NoSlopError.network("").errorDescription)
    }

    // MARK: Positions

    @Test func positionIsKeptExactly() {
        #expect(
            PlaybackRecovery.action(for: .forbidden, position: 1234.567, streamExpiresAt: nil, now: t0, attempt: 0)
                == .reresolveAndResume(at: 1234.567)
        )
        #expect(
            PlaybackRecovery.action(for: .network, position: 0, streamExpiresAt: nil, now: t0, attempt: 0)
                == .waitForNetworkThenRetry(at: 0)
        )
    }

    @Test(arguments: [-5.0, Double.nan, Double.infinity, -Double.infinity])
    func unusablePositionsStartFromTheBeginning(position: Double) {
        #expect(
            PlaybackRecovery.action(for: .forbidden, position: position, streamExpiresAt: nil, now: t0, attempt: 0)
                == .reresolveAndResume(at: 0)
        )
        #expect(
            PlaybackRecovery.action(for: .network, position: position, streamExpiresAt: nil, now: t0, attempt: 0)
                == .waitForNetworkThenRetry(at: 0)
        )
    }
}
