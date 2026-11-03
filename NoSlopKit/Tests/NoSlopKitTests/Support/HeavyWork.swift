import Foundation

/// Runs CPU-heavy synchronous test work at utility priority on a task of its own and returns its result.
///
/// Swift Testing starts every test and every test case at once, and a synchronous test body keeps the thread of the
/// cooperative pool it runs on until it returns. Tests that sweep megabyte-sized fixtures through every parser for
/// seconds therefore leave the timers, continuations and polling loops of all the other tests waiting in the pool's
/// queue: next to such a sweep a test with a 300 ms timeout was measured at 4 to 6 seconds (0.3 s on its own).
///
/// Work that runs at utility priority is served by a cooperative queue of its own, so the default-priority queue (where
/// the tests themselves and everything they await run) stays responsive, and the system favours default-priority
/// threads whenever the cores are busy. Use it for a test body that takes more than a few hundred milliseconds
/// without ever awaiting.
func heavyWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: work).value
}
