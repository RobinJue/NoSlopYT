import Testing
@testable import NoSlopKit

@Suite struct CaptionScaleTests {
    @Test func theBaseSizesAreTheOnesCaptionsHadBefore() {
        #expect(CaptionScale.baseSize(.regular, isLarge: false) == 14)
        #expect(CaptionScale.baseSize(.regular, isLarge: true) == 22)
        #expect(CaptionScale.baseSize(.compact, isLarge: false) == 12)
        #expect(CaptionScale.baseSize(.compact, isLarge: true) == 16)
    }

    @Test func withoutAStyleOfTheViewerTheDefaultLookStays() {
        // The system says "use the content's own value" (nil here), and the text size is the usual one.
        let scale = CaptionScale.scale(systemRelativeSize: nil, dynamicTypeScale: 1)
        #expect(scale == 1)
        #expect(CaptionScale.fontSize(.regular, isLarge: false, scale: scale) == 14)
        #expect(CaptionScale.fontSize(.regular, isLarge: true, scale: scale) == 22)
        #expect(CaptionScale.fontSize(.compact, isLarge: false, scale: scale) == 12)
    }

    @Test func aRelativeSizeOfTwoDoublesTheText() {
        let scale = CaptionScale.scale(systemRelativeSize: 2.0, dynamicTypeScale: 1)
        #expect(scale == 2.0)
        #expect(CaptionScale.fontSize(.regular, isLarge: false, scale: scale) == 28)
        #expect(CaptionScale.fontSize(.regular, isLarge: true, scale: scale) == 44)
        #expect(CaptionScale.fontSize(.compact, isLarge: false, scale: scale) == 24)
    }

    @Test func theSystemSizeIsKeptBetweenHalfAndDouble() {
        #expect(CaptionScale.scale(systemRelativeSize: 5, dynamicTypeScale: 1) == 2.0)
        #expect(CaptionScale.scale(systemRelativeSize: 0.1, dynamicTypeScale: 1) == 0.5)
        #expect(CaptionScale.scale(systemRelativeSize: 0.5, dynamicTypeScale: 1) == 0.5)
        #expect(CaptionScale.scale(systemRelativeSize: 1.5, dynamicTypeScale: 1) == 1.5)
    }

    @Test func aSizeThatMakesNoSenseIsNoSize() {
        for value in [0.0, -1, .nan, .infinity] {
            #expect(CaptionScale.scale(systemRelativeSize: value, dynamicTypeScale: 1) == 1, "\(value)")
        }
    }

    @Test func textSizeScalesTheCaptionsUpToTheLargestStep() {
        #expect(CaptionScale.scale(systemRelativeSize: nil, dynamicTypeScale: 1.2) == 1.2)
        // Accessibility sizes (3.1 times at the largest) stop where the largest regular size ends.
        #expect(CaptionScale.scale(systemRelativeSize: nil, dynamicTypeScale: 3.1) == CaptionScale.largestDynamicTypeScale)
        #expect(CaptionScale.largestDynamicTypeScale == 23.0 / 17.0)
    }

    @Test func aSmallTextSizeDoesNotShrinkTheCaptions() {
        #expect(CaptionScale.scale(systemRelativeSize: nil, dynamicTypeScale: 0.8) == 1)
        #expect(CaptionScale.scale(systemRelativeSize: nil, dynamicTypeScale: .nan) == 1)
    }

    @Test func theTwoPreferencesMultiplyAndTheResultIsKeptInRange() {
        #expect(CaptionScale.scale(systemRelativeSize: 0.5, dynamicTypeScale: 1.3) == 0.65)
        #expect(CaptionScale.scale(systemRelativeSize: 1.5, dynamicTypeScale: 1.2) == 1.5 * 1.2)
        // Double size and the largest text size together would be 2.7.
        #expect(CaptionScale.scale(systemRelativeSize: 2.0, dynamicTypeScale: 1.3) == 2.5)
    }
}
