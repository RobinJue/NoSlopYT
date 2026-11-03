import Foundation

/// The Google OAuth client the user pasted into Settings, and the URLs derived from it.
///
/// STUB (Task 1A). Task 5 owns this file: `init?` returns nil and the derived strings are empty until it is
/// filled in. `scopes` is already final.
public struct GoogleOAuthConfig: Sendable, Hashable {
    public let clientID: String

    /// Trims `clientID`; fails unless it ends with ".apps.googleusercontent.com".
    public init?(clientID: String) {
        return nil
    }

    /// "com.googleusercontent.apps.<prefix>"
    public var redirectScheme: String {
        ""
    }

    /// `redirectScheme` + ":/oauth2redirect"
    public var redirectURI: String {
        ""
    }

    public static let scopes: [String] = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/youtube",
    ]

    public func authorizationURL(state: String, codeChallenge: String) -> URL {
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    }
}
