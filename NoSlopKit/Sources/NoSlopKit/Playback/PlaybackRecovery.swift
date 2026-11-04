import Foundation

/// Why AVPlayer stopped, reduced to what recovery cares about.
public enum PlaybackFailure: Equatable, Sendable {
    /// HTTP 403: the stream URL is no longer valid for this client (expired, or bound to another IP address).
    case forbidden
    /// Any other HTTP status the media server answered with.
    case httpStatus(Int)
    /// The connection is gone or unusable (offline, timed out, connection lost, DNS).
    case network
    /// The media is there but cannot be decoded or parsed; fresh URLs would not help. (A download is the exception to the
    /// Retry that follows: it streams the video instead, see `PlayerFailureAdvice`.)
    case decode
    /// Anything else AVFoundation reported.
    case unknown
}

extension PlaybackFailure {
    /// One link of an error chain: the domain and code of an `NSError`, or of one of its underlying errors.
    public struct ErrorLink: Equatable, Sendable {
        public var domain: String
        public var code: Int

        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }
    }

    /// Reduces what AVFoundation reported to a `PlaybackFailure`.
    ///
    /// - Parameters:
    ///   - chain: the player item's error and its underlying errors, outermost first. `AVPlayerItem.error` is
    ///     usually the unhelpful `AVFoundationErrorDomain -11800` with the real cause one or two levels down.
    ///   - httpStatus: `errorStatusCode` of the last event in the item's error log, if there was one.
    ///
    /// A lost connection wins over an HTTP status, because the log may still hold the status of an earlier,
    /// recovered hiccup while the connection is what ended playback.
    public static func classify(chain: [ErrorLink], httpStatus: Int?) -> PlaybackFailure {
        if chain.contains(where: isConnectionProblem) {
            return .network
        }
        if let status = httpStatus, status >= 400 {
            return status == 403 ? .forbidden : .httpStatus(status)
        }
        for link in chain {
            switch (link.domain, link.code) {
            case ("CoreMediaErrorDomain", -12660):
                return .forbidden
            case ("AVFoundationErrorDomain", -11821), ("AVFoundationErrorDomain", -11833):
                // AVError.decodeFailed and .decoderNotFound. (-11828 "Cannot Open" is deliberately not here: an
                // expired link answers with an HTML error page that AVFoundation reports as exactly that.)
                return .decode
            default:
                continue
            }
        }
        return .unknown
    }

    /// A plain sentence for the error screen.
    public var message: String {
        switch self {
        case .network:
            return NoSlopError.network("").errorDescription ?? "Can't reach YouTube. Check your connection."
        case .decode:
            return "This video can't be played on this device. Try opening it on YouTube."
        case .forbidden, .httpStatus, .unknown:
            return "YouTube stopped sending this video. Try again, or open it on YouTube."
        }
    }

    private static func isConnectionProblem(_ link: ErrorLink) -> Bool {
        switch link.domain {
        case "NSURLErrorDomain", "kCFErrorDomainCFNetwork":
            // timed out, cannot find host, cannot connect, connection lost, DNS failure, offline, roaming off,
            // call active, data not allowed, secure connection failed
            return [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020, -1200].contains(link.code)
        case "NSPOSIXErrorDomain":
            // ENETDOWN, ENETUNREACH, ECONNABORTED, ECONNRESET, ENOTCONN, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH
            return [50, 51, 53, 54, 57, 60, 61, 64, 65].contains(link.code)
        default:
            return false
        }
    }
}

/// Decides how the player reacts to a playback failure: re-resolve the stream URLs (they expire after ~6 h and are
/// IP-bound), wait for connectivity, or give up and show an error.
///
/// Every failure is recovered from silently once: `attempt` is the number of recoveries already tried for this
/// stretch of trouble (0 for the first failure), and from the second failure on the answer is always `.showError`.
/// The caller resets its counter once playback has really run again.
///
/// Both recovery actions mean "build a fresh player item from freshly resolved stream URLs and resume at the given
/// position"; `.waitForNetworkThenRetry` first waits until the device is online (resolving needs the network too, and
/// a network change invalidates IP-bound URLs, so the old URLs are never worth retrying).
public enum PlaybackRecovery {
    public enum Action: Equatable, Sendable {
        case reresolveAndResume(at: Double)
        case waitForNetworkThenRetry(at: Double)
        case showError
    }

    /// How many silent recoveries are tried before the error is shown.
    public static let maxRecoveries = 1

    /// A stream counts as expired this long before its `expiresAt`, like `StreamInfo.isExpired`.
    public static let expiryMargin: TimeInterval = 120

    /// - Parameters:
    ///   - failure: what went wrong.
    ///   - position: where playback was, in seconds. Unusable values (negative, NaN, infinite) resume from 0.
    ///   - streamExpiresAt: when the stream URLs stop working, if known.
    ///   - now: the current time.
    ///   - attempt: recoveries already tried for this failure sequence; 0 for the first failure.
    public static func action(
        for failure: PlaybackFailure,
        position: Double,
        streamExpiresAt: Date?,
        now: Date,
        attempt: Int
    ) -> Action {
        guard attempt < maxRecoveries else { return .showError }
        let resume = position.isFinite && position > 0 ? position : 0

        switch failure {
        case .decode:
            return .showError

        case .network:
            // Nothing can be done until the connection is back, expired URLs included.
            return .waitForNetworkThenRetry(at: resume)

        case .forbidden, .unknown:
            return .reresolveAndResume(at: resume)

        case .httpStatus(let status):
            switch status {
            case 408, 429, 500...599:
                // The server is busy or timing out: waiting helps, unless the link itself has expired, in which
                // case the odd status is the stale link's doing and a fresh one is the cure.
                return isExpired(streamExpiresAt, now: now)
                    ? .reresolveAndResume(at: resume)
                    : .waitForNetworkThenRetry(at: resume)
            default:
                // 403, 404, 410 (the link is dead) and anything unusual: fresh URLs are the one cheap thing to try.
                return .reresolveAndResume(at: resume)
            }
        }
    }

    private static func isExpired(_ expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt.addingTimeInterval(-expiryMargin)
    }
}
