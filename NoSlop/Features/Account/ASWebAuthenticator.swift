import AuthenticationServices
import Foundation
import NoSlopKit

/// PLACEHOLDER (Task 1B). Task 9 owns this file and implements it with `ASWebAuthenticationSession`
/// (custom-scheme callback, non-ephemeral, key-window presentation anchor, `.canceledLogin` -> `.cancelled`).
/// The type name and the `WebAuthenticating` conformance are final.
@MainActor
final class ASWebAuthenticator: WebAuthenticating {
    init() {}

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        throw NoSlopError.notImplemented("ASWebAuthenticator.authenticate")
    }
}
