import Foundation

/// Splits a file of known size into HTTP Range chunks (10 MiB by default).
///
/// STUB (Task 1A). Task 7 owns this file: returns no ranges until it is filled in.
public enum ChunkPlanner {
    public static func ranges(totalBytes: Int64, chunkSize: Int64 = 10_485_760) -> [ClosedRange<Int64>] {
        []
    }
}
