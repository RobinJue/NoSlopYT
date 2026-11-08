import Foundation
import Testing
@testable import NoSlopKit

@Suite struct HomeSourceDecisionTests {
    private func video(_ n: Int) -> VideoSummary { VideoSummary(id: "vid\(n)", title: "Video \(n)") }

    private func page(_ range: ClosedRange<Int>, loggedIn: Bool? = true, continuation: String? = nil) -> TVHomePage {
        TVHomePage(
            loggedIn: loggedIn,
            videos: range.map(video),
            cardIDs: [],
            continuation: continuation,
            report: HomeLoadReport(recipe: "test", at: Date(timeIntervalSince1970: 0))
        )
    }

    @Test func eightVisibleVideosUseYouTube() {
        let result = HomeSourceDecision.decide(pages: [page(1...5, continuation: "c1"), page(6...8, continuation: "c2")], filter: { _ in true }, excluded: [])
        #expect(result.useYouTube)
        #expect(result.videos.map(\.id) == (1...8).map { "vid\($0)" })
        #expect(result.continuation == "c2")
    }

    @Test func aThinOrSignedOutHomeFallsBack() {
        let thin = HomeSourceDecision.decide(pages: [page(1...7)], filter: { _ in true }, excluded: [])
        #expect(!thin.useYouTube)
        #expect(thin.videos.isEmpty && thin.continuation == nil)
        let signedOut = HomeSourceDecision.decide(pages: [page(1...12, loggedIn: false)], filter: { _ in true }, excluded: [])
        #expect(!signedOut.useYouTube)
        let unknown = HomeSourceDecision.decide(pages: [page(1...12, loggedIn: nil)], filter: { _ in true }, excluded: [])
        #expect(!unknown.useYouTube)
        #expect(!HomeSourceDecision.decide(pages: [], filter: { _ in true }, excluded: []).useYouTube)
        // Only the first three pages count.
        let late = HomeSourceDecision.decide(pages: [page(1...3), page(4...5), page(6...7), page(8...12)], filter: { _ in true }, excluded: [])
        #expect(!late.useYouTube)
    }

    @Test func continueWatchingVideosAreNotCounted() {
        let pages = [page(1...10)]
        let withExcluded = HomeSourceDecision.decide(pages: pages, filter: { _ in true }, excluded: ["vid1", "vid2", "vid3"])
        #expect(!withExcluded.useYouTube)
        let filtered = HomeSourceDecision.decide(pages: pages, filter: { $0.id != "vid10" && $0.id != "vid9" }, excluded: [])
        #expect(filtered.useYouTube)
        #expect(filtered.videos.count == 8)
        let duplicates = HomeSourceDecision.decide(pages: [page(1...5), page(1...5)], filter: { _ in true }, excluded: [])
        #expect(!duplicates.useYouTube)
    }
}
