import Testing
@testable import NoSlopKit

@Suite struct MockSponsorBlockTests {
    @Test func theDefaultMockAlwaysAnswers() async throws {
        let mock = MockSponsorBlock(delay: .zero)

        for _ in 0..<3 {
            #expect(try await mock.segments(videoID: "aqz-KE-bpKQ") == SampleData.segments)
        }
    }

    @Test func aFlakyMockFailsItsFirstLookupsAndAnswersAfterwards() async throws {
        let mock = MockSponsorBlock(delay: .zero, failingFirst: 2)

        for _ in 0..<2 {
            await #expect(throws: NoSlopError.self) {
                _ = try await mock.segments(videoID: "aqz-KE-bpKQ")
            }
        }
        #expect(try await mock.segments(videoID: "aqz-KE-bpKQ") == SampleData.segments)
        #expect(try await mock.segments(videoID: "aqz-KE-bpKQ") == SampleData.segments)
    }

    @Test func theFailuresAreCountedAcrossCopiesOfTheMock() async throws {
        let mock = MockSponsorBlock(delay: .zero, failingFirst: 1)
        let copy = mock

        await #expect(throws: NoSlopError.self) {
            _ = try await mock.segments(videoID: "v")
        }
        // The copy shares the count: the one failure is used up.
        #expect(try await copy.segments(videoID: "v") == SampleData.segments)
    }

    @Test func noFailuresMeansAnAlwaysWorkingMock() async throws {
        for count in [0, -3] {
            let mock = MockSponsorBlock(delay: .zero, failingFirst: count)
            #expect(try await mock.segments(videoID: "v") == SampleData.segments, "failingFirst \(count)")
        }
    }
}
