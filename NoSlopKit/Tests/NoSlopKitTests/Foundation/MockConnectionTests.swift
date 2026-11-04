import Foundation
import Testing
@testable import NoSlopKit

/// The mocks that back simulator runs can lose their connection and get it back, and the feed mocks remember the feed
/// they built last, as the real service does. The browse screens' offline states are checked with them.
@Suite struct MockConnectionTests {
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

    // MARK: The YouTube mock

    @Test func youTubeCallsFailWhileTheConnectionIsOffAndWorkWhenItComesBack() async throws {
        let connection = MockConnection(isOnline: false)
        let service = MockYouTubeService(delay: .zero, connection: connection)

        await expectNetworkError { _ = try await service.search(query: "blender", filter: SearchFilter()) }
        await expectNetworkError { _ = try await service.videoDetails(id: "aqz-KE-bpKQ") }
        await expectNetworkError { _ = try await service.suggestions(for: "blender") }
        await expectNetworkError { _ = try await service.channel(id: SampleData.blender.id) }

        connection.isOnline = true
        #expect(try await service.search(query: "blender", filter: SearchFilter()).items.isEmpty == false)
        #expect(try await service.videoDetails(id: "aqz-KE-bpKQ").id == "aqz-KE-bpKQ")

        connection.isOnline = false
        await expectNetworkError { _ = try await service.search(query: "blender", filter: SearchFilter()) }
    }

    @Test func aMockWithoutAConnectionIsAlwaysOnline() async throws {
        let service = MockYouTubeService(delay: .zero)
        #expect(try await service.videoDetails(id: "aqz-KE-bpKQ").id == "aqz-KE-bpKQ")
    }

    // MARK: The subscription feed

    @Test func theSubscriptionFeedRemembersTheFeedItBuiltLast() async throws {
        let feed = MockSubscriptionFeed(delay: .zero)
        let blender = SubscribedChannel(id: SampleData.blender.id, name: "Blender")
        #expect(await feed.cachedFeed().isEmpty)

        let built = try await feed.feed(channels: [blender], forceRefresh: false)

        #expect(!built.isEmpty)
        #expect(await feed.cachedFeed() == built)
        // A feed for no channels is an empty feed, as in the real service.
        _ = try await feed.feed(channels: [], forceRefresh: false)
        #expect(await feed.cachedFeed().isEmpty)
    }

    @Test func theSubscriptionFeedCanStartWithAFeedFromAnEarlierSession() async throws {
        let older = Array(SampleData.videos(forChannel: SampleData.blender.id).dropFirst())
        let feed = MockSubscriptionFeed(delay: .zero, cached: older)
        #expect(await feed.cachedFeed() == older)

        let blender = SubscribedChannel(id: SampleData.blender.id, name: "Blender")
        let fresh = try await feed.feed(channels: [blender], forceRefresh: false)

        #expect(fresh.count == older.count + 1)
        #expect(await feed.cachedFeed() == fresh)
    }

    @Test func theSubscriptionFeedFailsOfflineAndKeepsItsCache() async throws {
        let connection = MockConnection()
        let blender = SubscribedChannel(id: SampleData.blender.id, name: "Blender")
        let feed = MockSubscriptionFeed(delay: .zero, connection: connection)
        let built = try await feed.feed(channels: [blender], forceRefresh: false)

        connection.isOnline = false
        await expectNetworkError { _ = try await feed.feed(channels: [blender], forceRefresh: true) }

        #expect(await feed.cachedFeed() == built)
    }

    // MARK: The home feed

    private func entry(_ video: VideoSummary, progress: Double = 100) -> HistoryEntry {
        HistoryEntry(video: video, lastWatchedAt: Date(), progressSeconds: progress, durationSeconds: video.durationSeconds.map(Double.init))
    }

    @Test func theHomeFeedWithoutAConnectionHasOnlyWhatIsLocalAndSaysSo() async {
        let connection = MockConnection(isOnline: false)
        let home = MockHomeFeed(delay: .zero, connection: connection)
        let watched = SampleData.videos[0]
        let uploaded = SampleData.videos[1]

        let feed = await home.homeFeed(history: [entry(watched)], subscriptionVideos: [uploaded, watched])

        #expect(feed.continueWatching.map(\.id) == [watched.id])
        #expect(feed.forYou.map(\.id) == [uploaded.id])
        #expect(feed.relatedUnavailable)
    }

    @Test func theHomeFeedWithoutAConnectionOrAHistoryHasNothingToAskAbout() async {
        let home = MockHomeFeed(delay: .zero, connection: MockConnection(isOnline: false))

        let feed = await home.homeFeed(history: [], subscriptionVideos: [])

        #expect(feed.forYou.isEmpty)
        #expect(!feed.relatedUnavailable)
    }

    @Test func theHomeFeedWithAConnectionIsAvailableAgain() async {
        let connection = MockConnection(isOnline: false)
        let home = MockHomeFeed(delay: .zero, connection: connection)
        let history = [entry(SampleData.videos[0])]
        #expect(await home.homeFeed(history: history, subscriptionVideos: []).relatedUnavailable)

        connection.isOnline = true
        let feed = await home.homeFeed(history: history, subscriptionVideos: [])

        #expect(!feed.relatedUnavailable)
        #expect(!feed.forYou.isEmpty)
    }
}
