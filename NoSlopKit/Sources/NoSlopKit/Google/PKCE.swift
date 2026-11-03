import Foundation

/// PKCE (RFC 7636) verifier and S256 challenge.
///
/// STUB (Task 1A). Task 5 owns this file: both functions return an empty string until it is filled in.
public enum PKCE {
    /// 64 random characters from `[A-Za-z0-9-._~]`.
    public static func makeVerifier() -> String {
        ""
    }

    /// base64url(SHA-256(ASCII verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        ""
    }
}
