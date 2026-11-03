import Foundation
import Testing
@testable import NoSlopKit

private func resolve(_ text: String) -> ResolvedURL? {
    guard let url = URL(string: text) else { return nil }
    return YouTubeURL.resolveLocally(url)
}

@Suite struct YouTubeURLTests {
    // MARK: From the plan

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", ResolvedURL.video(id: "dQw4w9WgXcQ", startSeconds: 42)),
        ("https://youtu.be/dQw4w9WgXcQ?t=1m5s", ResolvedURL.video(id: "dQw4w9WgXcQ", startSeconds: 65)),
        ("https://m.youtube.com/watch?v=jNQXAC9IVRw", ResolvedURL.video(id: "jNQXAC9IVRw", startSeconds: nil)),
        ("https://www.youtube.com/shorts/gIjBeEvDXew", ResolvedURL.video(id: "gIjBeEvDXew", startSeconds: nil)),
        ("https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg", ResolvedURL.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")),
        ("https://www.youtube.com/playlist?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B", ResolvedURL.playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")),
        ("noslop://watch?v=dQw4w9WgXcQ&t=10", ResolvedURL.video(id: "dQw4w9WgXcQ", startSeconds: 10)),
        ("noslop://channel/UCSMOQeBJ2RAnuFungnQOxLg", ResolvedURL.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")),
        ("noslop://search?q=blender%20donut", ResolvedURL.search(query: "blender donut")),
    ])
    func planTable(input: String, expected: ResolvedURL) {
        #expect(resolve(input) == expected)
    }

    @Test(arguments: [
        "https://www.youtube.com/@BlenderOfficial",   // a handle needs the network
        "https://example.com/watch?v=x",
    ])
    func planTableNeedsTheNetworkOrIsForeign(input: String) {
        #expect(resolve(input) == nil)
    }

    @Test func extractURLFindsTheLinkInAShareMessage() {
        #expect(YouTubeURL.extractURL(from: "look https://youtu.be/dQw4w9WgXcQ !")?.absoluteString == "https://youtu.be/dQw4w9WgXcQ")
    }

    // MARK: Hosts

    @Test(arguments: [
        "https://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://gaming.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://WWW.YouTube.COM/watch?v=dQw4w9WgXcQ",
        "HTTPS://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "https://youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://www.youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/v/dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share&si=abcDEF123",
        "https://youtu.be/dQw4w9WgXcQ?si=abcDEF123&feature=shared",
    ])
    func everyKnownHostAndPathFormGivesTheVideo(input: String) {
        #expect(resolve(input) == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test(arguments: [
        "https://example.com/watch?v=dQw4w9WgXcQ",
        "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "https://evilyoutu.be/dQw4w9WgXcQ",
        "https://youtube.evil.com/watch?v=dQw4w9WgXcQ",
        "https://vimeo.com/123456789",
        "ftp://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "file:///watch?v=dQw4w9WgXcQ",
        "mailto:someone@youtube.com",
        "youtube.com/watch?v=dQw4w9WgXcQ",   // no scheme: the caller must add one
        "//www.youtube.com/watch?v=dQw4w9WgXcQ",
    ])
    func foreignHostsAndSchemesAreNotResolved(input: String) {
        #expect(resolve(input) == nil)
    }

    // MARK: Video ids

    @Test func theFirstElevenCharactersOfAGluedQueryAreTheId() {
        // "…?v=ID?feature=share" (a typo that is common in pasted links) leaves one value: "ID?feature=share".
        #expect(resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ?feature=share") == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test func idsStartingWithADashOrUnderscoreAreFine() {
        #expect(resolve("https://youtu.be/-abc_DEF-12") == .video(id: "-abc_DEF-12", startSeconds: nil))
        #expect(resolve("https://youtu.be/_abc-DEF_12") == .video(id: "_abc-DEF_12", startSeconds: nil))
    }

    @Test(arguments: [
        "https://www.youtube.com/watch",
        "https://www.youtube.com/watch?v=",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=waytoolongforavideoid",
        "https://www.youtube.com/watch?v=has%20space",
        "https://www.youtube.com/watch?v=dQw4w9WgXc!",
        "https://www.youtube.com/shorts/",
        "https://www.youtube.com/shorts",
        "https://www.youtube.com/embed/",
        "https://youtu.be/",
        "https://youtu.be",
        "https://www.youtube.com/",
        "https://www.youtube.com",
        "https://www.youtube.com/feed/subscriptions",
        "https://www.youtube.com/user/BlenderFoundation",
        "https://www.youtube.com/c/BlenderFoundation",
        "https://www.youtube.com/BlenderFoundation",
        "https://www.youtube.com/@BlenderOfficial/videos",
    ])
    func linksWithoutAUsableIdAreLeftToTheNetwork(input: String) {
        #expect(resolve(input) == nil)
    }

    // MARK: Start times

    @Test(arguments: [
        ("42", 42), ("42s", 42), ("1m5s", 65), ("1h2m3s", 3_723), ("90", 90), ("0", 0), ("0s", 0),
        ("2h", 7_200), ("3m", 180), ("1m", 60), ("1h", 3_600), ("1H2M3S", 3_723), ("65s", 65),
        ("1:05", 65), ("1:02:03", 3_723), ("0:42", 42), ("1m5", 65),
    ])
    func startTimeForms(value: String, seconds: Int) {
        #expect(resolve("https://youtu.be/dQw4w9WgXcQ?t=\(value)") == .video(id: "dQw4w9WgXcQ", startSeconds: seconds))
    }

    @Test(arguments: ["", "abc", "-5", "1x", "m", "1.5", "1m-5", "99999999999999999999", "1:2:3:4", "::", "1h99999999999999999999m"])
    func unusableStartTimesAreIgnoredButTheVideoStillOpens(value: String) {
        #expect(resolve("https://youtu.be/dQw4w9WgXcQ?t=\(value)") == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test func startAndTimeContinueAreAlternativesToT() {
        #expect(resolve("https://www.youtube.com/embed/dQw4w9WgXcQ?start=30") == .video(id: "dQw4w9WgXcQ", startSeconds: 30))
        #expect(resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ&time_continue=7") == .video(id: "dQw4w9WgXcQ", startSeconds: 7))
    }

    @Test func tWinsOverStart() {
        #expect(resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ&start=5&t=9") == .video(id: "dQw4w9WgXcQ", startSeconds: 9))
    }

    @Test func theTimeMayAlsoSitInTheFragment() {
        #expect(resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ#t=1m5s") == .video(id: "dQw4w9WgXcQ", startSeconds: 65))
        #expect(resolve("https://youtu.be/dQw4w9WgXcQ#t=12") == .video(id: "dQw4w9WgXcQ", startSeconds: 12))
    }

    // MARK: Playlists, channels, search

    @Test func aWatchLinkWithOnlyAListIsThePlaylist() {
        #expect(resolve("https://www.youtube.com/watch?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B") == .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"))
    }

    @Test func theVideoWinsWhenALinkNamesBothAVideoAndAList() {
        #expect(resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B&index=3") == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test func embeddedPlaylistsAreRecognised() {
        // "videoseries" has eleven valid characters, so it must not be mistaken for a video id.
        #expect(resolve("https://www.youtube.com/embed/videoseries?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B") == .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"))
        #expect(resolve("https://www.youtube.com/embed/videoseries") == nil)
    }

    @Test(arguments: [
        "https://www.youtube.com/playlist",
        "https://www.youtube.com/playlist?list=",
        "https://www.youtube.com/playlist?list=PL%20bad",
        "https://www.youtube.com/playlist?foo=bar",
    ])
    func playlistLinksWithoutAUsableListAreNotResolved(input: String) {
        #expect(resolve(input) == nil)
    }

    @Test func channelLinksNeedAChannelId() {
        #expect(resolve("https://www.youtube.com/channel/UCOKHwx1VCdgnxwbjyb9Iu1g/videos") == .channel(id: "UCOKHwx1VCdgnxwbjyb9Iu1g"))
        #expect(resolve("https://m.youtube.com/channel/UCOKHwx1VCdgnxwbjyb9Iu1g?si=x") == .channel(id: "UCOKHwx1VCdgnxwbjyb9Iu1g"))
        #expect(resolve("https://www.youtube.com/channel/") == nil)
        #expect(resolve("https://www.youtube.com/channel/notAChannelId") == nil)
        #expect(resolve("https://www.youtube.com/channel/UC bad") == nil)
    }

    @Test func youtubeSearchPagesBecomeSearches() {
        #expect(resolve("https://www.youtube.com/results?search_query=blender+donut") == .search(query: "blender donut"))
        #expect(resolve("https://www.youtube.com/results?search_query=blender%20donut") == .search(query: "blender donut"))
        #expect(resolve("https://www.youtube.com/results?search_query=") == nil)
        #expect(resolve("https://www.youtube.com/results") == nil)
    }

    // MARK: noslop:// links

    @Test func noslopLinks() {
        #expect(resolve("noslop://watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
        #expect(resolve("noslop://watch?v=dQw4w9WgXcQ&start=7") == .video(id: "dQw4w9WgXcQ", startSeconds: 7))
        #expect(resolve("noslop://playlist/PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B") == .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"))
        #expect(resolve("noslop://playlist?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B") == .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"))
        #expect(resolve("noslop://search?q=a%2Bb%20c") == .search(query: "a+b c"))
        #expect(resolve("NOSLOP://watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test(arguments: [
        "noslop://watch",
        "noslop://watch?v=",
        "noslop://channel",
        "noslop://channel/",
        "noslop://playlist",
        "noslop://search",
        "noslop://search?q=",
        "noslop://tab/home",
        "noslop://route/settings",
        "noslop://unknown/thing",
        "noslop:",
    ])
    func noslopLinksThatAreNotContentLinks(input: String) {
        #expect(resolve(input) == nil)
    }

    // MARK: extractURL

    @Test func extractURLFromPlainURLs() {
        #expect(YouTubeURL.extractURL(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(YouTubeURL.extractURL(from: "  https://youtu.be/dQw4w9WgXcQ\n")?.absoluteString == "https://youtu.be/dQw4w9WgXcQ")
    }

    @Test func extractURLTakesTheFirstOfSeveralLinks() {
        let text = "first https://youtu.be/dQw4w9WgXcQ then https://youtu.be/jNQXAC9IVRw"
        #expect(YouTubeURL.extractURL(from: text)?.absoluteString == "https://youtu.be/dQw4w9WgXcQ")
    }

    @Test func extractURLKeepsTheQueryAndDropsSentencePunctuation() {
        #expect(YouTubeURL.extractURL(from: "Watch this: https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s.")?.absoluteString
            == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        #expect(YouTubeURL.extractURL(from: "(https://youtu.be/dQw4w9WgXcQ)")?.absoluteString == "https://youtu.be/dQw4w9WgXcQ")
    }

    @Test func extractURLAcceptsALinkWithoutAScheme() throws {
        let url = try #require(YouTubeURL.extractURL(from: "youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(YouTubeURL.resolveLocally(url) == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test func extractURLFindsTheAppsOwnLinks() throws {
        let url = try #require(YouTubeURL.extractURL(from: "open noslop://watch?v=dQw4w9WgXcQ&t=10 please"))
        #expect(url.scheme == "noslop")
        #expect(YouTubeURL.resolveLocally(url) == .video(id: "dQw4w9WgXcQ", startSeconds: 10))
    }

    @Test(arguments: [
        "",
        "   ",
        "blender donut tutorial",
        "how to model a donut in blender?",
        "mail me at someone@example.com",
        "call +49 30 1234567",
        "3.14159 is pi",
    ])
    func extractURLReturnsNilForPlainSearches(text: String) {
        #expect(YouTubeURL.extractURL(from: text) == nil)
    }

    @Test func extractURLToleratesVeryLongText() {
        let filler = String(repeating: "blender donut ", count: 5_000)
        _ = YouTubeURL.extractURL(from: filler + " https://youtu.be/dQw4w9WgXcQ")
        // It must return (quickly) either way; whether a link beyond the scanned window is found is not specified.
        #expect(YouTubeURL.extractURL(from: filler) == nil)
    }
}
