import Foundation
import Testing
@testable import NoSlopKit

@Suite struct ModelsTests {
    // MARK: From the plan

    @Test func settingsDecodeEmptyObjectGivesDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
        #expect(s.segmentBehaviors[.sponsor] == .autoSkip)
        #expect(s.segmentBehaviors[.intro] == .showInBar)
    }

    @Test func historyFinished() {
        let v = VideoSummary(id: "a", title: "t")
        #expect(HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: 590, durationSeconds: 600).isFinished)
        #expect(!HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: 300, durationSeconds: 600).isFinished)
        #expect(!HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: 300, durationSeconds: nil).isFinished)
    }

    @Test func defaultThumbnails() {
        #expect(VideoSummary.defaultThumbnails(for: "abc").first?.url.absoluteString == "https://i.ytimg.com/vi/abc/mqdefault.jpg")
    }

    @Test func thumbnailBest() {
        let list = [168, 336, 480].map { width in
            Thumbnail(url: URL(string: "https://i.ytimg.com/vi/x/\(width).jpg")!, width: width, height: width * 9 / 16)
        }
        #expect(list.best(minWidth: 300)?.width == 336)
        #expect(list.best(minWidth: 1000)?.width == 480)
    }

    @Test func downloadQualityKeys() {
        #expect(DownloadQuality.video(maxHeight: 720).key == "720")
        #expect(DownloadQuality.audioOnly.label == "Audio only")
    }

    @Test func streamInfoExpiry() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let info = StreamInfo(videoID: "v", title: "t", author: "a", channelID: "c", lengthSeconds: 10, expiresAt: t0.addingTimeInterval(21_540))
        #expect(!info.isExpired(now: t0))
        #expect(info.isExpired(now: t0.addingTimeInterval(21_500)))
    }

    // MARK: Thumbnails and videos

    @Test func thumbnailBestIgnoresOrderAndFallsBack() {
        func thumb(_ width: Int) -> Thumbnail { Thumbnail(url: URL(string: "https://i/\(width)")!, width: width) }
        #expect([thumb(480), thumb(168), thumb(336)].best(minWidth: 300)?.width == 336)
        #expect([thumb(480), thumb(168), thumb(336)].best(minWidth: 1000)?.width == 480)
        #expect([thumb(480), thumb(168)].best(minWidth: 0)?.width == 168)
        // Without any widths the last element wins; an empty list has none.
        let unsized = [Thumbnail(url: URL(string: "https://i/a")!), Thumbnail(url: URL(string: "https://i/b")!)]
        #expect(unsized.best(minWidth: 100)?.url.absoluteString == "https://i/b")
        #expect([Thumbnail]().best(minWidth: 100) == nil)
    }

    @Test func defaultThumbnailsAreAscending() {
        let thumbnails = VideoSummary.defaultThumbnails(for: "abc")
        #expect(thumbnails.map(\.width) == [320, 480, 640])
        #expect(thumbnails.map(\.height) == [180, 360, 480])
        #expect(thumbnails.map(\.url.lastPathComponent) == ["mqdefault.jpg", "hqdefault.jpg", "sddefault.jpg"])
    }

    @Test func videoSummaryDerivedValues() {
        let bare = VideoSummary(id: "dQw4w9WgXcQ", title: "t")
        #expect(bare.watchURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(bare.displayThumbnails == VideoSummary.defaultThumbnails(for: "dQw4w9WgXcQ"))
        #expect(!bare.isLive && !bare.isUpcoming && !bare.isShort && !bare.isMembersOnly)

        let own = Thumbnail(url: URL(string: "https://i/own.jpg")!, width: 360)
        #expect(VideoSummary(id: "a", title: "t", thumbnails: [own]).displayThumbnails == [own])
    }

    @Test func videoSummaryDecodesMissingKeysToDefaults() throws {
        let video = try JSONDecoder().decode(VideoSummary.self, from: Data(#"{"id":"abc"}"#.utf8))
        #expect(video == VideoSummary(id: "abc", title: ""))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(VideoSummary.self, from: Data("{}".utf8)) }
    }

    @Test func videoSummaryRoundTrips() throws {
        let video = VideoSummary(
            id: "abc", title: "Title", channel: ChannelRef(id: "UC1", name: "Chan", avatarURL: URL(string: "https://a/b.jpg"), handle: "@chan"),
            thumbnails: VideoSummary.defaultThumbnails(for: "abc"), durationSeconds: 280, viewCount: 9_793, viewCountText: "9.8K views",
            publishedText: "22 hours ago", publishedAt: Date(timeIntervalSince1970: 1_800_000_000), isLive: true, isUpcoming: true,
            isShort: true, isMembersOnly: true
        )
        let data = try JSONEncoder().encode(video)
        #expect(try JSONDecoder().decode(VideoSummary.self, from: data) == video)
    }

    @Test func channelRefsMirrorTheirOwners() {
        let url = URL(string: "https://a/b.jpg")
        let summary = ChannelSummary(id: "UC1", name: "N", handle: "@n", avatarURL: url, subscriberCountText: "1M subscribers")
        #expect(summary.ref == ChannelRef(id: "UC1", name: "N", avatarURL: url, handle: "@n"))
        let header = ChannelHeader(id: "UC1", name: "N", handle: "@n", avatarURL: url, bannerURL: URL(string: "https://a/banner.jpg"))
        #expect(header.ref == summary.ref)
        #expect(SubscribedChannel(id: "UC1", name: "N", avatarURL: url).ref == ChannelRef(id: "UC1", name: "N", avatarURL: url))
    }

    // MARK: Search

    @Test func searchItemIdentity() {
        let video = VideoSummary(id: "v", title: "t")
        #expect(SearchItem.video(video).id == "video:v")
        #expect(SearchItem.channel(ChannelSummary(id: "UC1", name: "n")).id == "channel:UC1")
        #expect(SearchItem.playlist(PlaylistSummary(id: "PL1", title: "t")).id == "playlist:PL1")
        #expect(SearchItem.video(video).video == video)
        #expect(SearchItem.channel(ChannelSummary(id: "UC1", name: "n")).video == nil)
    }

    @Test func searchFilterDefault() {
        #expect(SearchFilter().isDefault)
        #expect(!SearchFilter(type: .video).isDefault)
        #expect(!SearchFilter(sort: .uploadDate).isDefault)
        #expect(!SearchFilter(duration: .long).isDefault)
        #expect(!SearchFilter(uploadDate: .today).isDefault)
    }

    @Test func pagesCompareWhenTheirItemsDo() {
        #expect(Page<Int>() == Page<Int>(items: [], continuation: nil))
        #expect(Page(items: [1, 2], continuation: "c") == Page(items: [1, 2], continuation: "c"))
        #expect(Page(items: [1, 2], continuation: "c") != Page(items: [1, 2], continuation: nil))
    }

    // MARK: Streams

    @Test func streamFormatCodecs() {
        func format(_ mime: String, progressive: Bool = false) -> StreamFormat {
            StreamFormat(itag: 1, url: URL(string: "https://v/1")!, mimeType: mime, isProgressive: progressive)
        }
        #expect(format(#"video/mp4; codecs="avc1.640028""#).codecs == "avc1.640028")
        #expect(format(#"video/mp4; codecs="avc1.42001E, mp4a.40.2""#, progressive: true).codecs == "avc1.42001E, mp4a.40.2")
        #expect(format("video/mp4").codecs == "")
        #expect(format(#"video/mp4; codecs="avc1"#).codecs == "")
    }

    @Test func streamFormatKinds() {
        func format(_ mime: String, progressive: Bool = false) -> StreamFormat {
            StreamFormat(itag: 1, url: URL(string: "https://v/1")!, mimeType: mime, isProgressive: progressive)
        }
        #expect(format(#"audio/mp4; codecs="mp4a.40.2""#).isAudioOnly)
        #expect(!format(#"audio/mp4; codecs="mp4a.40.2""#).isVideoOnly)
        #expect(format(#"video/mp4; codecs="avc1.640028""#).isVideoOnly)
        #expect(!format(#"video/mp4; codecs="avc1.640028""#).isAudioOnly)
        // A progressive file carries audio too.
        #expect(!format(#"video/mp4; codecs="avc1.42001E, mp4a.40.2""#, progressive: true).isVideoOnly)
    }

    @Test func streamFormatAVFoundationCompatibility() {
        func compatible(_ mime: String) -> Bool {
            StreamFormat(itag: 1, url: URL(string: "https://v/1")!, mimeType: mime).isAVFoundationCompatible
        }
        #expect(compatible(#"video/mp4; codecs="avc1.640028""#))
        #expect(compatible(#"audio/mp4; codecs="mp4a.40.2""#))
        #expect(!compatible(#"video/webm; codecs="vp9""#))
        #expect(!compatible(#"video/mp4; codecs="av01.0.12M.08""#))
        #expect(!compatible(#"audio/webm; codecs="opus""#))
        #expect(!compatible(#"video/mp4; codecs="mp4a.40.2""#))
        #expect(!compatible("video/mp4"))
    }

    @Test func captionTrackIdSeparatesAutoGenerated() {
        let url = URL(string: "https://www.youtube.com/api/timedtext?v=x")!
        #expect(CaptionTrack(languageCode: "en", name: "English", baseURL: url).id == "en-std")
        #expect(CaptionTrack(languageCode: "en", name: "English (auto-generated)", baseURL: url, isAutoGenerated: true).id == "en-asr")
    }

    @Test func streamInfoExpiryHonoursTheMargin() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let info = StreamInfo(videoID: "v", title: "t", author: "a", channelID: "c", lengthSeconds: 10, expiresAt: t0.addingTimeInterval(1_000))
        #expect(!info.isExpired(now: t0.addingTimeInterval(879)))
        #expect(info.isExpired(now: t0.addingTimeInterval(880)))
        #expect(!info.isExpired(now: t0.addingTimeInterval(990), margin: 5))
        #expect(info.isExpired(now: t0.addingTimeInterval(995), margin: 5))
        #expect(info.isExpired(now: t0.addingTimeInterval(2_000)))
    }

    // MARK: Account

    @Test func oauthTokensExpireWithLeeway() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: t0.addingTimeInterval(3_599))
        #expect(!tokens.isExpired(now: t0))
        #expect(!tokens.isExpired(now: t0.addingTimeInterval(3_538)))
        #expect(tokens.isExpired(now: t0.addingTimeInterval(3_539)))
        #expect(tokens.isExpired(now: t0.addingTimeInterval(3_599), leeway: 0))
        #expect(!tokens.isExpired(now: t0.addingTimeInterval(3_598), leeway: 0))
    }

    @Test func storedCredentialsRoundTrip() throws {
        let credentials = StoredCredentials(
            clientID: "123-abc.apps.googleusercontent.com",
            tokens: OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), scope: "openid", idToken: "id"),
            account: GoogleAccount(id: "1234", email: "you@example.com", name: "You", pictureURL: URL(string: "https://p/x.jpg"))
        )
        let data = try JSONEncoder().encode(credentials)
        #expect(try JSONDecoder().decode(StoredCredentials.self, from: data) == credentials)
    }

    // MARK: Library

    @Test func historyFinishedEdges() {
        let v = VideoSummary(id: "a", title: "t")
        func entry(_ progress: Double, _ duration: Double?) -> HistoryEntry {
            HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: progress, durationSeconds: duration)
        }
        // The two rules overlap, so pick lengths where only one of them can apply.
        #expect(entry(85, 100).isFinished)             // within 15 s of the end (85% through a short video)
        #expect(!entry(84, 100).isFinished)
        #expect(entry(9_500, 10_000).isFinished)       // at least 95% through (500 s before the end of a long one)
        #expect(!entry(9_499, 10_000).isFinished)
        #expect(entry(9_985, 10_000).isFinished)
        #expect(!entry(5, 0).isFinished)               // zero duration is "unknown"
        #expect(!entry(0, 600).isFinished)
    }

    @Test func subscriptionSourcesRoundTrip() throws {
        let channels = [
            SubscribedChannel(id: "UC1", name: "Local", source: .local),
            SubscribedChannel(id: "UC2", name: "Google", avatarURL: URL(string: "https://a/b.jpg"), source: .google(subscriptionID: "sub-1"),
                              subscribedAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ]
        let data = try JSONEncoder().encode(channels)
        #expect(try JSONDecoder().decode([SubscribedChannel].self, from: data) == channels)
    }

    @Test func subscribedChannelDecodesMissingKeysToDefaults() throws {
        let channel = try JSONDecoder().decode(SubscribedChannel.self, from: Data(#"{"id":"UC1"}"#.utf8))
        #expect(channel == SubscribedChannel(id: "UC1", name: ""))
        #expect(channel.source == .local)
    }

    @Test func historyEntryAndPlaylistDecodeMissingKeysToDefaults() throws {
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(#"{"video":{"id":"abc"}}"#.utf8))
        #expect(entry.id == "abc")
        #expect(entry.progressSeconds == 0)
        #expect(entry.durationSeconds == nil)

        let uuid = UUID()
        let playlist = try JSONDecoder().decode(LocalPlaylist.self, from: Data(#"{"id":"\#(uuid.uuidString)"}"#.utf8))
        #expect(playlist.id == uuid)
        #expect(playlist.videos.isEmpty)
        #expect(playlist.title == "")
    }

    @Test func localPlaylistRoundTrips() throws {
        let playlist = LocalPlaylist(
            title: "Faves", videos: [VideoSummary(id: "a", title: "A"), VideoSummary(id: "b", title: "B")],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let data = try JSONEncoder().encode(playlist)
        #expect(try JSONDecoder().decode(LocalPlaylist.self, from: data) == playlist)
    }

    // MARK: Downloads

    @Test func downloadQualityLabelsAndCoding() throws {
        #expect(DownloadQuality.video(maxHeight: 720).label == "720p")
        #expect(DownloadQuality.video(maxHeight: 1080).key == "1080")
        #expect(DownloadQuality.audioOnly.key == "audio")
        for quality in [DownloadQuality.video(maxHeight: 360), .audioOnly] {
            let data = try JSONEncoder().encode(quality)
            #expect(try JSONDecoder().decode(DownloadQuality.self, from: data) == quality)
        }
    }

    @Test func downloadItemRoundTripsAndToleratesMissingKeys() throws {
        let item = DownloadItem(
            id: "abc-720", video: VideoSummary(id: "abc", title: "T"), quality: .video(maxHeight: 720), state: .downloading,
            progress: 0.5, bytesDownloaded: 5, bytesTotal: 10, relativeFilePath: "T [abc].mp4",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), errorMessage: "oops"
        )
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(DownloadItem.self, from: data) == item)

        let audioQualityJSON = String(decoding: try JSONEncoder().encode(DownloadQuality.audioOnly), as: UTF8.self)
        let minimal = #"{"id":"abc-audio","video":{"id":"abc"},"quality":\#(audioQualityJSON)}"#
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: Data(minimal.utf8))
        #expect(decoded.id == "abc-audio")
        #expect(decoded.quality == .audioOnly)
        #expect(decoded.progress == 0)
        #expect(decoded.bytesDownloaded == 0)
        #expect(decoded.bytesTotal == nil)
    }

    @Test func downloadOptionIdIsTheQualityKey() {
        #expect(DownloadOption(quality: .video(maxHeight: 480), label: "480p").id == "480")
        #expect(DownloadOption(quality: .audioOnly, label: "Audio only", estimatedBytes: 10).id == "audio")
    }

    // MARK: SponsorBlock

    @Test func sponsorCategoriesMatchTheSponsorBlockApi() {
        #expect(SponsorCategory.allCases.map(\.rawValue) == [
            "sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic", "filler", "poi_highlight",
        ])
        #expect(SponsorCategory.allCases.map(\.displayName) == [
            "Sponsor", "Self-promotion", "Interaction reminder", "Intro", "Outro", "Preview/recap", "Non-music section", "Filler", "Highlight",
        ])
        #expect(SponsorCategory.allCases.map(\.colorHex) == [
            "#00D400", "#FFFF00", "#CC00FF", "#00FFFF", "#0202ED", "#008FD6", "#FF9900", "#7300FF", "#FF1684",
        ])
    }

    @Test func segmentModelsDecodeFromRawValues() throws {
        let segment = try JSONDecoder().decode(
            SponsorSegment.self,
            from: Data(#"{"id":"u","category":"music_offtopic","actionType":"mute","start":1.5,"end":2.5}"#.utf8)
        )
        #expect(segment == SponsorSegment(id: "u", category: .musicOfftopic, actionType: .mute, start: 1.5, end: 2.5))
        #expect(SegmentActionType(rawValue: "poi") == .poi)
        #expect(SegmentBehavior.allCases == [.autoSkip, .showInBar, .ignore])
    }

    // MARK: Settings

    @Test func qualityPreferences() {
        #expect(QualityPreference.allCases.map(\.maxHeight) == [nil, 1080, 720, 480, 360])
        #expect(QualityPreference.allCases.map(\.label) == ["Auto", "1080p", "720p", "480p", "360p"])
    }

    @Test func settingsDefaultsMatchTheSpec() {
        let s = AppSettings()
        #expect(s.hideShorts && s.hideMembersOnly && !s.hideLiveAndUpcoming && !s.hideWatchedInSubscriptions)
        #expect(s.blockedChannels.isEmpty && s.blockedKeywords.isEmpty)
        #expect(s.sponsorBlockEnabled && s.deArrowTitles)
        #expect(s.wifiQuality == .auto && s.cellularQuality == .p720)
        #expect(s.defaultPlaybackRate == 1.0 && !s.autoplayNext && s.backgroundPlayback && s.autoPictureInPicture)
        #expect(s.preferredCaptionLanguage == nil && s.googleClientID == "" && s.contentLanguage == nil && s.contentRegion == nil)
        for category in SponsorCategory.allCases {
            let expected: SegmentBehavior = [.sponsor, .selfpromo, .interaction].contains(category) ? .autoSkip : .showInBar
            #expect(s.segmentBehaviors[category] == expected, "\(category)")
        }
    }

    @Test func settingsFromAnOlderBuildKeepTheirValuesAndDefaultTheRest() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hideShorts":false}"#.utf8))
        var expected = AppSettings()
        expected.hideShorts = false
        #expect(s == expected)
    }

    @Test func oneWronglyTypedSettingDoesNotResetTheOthers() throws {
        // "hideShorts" is a string where a Bool belongs; every other key is fine and must be kept.
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hideShorts":"yes","autoplayNext":true,"blockedKeywords":["a","b"],"wifiQuality":"p1080"}"#.utf8))
        var expected = AppSettings()
        expected.autoplayNext = true
        expected.blockedKeywords = ["a", "b"]
        expected.wifiQuality = .p1080
        #expect(s.hideShorts, "the wrong value falls back to this key's default (on)")
        #expect(s == expected)
    }

    @Test func everySettingFallsBackOnItsOwnWhenItsValueIsUnreadable() throws {
        // A missing key, a null, a wrong type and an unknown enum value, each in a different place.
        let json = #"""
        {"hideShorts":"yes","hideMembersOnly":false,"hideLiveAndUpcoming":null,"autoplayNext":true,
         "wifiQuality":"p1080","cellularQuality":"bogus","defaultPlaybackRate":"fast",
         "blockedKeywords":["minecraft",5,"reaction"],
         "blockedChannels":[{"id":"UC1","name":"One"},{"id":7},"x",{"id":"UC2","name":"Two"}],
         "segmentBehaviors":{"sponsor":"ignore","intro":5,"outro":"autoSkip","from_the_future":"autoSkip"},
         "googleClientID":42,"contentLanguage":"de","contentRegion":["AT"],"preferredCaptionLanguage":false}
        """#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        var expected = AppSettings()
        expected.hideMembersOnly = false
        expected.autoplayNext = true
        expected.wifiQuality = .p1080
        expected.blockedKeywords = ["minecraft", "reaction"]
        expected.blockedChannels = [BlockedChannel(id: "UC1", name: "One"), BlockedChannel(id: "UC2", name: "Two")]
        expected.segmentBehaviors[.sponsor] = .ignore
        expected.segmentBehaviors[.outro] = .autoSkip
        expected.contentLanguage = "de"
        #expect(s == expected)
        // Spelled out, because a mistake in `expected` must not hide a wrong default.
        #expect(s.hideShorts && !s.hideLiveAndUpcoming && s.cellularQuality == .p720 && s.defaultPlaybackRate == 1.0)
        #expect(s.googleClientID == "" && s.contentRegion == nil && s.preferredCaptionLanguage == nil)
        #expect(s.segmentBehaviors[.intro] == .showInBar)
    }

    @Test(arguments: ["[]", "\"text\"", "42", "null"])
    func settingsThatAreNotAnObjectAreStillRejected(text: String) {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))
        }
    }

    @Test func settingsRoundTripAndWriteBehavioursAsAKeyedObject() throws {
        var s = AppSettings()
        s.hideShorts = false
        s.blockedChannels = [BlockedChannel(id: "UC1", name: "Spam")]
        s.blockedKeywords = ["minecraft"]
        s.segmentBehaviors[.sponsor] = .ignore
        s.segmentBehaviors[.musicOfftopic] = .autoSkip
        s.wifiQuality = .p1080
        s.defaultPlaybackRate = 1.5
        s.preferredCaptionLanguage = "en"
        s.googleClientID = "123-abc.apps.googleusercontent.com"
        s.contentLanguage = "de"

        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)

        let behaviors = try #require(try JSON(data: data)["segmentBehaviors"]?.object)
        #expect(behaviors["sponsor"] == "ignore")
        #expect(behaviors["music_offtopic"] == "autoSkip")
        #expect(behaviors.count == SponsorCategory.allCases.count)
    }

    @Test func settingsIgnoreUnknownBehaviourKeysAndKeepDefaultsForMissingOnes() throws {
        let json = #"{"segmentBehaviors":{"sponsor":"ignore","from_the_future":"autoSkip","intro":"bogus"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.segmentBehaviors[.sponsor] == .ignore)
        #expect(s.segmentBehaviors[.intro] == .showInBar)
        #expect(s.segmentBehaviors[.selfpromo] == .autoSkip)
        #expect(s.segmentBehaviors.count == SponsorCategory.allCases.count)
    }

    // MARK: Watch page, errors, feed

    @Test func videoDetailsSummary() {
        let channel = ChannelRef(id: "UC1", name: "Blender")
        let details = VideoDetails(
            id: "aqz", title: "Big Buck Bunny", channel: channel, viewCount: 23_500_582, viewCountText: "23,500,582 views",
            relativeDateText: "11 years ago", isLive: true
        )
        let summary = details.summary
        #expect(summary.id == "aqz" && summary.title == "Big Buck Bunny" && summary.channel == channel)
        #expect(summary.viewCount == 23_500_582 && summary.viewCountText == "23,500,582 views")
        #expect(summary.publishedText == "11 years ago")
        #expect(summary.isLive && !summary.isShort)
        #expect(VideoDetails(id: "a", title: "t", channel: channel).description == .empty)
    }

    @Test func descriptionLinksRoundTrip() throws {
        let description = AttributedDescription(text: "Jump to 1:00 #blender https://x.y", links: [
            DescriptionLink(range: 8..<12, target: .timestamp(seconds: 60)),
            DescriptionLink(range: 13..<21, target: .hashtag("blender")),
            DescriptionLink(range: 22..<33, target: .url(URL(string: "https://x.y")!)),
            DescriptionLink(range: 0..<1, target: .video(id: "dQw4w9WgXcQ", startSeconds: 10)),
            DescriptionLink(range: 0..<1, target: .channel(id: "UC1")),
            DescriptionLink(range: 0..<1, target: .playlist(id: "PL1")),
        ])
        let data = try JSONEncoder().encode(description)
        #expect(try JSONDecoder().decode(AttributedDescription.self, from: data) == description)
        #expect(AttributedDescription.empty == AttributedDescription(text: "", links: []))
    }

    @Test func homeFeedStartsEmpty() {
        #expect(HomeFeed.empty.continueWatching.isEmpty)
        #expect(HomeFeed.empty.forYou.isEmpty)
    }

    @Test func errorMessagesAreShortPlainSentences() {
        #expect(NoSlopError.botCheck.errorDescription == "YouTube asked to confirm you're not a bot. Try again in a minute, or open the video on YouTube.")
        #expect(NoSlopError.unplayable(reason: "This video is private.").errorDescription == "This video is private.")
        #expect(NoSlopError.notPlayableYet(reason: "This live event will begin in 2 hours.").errorDescription == "This live event will begin in 2 hours.")
        #expect(NoSlopError.notSignedIn.errorDescription == "Sign in with Google to use this.")
        #expect(NoSlopError.googleNotConfigured.errorDescription == "Add your Google OAuth client ID in Settings \u{2192} Account first.")
        #expect(NoSlopError.quotaExceeded.errorDescription == "YouTube's daily API quota for your Google project is used up. Try again tomorrow.")
        #expect(NoSlopError.network("The Internet connection appears to be offline.").errorDescription == "Can't reach YouTube. Check your connection.")

        let others: [NoSlopError] = [.notImplemented("Foo.bar"), .http(status: 500), .decoding("x"), .oauth("access_denied"), .oauth(""), .cancelled]
        for error in others {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "\(error)")
            #expect(text.hasSuffix("."), "\(error)")
        }
        #expect(NoSlopError.oauth("access_denied").errorDescription?.contains("access_denied") == true)
        #expect(NoSlopError.notImplemented("Foo.bar").errorDescription?.contains("Foo.bar") == true)
        #expect(NoSlopError.http(status: 503).errorDescription?.contains("503") == true)
    }

    @Test func anOAuthMessageThatIsAlreadyASentenceIsNotWrapped() {
        let refusal = "YouTube access wasn't granted. Sign in again and allow access to your YouTube account."
        #expect(NoSlopError.oauth(refusal).errorDescription == refusal)
        #expect(NoSlopError.oauth("The sign-in page could not be opened.").errorDescription == "The sign-in page could not be opened.")
        #expect(NoSlopError.oauth("The sign-in page returned no result.").errorDescription == "The sign-in page returned no result.")
        #expect(NoSlopError.oauth("Is this working?").errorDescription == "Is this working?")
        #expect(NoSlopError.oauth("  Padded sentence.\n").errorDescription == "Padded sentence.")
    }

    @Test func aBareOAuthReasonKeepsItsFrame() {
        #expect(NoSlopError.oauth("access_denied").errorDescription == "Google sign-in failed (access_denied).")
        #expect(NoSlopError.oauth("state mismatch").errorDescription == "Google sign-in failed (state mismatch).")
        #expect(NoSlopError.oauth("no authorization code").errorDescription == "Google sign-in failed (no authorization code).")
        // Google's description ends in a full stop of its own: it must not come out as ".)."
        let withDescription = NoSlopError.oauth("invalid_client: The OAuth client was not found.").errorDescription
        #expect(withDescription == "Google sign-in failed (invalid_client: The OAuth client was not found).")
        #expect(NoSlopError.oauth("").errorDescription == "Google sign-in failed.")
        #expect(NoSlopError.oauth("  \n").errorDescription == "Google sign-in failed.")
        #expect(NoSlopError.oauth(".").errorDescription == "Google sign-in failed.")
    }

    @Test(arguments: [
        "YouTube access wasn't granted. Sign in again and allow access to your YouTube account.",
        "access_denied", "invalid_client: The OAuth client was not found.", "state mismatch", "",
    ])
    func noOAuthMessageEndsInADoubledPunctuation(message: String) {
        let text = NoSlopError.oauth(message).errorDescription ?? ""
        #expect(!text.contains(".)"), "\(text)")
        #expect(!text.hasSuffix(".."), "\(text)")
        #expect(!text.isEmpty)
    }

    @Test func aMissingDataAPIExplainsHowToEnableIt() {
        let text = NoSlopError.dataAPINotEnabled.errorDescription ?? ""
        #expect(text.contains("YouTube Data API v3"))
        #expect(text.contains("enable"))
        #expect(text.contains("wait a minute"))
        #expect(text.hasSuffix("."))
        #expect(NoSlopError.dataAPINotEnabled == .dataAPINotEnabled)
        #expect(NoSlopError.dataAPINotEnabled != .http(status: 403))
    }

    @Test func theTVConnectionSpeaksInPlainSentencesNotGoogleSignInWording() {
        #expect(NoSlopError.recommendationsNotConnected.errorDescription == "YouTube recommendations aren't connected.")
        for message in ["The code expired. Start again.", "The sign-in was declined.", "The sign-in couldn't start. Try again later.", "The sign-in didn't work. Try again."] {
            #expect(NoSlopError.oauth(message).errorDescription == message)
        }
    }

    @Test func onlyFailuresTheViewerCanActOnAreShownAfterSignIn() {
        // Shown: nothing else will tell the viewer why the import keeps failing.
        for error: NoSlopError in [.dataAPINotEnabled, .quotaExceeded, .http(status: 403), .http(status: 500), .decoding("x"), .oauth("Keychain: x")] {
            #expect(NoSlopError.isWorthShowingAfterSignIn(error), "\(error)")
        }
        // Not shown: the signed-out screens say it, the connection says it, or nobody is waiting for an answer.
        for error: NoSlopError in [.notSignedIn, .network("offline"), .cancelled] {
            #expect(!NoSlopError.isWorthShowingAfterSignIn(error), "\(error)")
        }
        #expect(!NoSlopError.isWorthShowingAfterSignIn(CancellationError()))
        // An error the kit does not know is still worth saying.
        struct Unknown: Error {}
        #expect(NoSlopError.isWorthShowingAfterSignIn(Unknown()))
    }

    @Test func errorsCompareByCaseAndPayload() {
        #expect(NoSlopError.http(status: 404) == .http(status: 404))
        #expect(NoSlopError.http(status: 404) != .http(status: 500))
        #expect(NoSlopError.botCheck != .notSignedIn)
        #expect(NoSlopError.network("a") != .network("b"))
        // The message is what `localizedDescription` shows for a thrown error.
        let thrown: any Error = NoSlopError.notSignedIn
        #expect(thrown.localizedDescription == "Sign in with Google to use this.")
    }
}
