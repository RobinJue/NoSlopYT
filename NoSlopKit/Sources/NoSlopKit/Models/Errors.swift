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
            return message.isEmpty ? "Google sign-in failed." : "Google sign-in failed (\(message))."
        case .quotaExceeded:
            return "YouTube's daily API quota for your Google project is used up. Try again tomorrow."
        case .cancelled:
            return "Cancelled."
        }
    }
}
