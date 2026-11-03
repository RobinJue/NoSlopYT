import Foundation
import Security

/// Keeps the Google credentials in the Keychain.
///
/// One generic-password item per `service`, account "credentials", whose data is the JSON-encoded
/// `StoredCredentials`. The item is readable after the first unlock (so background work can refresh tokens) and is
/// neither synchronised to iCloud nor shared with other apps.
///
/// On macOS this uses the login keychain (the data-protection keychain needs an entitlement a command-line test
/// process does not have); on iOS the same calls use the app's own keychain.
public final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()  // makes "update, else add" one step within this process

    private static let account = "credentials"

    public init(service: String = "com.robinjungerich.noslopyt.google") {
        self.service = service
    }

    /// The stored credentials; nil when there are none. Throws when the Keychain cannot be read, or when the item is
    /// not valid credentials (a later `save` replaces it).
    public func load() throws -> StoredCredentials? {
        try lock.withLock {
            var query = identity
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data,
                      let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data)
                else { throw NoSlopError.decoding("The stored Google credentials are unreadable.") }
                return credentials
            case errSecItemNotFound:
                return nil
            default:
                throw Self.error(for: status)
            }
        }
    }

    public func save(_ credentials: StoredCredentials) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw NoSlopError.decoding("The Google credentials could not be encoded.")
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
                    // Another writer added the item between our update and our add: update theirs.
                    status = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
                }
            }
            guard status == errSecSuccess else { throw Self.error(for: status) }
        }
    }

    /// Removes the item. Clearing when there is nothing stored is not an error.
    public func clear() throws {
        try lock.withLock {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
        }
    }

    /// The attributes that identify the item.
    private var identity: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
        ]
    }

    private static func error(for status: OSStatus) -> NoSlopError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
        return .oauth("Keychain: \(message) (\(status))")
    }
}

/// Keeps the Google credentials in memory (tests, previews).
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: StoredCredentials?

    public init(_ initial: StoredCredentials? = nil) {
        self.credentials = initial
    }

    public func load() throws -> StoredCredentials? {
        lock.withLock { credentials }
    }

    public func save(_ credentials: StoredCredentials) throws {
        lock.withLock { self.credentials = credentials }
    }

    public func clear() throws {
        lock.withLock { credentials = nil }
    }
}
