import Foundation

/// A first-in, first-out gate that lets a few tasks at a time into a section of code and makes the rest wait.
///
/// It exists for media exports. `AVAssetExportSession.export(to:as:)` does not suspend while it sets the export up: it
/// blocks the thread it was called on until CoreMedia's queue, which every export in the process shares, lets it
/// through. Called from Swift concurrency, that thread belongs to the cooperative pool, which has as many threads as the
/// device has cores. Downloads that finish at about the same time start their merges at about the same time, and with
/// enough exports waiting at once every pool thread is inside one of them: the pool has no thread left for anything
/// else, and CoreMedia, waiting for work that needs one of those threads, never answers. Exports therefore go through
/// `ExportGate.shared`, which lets two of them run at a time.
///
/// Waiting is cancellable. A task that is cancelled while it waits leaves the line at once and `acquire()` throws
/// `CancellationError`; it never holds a permit, so a cancelled or deleted download neither keeps one nor leaks one.
actor ExportGate {
    /// How many exports of the whole process run at once.
    static let defaultPermits = 2

    /// The gate every media export of the process goes through.
    static let shared = ExportGate(permits: defaultPermits)

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let permits: Int
    private var available: Int
    /// In the order they asked.
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init(permits: Int) {
        self.permits = max(1, permits)
        self.available = max(1, permits)
    }

    /// How many exports this gate lets run at once. Read-only; mostly for tests.
    var capacity: Int { permits }

    /// Permits nobody holds. Mostly for tests.
    var availablePermits: Int { available }

    /// Tasks that are waiting for a permit. Mostly for tests.
    var waitingCount: Int { waiters.count }

    /// Takes a permit, waiting for one when all are taken. Every successful call needs a `release()`.
    ///
    /// - Throws: `CancellationError` when the task is cancelled before it has a permit, or while it waits for one. A
    ///   task that is cancelled after it was given its permit still has it.
    func acquire() async throws {
        try Task.checkCancellation()
        // A permit is available only while nobody waits: `release()` hands a permit to the first waiter before it makes
        // one available, so a newcomer can never get ahead of the line.
        if available > 0 {
            available -= 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // Runs on whichever thread cancelled the task, so it cannot touch the line itself.
            Task { await self.abandon(waiterID: id) }
        }
    }

    /// Gives a permit back: to the first waiter if there is one, else to the gate.
    func release() {
        if waiters.isEmpty {
            available = min(permits, available + 1)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// A waiter's task was cancelled: it leaves the line and its `acquire()` throws. Nothing happens when the waiter was
    /// given a permit in the meantime (it keeps it and gives it back as usual) or has left already.
    private func abandon(waiterID: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Runs `operation` while holding a permit, and gives the permit back however `operation` ends: with a value, with
    /// an error or by being cancelled. Waits for the permit first (and throws `CancellationError` if the task is
    /// cancelled while it waits, without running `operation`).
    nonisolated func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        let result: Result<T, any Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        await release()
        return try result.get()
    }
}
