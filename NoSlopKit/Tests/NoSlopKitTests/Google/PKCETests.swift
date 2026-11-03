import CryptoKit
import Foundation
import Testing
@testable import NoSlopKit

@Suite struct PKCETests {
    /// RFC 3986 unreserved characters: the only ones a PKCE verifier may contain (RFC 7636, section 4.1).
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let base64URLAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    @Test func rfc7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierShape() {
        let v = PKCE.makeVerifier()
        #expect(v.count == 64)
        #expect(v.allSatisfy { Self.unreserved.contains($0) })
    }

    @Test func everyVerifierIsDifferent() {
        let verifiers = Set((0..<50).map { _ in PKCE.makeVerifier() })
        #expect(verifiers.count == 50)
    }

    @Test func verifiersUseTheWholeUnreservedAlphabet() {
        // 20 x 64 characters. Missing a whole character class (for example the four punctuation marks, 4 of 66
        // symbols) has a probability far below 1e-30, so this only fails for a biased or truncated alphabet.
        let characters = (0..<20).map { _ in PKCE.makeVerifier() }.joined()
        #expect(characters.contains { $0.isASCII && $0.isUppercase })
        #expect(characters.contains { $0.isASCII && $0.isLowercase })
        #expect(characters.contains { $0.isASCII && $0.isNumber })
        #expect(characters.contains { "-._~".contains($0) })
    }

    @Test func challengeIsUnpaddedBase64URL() {
        let challenge = PKCE.challenge(for: PKCE.makeVerifier())
        #expect(challenge.count == 43)  // 32 digest bytes -> 43 characters without "=" padding
        #expect(challenge.allSatisfy { Self.base64URLAlphabet.contains($0) })
    }

    @Test func challengeIsTheSHA256OfTheASCIIVerifier() {
        let verifier = PKCE.makeVerifier()
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let expected = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(PKCE.challenge(for: verifier) == expected)
    }

    @Test func challengeIsDeterministicAndDiffersPerVerifier() {
        #expect(PKCE.challenge(for: "abc") == PKCE.challenge(for: "abc"))
        #expect(PKCE.challenge(for: "abc") != PKCE.challenge(for: "abd"))
        // SHA-256("abc") is the well-known ba7816bf...0015ad; its base64url form:
        #expect(PKCE.challenge(for: "abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
    }
}
