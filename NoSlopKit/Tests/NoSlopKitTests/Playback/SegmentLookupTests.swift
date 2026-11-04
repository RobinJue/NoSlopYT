import Foundation
import Testing
@testable import NoSlopKit

/// A `SponsorBlockProviding` that answers from a script: each call takes the next reply, the last one repeats.
private final class ScriptedSponsorBlock: SponsorBlockProviding, @unchecked Sendable {
    enum Reply {
        case segments([SponsorSegment])
        case failure(NoSlopError)
    }

    private let lock = NSLock()
    private let replies: [Reply]
    private var calls = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func segments(videoID: String) async throws -> [SponsorSegment] {
        let reply = lock.withLock { () -> Reply in
            defer { calls += 1 }
            return replies[min(calls, replies.count - 1)]
        }
        switch reply {
        case .segments(let segments): return segments
        case .failure(let error): throw error
        }
    }
}

/// Stands in for `Task.sleep`: writes down how long it was asked to wait and returns at once.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Duration] = []

    var durations: [Duration] {
        lock.withLock { waits }
    }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { waits.append(duration) }
    }
}

private let sponsor = SponsorSegment(id: "a", category: .sponsor, actionType: .skip, start: 30, end: 45)
private let busy = ScriptedSponsorBlock.Reply.failure(.http(status: 503))

@Suite struct SegmentLookupTests {
    private func fetch(
        _ provider: ScriptedSponsorBlock,
        _ recorder: SleepRecorder = SleepRecorder()
    ) async -> SegmentLookup.Outcome {
        await SegmentLookup.fetch(videoID: "v", from: provider, sleep: { try await recorder.sleep($0) })
    }

    @Test func theRetriesComeAfterThreeAndThenTenSeconds() {
        #expect(SegmentLookup.retryDelays == [.seconds(3), .seconds(10)])
    }

    @Test func anAnswerIsTakenAsItIsWithoutWaiting() async {
        let provider = ScriptedSponsorBlock([.segments([sponsor])])
        let recorder = SleepRecorder()

        #expect(await fetch(provider, recorder) == .loaded([sponsor]))
        #expect(provider.callCount == 1)
        #expect(recorder.durations.isEmpty)
    }

    @Test func noSegmentsIsAnAnswerToo() async {
        // SponsorBlock says 404 when nobody submitted anything: that is not asked again.
        let provider = ScriptedSponsorBlock([.segments([])])
        let recorder = SleepRecorder()

        #expect(await fetch(provider, recorder) == .loaded([]))
        #expect(provider.callCount == 1)
        #expect(recorder.durations.isEmpty)
    }

    @Test func aFailureIsRetriedAfterThreeSeconds() async {
        let provider = ScriptedSponsorBlock([busy, .segments([sponsor])])
        let recorder = SleepRecorder()

        #expect(await fetch(provider, recorder) == .loaded([sponsor]))
        #expect(provider.callCount == 2)
        #expect(recorder.durations == [.seconds(3)])
    }

    @Test func aSecondFailureIsRetriedAfterTenMoreSeconds() async {
        let provider = ScriptedSponsorBlock([.failure(.network("offline")), busy, .segments([sponsor])])
        let recorder = SleepRecorder()

        #expect(await fetch(provider, recorder) == .loaded([sponsor]))
        #expect(provider.callCount == 3)
        #expect(recorder.durations == [.seconds(3), .seconds(10)])
    }

    @Test func aRetryThatFindsNoSegmentsIsAnAnswer() async {
        let provider = ScriptedSponsorBlock([busy, .segments([])])

        #expect(await fetch(provider) == .loaded([]))
        #expect(provider.callCount == 2)
    }

    @Test func afterTheLastRetryTheLookupHasFailed() async {
        let provider = ScriptedSponsorBlock([busy])
        let recorder = SleepRecorder()

        #expect(await fetch(provider, recorder) == .failed)
        // The first try and two retries, and no more.
        #expect(provider.callCount == 3)
        #expect(recorder.durations == [.seconds(3), .seconds(10)])
    }

    @Test func theDelaysAreTheCallersToChoose() async {
        let provider = ScriptedSponsorBlock([busy])
        let recorder = SleepRecorder()

        let outcome = await SegmentLookup.fetch(
            videoID: "v",
            from: provider,
            retryDelays: [.milliseconds(5)],
            sleep: { try await recorder.sleep($0) }
        )

        #expect(outcome == .failed)
        #expect(provider.callCount == 2)
        #expect(recorder.durations == [.milliseconds(5)])
    }

    @Test func noRetryDelaysMeansASingleTry() async {
        let provider = ScriptedSponsorBlock([busy, .segments([sponsor])])

        let outcome = await SegmentLookup.fetch(videoID: "v", from: provider, retryDelays: [], sleep: { _ in })

        #expect(outcome == .failed)
        #expect(provider.callCount == 1)
    }

    @Test func theLookupAsksForTheVideoItWasGiven() async {
        final class Recording: SponsorBlockProviding, @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [String] = []
            var requested: [String] { lock.withLock { ids } }
            func segments(videoID: String) async throws -> [SponsorSegment] {
                lock.withLock { ids.append(videoID) }
                return []
            }
        }
        let provider = Recording()

        _ = await SegmentLookup.fetch(videoID: "aqz-KE-bpKQ", from: provider, sleep: { _ in })

        #expect(provider.requested == ["aqz-KE-bpKQ"])
    }

    // MARK: Cancellation

    @Test func aCancelledSleepEndsTheLookupAtOnce() async {
        let provider = ScriptedSponsorBlock([busy, .segments([sponsor])])

        let outcome = await SegmentLookup.fetch(videoID: "v", from: provider, sleep: { _ in throw CancellationError() })

        #expect(outcome == .failed)
        #expect(provider.callCount == 1)
    }

    @Test func aCancelledTaskDoesNotRetry() async {
        let provider = ScriptedSponsorBlock([busy, .segments([sponsor])])
        let recorder = SleepRecorder()

        let outcome = await Task { () -> SegmentLookup.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SegmentLookup.fetch(videoID: "v", from: provider, sleep: { try await recorder.sleep($0) })
        }.value

        #expect(outcome == .failed)
        #expect(provider.callCount == 1)
        #expect(recorder.durations.isEmpty)
    }
}
