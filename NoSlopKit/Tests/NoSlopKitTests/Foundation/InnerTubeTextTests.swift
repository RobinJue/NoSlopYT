import Foundation
import Testing
@testable import NoSlopKit

@Suite struct InnerTubeTextTests {
    // MARK: parseCount

    @Test(arguments: [
        ("2,763,792 views", 2_763_792),
        ("810K views", 810_000),
        ("1.25M subscribers", 1_250_000),
        ("1.5K videos", 1_500),
        ("No views", 0),
    ])
    func parseCount(text: String, value: Int) {
        #expect(InnerTubeText.parseCount(text) == value)
    }

    @Test(arguments: [
        ("3B", 3_000_000_000),
        ("23M views", 23_000_000),
        ("9.8K views", 9_800),
        ("1 view", 1),
        ("1,833,297,545 views", 1_833_297_545),
        ("12,345 watching", 12_345),
        ("No subscribers", 0),
        ("  7.8M  ", 7_800_000),
        // Other locales: decimal commas before a magnitude, dots that group thousands.
        ("1,25 M d\u{2019}abonn\u{E9}s", 1_250_000),
        ("2.763.792 Aufrufe", 2_763_792),
    ])
    func parseCountVariants(text: String, value: Int) {
        #expect(InnerTubeText.parseCount(text) == value)
    }

    @Test(arguments: ["watching", "", "   ", "views", "1,2 Mio. Aufrufe"])
    func parseCountWithoutAUsableNumberIsNil(text: String) {
        #expect(InnerTubeText.parseCount(text) == nil)
    }

    @Test func parseCountNil() {
        #expect(InnerTubeText.parseCount(nil) == nil)
    }

    @Test func parseCountDoesNotMistakeWordsForSuffixes() {
        // "5 months" must not read the "m" as millions.
        #expect(InnerTubeText.parseCount("5 months ago") == 5)
        #expect(InnerTubeText.parseCount("2 days ago") == 2)
    }

    // MARK: parseDuration

    @Test(arguments: [("4:19:10", 15_550), ("4:40", 280), ("0:59", 59)])
    func parseDuration(t: String, v: Int) {
        #expect(InnerTubeText.parseDuration(t) == v)
    }

    @Test func parseDurationLive() {
        #expect(InnerTubeText.parseDuration("LIVE") == nil)
    }

    @Test(arguments: ["", "59", "1:2:3:4", "a:bc", "1::2", ":30", "4:40 PM"])
    func parseDurationRejectsOtherShapes(text: String) {
        #expect(InnerTubeText.parseDuration(text) == nil)
    }

    @Test func parseDurationNil() {
        #expect(InnerTubeText.parseDuration(nil) == nil)
    }

    // MARK: parseISO8601Duration

    @Test(arguments: [("PT1H2M3S", 3_723), ("PT4M40S", 280), ("PT59S", 59), ("P0D", 0), ("P1DT1S", 86_401)])
    func iso(s: String, v: Int) {
        #expect(InnerTubeText.parseISO8601Duration(s) == v)
    }

    @Test(arguments: [("PT0S", 0), ("P1W", 604_800), ("PT1M", 60), ("pt1h", 3_600), ("PT1.5S", 2)])
    func isoVariants(s: String, v: Int) {
        #expect(InnerTubeText.parseISO8601Duration(s) == v)
    }

    @Test(arguments: ["", "P", "PT", "1H", "PT1X", "PT1", "P1M", "P1Y", "PT1S1H1", "P1H"])
    func isoRejectsMalformedOrAmbiguousInput(s: String) {
        #expect(InnerTubeText.parseISO8601Duration(s) == nil)
    }

    @Test func isoNil() {
        #expect(InnerTubeText.parseISO8601Duration(nil) == nil)
    }

    // MARK: text

    @Test func textFromRunsSimpleTextAndContent() {
        #expect(InnerTubeText.text(["runs": [["text": "a"], ["text": "b"]]]) == "ab")
        #expect(InnerTubeText.text(["simpleText": "x"]) == "x")
        #expect(InnerTubeText.text(["content": "y"]) == "y")
    }

    @Test func textFromAStringNodeAndEmptyCases() {
        #expect(InnerTubeText.text("plain") == "plain")
        #expect(InnerTubeText.text("") == nil)
        #expect(InnerTubeText.text(nil) == nil)
        #expect(InnerTubeText.text([:]) == nil)
        #expect(InnerTubeText.text(["simpleText": ""]) == nil)
        #expect(InnerTubeText.text(["runs": []]) == nil)
        #expect(InnerTubeText.text(["runs": [["bold": true]]]) == nil)
        #expect(InnerTubeText.text(.number(5)) == nil)
    }

    @Test func textPrefersSimpleTextThenRunsThenContent() {
        #expect(InnerTubeText.text(["simpleText": "s", "runs": [["text": "r"]], "content": "c"]) == "s")
        #expect(InnerTubeText.text(["simpleText": "", "runs": [["text": "r"]], "content": "c"]) == "r")
        #expect(InnerTubeText.text(["runs": [], "content": "c"]) == "c")
    }

    @Test func textSkipsRunsWithoutText() {
        #expect(InnerTubeText.text(["runs": [["text": "a"], ["emoji": "x"], ["text": "c"]]]) == "ac")
    }

    @Test func textFromARealFixtureTitle() throws {
        let j = try Fixture.json("search_blender_tutorial.json")
        #expect(InnerTubeText.text(j.first("videoRenderer")?["title"]) == "Beginner Blender Tutorial (2026)")
    }

    // MARK: thumbnails

    @Test func thumbnailsProtocolRelativeAndSorted() {
        let t = InnerTubeText.thumbnails([
            "thumbnails": [
                ["url": "//yt3.ggpht.com/a=s176", "width": 176, "height": 176],
                ["url": "https://x/a=s88", "width": 88, "height": 88],
            ],
        ])
        #expect(t.map(\.width) == [88, 176])
        #expect(t.last?.url.absoluteString == "https://yt3.ggpht.com/a=s176")
    }

    @Test func thumbnailsFromSourcesAndBareArrays() {
        let fromSources = InnerTubeText.thumbnails(["sources": [["url": "https://i/b.jpg", "width": 720, "height": 404]]])
        #expect(fromSources == [Thumbnail(url: URL(string: "https://i/b.jpg")!, width: 720, height: 404)])

        let bare = InnerTubeText.thumbnails([["url": "https://i/c.jpg"]])
        #expect(bare == [Thumbnail(url: URL(string: "https://i/c.jpg")!)])
    }

    @Test func thumbnailsDropEntriesWithoutAUrlAndKeepOrderOfEqualWidths() {
        let t = InnerTubeText.thumbnails([
            "thumbnails": [
                ["width": 50],
                ["url": "https://i/first", "width": 100],
                ["url": "", "width": 10],
                ["url": "https://i/second", "width": 100],
                ["url": "https://i/small", "width": 20],
            ],
        ])
        #expect(t.map(\.url.absoluteString) == ["https://i/small", "https://i/first", "https://i/second"])
    }

    @Test func thumbnailsOfNothingAreEmpty() {
        #expect(InnerTubeText.thumbnails(nil).isEmpty)
        #expect(InnerTubeText.thumbnails([:]).isEmpty)
        #expect(InnerTubeText.thumbnails("x").isEmpty)
    }

    @Test func thumbnailsFromARealFixtureAreAscending() throws {
        let j = try Fixture.json("search_blender_tutorial.json")
        let node = j.first("videoRenderer")?["thumbnail"]
        let t = InnerTubeText.thumbnails(node)
        #expect(!t.isEmpty)
        #expect(t.compactMap(\.width) == t.compactMap(\.width).sorted())
    }

    // MARK: DurationFormatter

    @Test func durationFormatter() {
        #expect(DurationFormatter.string(seconds: 5) == "0:05")
        #expect(DurationFormatter.string(seconds: 280) == "4:40")
        #expect(DurationFormatter.string(seconds: 3723) == "1:02:03")
    }

    @Test func durationFormatterEdges() {
        #expect(DurationFormatter.string(seconds: 0) == "0:00")
        #expect(DurationFormatter.string(seconds: 59) == "0:59")
        #expect(DurationFormatter.string(seconds: 60) == "1:00")
        #expect(DurationFormatter.string(seconds: 3600) == "1:00:00")
        #expect(DurationFormatter.string(seconds: 15_550) == "4:19:10")
        #expect(DurationFormatter.string(seconds: 360_000) == "100:00:00")
        #expect(DurationFormatter.string(seconds: -7) == "0:00")
    }

    @Test(arguments: [4, 59, 61, 280, 3_599, 3_600, 15_550])
    func durationFormatterInvertsParseDuration(seconds: Int) {
        #expect(InnerTubeText.parseDuration(DurationFormatter.string(seconds: seconds)) == seconds)
    }
}
