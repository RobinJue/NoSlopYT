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
}
