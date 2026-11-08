import Foundation
import Testing

/// Limits how many tests run an AVFoundation export (`AVAssetExportSession`) at the same time.
///
/// `AVAssetExportSession.export(to:as:)` does not suspend while it sets the export up: it blocks the calling thread
/// until CoreMedia's queue, which every export in the process shares, lets it through. Called from Swift concurrency,
/// that thread is one of the cooperative pool, which has as many threads as the machine has cores. Exports that
/// overlapped therefore kept pool threads away from everything else, and the download tests (about eighty of them, all
/// started at once, most of them muxing the same two fixture files) overlap completely:
///
/// - The other tests starved. This was one of the reasons for the 5 to 7 seconds that `HomeFeedServiceTests`'s 300 ms
///   timeout took in a full run: for seconds, every thread of the pool was waiting inside an export.
/// - With enough overlap the test run hung for good. In a hung process all ten pool threads were inside
///   `AVAssetExportSession.export`, waiting for the shared queue, and that queue was itself waiting in
///   `FigReadSchedulerExpediteRequest` for a read that never completed. `DownloadManagerTests` alone hung in twelve of
///   twelve runs on an idle ten-core machine.
///
/// The app is protected on its own now: `MediaMuxer.mux` takes a permit of `ExportGate.shared` (two at a time, for the
/// whole process), and `MediaMuxerConcurrencyTests` exercises that gate without this trait. This trait is a second,
/// test-side limit: it keeps the many download tests from all being active at once and queueing behind those two
/// permits. A few exports at a time are fine here (the default is half the cores, at most four, so that threads stay
/// free for everyone else), and so is one after the other. `NOSLOP_TEST_EXPORTS=<n>` sets another number, for
/// experiments.
actor MediaExportGate {
    static let shared = MediaExportGate(permits: configuredPermits)

    private static var configuredPermits: Int {
        if let value = ProcessInfo.processInfo.environment["NOSLOP_TEST_EXPORTS"], let permits = Int(value) {
            return permits
        }
        return min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        available = max(1, permits)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// A test (or every test of a suite) that runs exports, directly or through a `DownloadManager`: it holds one permit
/// of the `MediaExportGate` while it runs. Waiting for a permit suspends the test; no thread is blocked.
struct LimitsMediaExports: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // Suites and test functions only contain test cases; the cases are what runs exports.
        guard testCase != nil else {
            try await function()
            return
        }
        await MediaExportGate.shared.acquire()
        do {
            try await function()
        } catch {
            await MediaExportGate.shared.release()
            throw error
        }
        await MediaExportGate.shared.release()
    }
}

extension Trait where Self == LimitsMediaExports {
    static var limitsMediaExports: Self { Self() }
}
