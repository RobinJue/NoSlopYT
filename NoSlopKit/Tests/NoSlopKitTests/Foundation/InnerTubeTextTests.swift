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
        ("810k views", 810_000),
        ("1,5K", 1_500),
        ("12M+ views", 12_000_000),
        ("2.7M • 3 days ago", 2_700_000),
        ("999 views", 999),
        ("0 views", 0),
        ("1,234 subscribers", 1_234),
        ("17 comments", 17),
        ("866 likes", 866),
        ("25 replies", 25),
        ("8 lessons", 8),
        ("8 episodes", 8),
        ("Like this video along with 110,320 other people", 110_320),
        ("like this video along with 866 other people", 866),
        // Texts that carry invisible direction marks.
        ("\u{2068}578K subscribers\u{2069}", 578_000),
        ("\u{200E}1.25M subscribers", 1_250_000),
    ])
    func parseCountEnglishVariants(text: String, value: Int) {
        #expect(InnerTubeText.parseCount(text) == value)
    }

    // MARK: parseCount, German

    @Test(arguments: [
        ("110 Tsd.", 110_000),
        ("1,25 Mio. Abonnenten", 1_250_000),
        ("2.763.792 Aufrufe", 2_763_792),
        ("3,2 Mrd. Aufrufe", 3_200_000_000),
        ("9,8 Tsd. Aufrufe", 9_800),
        ("12 Tsd. Aufrufe", 12_000),
        ("1,2 Mio. Aufrufe", 1_200_000),
        ("0,5 Mio.", 500_000),
        ("110 Tsd", 110_000),
        ("110 TSD.", 110_000),
        ("1,5 Mio", 1_500_000),
        ("1 Aufruf", 1),
        ("12 Aufrufe", 12),
        ("999 Abonnenten", 999),
        ("1.234 Aufrufe", 1_234),
        ("1.833.297.545 Aufrufe", 1_833_297_545),
        ("zusammen mit 110.123 anderen Personen", 110_123),
    ])
    func parseCountGermanUnits(text: String, value: Int) {
        #expect(InnerTubeText.parseCount(text) == value)
    }

    // MARK: parseCount, digit groups

    @Test(arguments: [" ", "\u{00A0}", "\u{202F}", "\u{2009}"])
    func parseCountDigitGroupsSeparatedBySpaces(separator: String) {
        #expect(InnerTubeText.parseCount("2\(separator)763\(separator)792\(separator)vues") == 2_763_792)
        #expect(InnerTubeText.parseCount("2\(separator)763\(separator)792 views") == 2_763_792)
        #expect(InnerTubeText.parseCount("12\(separator)345") == 12_345)
        #expect(InnerTubeText.parseCount("1\(separator)234 abonn\u{E9}s") == 1_234)
        #expect(InnerTubeText.parseCount("1\(separator)833\(separator)297\(separator)545 visualiza\u{E7}\u{F5}es") == 1_833_297_545)
    }

    @Test(arguments: [
        ("2 763 792 vues", 2_763_792),
        ("2.763.792 visualizaciones", 2_763_792),
        ("2,763,792 weergaven", 2_763_792),
        ("2 763 792 visningar", 2_763_792),
        ("1234 visualizaciones", 1_234),
        ("2763792 views", 2_763_792),
    ])
    func parseCountWrittenOutNumbersKeepAnyLatinNoun(text: String, value: Int) {
        // A number written out in full cannot be abbreviated, so what follows it is only the noun.
        #expect(InnerTubeText.parseCount(text) == value)
    }

    // MARK: parseCount, never a wrong number

    @Test(arguments: [
        // CJK units
        "12万 回視聴", "12万", "1.2万次观看", "125万人", "12천", "276만회", "조회수 12만회", "12億",
        // Cyrillic and other scripts
        "12 тыс. просмотров", "2,7 млн просмотров", "12 тыс.", "12 \u{0623}\u{0644}\u{0641}", "2.7 \u{0932}\u{093E}\u{0916}",
        // Latin abbreviations of other languages
        "12 tn visningar", "2,7 mn visningar", "12 tys. wyświetleń", "2,7 mln wyświetleń", "12 tis. zhlédnutí", "12 mil visualizações",
        "12 mil visualizaciones", "2,7 mi de visualizações", "12 rb x ditonton", "2,7 jt x ditonton", "12 B görüntüleme", "12 E megtekintés",
        "12 k vues", "2,7 M de vues", "2,7 M de visualizaciones", "1,25 M d\u{2019}abonn\u{E9}s", "12 K weergaven", "12K weergaven",
        // Long forms
        "578 thousand subscribers", "16 thousand views", "1.25 million subscribers", "12 million views", "3 billion views",
        // A short number and a noun this function does not know
        "12 vues", "12 visualizaciones", "3 friends", "12 Mal angesehen",
    ])
    func parseCountOfAnotherLanguagesUnitsIsNil(text: String) {
        #expect(InnerTubeText.parseCount(text) == nil, "\(text)")
    }

    @Test(arguments: [
        // Both a number written out in full and a unit.
        "1,234 Mio.", "1.234.567 Mio.", "2 763 792 Tsd.", "1234K views", "2,763,792K views",
        // Two readings of one number, or none.
        "1,234.5 views", "1.234,5 views", "1,234.567K views", "1,23,456 views", "12,34 views", "1.5 views", "1,25",
        // Not a count: a sign, a fraction or digits that run on.
        "-5 views", "\u{2212}5 views", ".5K views", "12 34 views", "1 2345 views", "12%", "12/20", "50-60 views",
        // Too big for an Int.
        "99999999999999999999 views", "99999999999999999999",
        // No number or no count at all.
        "watching", "", "   ", "views", "No", "No ads", "Keine Aufrufe", "\u{200E}",
    ])
    func parseCountNeverGuesses(text: String) {
        #expect(InnerTubeText.parseCount(text) == nil, "\(text)")
    }

    @Test(arguments: ["No views", "No subscribers", "no replies", "NO VIEWS", "No views yet", "No comments."])
    func parseCountExplicitZero(text: String) {
        #expect(InnerTubeText.parseCount(text) == 0, "\(text)")
    }

    @Test func parseCountNil() {
        #expect(InnerTubeText.parseCount(nil) == nil)
    }

    @Test func parseCountDoesNotMistakeWordsForSuffixes() {
        // "5 months" must not read the "m" as millions.
        #expect(InnerTubeText.parseCount("5 months ago") == 5)
        #expect(InnerTubeText.parseCount("2 days ago") == 2)
        #expect(InnerTubeText.parseCount("1 hour ago") == 1)
        #expect(InnerTubeText.parseCount("3 years ago") == 3)
    }

    @Test func parseCountReadsTheFirstNumberOnly() {
        #expect(InnerTubeText.parseCount("2,763,792 views \u{2022} 9 months ago") == 2_763_792)
        #expect(InnerTubeText.parseCount("810K views \u{2022} 2 years ago") == 810_000)
    }

    // MARK: parseCount, properties

    private static let writtenOutValues = [0, 1, 9, 10, 99, 100, 999, 1_000, 1_234, 9_999, 10_000, 123_456, 999_999, 1_000_000, 2_763_792, 999_999_999, 1_833_297_545, 12_345_678_901]

    /// `value` with its digits in groups of three, joined by `separator`.
    private static func grouped(_ value: Int, by separator: String) -> String {
        var digits = Array(String(value))
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(String(digits), at: 0)
        return groups.joined(separator: separator)
    }

    @Test(arguments: [",", ".", " ", "\u{00A0}", "\u{202F}"])
    func everyNumberWrittenOutInFullReadsBackWhateverTheNoun(separator: String) {
        for value in Self.writtenOutValues {
            let text = Self.grouped(value, by: separator)
            // Up to 999 there are no groups and only the nouns in English and German are known; from 1,000 on the number
            // is written out in full, so any Latin word that follows is just the noun.
            for noun in ["views", "Aufrufe", "subscribers", "Abonnenten", "videos", ""] {
                #expect(InnerTubeText.parseCount("\(text) \(noun)") == value, "\(text) \(noun)")
            }
            if value >= 1_000 {
                for noun in ["vues", "visualizaciones", "weergaven", "visningar", "visualiza\u{E7}\u{F5}es"] {
                    #expect(InnerTubeText.parseCount("\(text) \(noun)") == value, "\(text) \(noun)")
                }
            } else {
                #expect(InnerTubeText.parseCount("\(text) vues") == nil, "a short number and an unknown noun")
            }
            // Never a unit after a number written out in full.
            #expect(InnerTubeText.parseCount("\(text) K views") == nil)
            #expect(InnerTubeText.parseCount("\(text) \u{0442}\u{044B}\u{0441}.") == nil)
            #expect(InnerTubeText.parseCount("\(text)\u{4E07}") == nil)
        }
    }

    @Test func everyAbbreviatedCountReadsBackAsItsValue() {
        let mantissas: [(text: String, value: Double)] = [("1", 1), ("5", 5), ("12", 12), ("99", 99), ("100", 100), ("123", 123), ("999", 999), ("1.5", 1.5), ("9.8", 9.8), ("12.3", 12.3), ("0.5", 0.5), ("1.25", 1.25), ("123.4", 123.4)]
        for (text, value) in mantissas {
            // English: glued to the number.
            for (letter, factor) in [("K", 1e3), ("k", 1e3), ("M", 1e6), ("m", 1e6), ("B", 1e9), ("b", 1e9)] {
                let expected = Int((value * factor).rounded())
                #expect(InnerTubeText.parseCount("\(text)\(letter)") == expected, "\(text)\(letter)")
                #expect(InnerTubeText.parseCount("\(text)\(letter) views") == expected, "\(text)\(letter) views")
                #expect(InnerTubeText.parseCount("\(text) \(letter)") == nil, "English letters are not read after a space")
            }
            // German: decimal comma, unit after a space, with or without the dot.
            let german = text.replacingOccurrences(of: ".", with: ",")
            for (unit, factor) in [("Tsd.", 1e3), ("Tsd", 1e3), ("Mio.", 1e6), ("Mio", 1e6), ("Mrd.", 1e9), ("Mrd", 1e9)] {
                let expected = Int((value * factor).rounded())
                #expect(InnerTubeText.parseCount("\(german) \(unit)") == expected, "\(german) \(unit)")
                #expect(InnerTubeText.parseCount("\(german) \(unit) Aufrufe") == expected, "\(german) \(unit) Aufrufe")
            }
        }
    }

    @Test func randomTextNeverTrapsAndNeverMakesUpANumber() {
        // A deterministic xorshift generator, so a failure can be reproduced.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 1)
        }
        let pieces = [
            "0", "1", "2", "5", "7", "9", "12", "123", "1234", "999", "000", ",", ".", " ", "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2019}", "'",
            "K", "k", "M", "m", "B", "b", "Tsd.", "Mio.", "Mrd.", "views", "view", "Aufrufe", "vues", "watching", "No", "no ", "subscribers",
            "\u{4E07}", "\u{5104}", "\u{0442}\u{044B}\u{0441}.", "\u{0645}", "\u{0661}\u{0662}", "e\u{0301}", "\u{200E}", "\u{2068}", "+", "\u{2022}", "-", "%", "/", "\n", "\u{1F3AC}",
        ]
        for _ in 0..<20_000 {
            let text = (0..<(1 + abs(next()) % 12)).map { _ in pieces[abs(next()) % pieces.count] }.joined()
            if let value = InnerTubeText.parseCount(text) {
                // Whatever it answers is a count that fits the digits in the text: the largest abbreviation is 999B.
                #expect(value >= 0, "\(text.debugDescription)")
                #expect(text.contains(where: \.isNumber) || value == 0, "\(text.debugDescription)")
            }
        }
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
