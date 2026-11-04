import Testing
@testable import NoSlopKit

@Suite struct DisplayTitleTests {
    private let original = "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)"
    private let better = "Rick Astley - Never gonna give you up (official music video)"

    @Test func theCommunityTitleWinsWhenDeClickbaitTitlesIsOn() {
        #expect(DisplayTitle.resolve(original: original, better: better, deArrowEnabled: true) == better)
    }

    @Test func theOriginalStaysWhenThereIsNoBetterTitle() {
        #expect(DisplayTitle.resolve(original: original, better: nil, deArrowEnabled: true) == original)
    }

    @Test func theOriginalStaysWhenDeClickbaitTitlesIsOff() {
        #expect(DisplayTitle.resolve(original: original, better: better, deArrowEnabled: false) == original)
        #expect(DisplayTitle.resolve(original: original, better: nil, deArrowEnabled: false) == original)
    }

    @Test func aBlankBetterTitleIsNoTitle() {
        for blank in ["", " ", "\n\t "] {
            #expect(DisplayTitle.resolve(original: original, better: blank, deArrowEnabled: true) == original, "\(blank.debugDescription)")
        }
    }

    @Test func aVideoOpenedFromABareLinkHasNoOriginalYet() {
        // The title comes from the stream info a moment later; until then the community title, if known, is better
        // than nothing, and otherwise the empty original is handed back for the caller to deal with.
        #expect(DisplayTitle.resolve(original: "", better: better, deArrowEnabled: true) == better)
        #expect(DisplayTitle.resolve(original: "", better: nil, deArrowEnabled: true) == "")
        #expect(DisplayTitle.resolve(original: "", better: better, deArrowEnabled: false) == "")
    }

    @Test func theBetterTitleIsHandedBackAsItIs() {
        #expect(DisplayTitle.resolve(original: "x", better: "  spaced  ", deArrowEnabled: true) == "  spaced  ")
    }
}
