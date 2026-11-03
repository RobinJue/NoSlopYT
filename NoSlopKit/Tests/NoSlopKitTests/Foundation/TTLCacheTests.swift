import Foundation
import Testing
@testable import NoSlopKit

/// A clock the tests can move. File-private so it cannot clash with helpers in other test files.
private final class TTLCacheTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@Suite struct TTLCacheTests {
    @Test func ttlCacheExpires() async {
        let clock = TTLCacheTestClock()
        let cache = TTLCache<String, Int>(ttl: 60, now: { clock.now })
        await cache.insert(1, for: "a")
        #expect(await cache.value(for: "a") == 1)
        clock.advance(by: 59)
        #expect(await cache.value(for: "a") == 1)
        clock.advance(by: 1)
        #expect(await cache.value(for: "a") == nil)
    }

    @Test func missingKeysAreNil() async {
        let cache = TTLCache<String, Int>(ttl: 60)
        #expect(await cache.value(for: "nothing") == nil)
    }

    @Test func insertingAgainReplacesTheValueAndRestartsTheClock() async {
        let clock = TTLCacheTestClock()
        let cache = TTLCache<String, String>(ttl: 60, now: { clock.now })
        await cache.insert("old", for: "k")
        clock.advance(by: 50)
        await cache.insert("new", for: "k")
        clock.advance(by: 50)
        #expect(await cache.value(for: "k") == "new")
        clock.advance(by: 10)
        #expect(await cache.value(for: "k") == nil)
    }

    @Test func entriesExpireIndependently() async {
        let clock = TTLCacheTestClock()
        let cache = TTLCache<String, Int>(ttl: 60, now: { clock.now })
        await cache.insert(1, for: "early")
        clock.advance(by: 40)
        await cache.insert(2, for: "late")
        clock.advance(by: 30)
        #expect(await cache.value(for: "early") == nil)
        #expect(await cache.value(for: "late") == 2)
    }

    @Test func removeAllEmptiesTheCache() async {
        let cache = TTLCache<Int, Int>(ttl: 60)
        await cache.insert(1, for: 1)
        await cache.insert(2, for: 2)
        await cache.removeAll()
        #expect(await cache.value(for: 1) == nil)
        #expect(await cache.value(for: 2) == nil)
    }

    @Test func dropsTheOldestEntriesBeyondMaxEntries() async {
        let cache = TTLCache<Int, Int>(ttl: 600, maxEntries: 3)
        for key in 1...5 {
            await cache.insert(key * 10, for: key)
        }
        #expect(await cache.value(for: 1) == nil)
        #expect(await cache.value(for: 2) == nil)
        #expect(await cache.value(for: 3) == 30)
        #expect(await cache.value(for: 4) == 40)
        #expect(await cache.value(for: 5) == 50)
    }

    @Test func evictionPrefersExpiredEntriesOverNewerOnes() async {
        let clock = TTLCacheTestClock()
        let cache = TTLCache<Int, Int>(ttl: 60, maxEntries: 2, now: { clock.now })
        await cache.insert(1, for: 1)
        clock.advance(by: 30)
        await cache.insert(2, for: 2)
        clock.advance(by: 40)            // key 1 has expired, key 2 has not
        await cache.insert(3, for: 3)    // over capacity: expired key 1 goes, not key 2
        #expect(await cache.value(for: 1) == nil)
        #expect(await cache.value(for: 2) == 2)
        #expect(await cache.value(for: 3) == 3)
    }

    @Test func reinsertingAKeyRefreshesItsAgeForEviction() async {
        let cache = TTLCache<Int, Int>(ttl: 600, maxEntries: 2)
        await cache.insert(1, for: 1)
        await cache.insert(2, for: 2)
        await cache.insert(11, for: 1)   // key 1 is now the newest
        await cache.insert(3, for: 3)    // evicts the oldest, key 2
        #expect(await cache.value(for: 1) == 11)
        #expect(await cache.value(for: 2) == nil)
        #expect(await cache.value(for: 3) == 3)
    }

    @Test func supportsConcurrentUse() async {
        let cache = TTLCache<Int, Int>(ttl: 600, maxEntries: 1000)
        await withTaskGroup(of: Void.self) { group in
            for key in 0..<200 {
                group.addTask {
                    await cache.insert(key, for: key)
                    _ = await cache.value(for: key)
                }
            }
        }
        #expect(await cache.value(for: 199) == 199)
        #expect(await cache.value(for: 0) == 0)
    }
}
