import Foundation
import Testing
@testable import NoSlopKit

@Suite struct JSONTests {
    // MARK: Fixtures (from the plan)

    @Test func fixturesLoad() throws {
        let data = try Fixture.data("search_blender_tutorial.json")
        #expect(data.count > 600_000)
    }

    @Test func findAllCountsRenderers() throws {
        let j = try Fixture.json("search_blender_tutorial.json")
        #expect(j.findAll("videoRenderer").count == 17)
        #expect(j.findAll("shortsLockupViewModel").count == 5)
        #expect(j.first("videoRenderer")?["videoId"]?.string == "z-Xl9tGqH14")
    }

    /// The JSON fixtures captured before Task 1A (an explicit list, so fixtures added by later tasks can't affect it).
    private static let capturedJSONFixtures = [
        "browse_home_anon.json", "channel_blender_home.json", "channel_blender_live.json",
        "channel_blender_playlists.json", "channel_blender_shorts.json", "channel_blender_videos.json",
        "channel_blender_videos_cont.json", "comments_aqz.json", "comments_aqz_cont.json", "dearrow_prefix.json",
        "next_aqz.json", "next_aqz_related_cont.json", "next_rickroll.json", "next_with_chapters.json",
        "player_ios_sabr_only.json", "player_visionos_bigbuckbunny.json", "player_visionos_rickroll.json",
        "playlist_sample.json", "resolve_handle.json", "search_blender_tutorial.json",
        "search_blender_tutorial_cont.json", "search_channels_only.json", "search_playlists_only.json",
        "search_videos_only.json", "sponsorblock_prefix.json", "suggest_firefox.json", "visitor_id.json",
    ]

    @Test(arguments: capturedJSONFixtures)
    func everyCapturedFixtureParses(name: String) throws {
        let json = try Fixture.json(name)
        switch json {
        case .object(let object): #expect(!object.isEmpty)
        case .array(let array): #expect(!array.isEmpty)
        default: Issue.record("\(name) should be an object or an array")
        }
    }

    // MARK: Parsing

    @Test func parsesEveryScalarKind() throws {
        let json = try JSON(data: Data(#"{"t":true,"f":false,"one":1,"zero":0,"n":null,"s":"x","d":1.5,"neg":-3}"#.utf8))
        #expect(json["t"] == .bool(true))
        #expect(json["f"] == .bool(false))
        // 1 and 0 are numbers, never mistaken for booleans.
        #expect(json["one"] == .number(1))
        #expect(json["zero"] == .number(0))
        #expect(json["n"] == .null)
        #expect(json["s"] == .string("x"))
        #expect(json["d"] == .number(1.5))
        #expect(json["neg"] == .number(-3))
    }

    @Test func parsesTopLevelScalars() throws {
        #expect(try JSON(data: Data("42".utf8)) == .number(42))
        #expect(try JSON(data: Data("\"hi\"".utf8)) == .string("hi"))
        #expect(try JSON(data: Data("null".utf8)) == .null)
    }

    @Test func parsesUnicodeEscapes() throws {
        let json = try JSON(data: Data(#"{"a":"café 😀"}"#.utf8))
        #expect(json["a"]?.string == "caf\u{E9} \u{1F600}")
    }

    @Test func invalidJSONThrowsDecodingError() {
        #expect(throws: NoSlopError.self) { try JSON(data: Data("{oops".utf8)) }
        #expect(throws: NoSlopError.self) { try JSON(data: Data()) }
    }

    // MARK: Navigation

    @Test func subscriptsReturnNilInsteadOfTrapping() {
        let json: JSON = ["a": [10, 20], "s": "text"]
        #expect(json["a"]?[1] == .number(20))
        #expect(json["a"]?[2] == nil)
        #expect(json["a"]?[-1] == nil)
        #expect(json["missing"] == nil)
        #expect(json["s"]?["a"] == nil)
        #expect(json["s"]?[0] == nil)
        #expect(JSON.array([])[0] == nil)
        #expect(JSON.null["a"] == nil)
    }

    @Test func comparingWithNilMeansAbsentNotJSONNull() throws {
        // JSON is ExpressibleByNilLiteral, yet `== nil` is the Optional check: true only when the key is missing.
        let literal: JSON = ["k": nil]
        #expect(literal["k"] != nil)
        #expect(literal["k"] == .null)
        #expect(literal["absent"] == nil)

        let parsed = try JSON(data: Data(#"{"k":null}"#.utf8))
        #expect(parsed["k"] != nil)
        #expect(parsed["k"] == .null)
        #expect(parsed["k"]?.string == nil)
    }

    @Test func accessorsConvertOnlyMatchingTypes() {
        #expect(JSON.string("hi").string == "hi")
        #expect(JSON.number(5).string == nil)

        #expect(JSON.number(5).int == 5)
        #expect(JSON.number(5.5).int == nil)
        #expect(JSON.number(1e30).int == nil)
        #expect(JSON.string("635").int == 635)
        #expect(JSON.string(" 7 ").int == 7)
        #expect(JSON.string("x").int == nil)
        #expect(JSON.bool(true).int == nil)

        #expect(JSON.number(2.5).double == 2.5)
        #expect(JSON.string("2.5").double == 2.5)
        #expect(JSON.string("x").double == nil)

        #expect(JSON.bool(true).bool == true)
        #expect(JSON.number(1).bool == nil)
        #expect(JSON.string("true").bool == nil)

        #expect(JSON.array([1, 2]).array?.count == 2)
        #expect(JSON.object(["a": 1]).object?["a"] == .number(1))
        #expect(JSON.null.array == nil)
        #expect(JSON.null.object == nil)
    }

    @Test func literalsBuildTheExpectedCases() {
        let json: JSON = ["a": [1, 2.5, "s", true, nil], "b": ["c": false]]
        #expect(json["a"]?.array == [.number(1), .number(2.5), .string("s"), .bool(true), .null])
        #expect(json["b"]?["c"] == .bool(false))
        #expect(json["a"]?[1] == 2.5)
        #expect(json["b"]?["c"] == false)
    }

    @Test func duplicateKeysInADictionaryLiteralKeepTheLastValue() {
        let json = JSON(dictionaryLiteral: ("k", 1), ("k", 2))
        #expect(json["k"] == .number(2))
    }

    // MARK: Search

    @Test func findAllIsPreOrderWithSortedObjectKeys() {
        let json: JSON = [
            "b": ["id": 2, "inner": ["id": 3]],
            "a": ["id": 1],
            "c": [["id": 4], ["id": 5]],
        ]
        #expect(json.findAll("id").map(\.int) == [1, 2, 3, 4, 5])
    }

    @Test func findAllReportsAMatchBeforeMatchesInsideIt() {
        let json: JSON = ["x": ["x": "inner"]]
        let found = json.findAll("x")
        #expect(found.count == 2)
        #expect(found[0] == ["x": "inner"])
        #expect(found[1] == "inner")
    }

    @Test func findAllSearchesArraysAtTheRoot() {
        let json: JSON = [["k": 1], ["z": [["k": 2]]], "ignored", 5]
        #expect(json.findAll("k").map(\.int) == [1, 2])
    }

    @Test func firstReturnsTheFirstMatchOnly() {
        let json: JSON = ["a": ["id": "first"], "b": ["id": "second"]]
        #expect(json.first("id") == "first")
        #expect(json.first("nothing") == nil)
        #expect(JSON.string("x").first("id") == nil)
    }

    @Test func findAllIsDeterministicAcrossParses() throws {
        let data = try Fixture.data("search_blender_tutorial.json")
        let first = try JSON(data: data).findAll("videoId").compactMap(\.string)
        let second = try JSON(data: data).findAll("videoId").compactMap(\.string)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    // MARK: Serialising

    @Test func serialisesCompactSortedUTF8() throws {
        let json: JSON = ["b": [1, 2.5], "a": "x\"y\\z\n\u{1F600}", "n": nil, "t": true]
        let text = String(decoding: try json.data(), as: UTF8.self)
        #expect(text == #"{"a":"x\"y\\z\n😀","b":[1,2.5],"n":null,"t":true}"#)
    }

    @Test func wholeNumbersHaveNoFraction() throws {
        let text = String(decoding: try JSON.array([5, -3, 0, 1e20, 0.25]).data(), as: UTF8.self)
        #expect(text == "[5,-3,0,1e+20,0.25]")
    }

    @Test func controlCharactersAreEscapedAndSlashesAreNot() throws {
        let json: JSON = ["u": "https://www.youtube.com/@x\u{01}\t"]
        let text = String(decoding: try json.data(), as: UTF8.self)
        #expect(text == #"{"u":"https://www.youtube.com/@x\u0001\t"}"#)
    }

    @Test func roundTripsThroughOurParserAndFoundation() throws {
        let json: JSON = ["a": [1, "two", false, nil, ["deep": ["x": 1.5]]], "e": [], "o": [:], "s": "caf\u{E9} \u{1F600} \"q\""]
        let data = try json.data()
        #expect(try JSON(data: data) == json)
        // Foundation must agree that our output is valid JSON.
        #expect(throws: Never.self) { _ = try JSONSerialization.jsonObject(with: data) }
    }

    @Test func serialisingANonFiniteNumberThrows() {
        #expect(throws: NoSlopError.self) { try JSON.number(.infinity).data() }
        #expect(throws: NoSlopError.self) { try JSON.array([1, .number(.nan)]).data() }
    }

    @Test func fixtureSurvivesAParseSerialiseParseRoundTrip() throws {
        let original = try Fixture.json("resolve_handle.json")
        #expect(try JSON(data: original.data()) == original)
    }
}
