import Foundation
import Testing
@testable import NoSlopKit

@Suite struct TVHomeParserTests {
    private func mixed() throws -> JSON { try Fixture.json("tvsynthetic_home_mixed.json") }

    @Test func aMixedPageKeepsOnlyRealVideos() throws {
        let page = TVHomeParser.parse(try mixed())
        #expect(page.videos.map(\.id) == ["vidLIVE0001", "vidMEMBER01", "vidPLAIN001"])
        #expect(!page.videos.map(\.id).contains("vidAD00001"))
        #expect(page.skipped["adSlotRenderer"] == 1)
        #expect(page.skipped["gridButtonRenderer"] == 1)
        #expect(page.skipped["tile:CHANNEL"] == 1)
        #expect(page.skipped["shelf:EDU"] == 1)
        #expect(page.shorts == 3)
        #expect(page.loggedIn == true)
        #expect(page.sectionContinuation == "SECTIONCONT-1")

        let live = try #require(page.videos.first { $0.id == "vidLIVE0001" })
        #expect(live.isLive && !live.isUpcoming && !live.isShort && live.durationSeconds == nil)
        let members = try #require(page.videos.first { $0.id == "vidMEMBER01" })
        #expect(members.isMembersOnly && !members.isLive)
        let plain = try #require(page.videos.first { $0.id == "vidPLAIN001" })
        #expect(plain.title == "Plain video")
        #expect(plain.channel?.name == "Some Channel")
        #expect(plain.channel?.id == "")
        #expect(plain.durationSeconds == 240)
        #expect(plain.viewCountText == "1K views")
        #expect(!plain.isMembersOnly)
    }

    @Test func aTileWithoutDurationThatIsNotLiveIsAShort() throws {
        var reply = try mixed()
        // Strip the duration overlay from the plain video: it is neither live nor upcoming, so it is a Short.
        var text = String(decoding: try reply.data(), as: UTF8.self)
        let marker = "\"vidPLAIN001\""
        #expect(text.contains(marker))
        reply = try JSON(data: Data(text.utf8))
        let plainBefore = TVHomeParser.parse(reply)
        #expect(plainBefore.videos.map(\.id).contains("vidPLAIN001"))

        text = text.replacingOccurrences(of: "\"simpleText\":\"4:00\"", with: "\"simpleText\":\"\"")
        text = text.replacingOccurrences(of: "\"simpleText\" : \"4:00\"", with: "\"simpleText\" : \"\"")
        let stripped = TVHomeParser.parse(try JSON(data: Data(text.utf8)))
        #expect(!stripped.videos.map(\.id).contains("vidPLAIN001"))
        #expect(stripped.shorts > plainBefore.shorts)
    }

    @Test func aSignedOutPageSaysSo() throws {
        let page = TVHomeParser.parse(try Fixture.json("tvsynthetic_home_signed_out.json"))
        #expect(page.loggedIn == false)
        #expect(page.videos.isEmpty)
        #expect(page.skipped["searchBarRenderer"] == 1)
        #expect(page.skipped["feedNudgeRenderer"] == 1)
        #expect(TVHomeParser.parse(.object([:])).loggedIn == nil)
    }

    @Test func lockupsAreReadToo() throws {
        let page = TVHomeParser.parse(try Fixture.json("tvsynthetic_home_lockups.json"))
        #expect(page.videos.map(\.id) == ["vidLOCK0001"])
        #expect(page.videos.first?.title == "A lockup video")
        #expect(page.videos.first?.thumbnails.first?.width == 320)
        #expect(page.shorts == 1)
        #expect(page.skipped["lockup:PLAYLIST"] == 1)
        #expect(page.loggedIn == true)
    }

    @Test func aSectionContinuationIsReadWithItsNextToken() throws {
        let page = TVHomeParser.parse(try Fixture.json("tvsynthetic_home_section_cont.json"))
        #expect(page.videos.map(\.id) == ["vidNEXT0001", "vidNEXT0002"])
        #expect(page.sectionContinuation == "SECTIONCONT-2")
        #expect(page.loggedIn == true)
    }

    @Test func cardHandlesAreKeptPerVideo() throws {
        let page = TVHomeParser.parse(try mixed())
        #expect(page.handles["vidPLAIN001"] == TVCardHandle(panelID: "PAcontext_menu", params: "FAKEPARAMS-vidPLAIN001"))
        #expect(page.handles["vidLIVE0001"]?.params == "FAKEPARAMS-vidLIVE0001")
        #expect(page.handles["vidAD00001"] == nil)
        #expect(page.handles["vidSHORT001"] == nil)
        let shown = "\(page.handles["vidPLAIN001"]!) \(page) \(String(reflecting: page))"
        #expect(!shown.contains("FAKEPARAMS"))
        #expect(!shown.contains("SECTIONCONT"))
    }

    @Test func unknownRenderersAreCountedNotShown() throws {
        var text = String(decoding: try mixed().data(), as: UTF8.self)
        let mystery = "{\"mysteryRenderer\":{\"tileRenderer\":{\"contentId\":\"vidHIDDEN01\"}}},"
        let anchor = "\"sectionListRenderer\":{\"contents\":["
        let range = try #require(text.range(of: anchor))
        text.insert(contentsOf: mystery, at: range.upperBound)
        let page = TVHomeParser.parse(try JSON(data: Data(text.utf8)))
        #expect(page.unknown["mysteryRenderer"] == 1)
        #expect(!page.videos.map(\.id).contains("vidHIDDEN01"))
        #expect(page.videos.count == 3)
    }

    // MARK: Paid, upsell and Short rules (Task 4 review)

    private func page(shelfExtra: String = "", items: String) throws -> TVHomeParse {
        let text = "{\"contents\":{\"sectionListRenderer\":{\"contents\":[{\"shelfRenderer\":{\(shelfExtra)"
            + "\"content\":{\"horizontalListRenderer\":{\"items\":[\(items)]}}}}]}}}"
        return TVHomeParser.parse(try JSON(data: Data(text.utf8)))
    }

    private func tile(id: String, extra: String = "") -> String {
        let time = "\"thumbnailOverlays\":[{\"thumbnailOverlayTimeStatusRenderer\":{\"text\":{\"simpleText\":\"4:00\"},\"style\":\"DEFAULT\"}}]"
        return "{\"tileRenderer\":{\"contentId\":\"\(id)\",\"contentType\":\"TILE_CONTENT_TYPE_VIDEO\",\(extra)"
            + "\"header\":{\"tileHeaderRenderer\":{\(time)}},"
            + "\"metadata\":{\"tileMetadataRenderer\":{\"title\":{\"simpleText\":\"T\"}}}}}"
    }

    @Test func aPlainSyntheticTileCountsAsAVideo() throws {
        let parsed = try page(items: tile(id: "vidOK000001"))
        #expect(parsed.videos.map(\.id) == ["vidOK000001"])
        #expect(parsed.shorts == 0)
    }

    /// A tile whose lines are the channel and then the given items of the statistics line, one `lineItemRenderer` each.
    private func tile(id: String, statistics items: [String]) -> String {
        func line(_ texts: [String]) -> String {
            let renderers = texts.map { "{\"lineItemRenderer\":{\"text\":{\"simpleText\":\"\($0)\"}}}" }
            return "{\"lineRenderer\":{\"items\":[\(renderers.joined(separator: ","))]}}"
        }
        let lines = "\"lines\":[\(line(["Some Channel"])),\(line(items))]"
        return tile(id: id).replacingOccurrences(of: "\"title\":{\"simpleText\":\"T\"}", with: "\"title\":{\"simpleText\":\"T\"},\(lines)")
    }

    @Test func theAgeIsTheItemAfterTheBulletNotTheBullet() throws {
        let parsed = try page(items: tile(id: "vidAGE00001", statistics: ["188K views", "•", "3 days ago"]))
        let video = try #require(parsed.videos.first)
        #expect(video.viewCountText == "188K views")
        #expect(video.viewCount == 188_000)
        #expect(video.publishedText == "3 days ago")
    }

    @Test func aBadgeAfterTheAgeIsNeitherTheViewsNorTheAge() throws {
        let parsed = try page(items: tile(id: "vidAGE00002", statistics: ["188K views", "•", "3 days ago", "•", "4K"]))
        let video = try #require(parsed.videos.first)
        #expect(video.viewCountText == "188K views")
        #expect(video.publishedText == "3 days ago")
    }

    @Test func aBulletInsideOneItemSplitsIntoViewsAndAge() throws {
        let parsed = try page(items: tile(id: "vidAGE00003", statistics: ["188K views • 3 days ago"]))
        let video = try #require(parsed.videos.first)
        #expect(video.viewCountText == "188K views")
        #expect(video.publishedText == "3 days ago")
    }

    @Test func aLiveTileHasNoAgeAndAnUpcomingOneHasItsDate() throws {
        let live = try #require(try page(items: tile(id: "vidAGE00004", statistics: ["1.2K watching"])).videos.first)
        #expect(live.viewCountText == "1.2K watching")
        #expect(live.publishedText == nil)
        let upcoming = try #require(try page(items: tile(id: "vidAGE00005", statistics: ["Scheduled for 12/5/26"])).videos.first)
        #expect(upcoming.publishedText == "Scheduled for 12/5/26")
    }

    @Test func statisticsAreTakenByPositionWhenTheWordsAreInAnotherLanguage() {
        let german = TVHomeParser.statistics(from: ["188.000 Aufrufe", "•", "vor 3 Tagen", "•", "4K"])
        #expect(german.views == "188.000 Aufrufe")
        #expect(german.published == "vor 3 Tagen")
        let mixed = TVHomeParser.statistics(from: ["188K views", "•", "vor 3 Tagen"])
        #expect(mixed.views == "188K views")
        #expect(mixed.published == "vor 3 Tagen")
    }

    @Test func statisticsWithNothingOrOnlyBulletsAreEmpty() {
        for items in [[], ["•"], ["  ", "·", "|"]] as [[String]] {
            let result = TVHomeParser.statistics(from: items)
            #expect(result.views == nil && result.published == nil)
        }
        let only = TVHomeParser.statistics(from: ["188K views", "•"])
        #expect(only.views == "188K views" && only.published == nil)
    }

    @Test func aTileWithAYPCBadgeIsSkippedAsPaid() throws {
        let paid = tile(id: "vidPAID0001").replacingOccurrences(
            of: "\"metadata\":{", with: "\"metadata\":{\"badges\":[{\"metadataBadgeRenderer\":{\"style\":\"BADGE_STYLE_TYPE_YPC\"}}],")
        let parsed = try page(items: paid + "," + tile(id: "vidOK000001"))
        #expect(parsed.videos.map(\.id) == ["vidOK000001"])
        #expect(parsed.skipped["paid"] == 1)
        let byKey = tile(id: "vidPAID0002").replacingOccurrences(of: "\"metadata\":{", with: "\"metadata\":{\"ypcBadge\":{},")
        let keyed = try page(items: byKey)
        #expect(keyed.videos.isEmpty)
        #expect(keyed.skipped["paid"] == 1)
    }

    @Test func aLockupWithAYPCMarkerIsSkippedAsPaid() throws {
        let lockup = "{\"lockupViewModel\":{\"contentId\":\"vidLPAID001\",\"contentType\":\"LOCKUP_CONTENT_TYPE_VIDEO\","
            + "\"metadata\":{\"lockupMetadataViewModel\":{\"badges\":[{\"style\":\"BADGE_YPC\"}]}}}}"
        let plain = "{\"lockupViewModel\":{\"contentId\":\"vidLOCK0002\",\"contentType\":\"LOCKUP_CONTENT_TYPE_VIDEO\"}}"
        let parsed = try page(items: lockup + "," + plain)
        #expect(parsed.videos.map(\.id) == ["vidLOCK0002"])
        #expect(parsed.skipped["paid"] == 1)
    }

    @Test func aShelfWithAHideLogoIsSkippedAsAnUpsell() throws {
        let parsed = try page(shelfExtra: "\"tvhtml5Metadata\":{\"hideLogo\":true},", items: tile(id: "vidUPSELL01"))
        #expect(parsed.videos.isEmpty)
        #expect(parsed.skipped["upsellShelf"] == 1)
    }

    @Test func onlyATruthyHideLogoMarksAnUpsell() throws {
        for value in ["false", "null", "0", "\"\"", "{}", "[]"] {
            let parsed = try page(shelfExtra: "\"tvhtml5Metadata\":{\"hideLogo\":\(value)},", items: tile(id: "vidKEEP0001"))
            #expect(parsed.videos.map(\.id) == ["vidKEEP0001"], "hideLogo \(value)")
            #expect(parsed.skipped["upsellShelf"] == nil)
        }
        for value in ["1", "\"x\"", "{\"a\":1}", "[1]"] {
            let parsed = try page(shelfExtra: "\"tvhtml5Metadata\":{\"hideLogo\":\(value)},", items: tile(id: "vidDROP0001"))
            #expect(parsed.videos.isEmpty, "hideLogo \(value)")
            #expect(parsed.skipped["upsellShelf"] == 1)
        }
    }

    @Test func aReelEndpointAloneMakesAShort() throws {
        let reel = tile(id: "vidREEL0001", extra: "\"onSelectCommand\":{\"reelWatchEndpoint\":{\"videoId\":\"vidREEL0001\"}},")
        let parsed = try page(items: reel)
        #expect(parsed.videos.isEmpty)
        #expect(parsed.shorts == 1)
    }

    @Test func aShortStyleAloneMakesAShort() throws {
        let styled = tile(id: "vidSTYLE001", extra: "\"style\":\"TILE_STYLE_YTLR_SHORTS\",")
        let parsed = try page(items: styled)
        #expect(parsed.videos.isEmpty)
        #expect(parsed.shorts == 1)
    }
}
