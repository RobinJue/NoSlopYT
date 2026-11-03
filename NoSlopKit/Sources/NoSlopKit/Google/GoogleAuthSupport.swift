import Foundation
import Security

// Internal helpers of the Google sign-in and Data API code. Every name starts with "Google" so none can clash with
// the helpers other parts of the kit declare. Nothing here logs or prints: the values passing through include tokens.

/// Cryptographically secure random strings.
enum GoogleRandom {
    /// The RFC 3986 "unreserved" characters: the alphabet PKCE verifiers (RFC 7636) and `state` values use.
    static let unreservedAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `length` random characters from `unreservedAlphabet`. Bytes come from the system's secure random source and
    /// are rejection-sampled, so every character is exactly equally likely.
    static func string(length: Int) -> String {
        guard length > 0 else { return "" }
        let alphabet = unreservedAlphabet
        // Bytes at or above the largest multiple of the alphabet size would favour the first characters; skip them.
        let limit = 256 - (256 % alphabet.count)
        var result = ""
        result.reserveCapacity(length)
        var count = 0
        while count < length {
            for byte in bytes(count: length * 2) where Int(byte) < limit {
                result.append(alphabet[Int(byte) % alphabet.count])
                count += 1
                if count == length { break }
            }
        }
        return result
    }

    /// `SecRandomCopyBytes`, falling back to Swift's system generator (also cryptographically secure on Apple
    /// platforms) in the practically impossible case that it fails.
    static func bytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        }
        return bytes
    }
}

/// RFC 3986 percent-encoding for query strings and `application/x-www-form-urlencoded` bodies.
enum GoogleURLEncoding {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Every UTF-8 byte outside the unreserved set (and outside `extraAllowed`) becomes `%XX`.
    static func percentEncode(_ value: String, keeping extraAllowed: Set<UInt8> = []) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if unreserved.contains(byte) || extraAllowed.contains(byte) {
                output.append(byte)
            } else {
                output.append(UInt8(ascii: "%"))
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// `name=value&name=value`, in the given order, with commas left readable (`part=snippet,contentDetails`).
    static func queryString(_ items: [(String, String)]) -> String {
        let comma = Set(",".utf8)
        return items
            .map { "\(percentEncode($0.0, keeping: comma))=\(percentEncode($0.1, keeping: comma))" }
            .joined(separator: "&")
    }

    /// The body of a form POST: every name and value fully percent-encoded.
    static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&").utf8)
    }
}

/// Base64url (RFC 4648, section 5) without padding, as used by PKCE challenges and JWTs.
enum GoogleBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts input with or without padding; nil when it is not valid base64url.
    static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 2: base64 += "=="
        case 3: base64 += "="
        default: return nil  // a single leftover character cannot be valid base64
        }
        return Data(base64Encoded: base64)
    }
}

enum GoogleURLs {
    /// `string` as an http(s) URL that has a host; nil for anything else (empty, garbage, relative, other schemes).
    static func web(_ string: String?) -> URL? {
        guard let string,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

/// Reading a `GoogleAccount` from OpenID Connect claims: the `id_token` payload or the userinfo response.
enum GoogleAccountParser {
    static func account(fromClaims claims: JSON) -> GoogleAccount? {
        guard let id = claims["sub"]?.string ?? claims["sub"]?.int.map(String.init), !id.isEmpty else { return nil }
        return GoogleAccount(
            id: id,
            email: nonEmpty(claims["email"]?.string),
            name: nonEmpty(claims["name"]?.string),
            pictureURL: GoogleURLs.web(claims["picture"]?.string)
        )
    }

    /// The account in the payload of `idToken`. The token is not verified: it came straight from Google's token
    /// endpoint over TLS (OpenID Connect Core, 3.1.3.7), and it is only used to show who is signed in.
    static func account(fromIDToken idToken: String?) -> GoogleAccount? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let payload = GoogleBase64URL.decode(String(segments[1])),
              let claims = try? JSON(data: payload),
              claims.object != nil
        else { return nil }
        return account(fromClaims: claims)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
