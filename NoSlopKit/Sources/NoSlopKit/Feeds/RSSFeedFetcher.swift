import Foundation

/// `RSSFeedFetching` over HTTP: fetches `feeds/videos.xml?channel_id=<id>` and parses it with `RSSParser`.
/// The feed costs no API quota and lists the channel's latest 15 uploads.
public struct RSSFeedFetcher: RSSFeedFetching {
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func latestVideos(channelID: String) async throws -> [VideoSummary] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(YouTubeQueryEncoding.encode(channelID))") else {
            throw NoSlopError.decoding("Could not build the feed address for \(channelID).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/atom+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw NoSlopError.http(status: response.statusCode)
        }
        return RSSParser.parse(data)
    }
}
