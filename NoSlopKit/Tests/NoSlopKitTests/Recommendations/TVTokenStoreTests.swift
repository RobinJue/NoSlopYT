import Foundation
import Testing
@testable import NoSlopKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func credentials(access: String, refresh: String = "tvsynthetic_refresh", name: String? = nil) -> TVCredentials {
    TVCredentials(
        accessToken: access, refreshToken: refresh, expiresAt: t0.addingTimeInterval(3599), scope: "tvsynthetic_scope",
        clientID: "tvsynthetic_client", clientSecret: "tvsynthetic_secret", accountName: name, connectedAt: t0
    )
}

@Suite struct TVTokenStoreTests {
    @Test func theInMemoryStoreRoundTrips() throws {
        let store = InMemoryTVTokenStore()
        #expect(try store.load() == nil)
        let value = credentials(access: "tvsynthetic_a1", name: "Synthetic")
        try store.save(value)
        #expect(try store.load() == value)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }

    @Test func theServiceNameIsTheDocumentedOne() {
        #expect(TVKeychain.service == "com.robinjungerich.noslopyt.youtube-tv")
        #expect(TVKeychain.service != "com.robinjungerich.noslopyt.google")
    }

    @Test func credentialsSurviveEncodingExactly() throws {
        let value = credentials(access: "tvsynthetic_a2", name: nil)
        let back = try JSONDecoder().decode(TVCredentials.self, from: JSONEncoder().encode(value))
        #expect(back == value)
    }
}

/// The real Keychain (the macOS login keychain in `swift test`), under a unique service name per test.
/// Set `NOSLOP_SKIP_KEYCHAIN_TESTS=1` to skip where the Keychain asks for a password.
@Suite(.enabled(if: TVKeychainAvailability.isUsable, "The Keychain is not usable in this environment."), .timeLimit(.minutes(2)))
struct TVTokenStoreKeychainTests {
    @Test func saveLoadClearRoundTrip() throws {
        let store = KeychainTVTokenStore(service: "com.robinjungerich.noslopyt.tests.tv.\(UUID().uuidString)")
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let first = credentials(access: "tvsynthetic_k1")
        try store.save(first)
        #expect(try store.load() == first)
        let second = credentials(access: "tvsynthetic_k2", name: "Synthetic")
        try store.save(second)
        #expect(try store.load() == second)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }
}

private enum TVKeychainAvailability {
    static let isUsable: Bool = {
        if ProcessInfo.processInfo.environment["NOSLOP_SKIP_KEYCHAIN_TESTS"] == "1" { return false }
        let store = KeychainTVTokenStore(service: "com.robinjungerich.noslopyt.tests.tv.probe.\(UUID().uuidString)")
        defer { try? store.clear() }
        let probe = credentials(access: "tvsynthetic_probe")
        do {
            try store.save(probe)
            return try store.load() == probe
        } catch {
            return false
        }
    }()
}
