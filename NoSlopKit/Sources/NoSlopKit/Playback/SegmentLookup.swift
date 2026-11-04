import Foundation

/// How the player gets the SponsorBlock segments of a video: one lookup and, when it fails, a few more after growing
/// pauses.
///
/// The service is free and sometimes busy (429, 5xx), a request can time out, and a phone can be offline for a moment.
/// A lookup that gave up at the first failure would leave the whole viewing without auto-skip and without the coloured
/// marks in the seek bar, and nothing would tell the viewer. So a failure is retried a bounded number of times, with
/// pauses that do not hammer a rate-limited service. An answer of any kind ends the lookup, including "no segments"
/// (the service says 404 when nobody submitted any): only a failure is retried.
public enum SegmentLookup {
    public enum Outcome: Equatable, Sendable {
        /// The service answered with these segments; none at all is an answer too.
        case loaded([SponsorSegment])
        /// Every attempt failed, or the task was cancelled. The caller forgets that it asked, so that its next
        /// chance (Retry, a reload, the connection coming back) asks again.
        case failed
    }

    /// The pauses before the first and the second retry: three attempts in all, the last one 13 seconds after the
    /// first.
    public static let retryDelays: [Duration] = [.seconds(3), .seconds(10)]

    /// Asks `provider` for the segments of `videoID`, trying again after each of `retryDelays` when a try fails.
    ///
    /// - Parameter sleep: waits for a pause to pass; tests pass one that returns at once. A sleep that throws (the
    ///   task was cancelled) ends the lookup.
    public static func fetch(
        videoID: String,
        from provider: any SponsorBlockProviding,
        retryDelays: [Duration] = SegmentLookup.retryDelays,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Outcome {
        var retries = 0
        while true {
            do {
                return .loaded(try await provider.segments(videoID: videoID))
            } catch {
                // A cancelled task (the viewer moved on to another video) has no use for another try.
                guard !Task.isCancelled, retries < retryDelays.count else { return .failed }
            }
            do {
                try await sleep(retryDelays[retries])
            } catch {
                return .failed
            }
            retries += 1
        }
    }
}
