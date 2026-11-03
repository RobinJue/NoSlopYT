import Foundation
import NoSlopKit

/// What a text typed or pasted into the search field means: words to search for, or a link to open.
///
/// Only links to YouTube open directly: `youtube.com` and its subdomains (`www.`, `m.`, `music.`), `youtu.be`,
/// `youtube-nocookie.com`, and the app's own `noslop://` links. A domain anywhere else in the text is just part of
/// the words: "asp.net tutorial" and "vim.org tutorial" are searches. (`YouTubeURL.extractURL` reports the first link
/// of any host it finds, because it also serves pasted share messages. It does not say whether the link is one to open.)
nonisolated enum SearchInput: Equatable, Sendable {
    /// Search YouTube for this text.
    case search(String)
    /// A `noslop://` link to a tab or a screen of the app (`noslop://tab/library`, `noslop://route/settings`): open it.
    case appLink(URL)
    /// A YouTube link, or a `noslop://` link to a video, channel, playlist or search: find out what it points at.
    /// That can take the network (a `/@handle` has to be looked up) and may end in a search after all.
    case link(URL)

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = YouTubeURL.extractURL(from: trimmed) else {
            self = .search(trimmed)
            return
        }

        if url.scheme?.lowercased() == AppLink.scheme {
            switch AppLink(url: url) {
            case .tab, .route:
                self = .appLink(url)
            case .resolved, nil:
                // The kit knows what a video, channel, playlist or search link points at (and when the id is bad).
                self = YouTubeURL.resolveLocally(url) != nil ? .link(url) : .search(trimmed)
            }
        } else if Self.isYouTubeHost(of: url), Self.pointsSomewhere(url) {
            self = .link(url)
        } else {
            self = .search(trimmed)
        }
    }

    /// Hosts whose links open directly: YouTube and its subdomains (`m.`, `music.`), the short-link host and the
    /// embed host. Not look-alikes such as `notyoutube.com` or `youtube.com.example.org`.
    static func isYouTubeHost(of url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    /// A bare "youtube.com" (no path, no query) is a domain that was mentioned, not a link to anything.
    private static func pointsSomewhere(_ url: URL) -> Bool {
        let path = url.path
        return !(path.isEmpty || path == "/") || url.query != nil
    }
}
