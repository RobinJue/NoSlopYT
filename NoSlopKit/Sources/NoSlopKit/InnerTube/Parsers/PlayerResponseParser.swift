import Foundation

/// Turns a `player` response into a `StreamInfo`. The only parser that throws: playability errors
/// (`.botCheck`, `.unplayable`) are surfaced to the user.
///
/// STUB (Task 1A). Task 2 owns this file.
public enum PlayerResponseParser {
    public static func parse(_ json: JSON, now: Date) throws -> StreamInfo {
        throw NoSlopError.notImplemented("PlayerResponseParser.parse")
    }
}
