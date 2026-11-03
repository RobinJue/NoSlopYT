import Foundation

/// Splits a file of known size into HTTP Range chunks (10 MiB by default).
///
/// googlevideo throttles a plain GET of a stream to about 30 KB/s but serves 8-10 MiB `Range` requests at full line
/// speed, so every download is a list of these ranges, one URLSession task each.
public enum ChunkPlanner {
    /// The default chunk size: 10 MiB.
    static let defaultChunkSize: Int64 = 10_485_760

    /// Contiguous, inclusive byte ranges that cover `0..<totalBytes`, each `chunkSize` bytes long except the last.
    /// Empty for a size of zero or less. A `chunkSize` of zero or less means the default.
    public static func ranges(totalBytes: Int64, chunkSize: Int64 = 10_485_760) -> [ClosedRange<Int64>] {
        guard totalBytes > 0 else { return [] }
        let size = chunkSize > 0 ? chunkSize : defaultChunkSize

        var result: [ClosedRange<Int64>] = []
        var start: Int64 = 0
        while start < totalBytes {
            // `start + size` could overflow for absurd sizes, so compare against what is left instead.
            let end = totalBytes - start > size ? start + size - 1 : totalBytes - 1
            result.append(start...end)
            start = end + 1
        }
        return result
    }
}
