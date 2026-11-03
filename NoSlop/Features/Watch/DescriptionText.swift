import Foundation
import NoSlopKit

/// Builds the `AttributedString` of an expanded video description.
///
/// Every link of the description becomes a `noslop-description://<index>` link, where `<index>` is the position of
/// the `DescriptionLink` in `description.links`; the view maps a tapped URL back to its target with
/// `target(for:in:)`. That keeps one code path for timestamps, videos, channels, playlists, hashtags and web
/// addresses, and lets the screen decide what each one does.
///
/// Link ranges come from a parser reading YouTube's pages, so they are checked, not trusted: a range that is empty,
/// reversed, outside the text, or that splits a character is skipped and the text stays plain.
nonisolated enum DescriptionText {
    static let linkScheme = "noslop-description"

    static func attributedString(for description: AttributedDescription) -> AttributedString {
        var result = AttributedString(description.text)
        for (index, link) in description.links.enumerated() {
            guard let range = attributedRange(for: link.range, in: description.text, of: result) else { continue }
            result[range].link = URL(string: "\(linkScheme)://\(index)")
        }
        return result
    }

    /// The target of a link made by `attributedString(for:)`; nil for any other URL.
    static func target(for url: URL, in description: AttributedDescription) -> DescriptionLink.Target? {
        guard url.scheme == linkScheme,
              let host = url.host(percentEncoded: false),
              let index = Int(host),
              description.links.indices.contains(index) else { return nil }
        return description.links[index].target
    }

    /// The `noslop://watch?v=<id>&t=<seconds>` link the app's own URL handling understands; it looks up the video's
    /// title and channel, which a description link does not carry.
    static func watchLink(id: String, startSeconds: Int?) -> URL? {
        var components = URLComponents()
        components.scheme = "noslop"
        components.host = "watch"
        var items = [URLQueryItem(name: "v", value: id)]
        if let startSeconds {
            items.append(URLQueryItem(name: "t", value: String(startSeconds)))
        }
        components.queryItems = items
        return components.url
    }

    /// The search text for a hashtag target, with exactly one leading "#".
    static func hashtagQuery(_ tag: String) -> String {
        "#" + tag.drop(while: { $0 == "#" })
    }

    /// UTF-16 offsets (what the parser counts in) to a range of the attributed string.
    private static func attributedRange(
        for offsets: Range<Int>,
        in text: String,
        of attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let utf16 = text.utf16
        guard offsets.lowerBound >= 0, offsets.lowerBound < offsets.upperBound, offsets.upperBound <= utf16.count else {
            return nil
        }
        let lower = utf16.index(utf16.startIndex, offsetBy: offsets.lowerBound)
        let upper = utf16.index(utf16.startIndex, offsetBy: offsets.upperBound)
        // An offset between the two halves of a surrogate pair (an emoji) is not a position in the text.
        guard lower.samePosition(in: text.unicodeScalars) != nil,
              upper.samePosition(in: text.unicodeScalars) != nil else { return nil }
        return Range(lower..<upper, in: attributed)
    }
}
