import Foundation

/// Identifies one chunk download inside a URLSession task (stored in `URLSessionTask.taskDescription`).
///
/// A background session outlives the process, so after a relaunch the task description is the only thing that says
/// which item, stream and chunk a finished task belongs to.
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
        "\(itemID)|\(stream.rawValue)|\(chunkIndex)"
    }

    /// Parses `encoded` back. Fails for anything that is not exactly three parts with a known stream and a
    /// non-negative decimal chunk index. The two trailing parts are split off from the right, so an item id that
    /// itself contains "|" still round-trips.
    public init?(encoded: String) {
        guard let indexSeparator = encoded.lastIndex(of: "|") else { return nil }
        let indexText = encoded[encoded.index(after: indexSeparator)...]
        let head = encoded[..<indexSeparator]
        guard let streamSeparator = head.lastIndex(of: "|") else { return nil }
        let streamText = head[head.index(after: streamSeparator)...]
        let itemID = head[..<streamSeparator]

        guard !itemID.isEmpty,
              let stream = Stream(rawValue: String(streamText)),
              !indexText.isEmpty,
              indexText.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let chunkIndex = Int(indexText)
        else { return nil }

        self.init(itemID: String(itemID), stream: stream, chunkIndex: chunkIndex)
    }
}
