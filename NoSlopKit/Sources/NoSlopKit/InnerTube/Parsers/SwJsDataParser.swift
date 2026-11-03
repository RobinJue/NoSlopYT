import Foundation

/// Extracts `visitorData` from the `GET https://www.youtube.com/sw.js_data` response.
///
/// The body starts with the anti-hijacking prefix `)]}'` and then holds a JSON array. The token sits at
/// `[0][2][0][0][13]`. If YouTube moves it, the first string anywhere that looks like a token is used, and if the
/// JSON itself cannot be read the raw text is scanned for a quoted token. Tokens are returned percent-decoded.
public enum SwJsDataParser {
    public static func visitorData(from text: String) -> String? {
        let body = withoutXSSIPrefix(text)
        guard let json = try? JSON(data: Data(body.utf8)) else {
            return firstQuotedToken(in: body).map(decoded)
        }
        if let usual = json[0]?[2]?[0]?[0]?[13]?.string, isPlausibleInPlace(usual) {
            return decoded(usual)
        }
        return firstToken(in: json).map(decoded)
    }

    /// A token as the rest of the kit wants it: percent-decoded, or nil when the text cannot be a token.
    /// Used for the `visitor_id` fallback, whose answer arrives percent-encoded ("…%3D%3D").
    static func normalizedToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleInPlace(trimmed) else { return nil }
        return decoded(trimmed)
    }

    // MARK: Helpers

    private static func withoutXSSIPrefix(_ text: String) -> Substring {
        var body = Substring(text).drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if body.hasPrefix(")]}'") {
            body = body.dropFirst(4)
        }
        return body
    }

    private static func decoded(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }

    /// At the expected position any token-like string is trusted: letters, digits and the few symbols that
    /// base64 and percent-encoding use. Text with spaces or brackets (a user agent, a URL) is not.
    private static func isPlausibleInPlace(_ candidate: String) -> Bool {
        !candidate.isEmpty && candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-%=+/.".contains($0)) }
    }

    /// `^Cg[A-Za-z0-9_%-]{20,}$`: what the tokens YouTube has issued so far look like.
    private static func isTokenShaped(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("Cg"), candidate.count >= 22 else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "%" || $0 == "-") }
    }

    /// The first string in the document (arrays in order, object keys sorted) that is token-shaped.
    private static func firstToken(in json: JSON) -> String? {
        switch json {
        case .string(let value):
            return isTokenShaped(value) ? value : nil
        case .array(let values):
            for value in values {
                if let found = firstToken(in: value) { return found }
            }
            return nil
        case .object(let object):
            for key in object.keys.sorted() {
                if let value = object[key], let found = firstToken(in: value) { return found }
            }
            return nil
        case .number, .bool, .null:
            return nil
        }
    }

    /// For text that is not valid JSON (cut off, say): the first token-shaped string between two quote marks.
    private static func firstQuotedToken(in text: Substring) -> String? {
        let pieces = text.split(separator: "\"", omittingEmptySubsequences: false)
        // Odd pieces are inside quotes; a piece with nothing after it was never closed and may be cut short.
        for index in stride(from: 1, to: pieces.count - 1, by: 2) where isTokenShaped(String(pieces[index])) {
            return String(pieces[index])
        }
        return nil
    }
}
