import Foundation
import Testing
@testable import NoSlopKit

@Suite struct TVPanelParserTests {
    @Test func bothActionsAreFoundByStructure() throws {
        let f = TVPanelParser.parse(try Fixture.json("tvsynthetic_panel_menu.json"))
        #expect(f.notInterested == "NI")
        #expect(f.dontRecommend == "DR")
        #expect(f.channelID == "UCabcdefghijklmnopqrstuv")
        #expect(f.channelName == "Some Channel")
        #expect(f.handle == "@somechannel")
        #expect(!f.ambiguous)
    }

    @Test func twoCandidatesAreAmbiguousAndSendNothing() throws {
        let f = TVPanelParser.parse(try Fixture.json("tvsynthetic_panel_two_rows.json"))
        #expect(f.ambiguous)
        #expect(f.notInterested == nil)
        #expect(f.dontRecommend == nil)
    }

    @Test func aRowWithoutADismissalIsNotNotInterested() {
        let f = TVPanelParser.parse(["a": ["feedbackEndpoint": ["feedbackToken": "X"]]])
        #expect(f.notInterested == nil && f.dontRecommend == nil && !f.ambiguous)
    }

    @Test func anEmptyReplyFindsNothing() {
        let f = TVPanelParser.parse([:])
        #expect(f.notInterested == nil && f.dontRecommend == nil && f.channelID == nil && f.handle == nil && f.channelName == nil)
    }

    @Test func aHideEnclosingFollowUpCountsAsADismissal() {
        let reply: JSON = ["a": ["feedbackEndpoint": ["feedbackToken": "NI", "uiActions": ["hideEnclosingContainer": true]]]]
        #expect(TVPanelParser.parse(reply).notInterested == "NI")
    }

    @Test func twoDifferentChannelIDsLeaveTheChannelUnknown() {
        let a: JSON = ["browseEndpoint": ["browseId": "UCabcdefghijklmnopqrstuv"]]
        let b: JSON = ["browseEndpoint": ["browseId": "UCzzzzzzzzzzzzzzzzzzzzzz"]]
        #expect(TVPanelParser.parse(["a": a, "b": b, "c": a]).channelID == nil)
        #expect(TVPanelParser.parse(["a": a, "c": a]).channelID == "UCabcdefghijklmnopqrstuv")
    }

    @Test func theDescriptionHidesTheTokens() {
        let f = TVPanelFindings(notInterested: "SECRETNI", dontRecommend: "SECRETDR", channelID: nil, channelName: nil, handle: nil, ambiguous: false)
        for text in ["\(f)", String(reflecting: f)] {
            #expect(!text.contains("SECRETNI") && !text.contains("SECRETDR"))
        }
    }
}
