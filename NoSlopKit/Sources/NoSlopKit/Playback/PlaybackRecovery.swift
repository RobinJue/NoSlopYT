import Foundation

/// Why AVPlayer stopped, reduced to what recovery cares about.
public enum PlaybackFailure: Equatable, Sendable {
    case forbidden
    case httpStatus(Int)
    case network
    case decode
    case unknown
}

/// Decides how the player reacts to a playback failure: re-resolve the stream URLs (they expire after ~6 h and are
/// IP-bound), wait for connectivity, or give up and show an error after a second failure.
///
/// STUB (Task 1A). Task 10 owns this file: always answers `.showError` until it is filled in.
public enum PlaybackRecovery {
    public enum Action: Equatable, Sendable {
        case reresolveAndResume(at: Double)
        case waitForNetworkThenRetry(at: Double)
        case showError
    }

    public static func action(
        for failure: PlaybackFailure,
        position: Double,
        streamExpiresAt: Date?,
        now: Date,
        attempt: Int
    ) -> Action {
        .showError
    }
}
