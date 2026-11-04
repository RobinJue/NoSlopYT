import Foundation

/// Every failure the kit surfaces. Messages are short, plain sentences that the UI can show as-is.
public enum NoSlopError: Error, Equatable, Sendable, LocalizedError {
    /// A stub that the owning task has not filled in yet. The payload is "<Type>.<member>".
    case notImplemented(String)
    case network(String)
    case http(status: Int)
    case decoding(String)
    /// YouTube asked the client to prove it is not a bot (`LOGIN_REQUIRED` on `player`).
    case botCheck
    case unplayable(reason: String)
    case notSignedIn
    case googleNotConfigured
    case oauth(String)
    case quotaExceeded
    /// The Google project behind the OAuth client has not turned the YouTube Data API on (or did so a moment ago: it
    /// takes a minute to spread). Sign-in works without it, so the first failure the owner meets is a plain 403;
    /// this case says what to do about it.
    case dataAPINotEnabled
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what):
            return "\(what) is not implemented yet."
        case .network:
            return "Can't reach YouTube. Check your connection."
        case .http(let status):
            return "YouTube returned an error (HTTP \(status))."
        case .decoding:
            return "Couldn't read the response from YouTube."
        case .botCheck:
            return "YouTube asked to confirm you're not a bot. Try again in a minute, or open the video on YouTube."
        case .unplayable(let reason):
            return reason
        case .notSignedIn:
            return "Sign in with Google to use this."
        case .googleNotConfigured:
            return "Add your Google OAuth client ID in Settings → Account first."
        case .oauth(let message):
            return Self.oauthDescription(message)
        case .quotaExceeded:
            return "YouTube's daily API quota for your Google project is used up. Try again tomorrow."
        case .dataAPINotEnabled:
            return "The YouTube Data API isn't turned on for your Google project. In Google Cloud, open APIs & Services \u{2192} Library, enable \u{201C}YouTube Data API v3\u{201D}, wait a minute, then try again."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// The text of `.oauth(message)`. The message is either a bare reason from Google or from the redirect
    /// ("access_denied", "state mismatch", "invalid_client: The OAuth client was not found."), which reads as a detail
    /// of "Google sign-in failed (...).", or already a sentence of its own ("YouTube access wasn't granted. Sign in
    /// again and allow access to your YouTube account.", "The sign-in page could not be opened."), which is shown as
    /// it is: in brackets it would end in ".).".
    private static func oauthDescription(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, let last = text.last, first.isUppercase, ".!?".contains(last) {
            return text
        }
        // Google's own descriptions end in a full stop; the one after the bracket is the sentence's.
        let detail = text.hasSuffix(".") ? String(text.dropLast()) : text
        return detail.isEmpty ? "Google sign-in failed." : "Google sign-in failed (\(detail))."
    }

    /// Whether the failure of the subscription import that follows a successful sign-in should be shown to the viewer.
    ///
    /// The sign-in itself worked and the screens show the account, so only a failure that will keep happening, and
    /// that the viewer can do something about, deserves an alert: the Data API is not enabled, the quota is used up,
    /// Google refuses. Left quiet are the failures that explain themselves or mend themselves: the session ended
    /// (`notSignedIn`: the screens already turn to "Sign in"), the connection dropped (`network`: the next sync at
    /// launch or on pull to refresh brings the subscriptions) and a cancelled import (nobody is waiting).
    public static func isWorthShowingAfterSignIn(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        switch error as? NoSlopError {
        case .notSignedIn, .network, .cancelled:
            return false
        default:
            return true
        }
    }
}
