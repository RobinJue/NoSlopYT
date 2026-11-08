import Foundation

// The seams of the optional YouTube recommendations connection (YouTube's TV sign-in). The Google (Data API) sign-in has
// its own seam in `Services.swift`; the two are separate and neither changes the other.

/// The account behind the TV connection, as far as it is known.
public struct TVAccount: Sendable, Equatable {
    /// The account's name when YouTube told it (best effort), else nil.
    public let name: String?
    public let connectedAt: Date

    public init(name: String?, connectedAt: Date) {
        self.name = name
        self.connectedAt = connectedAt
    }
}

/// What the viewer needs to approve the sign-in on another page. The device code stays inside the auth service.
public struct TVSignInPrompt: Sendable {
    /// The code to type on the page, as the server wrote it ("ABC-DEF-GHI").
    public let userCode: String
    /// The page to open, with the code already in it.
    public let verificationURL: URL
    public let expiresAt: Date

    public init(userCode: String, verificationURL: URL, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
    }
}

/// The TV connection: sign in with a code, hand out tokens, disconnect. Conforms to `TVTokenProviding`, so `TVClient`
/// can ask it for every request.
public protocol RecommendationsAuthProviding: TVTokenProviding {
    /// The connected account from the Keychain, without any network traffic; nil when not connected.
    func currentAccount() async -> TVAccount?
    func beginSignIn() async throws -> TVSignInPrompt
    /// Waits until the viewer has approved the code (polling), then stores the tokens. Honours cancellation.
    func completeSignIn(_ prompt: TVSignInPrompt) async throws -> TVAccount
    /// Seconds until the access token expires; nil when not connected.
    func secondsLeft() async -> Int?
    /// Revokes the grant (best effort) and clears the stored credentials whatever the servers answer.
    /// - Returns: whether a revoke endpoint answered 200.
    func disconnect() async -> Bool
}
