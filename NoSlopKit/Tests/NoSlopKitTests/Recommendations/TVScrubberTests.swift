import Foundation
import Testing
@testable import NoSlopKit

@Suite struct TVScrubberTests {
    private func text(_ json: JSON) throws -> String { String(decoding: try json.data(), as: UTF8.self) }

    private var sample: JSON {
        [
            "responseContext": [
                "visitorData": "tvsynthetic_visitor_value",
                "serviceTrackingParams": [
                    ["service": "GFEEDBACK", "params": [["key": "logged_in", "value": "1"]]],
                ],
            ],
            "frameworkUpdates": ["x": "dropped"],
            "contents": [
                "tile": [
                    "title": ["simpleText": "A private title"],
                    "shortBylineText": ["runs": [["text": "A Channel"]]],
                    "url": "https://rr1---sn-abc.googlevideo.com/videoplayback?x=1 from 198.51.100.23",
                    "onTap": ["continuationCommand": ["token": "ya29.tvsynthetic_secret"], "params": "tvsynthetic_params"],
                    "continuation": "REALCONT",
                ],
            ],
        ]
    }

    @Test func secretsParamsIpsAndTrackingAreRemoved() throws {
        let out = try text(TVScrubber.scrub(sample))
        #expect(!out.contains("tvsynthetic_visitor_value"))
        #expect(!out.contains("tvsynthetic_secret"))
        #expect(!out.contains("tvsynthetic_params"))
        #expect(!out.contains("googlevideo.com"))
        #expect(!out.contains("198.51.100.23"))
        #expect(!out.contains("REALCONT"))
        #expect(!out.contains("frameworkUpdates"))
        #expect(!out.contains("serviceTrackingParams"))
        #expect(out.contains("CONTINUATION_1"))
        #expect(out.contains("203.0.113.7"))
        #expect(TVScrubber.leaks(out).isEmpty)
    }

    @Test func titlesAndChannelsCanBeRelabelled() throws {
        let out = try text(TVScrubber.scrub(sample, hideTitles: true))
        #expect(!out.contains("A private title"))
        #expect(!out.contains("A Channel"))
        #expect(out.contains("Title 1"))
        #expect(out.contains("Channel 1"))
    }

    @Test func loggedInIsKeptAsAFlag() throws {
        let out = TVScrubber.scrub(sample)
        #expect(out["_loggedIn"] == true)
    }

    @Test func leaksFindsTokensBearersAndForeignIPs() {
        #expect(TVScrubber.leaks("x ya29.abc-DEF_1 y") == ["ya29.abc-DEF_1"])
        #expect(TVScrubber.leaks("Authorization: Bearer abc.def").count == 1)
        #expect(TVScrubber.leaks("refresh 1//0gAbCd-ef").count == 1)
        #expect(TVScrubber.leaks("from 10.1.2.3 and 203.0.113.7") == ["10.1.2.3"])
        #expect(TVScrubber.leaks("https://example.invalid/ nothing here").isEmpty)
    }
}
