import Foundation

/// SHA-256 hash prefixes for the privacy-preserving SponsorBlock and DeArrow lookups.
///
/// STUB (Task 1A). Task 6 owns this file: returns an empty string until it is filled in.
public enum HashPrefix {
    /// The first `length` lowercase hex characters of the SHA-256 of `value`.
    public static func sha256Prefix(_ value: String, length: Int = 4) -> String {
        ""
    }
}
