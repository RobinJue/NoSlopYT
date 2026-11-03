import Foundation

/// `CaptionsProviding` over HTTP: fetches a track's WebVTT (`baseURL + "&fmt=vtt"`) and parses it.
public struct CaptionsService: CaptionsProviding {
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func cues(for track: CaptionTrack) async throws -> [CaptionCue] {
        guard let url = Self.webVTTURL(for: track.baseURL) else {
            throw NoSlopError.decoding("Could not build the caption address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw NoSlopError.http(status: response.statusCode)
        }
        return WebVTTParser.parse(String(decoding: data, as: UTF8.self))
    }

    /// `baseURL` with `fmt=vtt` as its last query parameter. The rest of the (signed) URL is kept byte for byte, and
    /// a `fmt` the URL already had is dropped.
    static func webVTTURL(for baseURL: URL) -> URL? {
        let text = baseURL.absoluteString
        let (withoutFragment, fragment) = text.firstIndex(of: "#").map { (String(text[..<$0]), String(text[$0...])) } ?? (text, "")
        guard let separator = withoutFragment.firstIndex(of: "?") else {
            return URL(string: withoutFragment + "?fmt=vtt" + fragment)
        }
        let path = withoutFragment[..<separator]
        let parameters = withoutFragment[withoutFragment.index(after: separator)...]
            .split(separator: "&", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("fmt=") }
        return URL(string: path + "?" + (parameters.map(String.init) + ["fmt=vtt"]).joined(separator: "&") + fragment)
    }
}
