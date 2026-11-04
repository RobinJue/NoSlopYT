import Foundation
import Testing
@testable import NoSlopKit

@Suite struct VideoStatusSpeechTests {
    private let english = Locale(identifier: "en_US")

    private func status(
        live: Bool = false,
        upcoming: Bool = false,
        duration: Int? = nil,
        watched: Double? = nil,
        downloaded: Bool = false
    ) -> String? {
        VideoStatusSpeech.status(
            isLive: live,
            isUpcoming: upcoming,
            durationSeconds: duration,
            watchedFraction: watched,
            isDownloaded: downloaded,
            locale: english
        )
    }

    @Test func theLengthIsSpoken() {
        #expect(status(duration: 200) == "3 minutes, 20 seconds")
        #expect(status(duration: 3_723) == "1 hour, 2 minutes, 3 seconds")
    }

    @Test func aLiveStreamSaysLiveAndNoLength() {
        #expect(status(live: true, duration: 200) == "Live")
        #expect(status(live: true) == "Live")
    }

    @Test func aPremiereThatHasNotStartedSaysUpcoming() {
        #expect(status(upcoming: true) == "Upcoming")
        #expect(status(upcoming: true, duration: 600) == "Upcoming")
        // The badge shows LIVE first when a stale copy says both.
        #expect(status(live: true, upcoming: true) == "Live")
    }

    @Test func theWatchedPartIsSpokenInPercent() {
        #expect(status(duration: 200, watched: 0.4) == "3 minutes, 20 seconds, 40 percent watched")
        #expect(status(watched: 0.376) == "38 percent watched")
        #expect(status(watched: 1) == "100 percent watched")
        #expect(status(watched: 1.5) == "100 percent watched")
    }

    @Test func aBarThatIsTooSmallToMeanAnythingIsNotSpoken() {
        #expect(status(duration: 200, watched: 0.004) == "3 minutes, 20 seconds")
        #expect(status(duration: 200, watched: 0) == "3 minutes, 20 seconds")
        #expect(status(duration: 200, watched: -0.5) == "3 minutes, 20 seconds")
        #expect(status(duration: 200, watched: .nan) == "3 minutes, 20 seconds")
        #expect(status(watched: 0.006) == "1 percent watched")
    }

    @Test func aDownloadIsMentionedLast() {
        #expect(status(duration: 200, watched: 0.4, downloaded: true) == "3 minutes, 20 seconds, 40 percent watched, Downloaded")
        #expect(status(downloaded: true) == "Downloaded")
    }

    @Test func aVideoWithNothingToSayHasNoStatus() {
        #expect(status() == nil)
        #expect(status(duration: 0) == nil)
        #expect(status(duration: -3) == nil)
    }
}
