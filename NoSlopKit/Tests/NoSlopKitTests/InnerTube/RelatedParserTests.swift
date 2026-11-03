import Foundation
import Testing
@testable import NoSlopKit

@Suite struct RelatedParserTests {
    private static let shelfShortIDs = ["fuZ6waTkfT4", "7aX5o12yuic", "EYSqDsNk0DQ", "3jOPks7goKk", "D2kjeaX1T_w", "TwvZpGlwgVE"]

    // MARK: From the plan

    @Test func relatedFromNext() throws {
        let p = RelatedParser.parse(next: try Fixture.json("next_aqz.json"))
        #expect(p.items.filter { !$0.isShort }.count == 20)
        #expect(p.items.filter(\.isShort).count == 6)
        let first = try #require(p.items.first)
        #expect(first.id == "7pPUE6cGFwI")
        #expect(first.title == "A Little Pony’s Big Heart")
        #expect(p.continuation != nil)
    }

    @Test func relatedContinuation() throws {
        let p = RelatedParser.parseContinuation(try Fixture.json("next_aqz_related_cont.json"))
        #expect(p.items.count == 20)
        #expect(p.continuation != nil)
    }

    // MARK: Order and Shorts

    @Test func shortsShelfComesAfterTheRegularVideos() throws {
        // In the response the Shorts shelf sits above the list; the "up next" list must start with a real video.
        let json = try Fixture.json("next_aqz.json")
        let first = try #require(json["contents"]?["twoColumnWatchNextResults"]?["secondaryResults"]?["secondaryResults"]?["results"]?[0])
        #expect(first["reelShelfRenderer"] != nil)

        let p = RelatedParser.parse(next: json)
        #expect(p.items.count == 26)
        #expect(p.items.prefix(20).allSatisfy { !$0.isShort })
        #expect(p.items.suffix(6).allSatisfy { $0.isShort })
        #expect(p.items.suffix(6).map(\.id) == Self.shelfShortIDs)
        // The regular videos keep their order.
        #expect(p.items.prefix(4).map(\.id) == ["7pPUE6cGFwI", "vE57fPUAQh0", "V9FfaieAj_4", "0S0L-iqUM-4"])
        #expect(p.items.dropFirst(19).first?.id == "jWuEHJCYajE")
    }

    @Test func shelfShortsAreFlaggedWithTheirDetails() throws {
        let p = RelatedParser.parse(next: try Fixture.json("next_aqz.json"))
        let short = try #require(p.items.first { $0.id == "fuZ6waTkfT4" })
        #expect(short.isShort)
        #expect(short.title == "Sierra Never Ignores Rhia 💛")
        #expect(short.viewCountText == "5.5M views")
        #expect(short.viewCount == 5_500_000)
    }

    // MARK: Item details (the "up next" lockups show bare counts and short ages)

    @Test func lockupDetails() throws {
        let p = RelatedParser.parse(next: try Fixture.json("next_aqz.json"))
        let v = try #require(p.items.first)
        #expect(v.durationSeconds == 729)   // 12:09
        #expect(v.viewCount == 7_800_000)
        #expect(v.viewCountText == "7.8M")
        #expect(v.publishedText == "13d ago")
        #expect(v.channel?.name == "PolyFilms")
        #expect(v.channel?.id == "UCpzUp21QjEZo_Jp7rt5w83Q")
        #expect(v.channel?.handle == "@PolyFilmsOfficial")
        #expect(v.channel?.avatarURL != nil)
        #expect(v.thumbnails.map(\.width) == [168, 336])
        #expect(!v.isLive && !v.isShort && !v.isUpcoming && !v.isMembersOnly)

        // A row with an extra empty row after the counts.
        let bear = try #require(p.items.first { $0.id == "xOXolSQcEb4" })
        #expect(bear.channel?.name == "The Art of Aaron Blaise")
        #expect(bear.viewCount == 10_000_000)
        #expect(bear.publishedText == "11mo ago")
        #expect(bear.durationSeconds == 706)

        // A channel name padded with spaces comes back trimmed; an Arabic title keeps its text.
        let padded = try #require(p.items.first { $0.id == "13xYy-1hH80" })
        #expect(padded.channel?.name == "Boxoffice ANIMATION ☆ Movie Scenes")
        let arabic = try #require(p.items.first { $0.id == "9m-NTI8170c" })
        #expect(arabic.publishedText == "3h ago")
        #expect(arabic.durationSeconds == 3546)
    }

    @Test func everyRelatedVideoHasTheEssentials() throws {
        for name in ["next_aqz.json", "next_rickroll.json", "next_with_chapters.json"] {
            let p = RelatedParser.parse(next: try Fixture.json(name))
            #expect(!p.items.isEmpty, "\(name)")
            #expect(p.items.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty && !$0.thumbnails.isEmpty }, "\(name)")
            #expect(p.items.filter { !$0.isShort }.allSatisfy { $0.channel != nil && $0.durationSeconds != nil && $0.viewCount != nil }, "\(name)")
            #expect(Set(p.items.map(\.id)).count == p.items.count, "\(name)")
            #expect(p.continuation != nil, "\(name)")
        }
    }

    @Test func otherNextFixtures() throws {
        #expect(RelatedParser.parse(next: try Fixture.json("next_rickroll.json")).items.count == 20)
        // 20 lockups, one of them a course ("Blender Donut Tutorial (2025)"): not a video, so not in the page.
        let chapters = RelatedParser.parse(next: try Fixture.json("next_with_chapters.json"))
        #expect(chapters.items.count == 19)
        #expect(!chapters.items.contains { $0.id == "PLjEaoINr3zgGUwGwXlj9kBe7TrVWNjkyv" })
        #expect(chapters.items.first?.id == "-tbSCMbJA6o")
    }

    // MARK: Continuation tokens

    @Test func tokensAreTheListsOwn() throws {
        let initial = try Fixture.json("next_aqz.json")
        let expected = try #require(initial["contents"]?["twoColumnWatchNextResults"]?["secondaryResults"]?["secondaryResults"]?["results"]?[21]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        #expect(RelatedParser.parse(next: initial).continuation == expected)

        let more = try Fixture.json("next_aqz_related_cont.json")
        let moreExpected = try #require(more["onResponseReceivedEndpoints"]?[0]?["appendContinuationItemsAction"]?["continuationItems"]?[20]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        #expect(RelatedParser.parseContinuation(more).continuation == moreExpected)
        #expect(moreExpected != expected)
    }

    @Test func aFirstPageIsNoContinuationAndViceVersa() throws {
        #expect(RelatedParser.parseContinuation(try Fixture.json("next_aqz.json")).items.isEmpty)
        #expect(RelatedParser.parse(next: try Fixture.json("next_aqz_related_cont.json")).items.isEmpty)
    }

    @Test func playlistAndMixLockupsAreNotVideos() throws {
        // Related lists sometimes carry playlist lockups; the page is videos only.
        let json = try Fixture.json("search_blender_tutorial_cont.json")
        let lockup = try #require(json.first("lockupViewModel"))
        let response: JSON = [
            "contents": ["twoColumnWatchNextResults": ["secondaryResults": ["secondaryResults": ["results": [
                ["lockupViewModel": lockup],
            ]]]]],
        ]
        #expect(RelatedParser.parse(next: response).items.isEmpty)
    }

    @Test func emptyAndForeignDocuments() throws {
        #expect(RelatedParser.parse(next: [:]).items.isEmpty)
        #expect(RelatedParser.parse(next: [:]).continuation == nil)
        #expect(RelatedParser.parseContinuation([:]).items.isEmpty)
        // A search response has videos but no secondary results.
        #expect(RelatedParser.parse(next: try Fixture.json("search_videos_only.json")).items.isEmpty)
    }
}
