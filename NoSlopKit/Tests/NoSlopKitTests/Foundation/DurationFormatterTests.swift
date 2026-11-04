import Foundation
import Testing
@testable import NoSlopKit

@Suite struct DurationFormatterTests {
    private let english = Locale(identifier: "en_US")

    @Test func aLengthIsSpokenInWords() {
        #expect(DurationFormatter.spokenString(seconds: 200, locale: english) == "3 minutes, 20 seconds")
        #expect(DurationFormatter.spokenString(seconds: 225, locale: english) == "3 minutes, 45 seconds")
        #expect(DurationFormatter.spokenString(seconds: 3_723, locale: english) == "1 hour, 2 minutes, 3 seconds")
        #expect(DurationFormatter.spokenString(seconds: 15_550, locale: english) == "4 hours, 19 minutes, 10 seconds")
    }

    @Test func unitsThatAreZeroAreLeftOut() {
        #expect(DurationFormatter.spokenString(seconds: 180, locale: english) == "3 minutes")
        #expect(DurationFormatter.spokenString(seconds: 3_600, locale: english) == "1 hour")
        #expect(DurationFormatter.spokenString(seconds: 3_605, locale: english) == "1 hour, 5 seconds")
        #expect(DurationFormatter.spokenString(seconds: 45, locale: english) == "45 seconds")
        #expect(DurationFormatter.spokenString(seconds: 1, locale: english) == "1 second")
        #expect(DurationFormatter.spokenString(seconds: 60, locale: english) == "1 minute")
    }

    @Test func aNegativeLengthIsNone() {
        #expect(DurationFormatter.spokenString(seconds: 0, locale: english) == "0 seconds")
        #expect(DurationFormatter.spokenString(seconds: -7, locale: english) == "0 seconds")
    }

    @Test func theLocaleDecidesTheWords() {
        let german = DurationFormatter.spokenString(seconds: 200, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("Minuten"))
        #expect(german.contains("Sekunden"))
    }

    @Test func aDayLongStreamIsStillInHours() {
        #expect(DurationFormatter.spokenString(seconds: 90_061, locale: english) == "25 hours, 1 minute, 1 second")
    }
}
