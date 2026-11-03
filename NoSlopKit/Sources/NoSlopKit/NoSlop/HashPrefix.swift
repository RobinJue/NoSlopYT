import CryptoKit
import Foundation

/// SHA-256 hash prefixes for the privacy-preserving SponsorBlock and DeArrow lookups: the servers only ever see the
/// first few hex characters of the hash of a video id, never the id itself.
public enum HashPrefix {
    private static let hexDigits = Array("0123456789abcdef")

    /// The first `length` lowercase hex characters (0...64) of the SHA-256 of the UTF-8 bytes of `value`.
    public static func sha256Prefix(_ value: String, length: Int = 4) -> String {
        let count = min(max(length, 0), 64)
        guard count > 0 else { return "" }
        var hex = ""
        hex.reserveCapacity(count + 1)
        for byte in SHA256.hash(data: Data(value.utf8)).prefix((count + 1) / 2) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(hex.prefix(count))
    }
}
