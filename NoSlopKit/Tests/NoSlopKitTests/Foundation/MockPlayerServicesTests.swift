import Foundation
import Testing
@testable import NoSlopKit

/// The services a playing video asks (stream info, SponsorBlock, captions) can lose their connection in a simulator run, so
/// that a download plays with nothing but what it kept (`-offlinePlayerServices`). And the fetcher that keeps the extras
/// of a download works with them.
@Suite struct MockPlayerServicesTests {
    private let videoID = "aqz-KE-bpKQ"

    /// Runs `call` and records an issue unless it fails with `NoSlopError.network`.
    private func expectNetworkError(_ call: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await call()
            Issue.record("expected a network error", sourceLocation: sourceLocation)
        } catch NoSlopError.network {
            // as expected
        } catch {
            Issue.record("expected a network error, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func theThreeServicesFailWhileTheConnectionIsOffAndWorkWhenItComesBack() async throws {
        let connection = MockConnection(isOnline: false)
        let streams = MockStreamResolver(delay: .zero, connection: connection)
        let sponsorBlock = MockSponsorBlock(delay: .zero, connection: connection)
        let captions = MockCaptions(delay: .zero, connection: connection)
        let track = try #require(SampleData.captionTracks(for: videoID).first)

        await expectNetworkError { _ = try await streams.streamInfo(videoID: videoID) }
        await expectNetworkError { _ = try await sponsorBlock.segments(videoID: videoID) }
        await expectNetworkError { _ = try await captions.cues(for: track) }

        connection.isOnline = true
        #expect(try await streams.streamInfo(videoID: videoID).videoID == videoID)
        #expect(try await sponsorBlock.segments(videoID: videoID) == SampleData.segments)
        #expect(try await captions.cues(for: track) == SampleData.captionCues)

        connection.isOnline = false
        await expectNetworkError { _ = try await sponsorBlock.segments(videoID: videoID) }
    }

    @Test func theFlakySponsorBlockMockFailsOfflineToo() async throws {
        let connection = MockConnection(isOnline: false)
        let sponsorBlock = MockSponsorBlock(delay: .zero, failingFirst: 1, connection: connection)
        await expectNetworkError { _ = try await sponsorBlock.segments(videoID: videoID) }
        connection.isOnline = true
        // The failure that was owed is still owed: the offline lookup did not use it up.
        await expectNetworkError { _ = try await sponsorBlock.segments(videoID: videoID) }
        #expect(try await sponsorBlock.segments(videoID: videoID) == SampleData.segments)
    }

    @Test func mocksWithoutAConnectionAreAlwaysOnline() async throws {
        #expect(try await MockStreamResolver(delay: .zero).streamInfo(videoID: videoID).videoID == videoID)
        #expect(try await MockSponsorBlock(delay: .zero).segments(videoID: videoID) == SampleData.segments)
        #expect(try await MockSponsorBlock(delay: .zero, failingFirst: 0).segments(videoID: videoID) == SampleData.segments)
        let track = try #require(SampleData.captionTracks(for: videoID).first)
        #expect(try await MockCaptions(delay: .zero).cues(for: track) == SampleData.captionCues)
    }

    // MARK: The fetcher on the mocks

    @Test func theFetcherKeepsWhatTheMocksHaveForAVideo() async {
        let fetcher = DownloadExtrasFetcher(
            sponsorBlock: MockSponsorBlock(delay: .zero),
            youTube: MockYouTubeService(delay: .zero),
            captions: MockCaptions(delay: .zero)
        )
        let extras = await fetcher.extras(for: SampleData.streamInfo(for: videoID))

        #expect(extras.segments == SampleData.segments)
        #expect(extras.chapters == SampleData.chapters, "from the watch page")
        #expect(extras.captions?.map(\.track.id) == ["en-std", "en-asr"], "the written track first")
        #expect(extras.captions?.allSatisfy { $0.cues == SampleData.captionCues } == true)
    }

    @Test func theFetcherKeepsNothingFromMocksThatAreOffline() async {
        let connection = MockConnection(isOnline: false)
        let fetcher = DownloadExtrasFetcher(
            sponsorBlock: MockSponsorBlock(delay: .zero, connection: connection),
            youTube: MockYouTubeService(delay: .zero, connection: connection),
            captions: MockCaptions(delay: .zero, connection: connection)
        )
        let extras = await fetcher.extras(for: SampleData.streamInfo(for: videoID))
        #expect(extras.isEmpty)
    }

    @Test func aVideoWithoutChaptersKnowsItHasNone() async throws {
        // Chapters are for videos of three minutes or more; the Short has none.
        let short = try #require(SampleData.videos.first { $0.isShort })
        let fetcher = DownloadExtrasFetcher(
            sponsorBlock: MockSponsorBlock(delay: .zero),
            youTube: MockYouTubeService(delay: .zero),
            captions: MockCaptions(delay: .zero)
        )
        let extras = await fetcher.extras(for: SampleData.streamInfo(for: short.id))
        #expect(extras.chapters == [])
    }
}
