import Foundation
import Testing
@testable import NoSlopKit

@Suite struct WebVTTParserTests {
    // MARK: From the plan

    @Test func rickrollVTT() throws {
        let cues = WebVTTParser.parse(String(decoding: try Fixture.data("captions_rickroll.vtt"), as: UTF8.self))
        try #require(cues.count >= 3)
        #expect(cues[0] == CaptionCue(start: 1.36, end: 3.04, text: "[♪♪♪]"))
        #expect(cues[1].start == 18.64)
        #expect(cues[1].text == "♪ We're no strangers to love ♪")
        #expect(cues[2].text == "♪ You know the rules\nand so do I ♪")
    }

    // MARK: The captured file

    @Test func theCapturedFileHasAllItsCuesInOrder() throws {
        let cues = WebVTTParser.parse(String(decoding: try Fixture.data("captions_rickroll.vtt"), as: UTF8.self))
        #expect(cues.count == 61)
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
        #expect(cues.allSatisfy { $0.end > $0.start && !$0.text.isEmpty })
        #expect(cues.last?.text == "♪ Never gonna tell a lie\nand hurt you ♪")
        #expect(cues.last?.start == 207.92)
        #expect(cues.last?.end == 211.32)
    }

    // MARK: Timestamps

    @Test func timestampsWithHoursMinutesAndMilliseconds() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        01:02:03.456 --> 01:02:04.001
        long
        """)
        #expect(cues == [CaptionCue(start: 3_723.456, end: 3_724.001, text: "long")])
    }

    @Test func hoursAreOptional() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        00:01.500 --> 00:03.250
        short
        """)
        #expect(cues == [CaptionCue(start: 1.5, end: 3.25, text: "short")])
    }

    @Test func millisecondsAreExactNotAccumulatedFloatingPointError() {
        // 18.64 and 1.36 must equal the literals, which a "seconds + 0.640" sum would not guarantee.
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:18.640 --> 00:00:21.880\nx\n\n00:00:01.360 --> 00:00:03.040\ny\n")
        #expect(cues.map(\.start) == [1.36, 18.64])   // sorted by start
        #expect(cues.map(\.end) == [3.04, 21.88])
    }

    @Test func fractionsOfOtherLengthsAndCommaSeparators() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        00:00:01.5 --> 00:00:02.25
        a

        00:00:03,500 --> 00:00:04,750
        b

        00:00:05.1234 --> 00:00:06
        c
        """)
        #expect(cues.map(\.start) == [1.5, 3.5, 5.123])
        #expect(cues.map(\.end) == [2.25, 4.75, 6.0])
    }

    @Test func cueSettingsAreIgnored() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        00:00:00.320 --> 00:00:18.790 align:start position:0% line:90% size:80%
        [Music]
        """)
        #expect(cues == [CaptionCue(start: 0.32, end: 18.79, text: "[Music]")])
    }

    @Test(arguments: [
        "00:00:01.000 -> 00:00:02.000",       // wrong arrow
        "00:00:01.000 --> ",                  // no end
        " --> 00:00:02.000",                  // no start
        "xx:yy:zz.000 --> 00:00:02.000",
        "00:00:01.000 --> 00:00:xx.000",
        "1 --> 2",
        "00:00:05.000 --> 00:00:02.000",      // ends before it starts
    ])
    func cuesWithBadTimingAreSkipped(timing: String) {
        let cues = WebVTTParser.parse("WEBVTT\n\n\(timing)\nlost\n\n00:00:10.000 --> 00:00:11.000\nkept\n")
        #expect(cues == [CaptionCue(start: 10, end: 11, text: "kept")])
    }

    @Test func minutesAndSecondsBeyondFiftyNineAreAcceptedArithmetically() {
        // Sloppy generators write long media as "90:00.000"; being lenient costs nothing.
        let cues = WebVTTParser.parse("WEBVTT\n\n90:00.000 --> 90:30.500\nlong\n\n00:00:75.000 --> 00:00:76.000\nodd\n")
        #expect(cues == [CaptionCue(start: 75, end: 76, text: "odd"), CaptionCue(start: 5_400, end: 5_430.5, text: "long")])
    }

    @Test func aCueWithUnreadableTimingNeitherSurvivesNorSticksToItsNeighbour() {
        // No blank lines here: the broken timing line must end "first" and swallow its own text.
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nfirst\n00:00:0x.000 --> 00:00:04.000\nlost\n\n00:00:05.000 --> 00:00:06.000\nlast\n")
        #expect(cues.map(\.text) == ["first", "last"])
    }

    // MARK: Structure

    @Test func headerNotesStylesAndRegionsAreSkipped() {
        let cues = WebVTTParser.parse("""
        WEBVTT - a title
        Kind: captions
        Language: en

        NOTE this is a comment
        that spans two lines

        STYLE
        ::cue { color: lime }

        REGION
        id:fred
        width:40%

        00:00:01.000 --> 00:00:02.000
        text
        """)
        #expect(cues == [CaptionCue(start: 1, end: 2, text: "text")])
    }

    @Test func aNoteInsideTheCueSectionDoesNotLeakIntoTheText() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        first

        NOTE a remark

        00:00:03.000 --> 00:00:04.000
        second
        """)
        #expect(cues.map(\.text) == ["first", "second"])
    }

    @Test func cueIdentifiersAreSkipped() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        intro
        00:00:01.000 --> 00:00:02.000
        first

        2
        00:00:03.000 --> 00:00:04.000
        second
        """)
        #expect(cues.map(\.text) == ["first", "second"])
    }

    @Test func multiLineCuesJoinWithNewlines() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nline one\nline two\nline three\n")
        #expect(cues.first?.text == "line one\nline two\nline three")
    }

    @Test func aWhitespaceOnlyLineDoesNotEndACue() {
        // YouTube's auto-generated tracks put a lone space before the real text; only an empty line separates cues.
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:00.320 --> 00:00:18.790 align:start position:0%\n \n[Music]\n\n00:00:19.000 --> 00:00:20.000\nnext\n")
        #expect(cues.map(\.text) == ["[Music]", "next"])
    }

    @Test func cuesWithoutTextAreDropped() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:18.790 --> 00:00:18.800\n \n \n\n00:00:19.000 --> 00:00:20.000\nkept\n\n00:00:21.000 --> 00:00:22.000\n<c></c>\n")
        #expect(cues.map(\.text) == ["kept"])
    }

    @Test func textIsTrimmedPerLine() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n   padded   \n\t tab\t\n")
        #expect(cues.first?.text == "padded\ntab")
    }

    @Test func cuesAreReturnedSortedByStartAndKeepTheirOrderOnTies() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        00:00:05.000 --> 00:00:06.000
        late

        00:00:01.000 --> 00:00:02.000
        tie a

        00:00:01.000 --> 00:00:03.000
        tie b
        """)
        #expect(cues.map(\.text) == ["tie a", "tie b", "late"])
    }

    @Test func cuesWithoutABlankLineBetweenThemStillSplit() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nfirst\n00:00:03.000 --> 00:00:04.000\nsecond\n")
        #expect(cues.map(\.text) == ["first", "second"])
    }

    // MARK: Line endings and encodings

    @Test func windowsAndOldMacLineEndings() {
        let crlf = WebVTTParser.parse("WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nline one\r\nline two\r\n\r\n00:00:03.000 --> 00:00:04.000\r\nnext\r\n")
        #expect(crlf.map(\.text) == ["line one\nline two", "next"])
        let cr = WebVTTParser.parse("WEBVTT\r\r00:00:01.000 --> 00:00:02.000\rone\r\r00:00:03.000 --> 00:00:04.000\rtwo\r")
        #expect(cr.map(\.text) == ["one", "two"])
    }

    @Test func aByteOrderMarkBeforeTheHeaderIsIgnored() {
        let cues = WebVTTParser.parse("\u{FEFF}WEBVTT\n\n00:00:01.000 --> 00:00:02.000\ntext\n")
        #expect(cues.map(\.text) == ["text"])
    }

    @Test func aFileWithoutAHeaderStillParses() {
        let cues = WebVTTParser.parse("00:00:01.000 --> 00:00:02.000\ntext\n")
        #expect(cues.map(\.text) == ["text"])
    }

    @Test func emojiAndCJKSurvive() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n日本語の字幕 🎬 ♪\n")
        #expect(cues.first?.text == "日本語の字幕 🎬 ♪")
    }

    // MARK: Markup and entities

    @Test func inlineTagsAreStripped() {
        let cues = WebVTTParser.parse("""
        WEBVTT

        00:00:19.000 --> 00:00:21.000
        We're<00:00:19.039><c> no</c><00:00:19.359><c> strangers</c> <i>to</i> <b>love</b>
        <v Roger>Hello</v> <c.colorE5E5E5>there</c> <ruby>a<rt>b</rt></ruby>
        """)
        #expect(cues.first?.text == "We're no strangers to love\nHello there ab")
    }

    @Test func namedAndNumericEntitiesAreDecoded() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nTom &amp; Jerry &lt;3 &gt; &quot;hi&quot; it&#39;s&nbsp;fine &#x266A; &#9835;\n")
        #expect(cues.first?.text == "Tom & Jerry <3 > \"hi\" it's fine ♪ ♫")
    }

    @Test func entitiesAreDecodedOnlyOnce() {
        // "&amp;lt;" is the text "&lt;", not "<".
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n&amp;lt; &amp;amp; &amp;#39;\n")
        #expect(cues.first?.text == "&lt; &amp; &#39;")
    }

    @Test func escapedAngleBracketsAreTextNotTags() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nuse &lt;b&gt; for bold\n")
        #expect(cues.first?.text == "use <b> for bold")
    }

    @Test func unknownEntitiesAndStrayAmpersandsAreLeftAlone() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nR&D &unknown; & more &#; &#xZZ; &#99999999999;\n")
        #expect(cues.first?.text == "R&D &unknown; & more &#; &#xZZ; &#99999999999;")
    }

    @Test func aLoneLessThanSignWithoutAClosingBracketIsKept() {
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n3 < 4 and that is it\n")
        #expect(cues.first?.text == "3 < 4 and that is it")
    }

    @Test func everythingBehindAnUnclosedLessThanSignIsText() {
        // Tags that are closed are removed; from the first "<" that has no ">" after it, the rest stays as written.
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<b>bold</b> 1 < 2 << 3 <\n")
        #expect(cues.first?.text == "bold 1 < 2 << 3 <")
    }

    @Test func aLineOfManyUnclosedLessThanSignsIsParsedInLinearTime() {
        // Each "<" used to search the rest of the line for a ">" again: 50,000 of them took 45 seconds in a debug
        // build. Caption files are content any uploader controls, so this must not be possible to exploit.
        let line = String(repeating: "<", count: 50_000)
        let started = ContinuousClock.now
        let cues = WebVTTParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n\(line)\n")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(cues.first?.text == line)
    }

    // MARK: The auto-generated roll-up style

    @Test func autoGeneratedRollUpCuesParse() {
        // Captured from a real auto-generated track. The single-space lines are payload, not separators, so the
        // lines are listed explicitly (an editor may strip trailing whitespace from a multi-line literal).
        let space = " "
        let lines = [
            "WEBVTT", "Kind: captions", "Language: en", "",
            "00:00:00.320 --> 00:00:18.790 align:start position:0%", space, "[Music]", "",
            "00:00:18.790 --> 00:00:18.800 align:start position:0%", space, space, "",
            "00:00:18.800 --> 00:00:21.790 align:start position:0%", space,
            "We're<00:00:19.039><c> no</c><00:00:19.359><c> strangers</c><00:00:19.840><c> to</c>", "",
            "00:00:21.790 --> 00:00:21.800 align:start position:0%", "We're no strangers to", space, "",
            "00:00:21.800 --> 00:00:25.950 align:start position:0%", "We're no strangers to",
            "love.<00:00:22.800><c> You</c><00:00:23.039><c> know</c><00:00:23.279><c> the</c>", "",
        ]
        let cues = WebVTTParser.parse(lines.joined(separator: "\n"))
        #expect(cues.map(\.text) == ["[Music]", "We're no strangers to", "We're no strangers to", "We're no strangers to\nlove. You know the"])
        #expect(cues.map(\.start) == [0.32, 18.8, 21.79, 21.8])
        #expect(cues.map(\.end) == [18.79, 21.79, 21.8, 25.95])
    }

    // MARK: Nothing usable

    @Test(arguments: ["", "\n\n\n", "WEBVTT", "WEBVTT\n\n", "not a caption file at all", "<html><body>Error</body></html>", "{\"events\":[]}"])
    func inputWithoutCuesGivesNoCues(text: String) {
        #expect(WebVTTParser.parse(text).isEmpty)
    }
}

// MARK: - CaptionsService

@Suite struct WebVTTCaptionsServiceTests {
    private let track = CaptionTrack(
        languageCode: "en",
        name: "English",
        baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&caps=asr&sparams=ip,ipbits,expire,v&signature=6A3A.2C85&key=yt8&lang=en")!
    )

    @Test func fetchesTheTrackAsWebVTTAndParsesIt() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/timedtext", body: try Fixture.data("captions_rickroll.vtt"))

        let cues = try await CaptionsService(http: http).cues(for: track)

        try #require(cues.count == 61)
        #expect(cues[0] == CaptionCue(start: 1.36, end: 3.04, text: "[♪♪♪]"))
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        // The signed baseURL is kept byte for byte; only "&fmt=vtt" is added.
        #expect(request.url?.absoluteString == track.baseURL.absoluteString + "&fmt=vtt")
        #expect(http.requests.count == 1)
    }

    @Test func anExistingFormatParameterIsReplaced() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/timedtext", body: Data("WEBVTT\n".utf8))
        let json3 = CaptionTrack(languageCode: "en", name: "English", baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=x&fmt=srv3&lang=en")!)
        _ = try await CaptionsService(http: http).cues(for: json3)
        #expect(http.requests.first?.url?.absoluteString == "https://www.youtube.com/api/timedtext?v=x&lang=en&fmt=vtt")
    }

    @Test func aBaseURLWithoutAQueryGetsOne() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/timedtext", body: Data("WEBVTT\n".utf8))
        let bare = CaptionTrack(languageCode: "en", name: "English", baseURL: URL(string: "https://www.youtube.com/api/timedtext")!)
        _ = try await CaptionsService(http: http).cues(for: bare)
        #expect(http.requests.first?.url?.absoluteString == "https://www.youtube.com/api/timedtext?fmt=vtt")
    }

    @Test func anEmptyTrackIsAnEmptyList() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/timedtext", body: Data())
        #expect(try await CaptionsService(http: http).cues(for: track).isEmpty)
    }

    @Test func httpErrorsMap() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/timedtext", status: 403, body: Data("forbidden".utf8))
        let service = CaptionsService(http: http)
        await #expect(throws: NoSlopError.http(status: 403)) {
            _ = try await service.cues(for: track)
        }
    }

    @Test func networkErrorsPropagate() async throws {
        let http = MockHTTPClient()
        http.enqueueError("api/timedtext", NoSlopError.network("offline"))
        let service = CaptionsService(http: http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await service.cues(for: track)
        }
    }

    @Test func invalidUTF8DoesNotThrow() async throws {
        let http = MockHTTPClient()
        var bytes = Array("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nab".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(contentsOf: Array("cd\n".utf8))
        http.enqueue("api/timedtext", body: Data(bytes))
        let cues = try await CaptionsService(http: http).cues(for: track)
        try #require(cues.count == 1)
        #expect(cues[0].text.hasPrefix("ab") && cues[0].text.hasSuffix("cd"))
    }
}
