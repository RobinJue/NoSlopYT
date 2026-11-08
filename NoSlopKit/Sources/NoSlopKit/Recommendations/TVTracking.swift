import Foundation

/// The pieces of watch reporting that are plain functions: the page's signature timestamp, the tracking values of a signed
/// `player` reply and the ping URLs. A port of the Mac probe's `tvprobe/report.py`.
/// Nothing here is logged: the URLs carry `ei`, `vm` and `of`.
public enum TVTracking {
    public enum Kind: String, Sendable {
        case playback, watchtime
    }

    private static let cpnAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// The web player's signatureTimestamp: the first `"STS":<digits>` on the youtube.com home page.
    public static func signatureTimestamp(fromHomepage html: String) -> Int? {
        guard let match = html.firstMatch(of: /"STS":(\d+)/) else { return nil }
        return Int(match.1)
    }

    /// What the reporter needs from a `player` reply: its status and the two tracking base URLs, and whether `ei`, `vm`
    /// and `of` (non-empty) are in them.
    public static func values(fromPlayer reply: JSON) -> (
        status: String?, playbackURL: URL?, watchtimeURL: URL?, hasEI: Bool, hasVM: Bool, hasOF: Bool
    ) {
        let status = reply["playabilityStatus"]?["status"]?.string
        let playback = baseURL(reply, "videostatsPlaybackUrl")
        let watchtime = baseURL(reply, "videostatsWatchtimeUrl")
        var keys = Set<String>()
        for url in [playback, watchtime].compactMap({ $0 }) {
            for (name, value) in queryItems(of: url) where !value.isEmpty { keys.insert(name) }
        }
        return (status, playback, watchtime, keys.contains("ei"), keys.contains("vm"), keys.contains("of"))
    }

    /// Keeps every item of the base URL except the ones set here, sets the reporting items and sends the ping to
    /// www.youtube.com. Times have three decimals; `final=1` only when `final`.
    public static func pingURL(
        base: URL, kind: Kind, docid: String, length: Double, cpn: String, cmt: Double,
        st: Double?, et: Double?, final: Bool
    ) -> URL {
        var own: [(String, String)] = [
            ("ns", "yt"), ("ver", "2"), ("docid", docid), ("len", time(length)), ("cmt", time(cmt)), ("cpn", cpn),
        ]
        if let st { own.append(("st", time(st))) }
        if let et { own.append(("et", time(et))) }
        if final { own.append(("final", "1")) }
        let replaced = Set(own.map(\.0)).union(["final", "st", "et"])
        let items = queryItems(of: base).filter { !replaced.contains($0.0) } + own
        let query = items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: "https://www.youtube.com/api/stats/\(kind.rawValue)?\(query)")
            ?? URL(string: "https://www.youtube.com/api/stats/\(kind.rawValue)")!
    }

    /// A new client playback nonce: 16 characters of `A-Za-z0-9-_`.
    public static func newCPN() -> String {
        String((0..<16).map { _ in cpnAlphabet.randomElement()! })
    }

    // MARK: Private

    private static func time(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func baseURL(_ reply: JSON, _ key: String) -> URL? {
        guard let text = reply["playbackTracking"]?[key]?["baseUrl"]?.string, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// Like Python's `parse_qsl(keep_blank_values=True)`: `+` is a space, percent escapes are decoded, empty parts are skipped.
    private static func queryItems(of url: URL) -> [(String, String)] {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return [] }
        return query.split(separator: "&").compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = pieces.first, !name.isEmpty else { return nil }
            let value = pieces.count > 1 ? String(pieces[1]) : ""
            return (decode(String(name)), decode(value))
        }
    }

    private static func decode(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Like Python's `quote_plus`: letters, digits and `_.-~` stay, a space is `+`, everything else is percent-escaped.
    private static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                out += "+"
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
