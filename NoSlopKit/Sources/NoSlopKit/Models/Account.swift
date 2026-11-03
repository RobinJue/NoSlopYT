import Foundation

public struct GoogleAccount: Codable, Hashable, Sendable {
    public var id: String
    public var email: String?
    public var name: String?
    public var pictureURL: URL?

    public init(id: String, email: String? = nil, name: String? = nil, pictureURL: URL? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.pictureURL = pictureURL
    }
}

public struct OAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public var idToken: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date,
        scope: String? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.idToken = idToken
    }

    /// True once `now` is within `leeway` seconds of (or past) `expiresAt`.
    public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}

/// What the Keychain holds: the OAuth client the tokens belong to, the tokens, and the signed-in account.
public struct StoredCredentials: Codable, Hashable, Sendable {
    public var clientID: String
    public var tokens: OAuthTokens
    public var account: GoogleAccount

    public init(clientID: String, tokens: OAuthTokens, account: GoogleAccount) {
        self.clientID = clientID
        self.tokens = tokens
        self.account = account
    }
}

public enum VideoRating: String, Codable, Sendable {
    case like, dislike, none
}
