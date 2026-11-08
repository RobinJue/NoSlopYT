import Foundation
import Security

/// Where the TV connection's Keychain item lives. Not the Google sign-in's service.
public enum TVKeychain {
    public static let service = "com.robinjungerich.noslopyt.youtube-tv"
}

/// What the TV connection keeps: its tokens and the client pair they belong to. Never printed: `description` shows no secrets.
public struct TVCredentials: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String
    public var clientID: String
    public var clientSecret: String
    public var accountName: String?
    public var connectedAt: Date

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String,
        clientID: String,
        clientSecret: String,
        accountName: String? = nil,
        connectedAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accountName = accountName
        self.connectedAt = connectedAt
    }

    public var description: String { "TVCredentials(...)" }
    public var debugDescription: String { "TVCredentials(...)" }
}

/// Storage for the TV credentials.
public protocol TVTokenStoring: Sendable {
    /// The stored credentials; nil when there are none.
    func load() throws -> TVCredentials?
    func save(_ credentials: TVCredentials) throws
    /// Removes them. Clearing when there is nothing stored is not an error.
    func clear() throws
}

/// Keeps the TV credentials in the Keychain: one generic-password item per `service`, account "credentials", whose data is
/// the JSON-encoded `TVCredentials`. Readable after the first unlock, neither synchronised to iCloud nor shared with other apps.
public final class KeychainTVTokenStore: TVTokenStoring, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    private static let account = "credentials"

    public init(service: String = TVKeychain.service) {
        self.service = service
    }

    public func load() throws -> TVCredentials? {
        try lock.withLock {
            var query = identity
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data,
                      let credentials = try? JSONDecoder().decode(TVCredentials.self, from: data)
                else { throw NoSlopError.decoding("The stored YouTube TV credentials are unreadable.") }
                return credentials
            case errSecItemNotFound:
                return nil
            default:
                throw Self.error(for: status)
            }
        }
    }

    public func save(_ credentials: TVCredentials) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw NoSlopError.decoding("The YouTube TV credentials could not be encoded.")
        }
        try lock.withLock {
            let changes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            var status = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                var item = identity
                item[kSecValueData] = data
                item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(item as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    status = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
                }
            }
            guard status == errSecSuccess else { throw Self.error(for: status) }
        }
    }

    public func clear() throws {
        try lock.withLock {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
        }
    }

    private var identity: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
        ]
    }

    private static func error(for status: OSStatus) -> NoSlopError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
        return .oauth("The Keychain refused (\(message)).")
    }
}

/// Keeps the TV credentials in memory (tests, previews).
public final class InMemoryTVTokenStore: TVTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: TVCredentials?

    public init(_ initial: TVCredentials? = nil) {
        self.credentials = initial
    }

    public func load() throws -> TVCredentials? {
        lock.withLock { credentials }
    }

    public func save(_ credentials: TVCredentials) throws {
        lock.withLock { self.credentials = credentials }
    }

    public func clear() throws {
        lock.withLock { credentials = nil }
    }
}
