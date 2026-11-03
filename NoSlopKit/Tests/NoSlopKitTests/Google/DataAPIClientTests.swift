import Foundation
import Testing
@testable import NoSlopKit

// MARK: - Helpers (file-private so they never clash with other tasks' tests)

private let apiBase = "https://www.googleapis.com/youtube/v3/"
private let subscriptionsURL = apiBase + "subscriptions?part=snippet&mine=true&maxResults=50&order=alphabetical"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) ?? .distantPast
}

private func urlString(_ request: URLRequest) -> String {
    request.url?.absoluteString ?? ""
}

/// The decoded query parameters of a request URL.
private func query(_ request: URLRequest) -> [String: String] {
    guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

private func body(_ text: String) -> Data {
    Data(text.utf8)
}

private func apiError(status: Int, reason: String, domain: String = "global") -> Data {
    body(#"{"error":{"code":\#(status),"message":"Error message.","errors":[{"message":"Error message.","domain":"\#(domain)","reason":"\#(reason)"}]}}"#)
}

private func isDecodingError(_ error: any Error) -> Bool {
    if case NoSlopError.decoding = error { return true }
    return false
}

/// A stand-in `GoogleAuthProviding` that hands out the given tokens in order (the last one repeats), counts the
/// calls, and can be told to fail like a signed-out account.
private actor GoogleStubAuth: GoogleAuthProviding {
    private var tokens: [String]
    private let failure: NoSlopError?
    private(set) var calls = 0

    init(tokens: [String] = ["test-token"], failure: NoSlopError? = nil) {
        self.tokens = tokens
        self.failure = failure
    }

    func currentAccount() async -> GoogleAccount? {
        failure == nil ? GoogleAccount(id: "1") : nil
    }

    func signIn(clientID: String, authenticator: any WebAuthenticating) async throws -> GoogleAccount {
        throw NoSlopError.notImplemented("GoogleStubAuth.signIn")
    }

    func signOut() async {}

    func accessToken() async throws -> String {
        calls += 1
        if let failure { throw failure }
        return tokens.count > 1 ? tokens.removeFirst() : (tokens.first ?? "")
    }
}

private struct Rig {
    let http: MockHTTPClient
    let auth: GoogleStubAuth
    let client: YouTubeDataAPIClient

    init(tokens: [String] = ["test-token"], failure: NoSlopError? = nil) {
        let http = MockHTTPClient()
        let auth = GoogleStubAuth(tokens: tokens, failure: failure)
        self.http = http
        self.auth = auth
        self.client = YouTubeDataAPIClient(http: http, auth: auth)
    }
}

/// A `YouTubeDataAPIClient` wired to the real `GoogleOAuthService` (in-memory store, fixed clock), for the 401 flow.
private struct RealAuthRig {
    let http: MockHTTPClient
    let store: InMemoryTokenStore
    let client: YouTubeDataAPIClient

    init(refreshToken: String? = "rt") {
        let http = MockHTTPClient()
        self.http = http
        let credentials = StoredCredentials(
            clientID: "123-abc.apps.googleusercontent.com",
            tokens: OAuthTokens(accessToken: "old-at", refreshToken: refreshToken, expiresAt: t0.addingTimeInterval(3000)),
            account: GoogleAccount(id: "1234", email: "you@example.com", name: "You")
        )
        let store = InMemoryTokenStore(credentials)
        self.store = store
        self.client = YouTubeDataAPIClient(http: http, auth: GoogleOAuthService(http: http, store: store, now: { t0 }))
    }

    var tokenRequests: [URLRequest] { http.requests.filter { urlString($0).contains("oauth2.googleapis.com/token") } }
    var apiRequests: [URLRequest] { http.requests.filter { urlString($0).contains("googleapis.com/youtube/v3/") } }
}

// MARK: - Subscriptions

@Suite struct DataAPIClientSubscriptionTests {
    @Test func subscriptionsPaginate() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", body: try Fixture.data("dataapi_subscriptions_page1.json"))
        rig.http.enqueue("youtube/v3/subscriptions", body: try Fixture.data("dataapi_subscriptions_page2.json"))

        let channels = try await rig.client.subscriptions()

        #expect(channels.map(\.id) == ["UCYO_jab_esuFRV4b17AJtAw", "UCSMOQeBJ2RAnuFungnQOxLg", "UCOKHwx1VCdgnxwbjyb9Iu1g", "UCsXVk37bltHxD1rDPwtNM8Q", "UCHnyfMqiRRG1u-2MsSQLbXA"])
        #expect(channels.map(\.name) == ["3Blue1Brown", "Blender", "Blender Guru", "Kurzgesagt \u{2013} In a Nutshell", "Veritasium"])
        #expect(channels.map(\.source) == [
            .google(subscriptionID: "fGxWm1yQ4D8kZb7NcAoV2hS-uE3rTjLpX9wIeYtU0aM"),
            .google(subscriptionID: "kP3vD7sLq0ZcXn2RwHyU9gTbJm5oAeF-Ni1ElWtVxGQ"),
            .google(subscriptionID: "Zb8Hn4VqR1yLtKcD6xWjP0sUaEoF3mGiT_9XwYe2NvA"),
            .google(subscriptionID: "Tn6QeR2wYxK9sLvH4mDbZ0cUaPjF-8oGiN3EtXyW1VA"),
            .google(subscriptionID: "cW1uJ7Lk4NzS9xQeRdY2oVhTbA6mF-3gPiXtE0wDsGM"),
        ])
        // The channel is the subscribed-to channel (resourceId), not the user's own (snippet.channelId); the avatar is the default thumbnail.
        try #require(channels.count == 5)
        #expect(channels[1] == SubscribedChannel(
            id: "UCSMOQeBJ2RAnuFungnQOxLg",
            name: "Blender",
            avatarURL: URL(string: "https://yt3.ggpht.com/ytc/AIdro_kBlenderOfficialAvatar=s88-c-k-c0x00ffffff-no-rj"),
            source: .google(subscriptionID: "kP3vD7sLq0ZcXn2RwHyU9gTbJm5oAeF-Ni1ElWtVxGQ"),
            subscribedAt: utc(2020, 3, 18, 21, 40, 9)
        ))
        // Timestamps with 1 to 6 fractional digits, and none at all, all parse.
        #expect(channels.map(\.subscribedAt) == [utc(2019, 6, 2, 9, 15, 44), utc(2020, 3, 18, 21, 40, 9), utc(2021, 11, 30, 18, 3, 12), utc(2022, 2, 14, 7, 26, 51), utc(2023, 8, 9, 12, 0, 0)])

        #expect(rig.http.requests.map(urlString) == [subscriptionsURL, subscriptionsURL + "&pageToken=P2"])
    }

    @Test func everyRequestCarriesTheBearerTokenAndAsksForJSON() async throws {
        let rig = Rig(tokens: ["secret-token"])
        rig.http.enqueue("youtube/v3/subscriptions", body: try Fixture.data("dataapi_subscriptions_page2.json"))
        rig.http.enqueue("youtube/v3/videos", body: try Fixture.data("dataapi_liked_videos.json"))
        rig.http.enqueue("youtube/v3/playlists", body: try Fixture.data("dataapi_playlists.json"))
        rig.http.enqueue("youtube/v3/playlistItems", body: try Fixture.data("dataapi_playlist_items.json"))

        _ = try await rig.client.subscriptions()
        _ = try await rig.client.likedVideos(pageToken: nil)
        _ = try await rig.client.myPlaylists()
        _ = try await rig.client.playlistItems(playlistID: "PL1", pageToken: nil)

        #expect(rig.http.requests.count == 4)
        for request in rig.http.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.httpMethod == "GET")
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "www.googleapis.com")
        }
    }

    @Test func theTokenIsAskedForPerRequestNeverCachedByTheClient() async throws {
        // The auth service owns expiry and refresh; the client must always ask it.
        let rig = Rig(tokens: ["first", "second"])
        rig.http.enqueue("youtube/v3/videos/getRating", body: body(#"{"items":[{"videoId":"a","rating":"like"}]}"#))
        _ = try await rig.client.rating(videoID: "a")
        _ = try await rig.client.rating(videoID: "a")
        #expect(rig.http.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer first", "Bearer second"])
        #expect(await rig.auth.calls == 2)
    }

    @Test func subscriptionsSkipItemsWithoutAChannelOrAnID() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", body: body(#"""
        {"items":[
          {"id":"S1","snippet":{"title":"Good","resourceId":{"kind":"youtube#channel","channelId":"UC1"},"thumbnails":{"medium":{"url":"https://x/m.jpg"},"high":{"url":"https://x/h.jpg"}}}},
          {"id":"S2","snippet":{"title":"No resource id"}},
          {"id":"S3","snippet":{"title":"Empty channel id","resourceId":{"kind":"youtube#channel","channelId":""}}},
          {"snippet":{"title":"No subscription id","resourceId":{"kind":"youtube#channel","channelId":"UC4"}}},
          {"id":"S5","snippet":{"title":"Bare","resourceId":{"kind":"youtube#channel","channelId":"UC5"}}},
          "not an object",
          {}
        ]}
        """#))

        let channels = try await rig.client.subscriptions()

        #expect(channels.map(\.id) == ["UC1", "UC5"])
        // No "default" thumbnail: the smallest one that exists is used. No thumbnails at all: no avatar.
        try #require(channels.count == 2)
        #expect(channels[0].avatarURL == URL(string: "https://x/m.jpg"))
        #expect(channels[1].avatarURL == nil)
        #expect(channels[1].subscribedAt == nil)
    }

    @Test func aServerThatKeepsReturningTheSamePageTokenCannotLoopForever() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", body: body(#"{"nextPageToken":"SAME","items":[{"id":"S1","snippet":{"title":"A","resourceId":{"channelId":"UC1"}}}]}"#))
        let channels = try await rig.client.subscriptions()
        #expect(rig.http.requests.count == 2)  // the first page, then SAME once; the repeat of SAME stops it
        #expect(!channels.isEmpty)
    }

    @Test func subscribePostsTheChannelResourceAndReturnsTheSubscriptionID() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", body: body(#"{"kind":"youtube#subscription","etag":"e","id":"NEW-SUB-ID","snippet":{"resourceId":{"kind":"youtube#channel","channelId":"UCSMOQeBJ2RAnuFungnQOxLg"}}}"#))

        let id = try await rig.client.subscribe(channelID: "UCSMOQeBJ2RAnuFungnQOxLg")

        #expect(id == "NEW-SUB-ID")
        let request = try #require(rig.http.requests.first)
        #expect(rig.http.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(urlString(request) == apiBase + "subscriptions?part=snippet")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let sent = try #require(rig.http.bodyJSON(of: request))
        #expect(sent["snippet"]?["resourceId"]?["kind"]?.string == "youtube#channel")
        #expect(sent["snippet"]?["resourceId"]?["channelId"]?.string == "UCSMOQeBJ2RAnuFungnQOxLg")
    }

    @Test func subscribeWithoutAnIDInTheResponseIsADecodingError() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", body: body(#"{"kind":"youtube#subscription"}"#))
        await #expect { _ = try await rig.client.subscribe(channelID: "UC1") } throws: { isDecodingError($0) }
    }

    @Test func subscribingToAChannelThatIsAlreadySubscribedReturnsTheExistingSubscription() async throws {
        let rig = Rig()
        rig.http.enqueue("subscriptions?part=snippet", status: 400, body: apiError(status: 400, reason: "subscriptionDuplicate", domain: "youtube.subscription"))
        rig.http.enqueue("subscriptions?part=id", body: body(#"{"items":[{"kind":"youtube#subscription","id":"EXISTING-SUB-ID"}]}"#))

        let id = try await rig.client.subscribe(channelID: "UCSMOQeBJ2RAnuFungnQOxLg")

        #expect(id == "EXISTING-SUB-ID")
        #expect(rig.http.requests.map(urlString) == [
            apiBase + "subscriptions?part=snippet",
            apiBase + "subscriptions?part=id&mine=true&forChannelId=UCSMOQeBJ2RAnuFungnQOxLg",
        ])
        #expect(rig.http.requests.map { $0.httpMethod } == ["POST", "GET"])
    }

    @Test func aDuplicateWhoseSubscriptionCannotBeFoundStaysAnError() async throws {
        let rig = Rig()
        rig.http.enqueue("subscriptions?part=snippet", status: 400, body: apiError(status: 400, reason: "subscriptionDuplicate"))
        rig.http.enqueue("subscriptions?part=id", body: body(#"{"items":[]}"#))
        await #expect(throws: NoSlopError.http(status: 400)) { _ = try await rig.client.subscribe(channelID: "UC1") }
    }

    @Test func otherSubscribeFailuresMapToTheStatus() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 403, body: apiError(status: 403, reason: "subscriptionForbidden"))
        await #expect(throws: NoSlopError.http(status: 403)) { _ = try await rig.client.subscribe(channelID: "UC1") }
        #expect(rig.http.requests.count == 1, "only a duplicate triggers the lookup")
    }

    @Test func unsubscribeSendsDelete() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 204, body: Data())

        try await rig.client.unsubscribe(subscriptionID: "kP3vD7sLq0ZcXn2RwHyU9gTbJm5oAeF-Ni1ElWtVxGQ")

        let request = try #require(rig.http.requests.first)
        #expect(rig.http.requests.count == 1)
        #expect(request.httpMethod == "DELETE")
        #expect(urlString(request) == apiBase + "subscriptions?id=kP3vD7sLq0ZcXn2RwHyU9gTbJm5oAeF-Ni1ElWtVxGQ")
    }

    @Test func unsubscribeNotFoundIsSuccess() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 404, body: apiError(status: 404, reason: "subscriptionNotFound", domain: "youtube.subscription"))
        try await rig.client.unsubscribe(subscriptionID: "gone")  // already unsubscribed elsewhere: nothing to do
        #expect(rig.http.requests.count == 1)
    }

    @Test(arguments: [(403, "subscriptionForbidden"), (404, "playlistNotFound"), (500, "backendError")])
    func otherUnsubscribeFailuresThrow(status: Int, reason: String) async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", status: status, body: apiError(status: status, reason: reason))
        await #expect(throws: NoSlopError.http(status: status)) { try await rig.client.unsubscribe(subscriptionID: "x") }
    }

    @Test func aBare404WithoutAReasonIsNotTreatedAsAlreadyUnsubscribed() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 404, body: Data("<html>Not Found</html>".utf8))
        await #expect(throws: NoSlopError.http(status: 404)) { try await rig.client.unsubscribe(subscriptionID: "x") }
    }
}

// MARK: - Playlists and videos

@Suite struct DataAPIClientLibraryTests {
    @Test func myPlaylistsMapsTheFixture() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlists", body: try Fixture.data("dataapi_playlists.json"))

        let playlists = try await rig.client.myPlaylists()

        #expect(rig.http.requests.map(urlString) == [apiBase + "playlists?part=snippet,contentDetails&mine=true&maxResults=50"])
        #expect(playlists.map(\.id) == ["PLx7v0qkWc3tJZ9mXn2RoAyU4DbHsEeFgK", "PLq2w3e4r5t6y7u8i9o0pAsDfGhJkLzXcV", "PLm9n8b7v6c5x4z3a2s1d0fGhJkLqWeRtY"])
        #expect(playlists.map(\.title) == ["Blender references", "Music to model to", "Empty for now"])
        #expect(playlists.map(\.videoCount) == [5, 128, 0])
        try #require(playlists.count == 3)
        #expect(playlists[0].channel == ChannelRef(id: "UC4xKdmAXFh4ACyhpiQ_3qBw", name: "Example User"))
        #expect(playlists[0].thumbnails.map(\.width) == [120, 320, 480, 640, 1280], "ascending width")
        #expect(playlists[0].thumbnails.first?.url.absoluteString == "https://i.ytimg.com/vi/aqz-KE-bpKQ/default.jpg")
        #expect(playlists[1].thumbnails.map(\.width) == [120, 320, 480])
        #expect(playlists[2].thumbnails.isEmpty)
    }

    @Test func myPlaylistsReadsEveryPage() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlists", body: body(#"{"nextPageToken":"T2","items":[{"id":"PL1","snippet":{"title":"One","channelId":"UC1","channelTitle":"Me","thumbnails":{}},"contentDetails":{"itemCount":1}}]}"#))
        rig.http.enqueue("youtube/v3/playlists", body: body(#"{"items":[{"id":"PL2","snippet":{"title":"Two"},"contentDetails":{"itemCount":2}},{"snippet":{"title":"No id"}}]}"#))

        let playlists = try await rig.client.myPlaylists()

        #expect(playlists.map(\.id) == ["PL1", "PL2"])
        try #require(playlists.count == 2)
        #expect(playlists[1].channel == nil)
        let base = apiBase + "playlists?part=snippet,contentDetails&mine=true&maxResults=50"
        #expect(rig.http.requests.map(urlString) == [base, base + "&pageToken=T2"])
    }

    @Test func playlistItemsSkipPrivateAndDeleted() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlistItems", body: try Fixture.data("dataapi_playlist_items.json"))

        let page = try await rig.client.playlistItems(playlistID: "PLx7v0qkWc3tJZ9mXn2RoAyU4DbHsEeFgK", pageToken: nil)

        #expect(rig.http.requests.map(urlString) == [apiBase + "playlistItems?part=snippet,contentDetails&playlistId=PLx7v0qkWc3tJZ9mXn2RoAyU4DbHsEeFgK&maxResults=50"])
        #expect(page.items.map(\.id) == ["aqz-KE-bpKQ", "7pPUE6cGFwI", "jNQXAC9IVRw"], "Private video and Deleted video are dropped")
        #expect(page.continuation == "EAAaBlBUOkNESQ")

        try #require(page.items.count == 3)
        let first = page.items[0]
        #expect(first.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(first.channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"), "the video's owner, not the playlist owner")
        #expect(first.publishedAt == utc(2014, 11, 10, 14, 42, 37), "the upload date, not the date it was added to the playlist")
        #expect(first.thumbnails.map(\.width) == [120, 320, 480, 640, 1280])
        #expect(first.durationSeconds == nil)
        #expect(page.items[1].title == "A Little Pony\u{2019}s Big Heart")
        #expect(page.items[1].channel?.name == "PolyFilms")
    }

    @Test func playlistItemsPassTheContinuationAsPageToken() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlistItems", body: body(#"{"items":[{"snippet":{"title":"T","videoOwnerChannelId":"UC1","videoOwnerChannelTitle":"C"},"contentDetails":{"videoId":"vid"}}]}"#))
        let page = try await rig.client.playlistItems(playlistID: "PL1", pageToken: "EAAaBlBUOkNESQ")
        #expect(urlString(try #require(rig.http.requests.first)) == apiBase + "playlistItems?part=snippet,contentDetails&playlistId=PL1&maxResults=50&pageToken=EAAaBlBUOkNESQ")
        #expect(page.items.map(\.id) == ["vid"])
        #expect(page.continuation == nil, "the last page has no continuation")
    }

    @Test func aVideoThatIsReallyTitledPrivateVideoIsKeptWhenItHasAnOwner() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlistItems", body: body(#"""
        {"items":[
          {"snippet":{"title":"Private video","description":"A real upload with an unlucky title.","videoOwnerChannelId":"UC1","videoOwnerChannelTitle":"Owner"},"contentDetails":{"videoId":"real1"}},
          {"snippet":{"title":"Private video","description":"This video is private."},"contentDetails":{"videoId":"hidden"}},
          {"snippet":{"title":"Some title"},"contentDetails":{}},
          {"snippet":{"title":"Falls back to resourceId","videoOwnerChannelId":"UC2","resourceId":{"kind":"youtube#video","videoId":"viaResource"}}},
          {"snippet":{"title":"No owner but a real title"},"contentDetails":{"videoId":"orphan"}}
        ]}
        """#))
        let page = try await rig.client.playlistItems(playlistID: "PL1", pageToken: nil)
        #expect(page.items.map(\.id) == ["real1", "viaResource", "orphan"])
        try #require(page.items.count == 3)
        #expect(page.items[2].channel == nil)
    }

    @Test func likedVideosMapping() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", body: try Fixture.data("dataapi_liked_videos.json"))

        let page = try await rig.client.likedVideos(pageToken: nil)

        #expect(rig.http.requests.map(urlString) == [apiBase + "videos?part=snippet,contentDetails,statistics&myRating=like&maxResults=50"])
        #expect(page.items.map(\.id) == ["mHrHLqQj7Ts", "dQw4w9WgXcQ", "jfKfPfyJRdk", "PrEm1erE_42"])
        #expect(page.continuation == "CDIQAA")

        try #require(page.items.count == 4)
        let making = page.items[0]
        #expect(making.title == "Making of: The Blender Open Movies Exhibition")
        #expect(making.channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"))
        #expect(making.durationSeconds == 280, "PT4M40S")
        #expect(making.viewCount == 9793, "statistics.viewCount is a string in the API")
        #expect(making.publishedAt == utc(2026, 11, 2, 16, 30, 5))
        #expect(making.thumbnails.map(\.width) == [120, 320, 480, 640, 1280])
        #expect(making.thumbnails.last?.url.absoluteString == "https://i.ytimg.com/vi/mHrHLqQj7Ts/maxresdefault.jpg")
        #expect(!making.isLive && !making.isUpcoming && !making.isShort && !making.isMembersOnly)

        let rick = page.items[1]
        #expect(rick.durationSeconds == 213)
        #expect(rick.viewCount == 1_833_297_545)
        #expect(rick.channel?.name == "Rick Astley")

        // A live stream has no length and hidden statistics.
        let live = page.items[2]
        #expect(live.isLive && !live.isUpcoming)
        #expect(live.durationSeconds == nil, "P0D is not a length")
        #expect(live.viewCount == nil)

        let premiere = page.items[3]
        #expect(premiere.isUpcoming && !premiere.isLive)
        #expect(premiere.durationSeconds == nil)
        #expect(premiere.viewCount == 0)
    }

    @Test func likedVideosPassTheContinuationAsPageToken() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", body: body(#"{"items":[]}"#))
        let page = try await rig.client.likedVideos(pageToken: "CDIQAA")
        #expect(urlString(try #require(rig.http.requests.first)) == apiBase + "videos?part=snippet,contentDetails,statistics&myRating=like&maxResults=50&pageToken=CDIQAA")
        #expect(page.items.isEmpty)
        #expect(page.continuation == nil)
    }

    @Test func videosWithoutAnIDOrWithOddFieldsDoNotBreakThePage() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", body: body(#"""
        {"items":[
          {"snippet":{"title":"No id"}},
          {"id":"bare"},
          {"id":"weird","snippet":{"title":"Weird","channelId":"UC1","publishedAt":"yesterday","thumbnails":{"default":{"url":"not a url"},"high":{"url":"https://x/h.jpg","width":480,"height":360}}},"contentDetails":{"duration":"nonsense"},"statistics":{"viewCount":"many"}}
        ]}
        """#))
        let page = try await rig.client.likedVideos(pageToken: nil)
        #expect(page.items.map(\.id) == ["bare", "weird"])
        try #require(page.items.count == 2)
        let weird = page.items[1]
        #expect(weird.title == "Weird")
        #expect(weird.channel == ChannelRef(id: "UC1", name: ""))
        #expect(weird.publishedAt == nil)
        #expect(weird.durationSeconds == nil)
        #expect(weird.viewCount == nil)
        #expect(weird.thumbnails.map(\.url.absoluteString) == ["https://x/h.jpg"])
    }

    @Test(arguments: [("like", VideoRating.like), ("dislike", .dislike), ("none", .none), ("unspecified", .none), ("somethingNew", .none)])
    func ratingMapping(wire: String, expected: VideoRating) async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos/getRating", body: body(#"{"kind":"youtube#videoGetRatingResponse","etag":"e","items":[{"videoId":"dQw4w9WgXcQ","rating":"\#(wire)"}]}"#))
        #expect(try await rig.client.rating(videoID: "dQw4w9WgXcQ") == expected)
        #expect(rig.http.requests.map(urlString) == [apiBase + "videos/getRating?id=dQw4w9WgXcQ"])
    }

    @Test func ratingOfAVideoYouTubeDoesNotKnowIsNone() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos/getRating", body: body(#"{"items":[]}"#))
        #expect(try await rig.client.rating(videoID: "gone") == .none)
    }

    @Test func rateUsesPost() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos/rate", status: 204, body: Data())

        try await rig.client.rate(videoID: "dQw4w9WgXcQ", rating: .like)

        let request = try #require(rig.http.requests.first)
        #expect(rig.http.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(urlString(request) == apiBase + "videos/rate?id=dQw4w9WgXcQ&rating=like")
    }

    @Test(arguments: [(VideoRating.like, "like"), (.dislike, "dislike"), (.none, "none")])
    func rateSendsTheRatingName(rating: VideoRating, wire: String) async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos/rate", status: 204, body: Data())
        try await rig.client.rate(videoID: "a-b_c", rating: rating)
        #expect(query(try #require(rig.http.requests.first))["rating"] == wire)
        #expect(query(try #require(rig.http.requests.first))["id"] == "a-b_c")
    }

    @Test func addToPlaylistPostsTheVideoResource() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlistItems", body: body(#"{"kind":"youtube#playlistItem","id":"item"}"#))

        try await rig.client.addToPlaylist(videoID: "dQw4w9WgXcQ", playlistID: "PLx7v0qkWc3tJZ9mXn2RoAyU4DbHsEeFgK")

        let request = try #require(rig.http.requests.first)
        #expect(rig.http.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(urlString(request) == apiBase + "playlistItems?part=snippet")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let sent = try #require(rig.http.bodyJSON(of: request))
        #expect(sent["snippet"]?["playlistId"]?.string == "PLx7v0qkWc3tJZ9mXn2RoAyU4DbHsEeFgK")
        #expect(sent["snippet"]?["resourceId"]?["kind"]?.string == "youtube#video")
        #expect(sent["snippet"]?["resourceId"]?["videoId"]?.string == "dQw4w9WgXcQ")
    }

    @Test func addToPlaylistFailuresMapToTheStatus() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlistItems", status: 404, body: apiError(status: 404, reason: "playlistNotFound"))
        await #expect(throws: NoSlopError.http(status: 404)) { try await rig.client.addToPlaylist(videoID: "v", playlistID: "p") }
    }
}

// MARK: - Durations

@Suite struct DataAPIClientDurationTests {
    private static func ids(_ count: Int) -> [String] {
        (0..<count).map { "vid-" + String(format: "%07d", $0) }
    }

    /// A videos.list reply for `ids`, where video number `n` lasts `n + 1` seconds.
    private static func reply(for ids: ArraySlice<String>, firstIndex: Int) throws -> Data {
        var items: [JSON] = []
        for (offset, id) in ids.enumerated() {
            items.append(["kind": "youtube#video", "id": .string(id), "contentDetails": ["duration": .string("PT\(firstIndex + offset + 1)S")]])
        }
        return try JSON.object(["kind": "youtube#videoListResponse", "items": .array(items)]).data()
    }

    @Test func durationsBatchFifty() async throws {
        let rig = Rig()
        let ids = Self.ids(120)
        rig.http.enqueue("youtube/v3/videos", body: try Self.reply(for: ids[0..<50], firstIndex: 0))
        rig.http.enqueue("youtube/v3/videos", body: try Self.reply(for: ids[50..<100], firstIndex: 50))
        rig.http.enqueue("youtube/v3/videos", body: try Self.reply(for: ids[100..<120], firstIndex: 100))

        let durations = try await rig.client.durations(videoIDs: ids)

        #expect(rig.http.requests.count == 3)
        let batches = rig.http.requests.map { (query($0)["id"] ?? "").split(separator: ",").map(String.init) }
        #expect(batches.map(\.count) == [50, 50, 20])
        #expect(batches.flatMap { $0 } == ids, "every id requested exactly once, in order")
        #expect(rig.http.requests.allSatisfy { query($0)["part"] == "contentDetails" })
        #expect(durations.count == 120)
        #expect(durations["vid-0000000"] == 1)
        #expect(durations["vid-0000049"] == 50)
        #expect(durations["vid-0000050"] == 51)
        #expect(durations["vid-0000119"] == 120)
    }

    @Test func fiftyIdsFitInASingleRequest() async throws {
        let rig = Rig()
        let ids = Self.ids(50)
        rig.http.enqueue("youtube/v3/videos", body: try Self.reply(for: ids[...], firstIndex: 0))
        _ = try await rig.client.durations(videoIDs: ids)
        #expect(rig.http.requests.count == 1)
    }

    @Test func durationsMapTheFixtureAndLeaveOutLiveStreams() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", body: try Fixture.data("dataapi_videos_durations.json"))

        let durations = try await rig.client.durations(videoIDs: ["mHrHLqQj7Ts", "z-Xl9tGqH14", "sO_lhW8av3U", "jfKfPfyJRdk", "unknownId123"])

        // PT4M40S, PT4H19M10S, PT2M29S; the live stream (P0D) and the unknown id have no length.
        #expect(durations == ["mHrHLqQj7Ts": 280, "z-Xl9tGqH14": 15550, "sO_lhW8av3U": 149])
        let request = try #require(rig.http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(urlString(request).hasPrefix(apiBase + "videos?part=contentDetails&id=mHrHLqQj7Ts,z-Xl9tGqH14,sO_lhW8av3U,jfKfPfyJRdk,unknownId123"))
    }

    @Test func maxResultsIsNotSentWithTheIDFilter() async throws {
        // The Data API reference: maxResults "is not supported for use in conjunction with the id parameter".
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", body: body(#"{"items":[]}"#))
        _ = try await rig.client.durations(videoIDs: ["a"])
        #expect(query(try #require(rig.http.requests.first))["maxResults"] == nil)
    }

    @Test func noIDsMeansNoRequest() async throws {
        let rig = Rig()
        #expect(try await rig.client.durations(videoIDs: []).isEmpty)
        #expect(rig.http.requests.isEmpty)
        #expect(await rig.auth.calls == 0)
    }

    @Test func duplicateIDsAreAskedForOnce() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", body: body(#"{"items":[{"id":"a","contentDetails":{"duration":"PT1M"}},{"id":"b","contentDetails":{"duration":"PT2M"}}]}"#))
        let durations = try await rig.client.durations(videoIDs: ["a", "b", "a", "", "b"])
        #expect(query(try #require(rig.http.requests.first))["id"] == "a,b")
        #expect(durations == ["a": 60, "b": 120])
    }

    @Test func aFailingBatchFailsTheCall() async throws {
        let rig = Rig()
        let ids = Self.ids(60)
        rig.http.enqueue("youtube/v3/videos", body: try Self.reply(for: ids[0..<50], firstIndex: 0))
        rig.http.enqueue("youtube/v3/videos", status: 500, body: Data("oops".utf8))
        await #expect(throws: NoSlopError.http(status: 500)) { _ = try await rig.client.durations(videoIDs: ids) }
    }
}

// MARK: - Authorization and errors

@Suite struct DataAPIClientAuthAndErrorTests {
    private let unauthorized = apiError(status: 401, reason: "authError", domain: "global")

    @Test func unauthorizedRefreshesAndRetriesOnce() async throws {
        let rig = RealAuthRig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 401, body: unauthorized)
        rig.http.enqueue("youtube/v3/subscriptions", body: try Fixture.data("dataapi_subscriptions_page2.json"))
        rig.http.enqueue("oauth2.googleapis.com/token", body: body(#"{"access_token":"new-at","expires_in":3599,"token_type":"Bearer"}"#))

        let channels = try await rig.client.subscriptions()

        #expect(channels.map(\.name) == ["Kurzgesagt \u{2013} In a Nutshell", "Veritasium"])
        #expect(rig.http.requests.map(urlString) == [subscriptionsURL, "https://oauth2.googleapis.com/token", subscriptionsURL])
        try #require(rig.http.requests.count == 3)
        #expect(rig.http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-at")
        #expect(rig.http.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-at")
        #expect(try rig.store.load()?.tokens.accessToken == "new-at", "the refreshed token is kept for the next call")
    }

    @Test func aSecondUnauthorizedGivesUpAfterExactlyOneRetry() async throws {
        let rig = RealAuthRig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 401, body: unauthorized)
        rig.http.enqueue("oauth2.googleapis.com/token", body: body(#"{"access_token":"new-at","expires_in":3599}"#))

        await #expect(throws: NoSlopError.http(status: 401)) { _ = try await rig.client.subscriptions() }

        #expect(rig.apiRequests.count == 2)
        #expect(rig.tokenRequests.count == 1)
        #expect(try rig.store.load() != nil, "a persistent 401 is not a reason to sign the user out")
    }

    @Test func aRevokedGrantDuringTheRetrySignsTheUserOut() async throws {
        let rig = RealAuthRig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 401, body: unauthorized)
        rig.http.enqueue("oauth2.googleapis.com/token", status: 400, body: body(#"{"error":"invalid_grant"}"#))

        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.client.subscriptions() }

        #expect(rig.apiRequests.count == 1, "no retry without a token")
        #expect(try rig.store.load() == nil)
    }

    @Test func unauthorizedWithAPlainAuthProviderAsksItForTheTokenAgain() async throws {
        let rig = Rig(tokens: ["tok-1", "tok-2"])
        rig.http.enqueue("youtube/v3/videos/getRating", status: 401, body: unauthorized)
        rig.http.enqueue("youtube/v3/videos/getRating", body: body(#"{"items":[{"videoId":"v","rating":"like"}]}"#))

        #expect(try await rig.client.rating(videoID: "v") == .like)

        #expect(rig.http.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer tok-1", "Bearer tok-2"])
        #expect(await rig.auth.calls == 2)
    }

    @Test func aWriteThatIsRejectedIsRetriedWithTheSameBody() async throws {
        let rig = RealAuthRig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 401, body: unauthorized)
        rig.http.enqueue("youtube/v3/subscriptions", body: body(#"{"id":"SUB"}"#))
        rig.http.enqueue("oauth2.googleapis.com/token", body: body(#"{"access_token":"new-at","expires_in":3599}"#))

        #expect(try await rig.client.subscribe(channelID: "UC1") == "SUB")

        let posts = rig.apiRequests
        try #require(posts.count == 2)
        #expect(posts[0].httpBody == posts[1].httpBody)
        #expect(posts[0].httpBody?.isEmpty == false)
    }

    @Test func quotaExceededMaps() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/subscriptions", status: 403, body: try Fixture.data("dataapi_error_quota.json"))
        await #expect(throws: NoSlopError.quotaExceeded) { _ = try await rig.client.subscriptions() }
        #expect(rig.http.requests.count == 1, "no retry on a quota error")
    }

    @Test(arguments: ["quotaExceeded", "dailyLimitExceeded"])
    func bothQuotaReasonsMapToQuotaExceeded(reason: String) async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos", status: 403, body: apiError(status: 403, reason: reason, domain: "youtube.quota"))
        await #expect(throws: NoSlopError.quotaExceeded) { _ = try await rig.client.likedVideos(pageToken: nil) }
    }

    @Test func quotaErrorsAreRecognisedOnWritesToo() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/videos/rate", status: 403, body: try Fixture.data("dataapi_error_quota.json"))
        await #expect(throws: NoSlopError.quotaExceeded) { try await rig.client.rate(videoID: "v", rating: .like) }
    }

    @Test(arguments: [
        (403, "forbidden"), (403, "rateLimitExceeded"), (400, "invalidArgument"), (404, "videoNotFound"), (409, "playlistContainsMaximumNumberOfVideos"),
    ])
    func otherErrorsMapToTheHTTPStatus(status: Int, reason: String) async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3", status: status, body: apiError(status: status, reason: reason))
        await #expect(throws: NoSlopError.http(status: status)) { _ = try await rig.client.likedVideos(pageToken: nil) }
    }

    @Test(arguments: [500, 502, 503])
    func serverErrorsWithAnHTMLBodyMapToTheHTTPStatus(status: Int) async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3", status: status, body: Data("<html><body>Server Error</body></html>".utf8))
        await #expect(throws: NoSlopError.http(status: status)) { _ = try await rig.client.myPlaylists() }
    }

    @Test func aSuccessBodyThatIsNotJSONIsADecodingError() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3/playlists", body: Data("this is not json".utf8))
        await #expect { _ = try await rig.client.myPlaylists() } throws: { isDecodingError($0) }
    }

    @Test func transportErrorsPropagateUnchanged() async throws {
        let rig = Rig()
        rig.http.enqueueError("youtube/v3", NoSlopError.network("offline"))
        await #expect(throws: NoSlopError.network("offline")) { _ = try await rig.client.subscriptions() }
    }

    @Test func notSignedInSendsNothing() async throws {
        let rig = Rig(failure: .notSignedIn)
        let calls: [(String, @Sendable (YouTubeDataAPIClient) async throws -> Void)] = [
            ("subscriptions", { _ = try await $0.subscriptions() }),
            ("subscribe", { _ = try await $0.subscribe(channelID: "UC1") }),
            ("unsubscribe", { try await $0.unsubscribe(subscriptionID: "S1") }),
            ("myPlaylists", { _ = try await $0.myPlaylists() }),
            ("playlistItems", { _ = try await $0.playlistItems(playlistID: "PL1", pageToken: nil) }),
            ("likedVideos", { _ = try await $0.likedVideos(pageToken: nil) }),
            ("rating", { _ = try await $0.rating(videoID: "v") }),
            ("rate", { try await $0.rate(videoID: "v", rating: .like) }),
            ("addToPlaylist", { try await $0.addToPlaylist(videoID: "v", playlistID: "p") }),
            ("durations", { _ = try await $0.durations(videoIDs: ["v"]) }),
        ]
        for (name, call) in calls {
            await #expect(throws: NoSlopError.notSignedIn, "\(name)") { try await call(rig.client) }
        }
        #expect(rig.http.requests.isEmpty)
    }

    @Test func idsAreEncodedSoTheyCannotInjectParameters() async throws {
        let rig = Rig()
        rig.http.enqueue("youtube/v3", status: 204, body: Data())
        try await rig.client.unsubscribe(subscriptionID: "a&mine=true#x y")
        let request = try #require(rig.http.requests.first)
        #expect(query(request)["id"] == "a&mine=true#x y")
        #expect(query(request).count == 1)
        #expect(request.url?.fragment == nil)
    }
}
