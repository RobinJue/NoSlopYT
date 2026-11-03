import Foundation

/// Recognises YouTube links (and the app's own `noslop://` links) without touching the network.
///
/// STUB (Task 1A). Task 2 owns this file: both functions return nil until it is filled in.
public enum YouTubeURL {
    /// What `url` points at, when that can be decided locally (a handle like `/@name` needs the network and gives nil).
    public static func resolveLocally(_ url: URL) -> ResolvedURL? {
        nil
    }

    /// The first link found in free text, e.g. a pasted share message.
    public static func extractURL(from text: String) -> URL? {
        nil
    }
}
