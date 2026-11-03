import Foundation

/// Keeps the Google credentials in the Keychain.
///
/// STUB (Task 1A). Task 5 owns this file: every member throws `NoSlopError.notImplemented`.
public final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    public init(service: String = "com.robinjungerich.noslopyt.google") {}

    public func load() throws -> StoredCredentials? {
        throw NoSlopError.notImplemented("KeychainTokenStore.load")
    }

    public func save(_ credentials: StoredCredentials) throws {
        throw NoSlopError.notImplemented("KeychainTokenStore.save")
    }

    public func clear() throws {
        throw NoSlopError.notImplemented("KeychainTokenStore.clear")
    }
}

/// Keeps the Google credentials in memory (tests, previews).
///
/// STUB (Task 1A). Task 5 owns this file: every member throws `NoSlopError.notImplemented`.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    public init(_ initial: StoredCredentials? = nil) {}

    public func load() throws -> StoredCredentials? {
        throw NoSlopError.notImplemented("InMemoryTokenStore.load")
    }

    public func save(_ credentials: StoredCredentials) throws {
        throw NoSlopError.notImplemented("InMemoryTokenStore.save")
    }

    public func clear() throws {
        throw NoSlopError.notImplemented("InMemoryTokenStore.clear")
    }
}
