import Foundation

/// The Google OAuth client a sign-in uses, and the URLs derived from it: the app's own project by default, or the
/// client ID the user pasted into Settings after choosing their own project (`effectiveClientID`).
///
/// This is an iOS-type OAuth client: a public client, so there is no client secret anywhere. Its redirect URI is the
/// reversed client ID as a URL scheme, which `ASWebAuthenticationSession` catches without registering the scheme.
public struct GoogleOAuthConfig: Sendable, Hashable {
    public let clientID: String

    /// The iOS-type OAuth client of the author's Google project, which signs people in unless they choose their own
    /// project (Settings > Account > "Use my own Google project"). A client ID is public by design (this is a public
    /// client with no secret), so it belongs in the source. Empty while that project is not set up: a sign-in then needs
    /// a client ID of the user's own, as it did before there was a shared one.
    public static let sharedClientID = "652844062890-2i0d4kn1692pkqrq2i749m9h6ri9c3ke.apps.googleusercontent.com"

    /// Whether there is a shared project to sign in with.
    public static var hasSharedProject: Bool {
        GoogleOAuthConfig(clientID: sharedClientID) != nil
    }

    /// The client ID a sign-in uses: the shared project's, unless the user chose their own project or there is no shared
    /// one. The user's own is trimmed and not checked here (`init?(clientID:)` does that).
    public static func effectiveClientID(useOwnProject: Bool, ownClientID: String) -> String {
        let own = ownClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return useOwnProject || !hasSharedProject ? own : sharedClientID
    }

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

    /// The scope that matters: without it the YouTube Data API refuses every account call.
    static let youTubeScope = "https://www.googleapis.com/auth/youtube"

    public static let scopes: [String] = [
        "openid",
        "email",
        "profile",
        youTubeScope,
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
