import AuthenticationServices
import Foundation
import NoSlopKit
import UIKit

/// Shows Google's sign-in page in the system web-authentication sheet and returns the URL it redirects to.
///
/// - The page runs in `ASWebAuthenticationSession` with a custom-scheme callback, never in an embedded web view.
/// - It uses the shared (non-ephemeral) browser session, so a user who is already signed in to Google in Safari
///   does not have to type a password again.
/// - Cancelling the sheet maps to `NoSlopError.cancelled`; any other failure to `NoSlopError.oauth`.
///
/// The system keeps only a weak reference to the presentation provider (this object), so whoever starts a sign-in
/// must keep the authenticator alive until it returns.
@MainActor
final class ASWebAuthenticator: NSObject, WebAuthenticating {
    private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        // A sign-in page that is still open from an earlier call is closed first.
        session?.cancel()
        defer { session = nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                // The completion handler and a failed `start()` must never both resume the continuation.
                let gate = ResumeGate()
                let authSession = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(callbackScheme)
                ) { @Sendable callbackURL, error in
                    gate.run {
                        if let callbackURL {
                            continuation.resume(returning: callbackURL)
                        } else {
                            continuation.resume(throwing: Self.failure(for: error))
                        }
                    }
                }
                authSession.presentationContextProvider = self
                authSession.prefersEphemeralWebBrowserSession = false
                self.session = authSession
                if !authSession.start() {
                    gate.run {
                        continuation.resume(throwing: NoSlopError.oauth("The sign-in page could not be opened."))
                    }
                }
            }
        } onCancel: {
            // The calling task went away: close the sheet. The session then reports `.canceledLogin`.
            Task { @MainActor in self.session?.cancel() }
        }
    }

    /// `.canceledLogin` is the user closing the sheet; everything else is a failure with the system's message.
    private nonisolated static func failure(for error: (any Error)?) -> NoSlopError {
        guard let error else {
            return .oauth("The sign-in page returned no result.")
        }
        if let sessionError = error as? ASWebAuthenticationSessionError, sessionError.code == .canceledLogin {
            return .cancelled
        }
        return .oauth(error.localizedDescription)
    }
}

extension ASWebAuthenticator: ASWebAuthenticationPresentationContextProviding {
    /// The key window of the foreground scene.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.filter { $0.activationState == .foregroundActive }
        for scene in foreground + scenes {
            if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
                return window
            }
        }
        // Unreachable while the app shows UI: the sign-in is started from a visible screen.
        return ASPresentationAnchor()
    }
}

/// Runs a block at most once; used so a checked continuation is resumed exactly once.
private nonisolated final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func run(_ block: () -> Void) {
        lock.lock()
        let shouldRun = !hasRun
        hasRun = true
        lock.unlock()
        if shouldRun { block() }
    }
}
