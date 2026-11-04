import Foundation
import Testing
@testable import NoSlopKit

// A video in the library (Watch Later, a playlist, the history) is kept as it was when it was saved, and the library
// is read months later. Text that was only true on that day must not be kept: "3 days ago" does not become "4 days
// ago" by itself, and a stream that has ended is not "live" any more. The library therefore stores an absolute date
// for an age it can read, and nothing for text it cannot, and it forgets the live and upcoming marks and the count
// of people watching.

private let saved = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

// MARK: - Reading an age

@Suite struct RelativeAgeTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var text: String
        var seconds: TimeInterval
        init(_ text: String, _ seconds: TimeInterval) {
            self.text = text
            self.seconds = seconds
        }

        var testDescription: String { text }
    }

    @Test(arguments: [
        Case("1 second ago", 1),
        Case("30 seconds ago", 30),
        Case("1 minute ago", 60),
        Case("45 minutes ago", 45 * 60),
        Case("1 hour ago", 3_600),
        Case("22 hours ago", 22 * 3_600),
        Case("1 day ago", day),
        Case("3 days ago", 3 * day),
        Case("1 week ago", 7 * day),
        Case("2 weeks ago", 14 * day),
        Case("1 month ago", 30 * day),
        Case("11 months ago", 330 * day),
        Case("1 year ago", 365 * day),
        Case("11 years ago", 11 * 365 * day),
    ])
    func spelledOutAges(_ example: Case) {
        #expect(RelativeAge.date(from: example.text, relativeTo: saved) == saved.addingTimeInterval(-example.seconds))
    }

    @Test(arguments: [
        Case("13d ago", 13 * day),
        Case("17y ago", 17 * 365 * day),
        Case("2mo ago", 60 * day),
        Case("11mo ago", 330 * day),
        Case("3w ago", 21 * day),
        Case("5h ago", 5 * 3_600),
        Case("10m ago", 600),
        Case("20s ago", 20),
    ])
    func compactAges(_ example: Case) {
        #expect(RelativeAge.date(from: example.text, relativeTo: saved) == saved.addingTimeInterval(-example.seconds))
    }

    @Test(arguments: [
        Case("Streamed 5 days ago", 5 * day),
        Case("Streamed 2mo ago", 60 * day),
        Case("Premiered 3 days ago", 3 * day),
        Case("Started streaming 3 hours ago", 3 * 3_600),
        Case("Started streaming 1 hour ago", 3_600),
        Case("  3 Days Ago \n", 3 * day),
        Case("STREAMED 1 YEAR AGO", 365 * day),
    ])
    func streamsPremieresAndSloppyCase(_ example: Case) {
        #expect(RelativeAge.date(from: example.text, relativeTo: saved) == saved.addingTimeInterval(-example.seconds))
    }

    @Test(arguments: [
        // Not an age: dates still to come, other languages, loose words.
        "Scheduled for 11/3/26, 8:00 PM", "Premieres 11/3/26", "Premieres in 3 hours", "1,204 watching", "12 waiting",
        "vor 3 Tagen", "hace 3 d\u{00ED}as", "il y a 3 jours", "3 \u{65E5}\u{524D}", "3 \u{0434}\u{043D}\u{044F} \u{043D}\u{0430}\u{0437}\u{0430}\u{0434}",
        "yesterday", "just now", "", "   ", "ago", "days ago", "3 days", "3 ago", "Streamed", "Streamed ago",
        // Numbers that are not a plain count, units that are not known, nonsense.
        "3.5 days ago", "-3 days ago", "+3 days ago", "3 fortnights ago", "three days ago", "3 days ago ago", "3 days ago.",
        "99999999999999999999 days ago", "0 days ago extra", "2024 3 days ago", "11/3/26 3 days ago",
    ])
    func textThatIsNotAnAgeGivesNothing(_ text: String) {
        #expect(RelativeAge.date(from: text, relativeTo: saved) == nil, "\(text)")
    }

    @Test func zeroIsNow() {
        // YouTube does not write it, but "0 seconds ago" is exactly what it says.
        #expect(RelativeAge.date(from: "0 seconds ago", relativeTo: saved) == saved)
    }
}

// MARK: - A video as the library keeps it

@Suite struct LibraryVideoTests {
    private func video(
        text: String? = nil, at: Date? = nil, views: String? = nil, count: Int? = nil,
        live: Bool = false, upcoming: Bool = false
    ) -> VideoSummary {
        VideoSummary(
            id: "abc", title: "A video", channel: ChannelRef(id: "UC1", name: "Chan"),
            thumbnails: [Thumbnail(url: URL(string: "https://i.ytimg.com/vi/abc/hq.jpg")!, width: 480, height: 360)],
            durationSeconds: 600, viewCount: count, viewCountText: views, publishedText: text, publishedAt: at,
            isLive: live, isUpcoming: upcoming, isShort: false, isMembersOnly: true
        )
    }

    @Test func anAgeBecomesADateAndTheTextGoesAway() {
        let kept = video(text: "3 days ago", views: "1.2M views", count: 1_200_000).forLibrary(savedAt: saved)
        #expect(kept.publishedAt == saved.addingTimeInterval(-3 * day))
        #expect(kept.publishedText == nil)
        // Everything else is as it was.
        #expect(kept.viewCount == 1_200_000)
        #expect(kept.viewCountText == "1.2M views")
        #expect(kept.durationSeconds == 600)
        #expect(kept.isMembersOnly)
        #expect(kept.channel == video().channel)
        #expect(kept.thumbnails == video().thumbnails)
        #expect(kept.title == "A video" && kept.id == "abc")
    }

    @Test func aDateThatIsKnownIsKept() {
        // RSS and Data API items have a real date, and their age is worked out from it every time.
        let published = saved.addingTimeInterval(-9 * day)
        let kept = video(text: "3 days ago", at: published).forLibrary(savedAt: saved)
        #expect(kept.publishedAt == published)
        #expect(kept.publishedText == nil)
    }

    @Test(arguments: ["vor 3 Tagen", "Scheduled for 11/3/26, 8:00 PM", "yesterday"])
    func anAgeThatCannotBeReadIsNotKept(text: String) {
        let kept = video(text: text).forLibrary(savedAt: saved)
        #expect(kept.publishedText == nil)
        #expect(kept.publishedAt == nil)
    }

    @Test func withoutADateOfSavingThereIsNothingToCountBackFrom() {
        let kept = video(text: "3 days ago").forLibrary(savedAt: nil)
        #expect(kept.publishedText == nil)
        #expect(kept.publishedAt == nil)
        let dated = video(text: "3 days ago", at: saved).forLibrary(savedAt: nil)
        #expect(dated.publishedAt == saved)
    }

    @Test func aStreamIsNotLiveAnyMoreAndItsViewersAreForgotten() {
        let live = video(text: "Started streaming 3 hours ago", views: "1,204 watching", live: true)
        let kept = live.forLibrary(savedAt: saved)
        #expect(!kept.isLive && !kept.isUpcoming)
        #expect(kept.viewCount == nil)
        #expect(kept.viewCountText == nil)
        #expect(kept.publishedText == nil)
        #expect(kept.publishedAt == saved.addingTimeInterval(-3 * 3_600))
    }

    @Test func aWatchPageCountsViewersAsAViewCount() {
        // The watch page parses "1,204 watching now" into a number too.
        let kept = video(views: "1,204 watching now", count: 1_204, live: true).forLibrary(savedAt: saved)
        #expect(!kept.isLive)
        #expect(kept.viewCount == nil)
        #expect(kept.viewCountText == nil)
    }

    @Test func aPremiereIsNotUpcomingAnyMoreButKeepsItsScheduledDate() {
        let start = saved.addingTimeInterval(2 * day)
        let upcoming = video(text: "Scheduled for 11/3/26, 8:00 PM", at: start, views: "12 waiting", upcoming: true)
        let kept = upcoming.forLibrary(savedAt: saved)
        #expect(!kept.isUpcoming)
        #expect(kept.viewCountText == nil && kept.viewCount == nil)
        #expect(kept.publishedText == nil)
        #expect(kept.publishedAt == start)
    }

    @Test func aTotalThatIsKnownSurvivesTheMarks() {
        // A stream that was flagged live but whose text is a real total (for example from the Data API).
        let kept = video(views: "1,234,567 views", count: 1_234_567, live: true).forLibrary(savedAt: saved)
        #expect(!kept.isLive)
        #expect(kept.viewCount == 1_234_567)
        #expect(kept.viewCountText == "1,234,567 views")
    }

    @Test func aLiveStreamInAnotherLanguageLosesItsViewerText() {
        // Not read as a number (English only), so the count is nil: for a live video that text counts viewers.
        let kept = video(views: "1,2 Tsd. Zuschauer", live: true).forLibrary(savedAt: saved)
        #expect(kept.viewCountText == nil)
    }

    @Test func anOrdinaryVideoKeepsEverythingButTheText() {
        let german = video(text: "vor 3 Tagen", views: "9,8 Tsd. Aufrufe").forLibrary(savedAt: saved)
        #expect(german.viewCountText == "9,8 Tsd. Aufrufe")
        #expect(german.viewCount == nil)

        let plain = video(views: "1.2M views", count: 1_200_000)
        #expect(plain.forLibrary(savedAt: saved) == plain)
    }

    @Test func keepingAVideoTwiceChangesNothingTheSecondTime() {
        let once = video(text: "Started streaming 3 hours ago", views: "1,204 watching", live: true).forLibrary(savedAt: saved)
        #expect(once.forLibrary(savedAt: saved.addingTimeInterval(30 * day)) == once)
    }
}
