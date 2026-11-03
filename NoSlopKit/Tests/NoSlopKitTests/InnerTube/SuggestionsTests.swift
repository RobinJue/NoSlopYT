import Foundation
import Testing
@testable import NoSlopKit

@Suite struct SuggestionsTests {
    // MARK: From the plan

    @Test func firefoxSuggestions() throws {
        let s = SuggestionsParser.parse(try Fixture.data("suggest_firefox.json"))
        #expect(s.count == 10)
        #expect(s.first == "blender tutorial")
    }

    // MARK: Robustness

    @Test func firefoxSuggestionsKeepTheirOrder() throws {
        let s = SuggestionsParser.parse(try Fixture.data("suggest_firefox.json"))
        #expect(s.prefix(3) == ["blender tutorial", "blender tutorial for beginners", "blender tutorial animation"])
        #expect(s.last == "blender tutorial modeling")
    }

    @Test func theJSONPFlavourOfTheEndpointIsUnderstoodToo() throws {
        let s = SuggestionsParser.parse(try Fixture.data("suggest_youtube_jsonp.txt"))
        #expect(s.count == 14)
        #expect(s.first == "blender tutorial")
        #expect(s.last == "blender tutorial 2d animation")
    }

    @Test func nonASCIISuggestionsSurvive() {
        let data = Data(#"["größe",["größer werden","größenvergleich","日本語 ♪ 🎬"],[],{}]"#.utf8)
        #expect(SuggestionsParser.parse(data) == ["größer werden", "größenvergleich", "日本語 ♪ 🎬"])
    }

    @Test func entriesThatAreNotStringsAreSkipped() {
        // (An array whose first element is a string is the JSONP flavour's entry shape and does count.)
        let data = Data(#"["q",["a",1,null,"b",[2,"x"],[],{"x":1},"",  "  ","c"],[]]"#.utf8)
        #expect(SuggestionsParser.parse(data) == ["a", "b", "c"])
    }

    @Test func duplicatesAreKeptOnce() {
        let data = Data(#"["q",["a","b","a","c","b"]]"#.utf8)
        #expect(SuggestionsParser.parse(data) == ["a", "b", "c"])
    }

    @Test func whitespaceAroundSuggestionsIsTrimmed() {
        let data = Data(#"["q",["  blender  ","\tcycles\n"]]"#.utf8)
        #expect(SuggestionsParser.parse(data) == ["blender", "cycles"])
    }

    @Test(arguments: [
        "",
        "not json",
        "{}",
        "[]",
        #"["q"]"#,
        #"["q", null]"#,
        #"["q","not an array"]"#,
        #"{"suggestions":["a"]}"#,
        "<html><body>Error 403</body></html>",
        "window.google.ac.h(",
    ])
    func unusableInputGivesNoSuggestions(text: String) {
        #expect(SuggestionsParser.parse(Data(text.utf8)).isEmpty)
    }
}
