import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

/// The gate every media export goes through (see `ExportGate`): how many get in at once, in what order, and what
/// happens to a waiter that gives up. Each test builds a gate of its own, so nothing here touches the shared one.
@Suite(.timeLimit(.minutes(1))) struct ExportGateTests {
    /// Polls until `condition` holds (true) or the time runs out (false). The gate is an actor, so every look is an await.
    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    private struct Boom: Error {}

    /// How many tasks are inside at once, and the most there ever were.
    private final class Occupancy: Sendable {
        private struct State {
            var current = 0
            var peak = 0
        }

        private let state = Mutex(State())

        func enter() { state.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) } }
        func leave() { state.withLock { $0.current -= 1 } }
        var peak: Int { state.withLock { $0.peak } }
    }

    /// The numbers in the order they were added.
    private final class Order: Sendable {
        private let numbers = Mutex<[Int]>([])

        func add(_ number: Int) { numbers.withLock { $0.append(number) } }
        var all: [Int] { numbers.withLock { $0 } }
    }

    // MARK: How many

    @Test func theSharedGateLetsTwoExportsRunAtOnce() {
        #expect(ExportGate.defaultPermits == 2)
    }

    @Test func atMostTwoAreInsideAtOnce() async throws {
        let gate = ExportGate(permits: 2)
        let occupancy = Occupancy()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.withPermit {
                        occupancy.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        occupancy.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(occupancy.peak >= 1 && occupancy.peak <= 2, "peak \(occupancy.peak)")
        #expect(await gate.availablePermits == 2)
        #expect(await gate.waitingCount == 0)
    }

    @Test func twoHoldAPermitAtOnceAndTheThirdWaitsForOneToCome() async throws {
        let gate = ExportGate(permits: 2)
        try await gate.acquire()
        try await gate.acquire()
        #expect(await gate.availablePermits == 0)

        let third = Task { try await gate.acquire() }
        #expect(await eventually { await gate.waitingCount == 1 })

        await gate.release()
        try await third.value
        #expect(await gate.waitingCount == 0)
        #expect(await gate.availablePermits == 0, "the permit went straight to the waiter")

        await gate.release()
        await gate.release()
        #expect(await gate.availablePermits == 2)
    }

    @Test func aGateAlwaysHasAtLeastOnePermit() async throws {
        let gate = ExportGate(permits: 0)
        #expect(await gate.availablePermits == 1)
        try await gate.acquire()
        #expect(await gate.availablePermits == 0)
    }

    @Test func givingBackMorePermitsThanWereTakenAddsNone() async {
        let gate = ExportGate(permits: 2)
        await gate.release()
        await gate.release()
        #expect(await gate.availablePermits == 2)
    }

    // MARK: In what order

    @Test func waitersAreServedInTheOrderTheyArrived() async throws {
        let gate = ExportGate(permits: 1)
        try await gate.acquire()   // the test holds the only permit
        let order = Order()
        var tasks: [Task<Void, any Error>] = []
        for number in 1...5 {
            tasks.append(Task {
                try await gate.withPermit { order.add(number) }
            })
            // Each one is in line before the next one asks.
            #expect(await eventually { await gate.waitingCount == number })
        }
        await gate.release()
        for task in tasks { try await task.value }
        #expect(order.all == [1, 2, 3, 4, 5])
        #expect(await gate.availablePermits == 1)
    }

    @Test func aNewcomerDoesNotJumpTheQueue() async throws {
        let gate = ExportGate(permits: 1)
        try await gate.acquire()
        let order = Order()
        let first = Task { try await gate.withPermit { order.add(1) } }
        #expect(await eventually { await gate.waitingCount == 1 })

        // The permit is handed to the first waiter; a task that asks right after finds none available.
        await gate.release()
        let second = Task { try await gate.withPermit { order.add(2) } }
        try await first.value
        try await second.value
        #expect(order.all == [1, 2])
    }

    // MARK: Giving up

    @Test func aCancelledWaiterLeavesTheQueueWithoutTakingAPermit() async throws {
        let gate = ExportGate(permits: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        #expect(await eventually { await gate.waitingCount == 1 })

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.waitingCount == 0)
        #expect(await gate.availablePermits == 0, "the permit is still the test's: the waiter never had it")

        // Giving it back makes it available again, and the next one does not have to wait.
        await gate.release()
        #expect(await gate.availablePermits == 1)
        try await gate.acquire()
        #expect(await gate.availablePermits == 0)
    }

    @Test func aCancelledWaiterInTheMiddleDoesNotChangeTheOrderOfTheOthers() async throws {
        let gate = ExportGate(permits: 1)
        try await gate.acquire()
        let order = Order()
        var tasks: [Task<Void, any Error>] = []
        for number in 1...3 {
            tasks.append(Task {
                try await gate.withPermit { order.add(number) }
            })
            #expect(await eventually { await gate.waitingCount == number })
        }

        tasks[1].cancel()
        await #expect(throws: CancellationError.self) { try await tasks[1].value }
        #expect(await gate.waitingCount == 2)

        await gate.release()
        try await tasks[0].value
        try await tasks[2].value
        #expect(order.all == [1, 3])
        #expect(await gate.availablePermits == 1)
    }

    @Test func aTaskThatWasCancelledBeforeAskingTakesNoPermit() async throws {
        let gate = ExportGate(permits: 1)
        let start = DownloadTestGate()
        let task = Task {
            await start.opened()
            try await gate.acquire()
        }
        task.cancel()
        start.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.availablePermits == 1, "a permit was free, and the cancelled task still did not take it")
        #expect(await gate.waitingCount == 0)
    }

    // MARK: Giving back

    @Test func thePermitComesBackWhateverHappensInside() async throws {
        let gate = ExportGate(permits: 1)

        // An error.
        await #expect(throws: Boom.self) { try await gate.withPermit { throw Boom() } }
        #expect(await gate.availablePermits == 1)

        // A cancellation while inside.
        let inside = Task { try await gate.withPermit { try await Task.sleep(for: .seconds(60)) } }
        #expect(await eventually { await gate.availablePermits == 0 })
        inside.cancel()
        await #expect(throws: CancellationError.self) { try await inside.value }
        #expect(await gate.availablePermits == 1)

        // A result.
        let value = try await gate.withPermit { 42 }
        #expect(value == 42)
        #expect(await gate.availablePermits == 1)
    }

    @Test func cancellingWhilePermitsAreGivenOutLeaksNothing() async throws {
        // Waiters give up at the same moment as the permits they wait for come back. Whichever way each race goes, every
        // permit ends up with the gate and nobody is left in line.
        for _ in 0..<50 {
            let gate = ExportGate(permits: 2)
            try await gate.acquire()
            try await gate.acquire()
            var waiters: [Task<Void, any Error>] = []
            for _ in 0..<6 {
                waiters.append(Task { try await gate.withPermit { await Task.yield() } })
            }
            #expect(await eventually { await gate.waitingCount == 6 })

            for index in [1, 3, 4] { waiters[index].cancel() }
            await gate.release()
            await gate.release()
            for waiter in waiters { _ = await waiter.result }

            #expect(await gate.availablePermits == 2)
            #expect(await gate.waitingCount == 0)
        }
    }
}
