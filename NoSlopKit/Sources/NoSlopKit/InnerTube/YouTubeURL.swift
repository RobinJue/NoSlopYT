import Foundation

/// Recognises YouTube links (and the app's own `noslop://` links) without touching the network.
///
/// `resolveLocally` answers only when the link itself says what it points at: a video id, a channel id (`UC…`),
/// a playlist id or a search. Links that need YouTube to look something up (`/@handle`, `/c/name`, `/user/name`) and
/// links with a malformed id give nil, so the caller can ask `YouTubeService.resolve(url:)`.
public enum YouTubeURL {
    /// What `url` points at, when that can be decided locally (a handle like `/@name` needs the network and gives nil).
    public static func resolveLocally(_ url: URL) -> ResolvedURL? {
        switch url.scheme?.lowercased() {
        case "noslop": return resolveAppLink(url)
        case "http", "https": return resolveWebLink(url)
        default: return nil
        }
    }

    /// The first link found in free text, e.g. a pasted share message. Only web links (`http`, `https`) and the
    /// app's own `noslop://` links count; email addresses and the like are not links here.
    public static func extractURL(from text: String) -> URL? {
        // A link needs a dot ("youtu.be/…") or a colon ("https://…"); this keeps ordinary searches off the detector.
        guard text.contains(".") || text.contains(":") else { return nil }
        let window = text.count > scanLimit ? String(text.prefix(scanLimit)) : text

        let range = NSRange(window.startIndex..., in: window)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: window, options: [], range: range) {
                if let url = match.url, isWebOrAppLink(url) {
                    return url
                }
            }
        }
        // The detector only knows registered schemes, so the app's own links are found by hand.
        for token in window.split(whereSeparator: \.isWhitespace) where token.lowercased().hasPrefix("noslop://") {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>\"'"))
            if let url = URL(string: trimmed) {
                return url
            }
        }
        return nil
    }

    /// True for http(s) links on a YouTube host. Only these may be sent to YouTube's URL resolver.
    static func isYouTubeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = normalizedHost(url.host) else { return false }
        return isYouTubeHost(host) || isShortLinkHost(host)
    }

    // MARK: Web links

    private static let scanLimit = 4_096

    private static func resolveWebLink(_ url: URL) -> ResolvedURL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = normalizedHost(components.host) else { return nil }
        let segments = pathSegments(of: components)

        if isShortLinkHost(host) {
            guard let id = videoID(from: segments.first) else { return nil }
            return video(id: id, in: components)
        }
        guard isYouTubeHost(host), let keyword = segments.first?.lowercased() else { return nil }

        switch keyword {
        case "watch":
            if let id = videoID(from: queryValue("v", in: components)) {
                return video(id: id, in: components)
            }
            return token(from: queryValue("list", in: components)).map { .playlist(id: $0) }
        case "embed" where segments.dropFirst().first?.lowercased() == "videoseries":
            // "videoseries" has eleven valid characters, so it would pass for a video id.
            return token(from: queryValue("list", in: components)).map { .playlist(id: $0) }
        case "shorts", "live", "embed", "v", "e":
            guard let id = videoID(from: segments.dropFirst().first) else { return nil }
            return .video(id: id, startSeconds: startSeconds(in: components))
        case "channel":
            return channelID(from: segments.dropFirst().first).map { .channel(id: $0) }
        case "playlist":
            return token(from: queryValue("list", in: components)).map { .playlist(id: $0) }
        case "results":
            return searchText(in: components).map { .search(query: $0) }
        default:
            return nil
        }
    }

    // MARK: noslop:// links

    private static func resolveAppLink(_ url: URL) -> ResolvedURL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let segments = pathSegments(of: components)

        switch host {
        case "watch":
            guard let id = videoID(from: queryValue("v", in: components) ?? segments.first) else { return nil }
            return video(id: id, in: components)
        case "channel":
            // Only what is a channel id on a web link is one here too: "noslop://channel/notachannel" is no link.
            return channelID(from: segments.first ?? queryValue("id", in: components)).map { .channel(id: $0) }
        case "playlist":
            return token(from: segments.first ?? queryValue("list", in: components)).map { .playlist(id: $0) }
        case "search":
            guard let text = formValue("q", in: components) else { return nil }
            return .search(query: text)
        default:
            return nil
        }
    }

    // MARK: Hosts

    /// Lowercased, without a trailing dot ("www.youtube.com." is the same host).
    private static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    private static func isShortLinkHost(_ host: String) -> Bool {
        host == "youtu.be" || host.hasSuffix(".youtu.be")
    }

    private static func isWebOrAppLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "noslop": return true
        default: return false
        }
    }

    // MARK: Components

    private static func pathSegments(of components: URLComponents) -> [String] {
        components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    /// A video link: with a playlist when the link names one (`list=`), which then is the queue the video plays in.
    /// `index=` is not used: the position is found in the playlist itself.
    private static func video(id: String, in components: URLComponents) -> ResolvedURL {
        let start = startSeconds(in: components)
        if let list = token(from: queryValue("list", in: components)) {
            return .videoInPlaylist(id: id, startSeconds: start, playlistID: list)
        }
        return .video(id: id, startSeconds: start)
    }

    /// The text of a YouTube results page: "+" is a space in this form-encoded value, "%2B" a plus sign.
    private static func searchText(in components: URLComponents) -> String? {
        formValue("search_query", in: components)
    }

    /// A query value read as a form value: "+" is a space, "%2B" a plus sign. Blank is nil.
    private static func formValue(_ name: String, in components: URLComponents) -> String? {
        let raw = components.percentEncodedQueryItems?.first { $0.name == name }?.value
        let text = raw?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Ids

    private static func isIDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    /// A video id is exactly eleven id characters. Anything glued on behind them with a separator
    /// ("ID?feature=share", "ID&t=5") is ignored; more id characters than eleven make it no id at all.
    private static func videoID(from raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.prefix(while: isIDCharacter)
        return id.count == 11 ? String(id) : nil
    }

    /// A non-empty run of id characters, for playlist and channel ids.
    private static func token(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.allSatisfy(isIDCharacter) else { return nil }
        return raw
    }

    private static func channelID(from raw: String?) -> String? {
        guard let id = token(from: raw), id.hasPrefix("UC"), id.count > 2 else { return nil }
        return id
    }

    // MARK: Start times

    /// `t`, then `start` (embeds), then `time_continue`, then a `#t=` fragment; the first that parses wins.
    private static func startSeconds(in components: URLComponents) -> Int? {
        for name in ["t", "start", "time_continue"] {
            if let value = queryValue(name, in: components), let seconds = parseSeconds(value) {
                return seconds
            }
        }
        for pair in (components.fragment ?? "").split(separator: "&") where pair.hasPrefix("t=") {
            if let seconds = parseSeconds(String(pair.dropFirst(2))) {
                return seconds
            }
        }
        return nil
    }

    /// "42", "42s", "1m5s", "1h2m3s" (a bare number at the end counts as seconds) and "1:05" / "1:02:03".
    /// Anything else, a negative value or an overflow gives nil.
    private static func parseSeconds(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        return text.contains(":") ? clockSeconds(text) : unitSeconds(text)
    }

    private static func unitSeconds(_ text: String) -> Int? {
        let multipliers: [Character: Int] = ["h": 3_600, "m": 60, "s": 1]
        var total = 0
        var pending: Int?
        for character in text {
            if character.isASCII, let digit = character.wholeNumberValue {
                guard let value = appending(digit, to: pending ?? 0) else { return nil }
                pending = value
            } else if let multiplier = multipliers[character] {
                guard let value = pending else { return nil }
                let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: multiplier)
                let (sum, sumOverflow) = total.addingReportingOverflow(scaled)
                guard !scaleOverflow, !sumOverflow else { return nil }
                total = sum
                pending = nil
            } else {
                return nil
            }
        }
        if let value = pending {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private static func clockSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            let (scaled, scaleOverflow) = total.multipliedReportingOverflow(by: 60)
            let (sum, sumOverflow) = scaled.addingReportingOverflow(value)
            guard !scaleOverflow, !sumOverflow else { return nil }
            total = sum
        }
        return total
    }

    private static func appending(_ digit: Int, to value: Int) -> Int? {
        let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
        let (sum, sumOverflow) = scaled.addingReportingOverflow(digit)
        return scaleOverflow || sumOverflow ? nil : sum
    }
}
