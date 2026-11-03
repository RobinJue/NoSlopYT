import Foundation
import Testing
@testable import NoSlopKit

@Suite struct DescriptorTests {
    @Test func descriptorRoundTrip() {
        let d = DownloadTaskDescriptor(itemID: "dQw4w9WgXcQ-720", stream: .video, chunkIndex: 3)
        #expect(d.encoded == "dQw4w9WgXcQ-720|video|3")
        #expect(DownloadTaskDescriptor(encoded: d.encoded) == d)
    }

    @Test func audioStreamRoundTrip() {
        let d = DownloadTaskDescriptor(itemID: "jNQXAC9IVRw-audio", stream: .audio, chunkIndex: 0)
        #expect(d.encoded == "jNQXAC9IVRw-audio|audio|0")
        #expect(DownloadTaskDescriptor(encoded: "jNQXAC9IVRw-audio|audio|0") == d)
    }

    @Test func largeChunkIndexRoundTrips() {
        let d = DownloadTaskDescriptor(itemID: "abc-360", stream: .video, chunkIndex: 12_345)
        #expect(DownloadTaskDescriptor(encoded: d.encoded)?.chunkIndex == 12_345)
    }

    @Test func itemIDsContainingTheSeparatorSurvive() {
        let d = DownloadTaskDescriptor(itemID: "odd|id|with|bars-720", stream: .audio, chunkIndex: 7)
        #expect(DownloadTaskDescriptor(encoded: d.encoded) == d)
    }

    @Test(arguments: [
        "",
        "dQw4w9WgXcQ-720",
        "dQw4w9WgXcQ-720|video",
        "dQw4w9WgXcQ-720|video|",
        "dQw4w9WgXcQ-720|video|x",
        "dQw4w9WgXcQ-720|video|-1",
        "dQw4w9WgXcQ-720|video|+1",
        "dQw4w9WgXcQ-720|video|1.5",
        "dQw4w9WgXcQ-720|movie|1",
        "dQw4w9WgXcQ-720|Video|1",
        "|video|1",
        "dQw4w9WgXcQ-720|video|99999999999999999999",
    ])
    func malformedStringsAreRejected(encoded: String) {
        #expect(DownloadTaskDescriptor(encoded: encoded) == nil)
    }

    @Test func differentChunksAreDifferentKeys() {
        let a = DownloadTaskDescriptor(itemID: "x-720", stream: .video, chunkIndex: 1)
        let b = DownloadTaskDescriptor(itemID: "x-720", stream: .video, chunkIndex: 2)
        let c = DownloadTaskDescriptor(itemID: "x-720", stream: .audio, chunkIndex: 1)
        #expect(Set([a, b, c, a]).count == 3)
    }
}
