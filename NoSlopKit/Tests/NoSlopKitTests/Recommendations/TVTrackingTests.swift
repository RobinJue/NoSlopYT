import Foundation
import Testing
@testable import NoSlopKit

private let watchtimeBase = URL(string: "https://s.youtube.com/api/stats/watchtime?cl=1&docid=v&ei=E&el=leanback&of=O&plid=P&vm=V&len=60")!

private func items(_ url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

@Suite struct TVTrackingTests {
    @Test func aWatchtimePingKeepsTheBaseItemsAndMovesToWww() {
        let url = TVTracking.pingURL(base: watchtimeBase, kind: .watchtime, docid: "v", length: 60, cpn: String(repeating: "c", count: 16), cmt: 30, st: 0, et: 30, final: false)
        let query = items(url)
        #expect(url.absoluteString.hasPrefix("https://www.youtube.com/api/stats/watchtime?"))
        for key in ["cl", "ei", "el", "of", "plid", "vm"] { #expect(query[key] != nil) }
        #expect(query["ei"] == "E")
        #expect(query["ns"] == "yt")
        #expect(query["ver"] == "2")
        #expect(query["cmt"] == "30.000")
        #expect(query["st"] == "0.000")
        #expect(query["et"] == "30.000")
        #expect(query["len"] == "60.000")
        #expect(query["docid"] == "v")
        #expect(query["cpn"] == String(repeating: "c", count: 16))
        #expect(query["final"] == nil)
    }

    @Test func aFinalPingSaysSo() {
        let url = TVTracking.pingURL(base: watchtimeBase, kind: .watchtime, docid: "v", length: 60, cpn: "cccccccccccccccc", cmt: 60, st: 0, et: 60, final: true)
        #expect(items(url)["final"] == "1")
    }

    @Test func aPlaybackPingHasNoStOrEt() {
        let base = URL(string: "https://s.youtube.com/api/stats/playback?cl=1&docid=v&ei=E&st=9&et=9&final=1")!
        let url = TVTracking.pingURL(base: base, kind: .playback, docid: "v", length: 60, cpn: "cccccccccccccccc", cmt: 0, st: nil, et: nil, final: false)
        let query = items(url)
        #expect(url.absoluteString.hasPrefix("https://www.youtube.com/api/stats/playback?"))
        #expect(query["st"] == nil)
        #expect(query["et"] == nil)
        #expect(query["final"] == nil)
        #expect(query["cmt"] == "0.000")
    }

    @Test func theBaseOrderIsKeptAndTheReportingItemsFollow() {
        let url = TVTracking.pingURL(base: watchtimeBase, kind: .watchtime, docid: "v", length: 60, cpn: "cccccccccccccccc", cmt: 1.5, st: 0, et: 1.5, final: false)
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        #expect(names == ["cl", "ei", "el", "of", "plid", "vm", "ns", "ver", "docid", "len", "cmt", "cpn", "st", "et"])
    }

    @Test func aCPNHasSixteenAllowedCharactersAndIsFresh() {
        let first = TVTracking.newCPN()
        #expect(first.count == 16)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(TVTracking.newCPN() != first)
    }

    @Test func trackingNeedsEIVMAndOF() throws {
        let values = TVTracking.values(fromPlayer: try Fixture.json("tvsynthetic_player_signed.json"))
        #expect(values.status == "OK")
        #expect(values.hasEI && values.hasVM && values.hasOF)
        #expect(values.playbackURL?.absoluteString.contains("/api/stats/playback") == true)
        #expect(values.watchtimeURL?.absoluteString.contains("/api/stats/watchtime") == true)
    }

    @Test func missingTrackingIsReportedAsMissing() {
        let values = TVTracking.values(fromPlayer: ["playabilityStatus": ["status": "LOGIN_REQUIRED"]])
        #expect(values.status == "LOGIN_REQUIRED")
        #expect(!values.hasEI && !values.hasVM && !values.hasOF)
        #expect(values.playbackURL == nil && values.watchtimeURL == nil)
    }

    @Test func aMissingOneOfTheThreeIsSeen() {
        let reply: JSON = [
            "playabilityStatus": ["status": "OK"],
            "playbackTracking": ["videostatsPlaybackUrl": ["baseUrl": "https://s.youtube.com/api/stats/playback?ei=E&vm=V&of="],
                                 "videostatsWatchtimeUrl": ["baseUrl": "https://s.youtube.com/api/stats/watchtime?ei=E&vm=V"]],
        ]
        let values = TVTracking.values(fromPlayer: reply)
        #expect(values.hasEI && values.hasVM && !values.hasOF)
    }

    @Test func theSignatureTimestampIsTheFirstSTS() {
        #expect(TVTracking.signatureTimestamp(fromHomepage: #"x"STS":20758,"y"STS":1"#) == 20758)
        #expect(TVTracking.signatureTimestamp(fromHomepage: "none") == nil)
    }
}
