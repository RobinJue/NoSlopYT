import Foundation

/// Google sign-in: authorization-code flow with PKCE, token refresh, sign-out.
///
/// STUB (Task 1A). Task 5 owns this file: there is no signed-in account, and `signIn` / `accessToken` throw
/// `NoSlopError.notImplemented`.
public actor GoogleOAuthService: GoogleAuthProviding {
    public init(http: any HTTPClient, store: any TokenStoring, now: @escaping @Sendable () -> Date = { Date() }) {}

    public func currentAccount() async -> GoogleAccount? {
        nil
    }

    public func signIn(clientID: String, authenticator: any WebAuthenticating) async throws -> GoogleAccount {
        throw NoSlopError.notImplemented("GoogleOAuthService.signIn")
    }

    public func signOut() async {}

    public func accessToken() async throws -> String {
        throw NoSlopError.notImplemented("GoogleOAuthService.accessToken")
    }
}
