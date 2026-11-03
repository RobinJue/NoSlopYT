import Foundation

/// Identifies one chunk download inside a URLSession task (stored in `URLSessionTask.taskDescription`).
///
/// STUB (Task 1A). Task 7 owns this file: `encoded` is empty and `init?(encoded:)` fails until it is filled in.
public struct DownloadTaskDescriptor: Hashable, Sendable {
    public enum Stream: String, Sendable {
        case video
        case audio
    }

    public var itemID: String
    public var stream: Stream
    public var chunkIndex: Int

    public init(itemID: String, stream: Stream, chunkIndex: Int) {
        self.itemID = itemID
        self.stream = stream
        self.chunkIndex = chunkIndex
    }

    /// "<itemID>|<stream>|<chunkIndex>"
    public var encoded: String {
        ""
    }

    public init?(encoded: String) {
        return nil
    }
}
