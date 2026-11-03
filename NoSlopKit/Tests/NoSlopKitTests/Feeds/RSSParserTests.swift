import Foundation
import Testing
@testable import NoSlopKit

private func feed(_ entries: String, header: String = "") -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <yt:channelId>SMOQeBJ2RAnuFungnQOxLg</yt:channelId>
     <title>Feed title</title>
     \(header)
     \(entries)
    </feed>
    """.utf8)
}

private func entry(
    id: String? = "dQw4w9WgXcQ",
    channelID: String? = "UCSMOQeBJ2RAnuFungnQOxLg",
    title: String = "A title",
    link: String? = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    author: String? = "Blender",
    published: String? = "2026-11-02T13:54:25+00:00",
    thumbnail: String? = "https://i2.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    views: String? = "9793"
) -> String {
    var lines = ["<entry>"]
    if let id { lines.append("<id>yt:video:\(id)</id>"); lines.append("<yt:videoId>\(id)</yt:videoId>") }
    if let channelID { lines.append("<yt:channelId>\(channelID)</yt:channelId>") }
    lines.append("<title>\(title)</title>")
    if let link { lines.append(#"<link rel="alternate" href="\#(link)"/>"#) }
    if let author { lines.append("<author><name>\(author)</name><uri>https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg</uri></author>") }
    if let published { lines.append("<published>\(published)</published><updated>2026-11-02T15:13:38+00:00</updated>") }
    lines.append("<media:group>")
    lines.append("<media:title>Media title that must not be used</media:title>")
    if let thumbnail { lines.append(#"<media:thumbnail url="\#(thumbnail)" width="480" height="360"/>"#) }
    lines.append("<media:description>Description</media:description>")
    lines.append("<media:community><media:starRating count=\"226\" average=\"5.00\" min=\"1\" max=\"5\"/>")
    if let views { lines.append(#"<media:statistics views="\#(views)"/>"#) }
    lines.append("</media:community></media:group>")
    lines.append("</entry>")
    return lines.joined(separator: "\n")
}

@Suite struct RSSParserTests {
    // MARK: From the plan

    @Test func blenderFeed() throws {
        let v = RSSParser.parse(try Fixture.data("rss_blender.xml"))
        #expect(v.count == 15)
        #expect(v.filter(\.isShort).count == 2)
        let first = try #require(v.first)
        #expect(first.id == "mHrHLqQj7Ts")
        #expect(first.title == "Making of: The Blender Open Movies Exhibition")
        #expect(first.publishedAt == ISO8601DateFormatter().date(from: "2026-11-02T13:54:25Z"))
        #expect(first.viewCount == 9793)
        #expect(first.channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"))
        #expect(first.thumbnails.first?.url.absoluteString == "https://i2.ytimg.com/vi/mHrHLqQj7Ts/hqdefault.jpg")
    }

    // MARK: The captured feed

    @Test func theFeedKeepsItsOrderAndFlagsTheShorts() throws {
        let v = RSSParser.parse(try Fixture.data("rss_blender.xml"))
        #expect(v.map(\.id).prefix(5) == ["mHrHLqQj7Ts", "H5TGt-susIY", "YsKxkP_kGbE", "dVrELpmfcEQ", "EycY6jDFK74"])
        #expect(v.filter(\.isShort).map(\.id) == ["YsKxkP_kGbE", "EycY6jDFK74"])
        #expect(v.last?.id == "X-zb1FxHuCw")
    }

    @Test func everyEntryHasTheChannelFromItsOwnEntryNotTheFeed() throws {
        // The feed-level <yt:channelId> lacks the "UC" prefix; the entries have the real id.
        let v = RSSParser.parse(try Fixture.data("rss_blender.xml"))
        #expect(Set(v.compactMap { $0.channel?.id }) == ["UCSMOQeBJ2RAnuFungnQOxLg"])
        #expect(Set(v.compactMap { $0.channel?.name }) == ["Blender"])
    }

    @Test func titlesDatesAndViewsOfTheFirstEntries() throws {
        let v = RSSParser.parse(try Fixture.data("rss_blender.xml"))
        try #require(v.count >= 3)
        #expect(v[1].title == "TOUCH your Blender 👀 Blender Today LIVE #292")
        #expect(v[1].viewCount == 23_825)
        #expect(v[1].publishedAt == ISO8601DateFormatter().date(from: "2026-10-28T20:22:59Z"))
        #expect(v[2].title == "Default Cube: the Interview")
        #expect(v[2].viewCount == 21_143)
        #expect(v.allSatisfy { $0.publishedAt != nil && $0.viewCount != nil })
    }

    @Test func nothingElseIsInventedForFeedEntries() throws {
        let video = try #require(RSSParser.parse(try Fixture.data("rss_blender.xml")).first)
        #expect(video.durationSeconds == nil)           // the feed has no durations
        #expect(video.publishedText == nil)
        #expect(video.viewCountText == nil)
        #expect(!video.isLive && !video.isUpcoming && !video.isMembersOnly)
        #expect(video.thumbnails.count == 1)
        #expect(video.thumbnails.first?.width == 480)
        #expect(video.thumbnails.first?.height == 360)
    }

    // MARK: Synthetic entries

    @Test func aShortIsRecognisedByItsLink() {
        let data = feed(entry(id: "gIjBeEvDXew", link: "https://www.youtube.com/shorts/gIjBeEvDXew") + entry(id: "dQw4w9WgXcQ"))
        let v = RSSParser.parse(data)
        #expect(v.map(\.isShort) == [true, false])
    }

    @Test func xmlEntitiesInTitlesAreDecoded() {
        let data = feed(entry(title: "Tom &amp; Jerry &quot;live&quot; &lt;3 &#39;quoted&#39; &#x1F600;"))
        #expect(RSSParser.parse(data).first?.title == #"Tom & Jerry "live" <3 'quoted' 😀"#)
    }

    @Test func thePublishedDateAcceptsOffsetsAndZ() throws {
        let data = feed(
            entry(id: "aaaaaaaaaaa", published: "2026-11-02T13:54:25+00:00")
                + entry(id: "bbbbbbbbbbb", published: "2026-11-02T15:54:25+02:00")
                + entry(id: "ccccccccccc", published: "2026-11-02T13:54:25Z")
                + entry(id: "ddddddddddd", published: "2026-11-02T13:54:25.250+00:00")
        )
        let dates = RSSParser.parse(data).map(\.publishedAt)
        let reference = ISO8601DateFormatter().date(from: "2026-11-02T13:54:25Z")
        try #require(dates.count == 4)
        #expect(dates[0] == reference)
        #expect(dates[1] == reference)
        #expect(dates[2] == reference)
        let fractional = try #require(dates[3])
        #expect(abs(fractional.timeIntervalSince(try #require(reference)) - 0.25) < 0.001)
    }

    @Test func optionalPartsMayBeMissing() throws {
        let data = feed(entry(link: nil, author: nil, published: nil, thumbnail: nil, views: nil))
        let video = try #require(RSSParser.parse(data).first)
        #expect(video.id == "dQw4w9WgXcQ")
        #expect(video.publishedAt == nil)
        #expect(video.viewCount == nil)
        #expect(video.thumbnails.isEmpty)
        #expect(!video.isShort)
        // The channel id alone is enough for a reference; the name falls back to empty.
        #expect(video.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg")
    }

    @Test func aGarbageViewCountIsNil() throws {
        let data = feed(entry(views: "many"))
        #expect(try #require(RSSParser.parse(data).first).viewCount == nil)
    }

    @Test func entriesWithoutAVideoIdAreSkipped() {
        let data = feed(entry(id: nil) + entry(id: "dQw4w9WgXcQ") + entry(id: ""))
        #expect(RSSParser.parse(data).map(\.id) == ["dQw4w9WgXcQ"])
    }

    @Test func theMediaTitleIsNotTheTitle() throws {
        let video = try #require(RSSParser.parse(feed(entry(title: "Real title"))).first)
        #expect(video.title == "Real title")
    }

    @Test func aChannelIdWithoutTheUCPrefixIsRepaired() throws {
        // Seen in the feed header; entries normally carry the full id, but a bare 22-character id is unambiguous.
        let video = try #require(RSSParser.parse(feed(entry(channelID: "SMOQeBJ2RAnuFungnQOxLg"))).first)
        #expect(video.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg")
    }

    @Test func theChannelFallsBackToTheAuthorURIWhenTheEntryHasNoChannelId() throws {
        let video = try #require(RSSParser.parse(feed(entry(channelID: nil))).first)
        #expect(video.channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"))
    }

    // MARK: Damaged input

    @Test(arguments: ["", "   ", "not xml at all", "<html><body>Error 404</body></html>", "<feed></feed>", #"<?xml version="1.0"?>"#])
    func inputWithoutEntriesGivesNoVideos(text: String) {
        #expect(RSSParser.parse(Data(text.utf8)).isEmpty)
    }

    @Test func aTruncatedFeedKeepsTheEntriesThatWereComplete() throws {
        let full = try Fixture.data("rss_blender.xml")
        let cut = full.prefix(full.count / 2)
        let v = RSSParser.parse(Data(cut))
        #expect(v.count >= 5)
        #expect(v.count < 15)
        #expect(v.first?.id == "mHrHLqQj7Ts")
        // Every kept entry is complete.
        #expect(v.allSatisfy { !$0.title.isEmpty && $0.channel != nil && $0.publishedAt != nil })
    }

    @Test func invalidUTF8DoesNotCrash() {
        var bytes = Array(feed(entry()))
        bytes.insert(contentsOf: [0xFF, 0xFE, 0xFD], at: bytes.count / 2)
        _ = RSSParser.parse(Data(bytes))
    }

    @Test func externalEntitiesAreNotResolved() {
        let hostile = Data("""
        <?xml version="1.0"?>
        <!DOCTYPE feed [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
         <entry><yt:videoId>dQw4w9WgXcQ</yt:videoId><yt:channelId>UCSMOQeBJ2RAnuFungnQOxLg</yt:channelId><title>&xxe;</title></entry>
        </feed>
        """.utf8)
        let titles = RSSParser.parse(hostile).map(\.title)
        #expect(!titles.contains { $0.contains("root:") })
    }
}

// MARK: - RSSFeedFetcher

@Suite struct RSSFeedFetcherTests {
    @Test func fetchesAndParsesTheChannelFeed() async throws {
        let http = MockHTTPClient()
        http.enqueue("feeds/videos.xml", body: try Fixture.data("rss_blender.xml"))
        let videos = try await RSSFeedFetcher(http: http).latestVideos(channelID: "UCSMOQeBJ2RAnuFungnQOxLg")

        #expect(videos.count == 15)
        #expect(videos.first?.id == "mHrHLqQj7Ts")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://www.youtube.com/feeds/videos.xml?channel_id=UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(http.requests.count == 1)
    }

    @Test func aMissingChannelIsAnHTTPError() async throws {
        let http = MockHTTPClient()
        http.enqueue("feeds/videos.xml", status: 404, body: Data("<html>404</html>".utf8))
        let fetcher = RSSFeedFetcher(http: http)
        await #expect(throws: NoSlopError.http(status: 404)) {
            _ = try await fetcher.latestVideos(channelID: "UCdoesnotexist000000000x")
        }
    }

    @Test func networkErrorsPropagate() async throws {
        let http = MockHTTPClient()
        http.enqueueError("feeds/videos.xml", NoSlopError.network("offline"))
        let fetcher = RSSFeedFetcher(http: http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await fetcher.latestVideos(channelID: "UCSMOQeBJ2RAnuFungnQOxLg")
        }
    }

    @Test func aSuccessfulAnswerWithoutEntriesIsAnEmptyList() async throws {
        let http = MockHTTPClient()
        http.enqueue("feeds/videos.xml", body: Data("<feed></feed>".utf8))
        #expect(try await RSSFeedFetcher(http: http).latestVideos(channelID: "UCSMOQeBJ2RAnuFungnQOxLg").isEmpty)
    }

    @Test func theChannelIdIsEscapedIntoTheQuery() async throws {
        let http = MockHTTPClient()
        http.enqueue("feeds/videos.xml", body: Data("<feed></feed>".utf8))
        _ = try await RSSFeedFetcher(http: http).latestVideos(channelID: "UC x&y=1")
        let url = try #require(http.requests.first?.url?.absoluteString)
        #expect(url == "https://www.youtube.com/feeds/videos.xml?channel_id=UC%20x%26y%3D1")
    }
}
