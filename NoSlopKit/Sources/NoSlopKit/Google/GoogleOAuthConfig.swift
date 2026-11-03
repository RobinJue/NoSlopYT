import Foundation

/// The Google OAuth client the user pasted into Settings, and the URLs derived from it.
///
/// This is an iOS-type OAuth client: a public client, so there is no client secret anywhere. Its redirect URI is the
/// reversed client ID as a URL scheme, which `ASWebAuthenticationSession` catches without registering the scheme.
public struct GoogleOAuthConfig: Sendable, Hashable {
    public let clientID: String

    private static let clientIDSuffix = ".apps.googleusercontent.com"
    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    /// Trims `clientID`; fails unless it ends with ".apps.googleusercontent.com" and what comes before that can be
    /// part of a URL scheme (letters, digits, "-", ".", "_"; at least one character).
    public init?(clientID: String) {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.clientIDSuffix) else { return nil }
        let prefix = trimmed.dropLast(Self.clientIDSuffix.count)
        guard !prefix.isEmpty, prefix.allSatisfy(Self.isSchemeCharacter) else { return nil }
        self.clientID = trimmed
    }

    private static func isSchemeCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "." || character == "_")
    }

    /// "com.googleusercontent.apps.<prefix>"
    public var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.dropLast(Self.clientIDSuffix.count)
    }

    /// `redirectScheme` + ":/oauth2redirect"
    public var redirectURI: String {
        redirectScheme + ":/oauth2redirect"
    }

    public static let scopes: [String] = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/youtube",
    ]

    /// The consent page URL for an authorization-code flow with PKCE (S256). Values are fully percent-encoded.
    public func authorizationURL(state: String, codeChallenge: String) -> URL {
        let query = GoogleURLEncoding.queryString([
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", Self.scopes.joined(separator: " ")),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ])
        // Every character in the query is ASCII and percent-encoded, so this URL always parses; the fallback is unreachable.
        return URL(string: "\(Self.authorizationEndpoint)?\(query)") ?? URL(string: Self.authorizationEndpoint)!
    }
}
