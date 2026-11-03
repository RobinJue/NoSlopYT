import Foundation

/// A small in-memory cache whose entries expire `ttl` seconds after they were inserted.
/// When it grows past `maxEntries`, expired entries go first, then the oldest ones.
public actor TTLCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        var value: Value
        var expiresAt: Date
        var sequence: Int
    }

    private let ttl: TimeInterval
    private let maxEntries: Int
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var insertions = 0

    /// - Parameter now: the clock; tests inject their own to advance time.
    public init(ttl: TimeInterval, maxEntries: Int = 200, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.maxEntries = max(1, maxEntries)
        self.now = now
    }

    /// The cached value, or nil when there is none or it has expired (expired entries are dropped).
    public func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        if now() >= entry.expiresAt {
            entries[key] = nil
            return nil
        }
        return entry.value
    }

    /// Stores `value` for `key`, restarting its time to live.
    public func insert(_ value: Value, for key: Key) {
        let current = now()
        insertions += 1
        entries[key] = Entry(value: value, expiresAt: current.addingTimeInterval(ttl), sequence: insertions)
        evictIfNeeded(at: current)
    }

    public func removeAll() {
        entries.removeAll()
    }

    private func evictIfNeeded(at current: Date) {
        guard entries.count > maxEntries else { return }
        entries = entries.filter { $0.value.expiresAt > current }
        let overflow = entries.count - maxEntries
        guard overflow > 0 else { return }
        let oldest = entries.sorted { $0.value.sequence < $1.value.sequence }.prefix(overflow)
        for (key, _) in oldest {
            entries[key] = nil
        }
    }
}
