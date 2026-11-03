import Foundation

/// Persists the InnerTube `visitorData` token in `UserDefaults`.
///
/// STUB (Task 1A). Task 2 owns this file: `load` returns nil and `save` does nothing until it is filled in.
public final class UserDefaultsVisitorDataStore: VisitorDataStoring, @unchecked Sendable {
    public init(defaults: UserDefaults = .standard, key: String = "noslop.visitorData") {}

    public func load() -> (value: String, fetchedAt: Date)? {
        nil
    }

    public func save(value: String, fetchedAt: Date) {}
}

/// Keeps the `visitorData` token in memory only (tests, previews).
///
/// STUB (Task 1A). Task 2 owns this file.
public final class InMemoryVisitorDataStore: VisitorDataStoring, @unchecked Sendable {
    public init() {}

    public func load() -> (value: String, fetchedAt: Date)? {
        nil
    }

    public func save(value: String, fetchedAt: Date) {}
}
