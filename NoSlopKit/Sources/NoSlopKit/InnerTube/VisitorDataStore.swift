import Foundation

/// Persists the InnerTube `visitorData` token in `UserDefaults`, so a relaunch within its lifetime needs no request.
///
/// Stored as one dictionary (`value`, `fetchedAt` as seconds since 1970) under a single key; anything that does not
/// have that shape reads as "nothing stored".
public final class UserDefaultsVisitorDataStore: VisitorDataStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "noslop.visitorData") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> (value: String, fetchedAt: Date)? {
        guard let stored = defaults.dictionary(forKey: key),
              let value = stored["value"] as? String, !value.isEmpty,
              let seconds = stored["fetchedAt"] as? Double else { return nil }
        return (value, Date(timeIntervalSince1970: seconds))
    }

    public func save(value: String, fetchedAt: Date) {
        defaults.set(["value": value, "fetchedAt": fetchedAt.timeIntervalSince1970], forKey: key)
    }
}

/// Keeps the `visitorData` token in memory only (tests, previews).
public final class InMemoryVisitorDataStore: VisitorDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (value: String, fetchedAt: Date)?

    public init() {}

    public func load() -> (value: String, fetchedAt: Date)? {
        lock.withLock { stored }
    }

    public func save(value: String, fetchedAt: Date) {
        lock.withLock { stored = (value, fetchedAt) }
    }
}
