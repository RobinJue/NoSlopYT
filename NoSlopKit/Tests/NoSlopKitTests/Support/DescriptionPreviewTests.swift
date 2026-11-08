import Testing
@testable import NoSlopKit

@Suite("DescriptionPreview")
struct DescriptionPreviewTests {
    @Test func dropsThreeDots() {
        #expect(DescriptionPreview.collapsedText("More info: https://studio.blender.org/projects/b...") == "More info: https://studio.blender.org/projects/b")
    }

    @Test func dropsEllipsisCharacterAndSpaceBeforeIt() {
        #expect(DescriptionPreview.collapsedText("A short film \u{2026}") == "A short film")
        #expect(DescriptionPreview.collapsedText("A short film ... \n") == "A short film")
    }

    @Test func dropsOnlyOneEnding() {
        #expect(DescriptionPreview.collapsedText("Wait... what...") == "Wait... what")
    }

    @Test func dropsTheEllipsisOfAShortenedAddressAtTheEndOfALine() {
        let text = "UHD version. More info: https://studio.blender.org/projects/b...\n\nLearn more about this film"
        #expect(DescriptionPreview.collapsedText(text) == "UHD version. More info: https://studio.blender.org/projects/b\n\nLearn more about this film")
    }

    @Test func keepsEllipsesInsideSentences() {
        #expect(DescriptionPreview.collapsedText("Wait... what is this\nand this...\nok") == "Wait... what is this\nand this...\nok")
        #expect(DescriptionPreview.collapsedText("a/b... more") == "a/b... more")
    }

    @Test func keepsTextWithoutEllipsis() {
        #expect(DescriptionPreview.collapsedText("Done.") == "Done.")
        #expect(DescriptionPreview.collapsedText("Hmm..") == "Hmm..")
        #expect(DescriptionPreview.collapsedText("") == "")
        #expect(DescriptionPreview.collapsedText("Trailing space ") == "Trailing space ")
    }
}
