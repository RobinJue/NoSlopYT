import Testing
@testable import NoSlopKit

@Suite("FeedRuns")
struct FeedRunsTests {
    private func split(_ items: [String]) -> [FeedRun<String>] {
        FeedRuns.split(items) { $0.hasPrefix("v") }
    }

    @Test func rowsBreakRunsOfCards() {
        let runs = split(["v1", "v2", "c1", "v3", "p1", "p2", "v4"])
        #expect(runs == [
            FeedRun(isGrid: true, items: ["v1", "v2"]),
            FeedRun(isGrid: false, items: ["c1"]),
            FeedRun(isGrid: true, items: ["v3"]),
            FeedRun(isGrid: false, items: ["p1"]),
            FeedRun(isGrid: false, items: ["p2"]),
            FeedRun(isGrid: true, items: ["v4"]),
        ])
    }

    @Test func rowFirstAndEmpty() {
        #expect(split(["c1", "v1"]) == [FeedRun(isGrid: false, items: ["c1"]), FeedRun(isGrid: true, items: ["v1"])])
        #expect(split([]).isEmpty)
    }

    @Test func onlyAGridRunOfOneIsALoneCard() {
        let runs = split(["v1", "v2", "c1", "v3", "p1", "v4", "v5", "v6"])
        #expect(runs.map(\.isLoneCard) == [false, false, true, false, false])
        #expect(FeedRun(isGrid: false, items: ["c1"]).isLoneCard == false)
    }
}
