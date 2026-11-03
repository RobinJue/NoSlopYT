import Foundation
import Testing
@testable import NoSlopKit

@Suite struct ChunkPlannerTests {
    @Test func chunkRanges() {
        #expect(ChunkPlanner.ranges(totalBytes: 26_214_400) == [0...10_485_759, 10_485_760...20_971_519, 20_971_520...26_214_399])
        #expect(ChunkPlanner.ranges(totalBytes: 0).isEmpty)
    }

    @Test func exactMultipleHasNoEmptyTail() {
        #expect(ChunkPlanner.ranges(totalBytes: 20_971_520) == [0...10_485_759, 10_485_760...20_971_519])
        #expect(ChunkPlanner.ranges(totalBytes: 10_485_760) == [0...10_485_759])
    }

    @Test func fileSmallerThanOneChunkIsOneRange() {
        #expect(ChunkPlanner.ranges(totalBytes: 195_278) == [0...195_277])
        #expect(ChunkPlanner.ranges(totalBytes: 1) == [0...0])
        #expect(ChunkPlanner.ranges(totalBytes: 10_485_761) == [0...10_485_759, 10_485_760...10_485_760])
    }

    @Test func nothingToPlanForNegativeSizes() {
        #expect(ChunkPlanner.ranges(totalBytes: -1).isEmpty)
        #expect(ChunkPlanner.ranges(totalBytes: Int64.min).isEmpty)
    }

    @Test func customChunkSize() {
        #expect(ChunkPlanner.ranges(totalBytes: 10, chunkSize: 4) == [0...3, 4...7, 8...9])
        #expect(ChunkPlanner.ranges(totalBytes: 8, chunkSize: 4) == [0...3, 4...7])
        #expect(ChunkPlanner.ranges(totalBytes: 3, chunkSize: 4) == [0...2])
    }

    @Test func nonPositiveChunkSizeFallsBackToTheDefault() {
        #expect(ChunkPlanner.ranges(totalBytes: 26_214_400, chunkSize: 0) == ChunkPlanner.ranges(totalBytes: 26_214_400))
        #expect(ChunkPlanner.ranges(totalBytes: 100, chunkSize: -5) == [0...99])
    }

    @Test func rangesAreContiguousAndCoverTheWholeFile() {
        for total: Int64 in [1, 2, 9, 10, 11, 99, 100, 101, 12_345] {
            for size: Int64 in [1, 3, 10, 64, 1_000_000] {
                let ranges = ChunkPlanner.ranges(totalBytes: total, chunkSize: size)
                #expect(ranges.first?.lowerBound == 0)
                #expect(ranges.last?.upperBound == total - 1)
                for (previous, next) in zip(ranges, ranges.dropFirst()) {
                    #expect(next.lowerBound == previous.upperBound + 1)
                }
                for range in ranges.dropLast() {
                    #expect(range.upperBound - range.lowerBound + 1 == size)
                }
                #expect(ranges.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound + 1) } == total)
            }
        }
    }

    @Test func hugeSizesDoNotOverflow() {
        let big = ChunkPlanner.ranges(totalBytes: Int64.max, chunkSize: Int64.max / 2)
        #expect(big.count == 3)
        #expect(big.last?.upperBound == Int64.max - 1)
        let one = ChunkPlanner.ranges(totalBytes: Int64.max, chunkSize: Int64.max)
        #expect(one == [0...(Int64.max - 1)])
    }
}
