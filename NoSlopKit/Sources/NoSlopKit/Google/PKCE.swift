import CryptoKit
import Foundation

/// PKCE (RFC 7636) verifier and S256 challenge.
public enum PKCE {
    /// 64 random characters from `[A-Za-z0-9-._~]`, from the system's secure random source.
    public static func makeVerifier() -> String {
        GoogleRandom.string(length: 64)
    }

    /// base64url(SHA-256(ASCII verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        GoogleBase64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}
