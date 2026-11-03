# No Slop YouTube Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build "No Slop", a native iPhone/iPad YouTube client with ad-free HLS playback, background audio, PiP, downloads, SponsorBlock, DeArrow, no Shorts, and optional Google sign-in for subscriptions, playlists and likes.

**Architecture:** A local Swift package `NoSlopKit` holds all platform-agnostic logic (InnerTube client and parsers, Google OAuth and Data API, feeds, library persistence, downloads, SponsorBlock/DeArrow). It is tested with `swift test` against real YouTube responses captured on 2026-11-03. The iOS app target `NoSlop` holds the SwiftUI screens, the AVPlayer-based player, and OS integration. Task 1 lays down every shared type, protocol, stub, mock and placeholder screen, so Tasks 2–10 can run in parallel git worktrees without touching each other's files. Task 11 merges and wires them; Task 12 runs QA in the simulator.

**Tech Stack:** Swift 6.2 / Xcode 26.2, SwiftUI + Observation, AVFoundation/AVKit, MediaPlayer, AuthenticationServices, CryptoKit, Security, Network; Swift Testing (`import Testing`); XcodeGen 2.46 with synced folders. No third-party packages.

**Spec:** `docs/superpowers/specs/2026-11-03-noslop-design.md` (read it first; it records the verified YouTube behaviour this plan relies on).

## Global Constraints

- iOS deployment target **18.0**; package platforms `.iOS(.v18), .macOS(.v15)`; `swift-tools-version: 6.2`; Swift language mode 6 everywhere.
- App target build settings: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. The package keeps default (nonisolated) isolation; UI-facing stores in the package are explicitly `@MainActor`.
- No third-party dependencies. Apple frameworks only.
- Bundle ID `com.robinjungerich.noslopyt`; display name `No Slop`; URL scheme `noslop`; Keychain service `com.robinjungerich.noslopyt.google`; background URLSession id `com.robinjungerich.noslopyt.downloads`.
- InnerTube base `https://www.youtube.com/youtubei/v1/<endpoint>?prettyPrint=false`, POST JSON. Profiles exactly as in the spec table: WEB `2.20261030.02.00` (client name id 1, Safari UA ending `,gzip(gfe)`); VISIONOS `1.02` (id 101, `deviceMake: Apple`, `deviceModel: RealityDevice17,1`, `osName: visionOS`, `osVersion: 26.5.23O471`, visionOS UA).
- Every InnerTube request carries visitorData (`context.client.visitorData` and header `X-Goog-Visitor-Id`), plus `hl`/`gl` from `InnerTubeConfig`, plus header `Origin: https://www.youtube.com`.
- Parsers never return ads (`adSlotRenderer`, `inFeedAdLayoutRenderer`, `promotedVideoRenderer`, `promotedSparklesWebRenderer`, `searchPyvRenderer`) or AI summaries (`videoSummaryContentViewModel`, `genAiFeedbackFormViewModel`). Shorts are returned with `isShort = true`; `ContentFilter` hides them.
- Parsers never throw for unknown or missing data; they skip what they can't map. (Only `PlayerResponseParser` throws, for playability errors.)
- Downloads: 10 MiB (`10_485_760` bytes) Range chunks; only `video/mp4` `avc1` and `audio/mp4` `mp4a` formats; prefer audio with `isDRC == false`; mux with time ranges clamped to the format's `approxDurationMs` (fallback `lengthSeconds`), audio-only included.
- SponsorBlock and DeArrow use the 4-hex-char SHA-256 prefix endpoints on `https://sponsor.ajay.app`. No analytics, no other third parties.
- Google OAuth: PKCE S256 in `ASWebAuthenticationSession`; scopes `openid email profile https://www.googleapis.com/auth/youtube`; no client secret.
- Persisted JSON: missing keys decode to defaults; an undecodable file is renamed `<file>.corrupt` (replacing an older one), never deleted.
- Everything the app uses from NoSlopKit is `public`. Models are `Sendable` value types.
- **Ownership:** a task creates or modifies only the files in its **Files** block. If a task needs a contract change, it works around it and lists it under "CONTRACT CHANGE REQUESTS" in its final report.
- Tests use Swift Testing, which runs in parallel. Every test uses its own temp directory or `UserDefaults(suiteName: UUID().uuidString)`.
- Commands (run from the repo root):
  - Package tests: `swift test --package-path NoSlopKit`
  - App build: `xcodebuild -project NoSlop.xcodeproj -scheme NoSlop -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet`
  - Live network tests (opt-in): `NOSLOP_LIVE=1 swift test --package-path NoSlopKit --filter Live`

## Review Focus

1. **YouTube returns a shape the fixtures don't show** (renamed renderer, missing field, new wrapper). Expected: that item is skipped and the rest of the page renders; a page with nothing parseable is an empty page, never a crash or a whole-page error. → Task 3 `testMutatedRenderersAreSkipped`, `testEmptyObjectYieldsEmptyPage`; Task 4 `testMissingEntityMutationSkipsComment`, `testMinimalNextStillParses`.
2. **YouTube's bot check on `player`** (stale/rejected visitorData). Expected: one silent retry with fresh visitorData, then a plain message plus "Open on YouTube". → Task 2 `testRetriesOnceWithFreshVisitorDataOnBotCheck`, `testSecondBotCheckThrowsBotCheck`.
3. **Resuming a paused video hours later (URLs expired) or losing network mid-play.** Expected: re-resolve and resume at the same position, or wait for connectivity and retry; error UI only after a second failure. → Task 10 `PlaybackRecoveryTests`.
4. **Interrupted downloads** (network drop, app killed, URL expiry). Expected: item ends `.failed` or `.paused` with Retry that re-resolves fresh URLs; a half-written file is never marked completed; merged files have the true duration. → Task 7 `chunkFailureMarksFailedAndCleansUp`, `retryReResolvesStreams`, `restoredInFlightItemBecomesPaused`, `zooClampedDuration`.
5. **Upgrades and corrupted local data** (settings/library JSON from an older build, or a truncated file). Expected: defaults for new keys, the corrupt file moved aside, everything readable kept. → Task 6 `testDecodesEmptySettingsObjectToDefaults`, `testCorruptLibraryFileIsMovedAside`.

---

## Execution model

| Phase | Tasks | Where |
|---|---|---|
| 1 Foundation | 1A (package contracts), then 1B (app shell, project) | main working tree, sequential |
| 2 Parallel build | 2, 3, 4, 5, 6, 7, 8, 9, 10 | one git worktree each, in parallel; each commits on its own branch |
| 3 Integration | 11 (merge, wire, integration tests, README) | main working tree |
| 4 Review | adversarial review and fixes | main working tree |
| 5 QA | 12 (simulator walkthrough with live YouTube) | main working tree |

Every Phase 2 task starts from the Task 1 commit. In its worktree it may build and test everything, because the stubs keep the whole project compiling. A Phase 2 task ends with `git add` of **its own files only** and one commit. Its final report names the branch, the commit hash, the test summary, and any contract change requests.

UI tasks (8, 9, 10) can check their screens visually without the shared simulator. Create a private device with `xcrun simctl create "NoSlop-T<n>" "iPhone 17"`, boot it, install the built app from `.build/DerivedData/Build/Products/Debug-iphonesimulator/NoSlop.app`, launch with `xcrun simctl launch <udid> com.robinjungerich.noslopyt -mockServices YES`, deep-link with `xcrun simctl openurl <udid> 'noslop://…'`, capture with `xcrun simctl io <udid> screenshot /tmp/<name>.png`, and read the PNG. Delete the device when done (`xcrun simctl delete <udid>`). For a simulator build, use `-destination 'platform=iOS Simulator,id=<udid>'` instead of the generic destination.

## File structure and ownership

```
project.yml, Config/*.xcconfig, scripts/*.sh, NoSlop.xcodeproj ........ 1B
README.md ......................................................... 1B (skeleton) → 11 (final)
NoSlopKit/Package.swift .............................................. 1A
NoSlopKit/Sources/NoSlopKit/
  Models/*.swift, Protocols/Services.swift, Support/*.swift, Mocks/*.swift ... 1A
  InnerTube/ClientProfile.swift, InnerTubeConfig.swift, InnerTubeClient.swift,
    VisitorDataStore.swift, InnerTubeYouTubeService.swift, InnerTubeStreamResolver.swift,
    YouTubeURL.swift ..................................................... 2
  InnerTube/Parsers/PlayerResponseParser.swift, SuggestionsParser.swift,
    ResolveURLParser.swift, SwJsDataParser.swift ........................ 2
  Feeds/RSSParser.swift, Feeds/RSSFeedFetcher.swift .................... 2
  Captions/WebVTTParser.swift, Captions/CaptionsService.swift .......... 2
  InnerTube/Parsers/ItemParser.swift, SearchParser.swift, ChannelParser.swift,
    PlaylistParser.swift, RelatedParser.swift, InnerTube/SearchParams.swift ... 3
  InnerTube/Parsers/WatchMetadataParser.swift, CommentsParser.swift ...... 4
  Google/*.swift ....................................................... 5
  Library/LibraryStore.swift, Library/SettingsStore.swift, Library/JSONFileStore.swift,
    NoSlop/ContentFilter.swift ......................................... 6
  NoSlop/HashPrefix.swift, NoSlop/SponsorBlockClient.swift, NoSlop/DeArrowClient.swift,
    NoSlop/SegmentSkipPlanner.swift, Feeds/SubscriptionFeedService.swift,
    Feeds/HomeFeedService.swift ........................................ 6
  Downloads/*.swift .................................................... 7
  Playback/*.swift ..................................................... 10
NoSlopKit/Tests/NoSlopKitTests/
  Fixtures/ (committed before Task 1) .................................. read-only
  Support/FixtureLoader.swift, Support/MockHTTPClient.swift, Foundation/*Tests.swift ... 1A
  InnerTube/Transport*, Player*, Suggestions*, YouTubeURL*, RSS*, WebVTT*, Live* ... 2
  InnerTube/Search*, Channel*, Playlist*, Related*, ItemParser*, SearchParams* ... 3
  InnerTube/WatchMetadata*, Comments* .................................. 4
  Google/* ............................................................. 5
  Library/*, NoSlop/*, Feeds/SubscriptionFeed*, Feeds/HomeFeed* ........ 6
  Downloads/* .......................................................... 7
  Playback/* ........................................................... 10
  Integration/* ........................................................ 11
NoSlop/  (app target, synced folder)
  App/NoSlopApp.swift, AppDelegate.swift, AppEnvironment.swift, Router.swift,
    RootView.swift, RouteDestinationView.swift ......................... 1B
  DesignSystem/*.swift ................................................. 1B (basic) → 8 (polish)
  Features/Home/*, Subscriptions/*, Search/*, Channel/*, Playlist/* ..... 8
  Features/Watch/*, Library/*, Downloads/*, Settings/*, Account/* ...... 9
  Player/*.swift ....................................................... 10
  Resources/Assets.xcassets ............................................ 1B (AccentColor) → 8 (AppIcon art)
```

---

## Shared contracts (Task 1A writes these exactly; bodies elided here)

All types below are `public` in NoSlopKit. "init(...)" means a memberwise public init with every optional/Bool/array parameter defaulted (`nil`/`false`/`[]`), in declaration order.

### Models

```swift
// Models/Video.swift
struct Thumbnail: Codable, Hashable, Sendable { var url: URL; var width: Int?; var height: Int?; init(...) }
extension Array where Element == Thumbnail {
    func best(minWidth: Int) -> Thumbnail?            // smallest with width >= minWidth, else largest width, else last
}
struct ChannelRef: Codable, Hashable, Sendable { var id: String; var name: String; var avatarURL: URL?; var handle: String?; init(...) }
struct VideoSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String; var title: String; var channel: ChannelRef?; var thumbnails: [Thumbnail]   // ascending width
    var durationSeconds: Int?; var viewCount: Int?; var viewCountText: String?
    var publishedText: String?; var publishedAt: Date?
    var isLive: Bool; var isUpcoming: Bool; var isShort: Bool; var isMembersOnly: Bool
    init(...)
    var watchURL: URL                                  // https://www.youtube.com/watch?v=<id>
    var displayThumbnails: [Thumbnail]                 // thumbnails, or defaultThumbnails(for: id) when empty
    static func defaultThumbnails(for id: String) -> [Thumbnail]
        // https://i.ytimg.com/vi/<id>/mqdefault.jpg 320x180, hqdefault.jpg 480x360, sddefault.jpg 640x480
}

// Models/Channel.swift
struct ChannelSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String; var name: String; var handle: String?; var avatarURL: URL?
    var subscriberCountText: String?; var videoCountText: String?; var descriptionSnippet: String?
    init(...); var ref: ChannelRef
}
enum ChannelTabKind: String, Codable, CaseIterable, Sendable { case videos, live, playlists }
struct ChannelHeader: Hashable, Sendable {
    var id: String; var name: String; var handle: String?; var avatarURL: URL?; var bannerURL: URL?
    var subscriberCountText: String?; var videoCountText: String?; var description: String?
    init(...); var ref: ChannelRef
}
struct ChannelPage: Sendable { var header: ChannelHeader; var availableTabs: [ChannelTabKind]; var videos: Page<SearchItem>; init(...) }

// Models/Playlist.swift
struct PlaylistSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String; var title: String; var channel: ChannelRef?; var thumbnails: [Thumbnail]
    var videoCount: Int?; var videoCountText: String?; init(...)
}
struct PlaylistPage: Sendable { var info: PlaylistSummary; var description: String?; var videos: Page<VideoSummary>; init(...) }

// Models/Search.swift
struct Page<Item: Sendable>: Sendable { var items: [Item]; var continuation: String?; init(items: [Item] = [], continuation: String? = nil) }
extension Page: Equatable where Item: Equatable {}
enum SearchItem: Hashable, Sendable, Identifiable {
    case video(VideoSummary), channel(ChannelSummary), playlist(PlaylistSummary)
    var id: String                                     // "video:<id>" | "channel:<id>" | "playlist:<id>"
    var video: VideoSummary? { get }
}
enum SearchType: String, Codable, CaseIterable, Sendable { case all, video, channel, playlist }
enum SearchSort: String, Codable, CaseIterable, Sendable { case relevance, uploadDate, viewCount }
enum SearchDuration: String, Codable, CaseIterable, Sendable { case any, short, medium, long }
enum SearchUploadDate: String, Codable, CaseIterable, Sendable { case any, lastHour, today, thisWeek, thisMonth, thisYear }
struct SearchFilter: Codable, Hashable, Sendable {
    var type: SearchType; var sort: SearchSort; var duration: SearchDuration; var uploadDate: SearchUploadDate
    init(type: SearchType = .all, sort: SearchSort = .relevance, duration: SearchDuration = .any, uploadDate: SearchUploadDate = .any)
    var isDefault: Bool
}
enum ResolvedURL: Hashable, Sendable { case video(id: String, startSeconds: Int?), channel(id: String), playlist(id: String), search(query: String) }

// Models/Watch.swift
struct DescriptionLink: Codable, Hashable, Sendable {
    enum Target: Codable, Hashable, Sendable {
        case url(URL), timestamp(seconds: Int), video(id: String, startSeconds: Int?)
        case channel(id: String), playlist(id: String), hashtag(String)
    }
    var range: Range<Int>                              // UTF-16 offsets into AttributedDescription.text
    var target: Target; init(range:target:)
}
struct AttributedDescription: Codable, Hashable, Sendable { var text: String; var links: [DescriptionLink]; init(text: String = "", links: [DescriptionLink] = []); static let empty }
struct Chapter: Codable, Hashable, Sendable { var title: String; var startSeconds: Double; var thumbnailURL: URL?; init(...) }
struct VideoDetails: Hashable, Sendable {
    var id: String; var title: String; var channel: ChannelRef; var subscriberCountText: String?
    var viewCount: Int?; var viewCountText: String?; var shortViewCountText: String?
    var dateText: String?; var relativeDateText: String?
    var likeCount: Int?; var likeCountText: String?
    var description: AttributedDescription; var chapters: [Chapter]
    var commentCountText: String?; var commentsContinuation: String?
    var related: [VideoSummary]; var relatedContinuation: String?
    var isLive: Bool
    init(id:title:channel: + defaults)
    var summary: VideoSummary                          // id, title, channel, viewCount(+Text), publishedText = relativeDateText, isLive
}

// Models/Comment.swift
struct Comment: Hashable, Sendable, Identifiable {
    var id: String; var authorName: String; var authorAvatarURL: URL?; var authorChannelID: String?
    var text: String; var publishedText: String; var likeCountText: String?
    var replyCount: Int; var repliesContinuation: String?
    var isPinned: Bool; var isByUploader: Bool; var isHearted: Bool
    init(...)
}
struct CommentSortOption: Hashable, Sendable { var title: String; var continuation: String; var isSelected: Bool; init(...) }
struct CommentsPage: Sendable { var comments: [Comment]; var continuation: String?; var totalCountText: String?; var sortOptions: [CommentSortOption]; init(...) }

// Models/Stream.swift
struct StreamFormat: Codable, Hashable, Sendable {
    var itag: Int; var url: URL; var mimeType: String; var bitrate: Int?
    var width: Int?; var height: Int?; var fps: Int?; var qualityLabel: String?
    var contentLength: Int64?; var approxDurationMs: Int?; var audioSampleRate: Int?
    var isDRC: Bool; var isProgressive: Bool
    init(...)
    var isAudioOnly: Bool                              // mimeType hasPrefix "audio/"
    var isVideoOnly: Bool                              // hasPrefix "video/" && !isProgressive
    var codecs: String                                 // text inside codecs="…", "" if none
    var isAVFoundationCompatible: Bool                 // (video/mp4 && codecs hasPrefix "avc1") || (audio/mp4 && codecs hasPrefix "mp4a")
}
struct CaptionTrack: Codable, Hashable, Sendable, Identifiable {
    var languageCode: String; var name: String; var baseURL: URL; var isAutoGenerated: Bool
    var id: String { "\(languageCode)-\(isAutoGenerated ? "asr" : "std")" }; init(...)
}
struct CaptionCue: Hashable, Sendable { var start: Double; var end: Double; var text: String; init(...) }
struct StreamInfo: Hashable, Sendable {
    var videoID: String; var title: String; var author: String; var channelID: String
    var lengthSeconds: Int; var viewCount: Int?; var shortDescription: String?; var thumbnails: [Thumbnail]
    var isLive: Bool; var hlsURL: URL?; var formats: [StreamFormat]; var captions: [CaptionTrack]; var expiresAt: Date
    init(...)
    func isExpired(now: Date = Date(), margin: TimeInterval = 120) -> Bool   // now >= expiresAt - margin
}

// Models/Account.swift
struct GoogleAccount: Codable, Hashable, Sendable { var id: String; var email: String?; var name: String?; var pictureURL: URL?; init(...) }
struct OAuthTokens: Codable, Hashable, Sendable {
    var accessToken: String; var refreshToken: String?; var expiresAt: Date; var scope: String?; var idToken: String?
    init(...); func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool
}
struct StoredCredentials: Codable, Hashable, Sendable { var clientID: String; var tokens: OAuthTokens; var account: GoogleAccount; init(...) }
enum VideoRating: String, Codable, Sendable { case like, dislike, none }

// Models/Library.swift
enum SubscriptionSource: Codable, Hashable, Sendable { case local, google(subscriptionID: String) }
struct SubscribedChannel: Codable, Hashable, Sendable, Identifiable {
    var id: String; var name: String; var avatarURL: URL?; var source: SubscriptionSource; var subscribedAt: Date?
    init(...); var ref: ChannelRef
}
struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    var video: VideoSummary; var lastWatchedAt: Date; var progressSeconds: Double; var durationSeconds: Double?
    var id: String { video.id }; init(...)
    var isFinished: Bool       // duration known && (progress >= duration - 15 || progress / duration >= 0.95)
}
struct LocalPlaylist: Codable, Hashable, Sendable, Identifiable { var id: UUID; var title: String; var videos: [VideoSummary]; var createdAt: Date; var updatedAt: Date; init(...) }
struct BlockedChannel: Codable, Hashable, Sendable, Identifiable { var id: String; var name: String; init(...) }

// Models/Download.swift
enum DownloadQuality: Codable, Hashable, Sendable {
    case video(maxHeight: Int), audioOnly
    var label: String          // "720p" | "Audio only"
    var key: String            // "720" | "audio"
}
enum DownloadState: String, Codable, Sendable { case queued, downloading, merging, completed, failed, paused }
struct DownloadItem: Codable, Hashable, Sendable, Identifiable {
    var id: String             // "<videoID>-<quality.key>"
    var video: VideoSummary; var quality: DownloadQuality; var state: DownloadState
    var progress: Double; var bytesDownloaded: Int64; var bytesTotal: Int64?
    var relativeFilePath: String?; var createdAt: Date; var errorMessage: String?
    init(...)
}
struct DownloadOption: Hashable, Sendable, Identifiable { var quality: DownloadQuality; var label: String; var estimatedBytes: Int64?; var id: String { quality.key }; init(...) }

// Models/SponsorBlock.swift
enum SponsorCategory: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case sponsor, selfpromo, interaction, intro, outro, preview
    case musicOfftopic = "music_offtopic", filler, poiHighlight = "poi_highlight"
    var displayName: String    // "Sponsor", "Self-promotion", "Interaction reminder", "Intro", "Outro", "Preview/recap", "Non-music section", "Filler", "Highlight"
    var colorHex: String       // #00D400 #FFFF00 #CC00FF #00FFFF #0202ED #008FD6 #FF9900 #7300FF #FF1684 (same order)
}
enum SegmentActionType: String, Codable, Sendable { case skip, mute, poi, full, chapter }
enum SegmentBehavior: String, Codable, CaseIterable, Sendable { case autoSkip, showInBar, ignore }
struct SponsorSegment: Codable, Hashable, Sendable, Identifiable { var id: String; var category: SponsorCategory; var actionType: SegmentActionType; var start: Double; var end: Double; init(...) }

// Models/Settings.swift
enum QualityPreference: String, Codable, CaseIterable, Sendable {
    case auto, p1080, p720, p480, p360
    var maxHeight: Int?        // nil, 1080, 720, 480, 360
    var label: String          // "Auto", "1080p", "720p", "480p", "360p"
}
struct AppSettings: Codable, Hashable, Sendable {
    var hideShorts = true; var hideMembersOnly = true; var hideLiveAndUpcoming = false; var hideWatchedInSubscriptions = false
    var blockedChannels: [BlockedChannel] = []; var blockedKeywords: [String] = []
    var sponsorBlockEnabled = true; var segmentBehaviors: [SponsorCategory: SegmentBehavior] = AppSettings.defaultSegmentBehaviors
    var deArrowTitles = true
    var wifiQuality: QualityPreference = .auto; var cellularQuality: QualityPreference = .p720
    var defaultPlaybackRate: Double = 1.0; var autoplayNext = false; var backgroundPlayback = true; var autoPictureInPicture = true
    var preferredCaptionLanguage: String? = nil
    var googleClientID: String = ""
    var contentLanguage: String? = nil; var contentRegion: String? = nil      // nil → device locale
    init()
    init(from decoder: Decoder) throws                 // every key decodeIfPresent ?? default
    static let defaultSegmentBehaviors: [SponsorCategory: SegmentBehavior]
        // sponsor, selfpromo, interaction → .autoSkip; all other categories → .showInBar
}

// Models/HomeFeed.swift
struct HomeFeed: Sendable { var continueWatching: [HistoryEntry]; var forYou: [VideoSummary]; init(...); static let empty }

// Models/Errors.swift
enum NoSlopError: Error, Equatable, Sendable, LocalizedError {
    case notImplemented(String), network(String), http(status: Int), decoding(String)
    case botCheck, unplayable(reason: String)
    case notSignedIn, googleNotConfigured, oauth(String), quotaExceeded, cancelled
    var errorDescription: String?
    // botCheck: "YouTube asked to confirm you're not a bot. Try again in a minute, or open the video on YouTube."
    // unplayable(r): r; notSignedIn: "Sign in with Google to use this."; googleNotConfigured: "Add your Google OAuth client ID in Settings → Account first."
    // quotaExceeded: "YouTube's daily API quota for your Google project is used up. Try again tomorrow."
    // network(m): "Can't reach YouTube. Check your connection." ; others: short plain sentences
}
```

### Support (Task 1A, final)

```swift
// Support/JSON.swift
enum JSON: Sendable, Hashable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
           ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(data: Data) throws                            // JSONSerialization; CFBoolean → .bool; throws NoSlopError.decoding
    func data() throws -> Data
    subscript(key: String) -> JSON? { get }            // nil unless .object containing key
    subscript(index: Int) -> JSON? { get }             // nil unless .array with index in bounds
    var string: String? { get }; var int: Int? { get } // int: .number, or .string parsable as Int
    var double: Double? { get }; var bool: Bool? { get }; var array: [JSON]? { get }; var object: [String: JSON]? { get }
    func findAll(_ key: String) -> [JSON]              // depth-first pre-order; arrays in order; object keys in sorted order
    func first(_ key: String) -> JSON?                 // findAll(key).first, stops early
}

// Support/HTTPClient.swift
protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
struct URLSessionHTTPClient: HTTPClient {
    init(session: URLSession = .shared)
    // URLError.cancelled → NoSlopError.cancelled; other URLError → .network(localizedDescription); non-HTTP response → .network
}

// Support/InnerTubeText.swift
enum InnerTubeText {
    static func text(_ node: JSON?) -> String?         // node.simpleText | runs[].text joined | content | node itself if .string; nil if empty
    static func thumbnails(_ node: JSON?) -> [Thumbnail] // node.thumbnails[] or node.sources[] (url,width,height); "//…" → "https://…"; sorted ascending width
    static func parseCount(_ text: String?) -> Int?    // "2,763,792 views"→2763792, "810K views"→810000, "1.25M subscribers"→1250000,
                                                       // "1.5K videos"→1500, "3B"→3000000000, "No views"→0, "watching"→nil, nil→nil
    static func parseDuration(_ text: String?) -> Int? // "4:19:10"→15550, "4:40"→280, "0:59"→59, "LIVE"→nil, nil→nil
    static func parseISO8601Duration(_ s: String?) -> Int? // "PT1H2M3S"→3723, "PT4M40S"→280, "PT59S"→59, "P0D"→0, "P1DT1S"→86401
}

// Support/DurationFormatter.swift
enum DurationFormatter { static func string(seconds: Int) -> String }   // 5→"0:05", 280→"4:40", 3723→"1:02:03"

// Support/TTLCache.swift
actor TTLCache<Key: Hashable & Sendable, Value: Sendable> {
    init(ttl: TimeInterval, maxEntries: Int = 200, now: @escaping @Sendable () -> Date = { Date() })
    func value(for key: Key) -> Value?; func insert(_ value: Value, for key: Key); func removeAll()
}
```

### Service protocols (`Protocols/Services.swift`, Task 1A, final)

```swift
protocol YouTubeService: Sendable {
    func search(query: String, filter: SearchFilter) async throws -> Page<SearchItem>
    func searchMore(continuation: String) async throws -> Page<SearchItem>
    func suggestions(for query: String) async throws -> [String]
    func videoDetails(id: String) async throws -> VideoDetails
    func moreRelated(continuation: String) async throws -> Page<VideoSummary>
    func comments(continuation: String) async throws -> CommentsPage
    func channel(id: String) async throws -> ChannelPage
    func channelTab(channelID: String, tab: ChannelTabKind) async throws -> Page<SearchItem>
    func channelMore(continuation: String) async throws -> Page<SearchItem>
    func playlist(id: String) async throws -> PlaylistPage
    func playlistMore(continuation: String) async throws -> Page<VideoSummary>
    func resolve(url: URL) async throws -> ResolvedURL?
}
protocol StreamResolving: Sendable { func streamInfo(videoID: String) async throws -> StreamInfo }
protocol CaptionsProviding: Sendable { func cues(for track: CaptionTrack) async throws -> [CaptionCue] }
protocol RSSFeedFetching: Sendable { func latestVideos(channelID: String) async throws -> [VideoSummary] }
@MainActor protocol WebAuthenticating: AnyObject, Sendable { func authenticate(url: URL, callbackScheme: String) async throws -> URL }
protocol TokenStoring: Sendable { func load() throws -> StoredCredentials?; func save(_ credentials: StoredCredentials) throws; func clear() throws }
protocol GoogleAuthProviding: Sendable {
    func currentAccount() async -> GoogleAccount?
    func signIn(clientID: String, authenticator: any WebAuthenticating) async throws -> GoogleAccount
    func signOut() async
    func accessToken() async throws -> String          // refreshes when needed; .notSignedIn when no credentials
}
protocol YouTubeAccountService: Sendable {
    func subscriptions() async throws -> [SubscribedChannel]
    func subscribe(channelID: String) async throws -> String          // subscription id
    func unsubscribe(subscriptionID: String) async throws
    func myPlaylists() async throws -> [PlaylistSummary]
    func playlistItems(playlistID: String, pageToken: String?) async throws -> Page<VideoSummary>
    func likedVideos(pageToken: String?) async throws -> Page<VideoSummary>
    func rating(videoID: String) async throws -> VideoRating
    func rate(videoID: String, rating: VideoRating) async throws
    func addToPlaylist(videoID: String, playlistID: String) async throws
    func durations(videoIDs: [String]) async throws -> [String: Int]
}
protocol SponsorBlockProviding: Sendable { func segments(videoID: String) async throws -> [SponsorSegment] }
protocol DeArrowProviding: Sendable { func betterTitle(videoID: String) async -> String? }
protocol SubscriptionFeedProviding: Sendable {
    func cachedFeed() async -> [VideoSummary]
    func feed(channels: [SubscribedChannel], forceRefresh: Bool) async throws -> [VideoSummary]
}
protocol HomeFeedProviding: Sendable { func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed }
protocol VisitorDataStoring: Sendable { func load() -> (value: String, fetchedAt: Date)?; func save(value: String, fetchedAt: Date) }
```

### Implementation types (Task 1A creates each as a compiling stub with this exact API; the owning task fills it in)

Stub rule: throwing members `throw NoSlopError.notImplemented("<Type>.<member>")`; non-throwing ones return empty/`nil`. `LibraryStore`, `SettingsStore` and `DownloadManager` stubs are simple in-memory implementations that actually work, so UI tasks can use them.

```swift
// Task 2 — InnerTube transport, streams, URLs, RSS, captions
struct InnerTubeConfig: Sendable, Hashable { var hl: String; var gl: String; init(hl:gl:); static func fromLocale(_ locale: Locale = .current) -> InnerTubeConfig }
struct ClientProfile: Sendable, Hashable {
    var clientName: String; var clientVersion: String; var clientNameID: Int; var userAgent: String; var extraClientFields: [String: String]
    static let web: ClientProfile; static let visionOS: ClientProfile
}
final class UserDefaultsVisitorDataStore: VisitorDataStoring, @unchecked Sendable { init(defaults: UserDefaults = .standard, key: String = "noslop.visitorData") }
final class InMemoryVisitorDataStore: VisitorDataStoring, @unchecked Sendable { init() }
actor InnerTubeClient {
    init(http: any HTTPClient, config: InnerTubeConfig, visitorStore: any VisitorDataStoring = UserDefaultsVisitorDataStore(), now: @escaping @Sendable () -> Date = { Date() })
    func visitorData(forceRefresh: Bool = false) async throws -> String
    func post(endpoint: String, profile: ClientProfile, body: [String: JSON]) async throws -> JSON
    var config: InnerTubeConfig { get }
}
struct InnerTubeYouTubeService: YouTubeService { init(client: InnerTubeClient, http: any HTTPClient) }
struct InnerTubeStreamResolver: StreamResolving { init(client: InnerTubeClient) }
struct CaptionsService: CaptionsProviding { init(http: any HTTPClient) }
struct RSSFeedFetcher: RSSFeedFetching { init(http: any HTTPClient) }
enum RSSParser { static func parse(_ data: Data) -> [VideoSummary] }
enum WebVTTParser { static func parse(_ text: String) -> [CaptionCue] }
enum PlayerResponseParser { static func parse(_ json: JSON, now: Date) throws -> StreamInfo }
enum SuggestionsParser { static func parse(_ data: Data) -> [String] }
enum ResolveURLParser { static func parse(_ json: JSON) -> ResolvedURL? }
enum SwJsDataParser { static func visitorData(from text: String) -> String? }
enum YouTubeURL { static func resolveLocally(_ url: URL) -> ResolvedURL?; static func extractURL(from text: String) -> URL? }

// Task 3 — browse parsers
enum ItemParser {
    static func items(in json: JSON) -> [SearchItem]   // harvest in document order, dropping ads/AI blocks
    static func video(fromVideoRenderer json: JSON) -> VideoSummary?
    static func video(fromLockup json: JSON) -> VideoSummary?
    static func playlist(fromLockup json: JSON) -> PlaylistSummary?
    static func short(fromShortsLockup json: JSON) -> VideoSummary?
    static func channel(fromChannelRenderer json: JSON) -> ChannelSummary?
}
enum SearchParser { static func parse(_ json: JSON) -> Page<SearchItem> }              // initial and continuation responses
enum SearchParams { static func encode(_ filter: SearchFilter) -> String? }           // nil for default filter
enum ChannelParser {
    static let tabParams: [ChannelTabKind: String]
    static func parseChannelPage(_ json: JSON) -> ChannelPage?
    static func parseTab(_ json: JSON) -> Page<SearchItem>
    static func parseContinuation(_ json: JSON) -> Page<SearchItem>
}
enum PlaylistParser { static func parse(_ json: JSON, playlistID: String) -> PlaylistPage?; static func parseContinuation(_ json: JSON) -> Page<VideoSummary> }
enum RelatedParser { static func parse(next json: JSON) -> Page<VideoSummary>; static func parseContinuation(_ json: JSON) -> Page<VideoSummary> }

// Task 4 — watch page and comments
enum WatchMetadataParser { static func parse(_ json: JSON, videoID: String) -> VideoDetails? }   // related left empty
enum CommentsParser { static func parse(_ json: JSON) -> CommentsPage }

// Task 5 — Google
struct GoogleOAuthConfig: Sendable, Hashable {
    let clientID: String
    init?(clientID: String)                            // trims; must end with ".apps.googleusercontent.com"
    var redirectScheme: String                         // "com.googleusercontent.apps.<prefix>"
    var redirectURI: String                            // redirectScheme + ":/oauth2redirect"
    static let scopes: [String]                        // ["openid","email","profile","https://www.googleapis.com/auth/youtube"]
    func authorizationURL(state: String, codeChallenge: String) -> URL
}
enum PKCE { static func makeVerifier() -> String; static func challenge(for verifier: String) -> String }
final class KeychainTokenStore: TokenStoring, @unchecked Sendable { init(service: String = "com.robinjungerich.noslopyt.google") }
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable { init(_ initial: StoredCredentials? = nil) }
actor GoogleOAuthService: GoogleAuthProviding { init(http: any HTTPClient, store: any TokenStoring, now: @escaping @Sendable () -> Date = { Date() }) }
struct YouTubeDataAPIClient: YouTubeAccountService { init(http: any HTTPClient, auth: any GoogleAuthProviding) }

// Task 6 — library, settings, filters, feeds, SponsorBlock, DeArrow
@MainActor @Observable final class LibraryStore {
    init(directory: URL)
    private(set) var subscriptions: [SubscribedChannel]; private(set) var history: [HistoryEntry]   // history most recent first
    private(set) var watchLater: [VideoSummary]; private(set) var playlists: [LocalPlaylist]; private(set) var searchHistory: [String]
    func isSubscribed(channelID: String) -> Bool
    func subscribe(_ channel: SubscribedChannel); func unsubscribe(channelID: String)
    func replaceGoogleSubscriptions(_ channels: [SubscribedChannel])   // keep .local ones, replace .google ones; a channel in both becomes .google
    func convertGoogleSubscriptionsToLocal()
    func recordProgress(video: VideoSummary, seconds: Double, duration: Double?)
    func progress(for videoID: String) -> HistoryEntry?
    func removeFromHistory(videoID: String); func clearHistory()
    func isInWatchLater(_ videoID: String) -> Bool; func toggleWatchLater(_ video: VideoSummary)
    @discardableResult func createPlaylist(title: String) -> LocalPlaylist
    func renamePlaylist(_ id: UUID, title: String); func deletePlaylist(_ id: UUID)
    func add(_ video: VideoSummary, toPlaylist id: UUID); func remove(videoID: String, fromPlaylist id: UUID)
    func recordSearch(_ query: String); func clearSearchHistory()
    func flush() async
}
@MainActor @Observable final class SettingsStore { init(defaults: UserDefaults = .standard, key: String = "noslop.settings"); var settings: AppSettings }
struct ContentFilter: Sendable {
    enum Context: Sendable { case general, subscriptions }
    init(settings: AppSettings, watchedIDs: Set<String> = [])
    func allows(_ video: VideoSummary, context: Context = .general) -> Bool
    func filter(_ videos: [VideoSummary], context: Context = .general) -> [VideoSummary]
    func filter(_ items: [SearchItem]) -> [SearchItem]
}
enum HashPrefix { static func sha256Prefix(_ value: String, length: Int = 4) -> String }   // lowercase hex
actor SponsorBlockClient: SponsorBlockProviding { init(http: any HTTPClient, baseURL: URL = URL(string: "https://sponsor.ajay.app")!) }
actor DeArrowClient: DeArrowProviding { init(http: any HTTPClient, baseURL: URL = URL(string: "https://sponsor.ajay.app")!) }
struct SegmentSkipPlanner: Sendable {
    init(segments: [SponsorSegment], behaviors: [SponsorCategory: SegmentBehavior])
    func segmentToSkip(at time: Double, alreadySkipped: Set<String>) -> SponsorSegment?
    var visibleSegments: [SponsorSegment] { get }
}
actor SubscriptionFeedService: SubscriptionFeedProviding { init(rss: any RSSFeedFetching, account: (any YouTubeAccountService)?, cacheURL: URL?, maxConcurrent: Int = 8) }
actor HomeFeedService: HomeFeedProviding { init(youTube: any YouTubeService, maxSeeds: Int = 6) }

// Task 7 — downloads
@MainActor @Observable final class DownloadManager {
    init(rootDirectory: URL, streams: any StreamResolving, sessionConfiguration: URLSessionConfiguration? = nil)   // nil → background config with the global id
    private(set) var items: [DownloadItem]            // newest first
    func availableOptions(for info: StreamInfo) -> [DownloadOption]
    func enqueue(video: VideoSummary, quality: DownloadQuality)
    func cancel(id: String); func delete(id: String); func retry(id: String)
    func completedItem(videoID: String) -> DownloadItem?
    func fileURL(for item: DownloadItem) -> URL?
    var bytesOnDisk: Int64 { get }
    func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping @Sendable () -> Void)
}
struct SelectedFormats: Sendable, Hashable { var video: StreamFormat?; var audio: StreamFormat }
enum FormatSelector { static func select(from formats: [StreamFormat], quality: DownloadQuality) -> SelectedFormats? }
enum ChunkPlanner { static func ranges(totalBytes: Int64, chunkSize: Int64 = 10_485_760) -> [ClosedRange<Int64>] }
enum MediaMuxer { static func mux(videoFile: URL?, audioFile: URL, durationSeconds: Double, output: URL) async throws }
struct DownloadTaskDescriptor: Hashable, Sendable {
    enum Stream: String, Sendable { case video, audio }
    var itemID: String; var stream: Stream; var chunkIndex: Int
    var encoded: String                                // "<itemID>|<stream>|<chunkIndex>"
    init(itemID:stream:chunkIndex:); init?(encoded: String)
}

// Task 10 — playback logic in the kit
enum PlaybackFailure: Equatable, Sendable { case forbidden, httpStatus(Int), network, decode, unknown }
enum PlaybackRecovery {
    enum Action: Equatable, Sendable { case reresolveAndResume(at: Double), waitForNetworkThenRetry(at: Double), showError }
    static func action(for failure: PlaybackFailure, position: Double, streamExpiresAt: Date?, now: Date, attempt: Int) -> Action
}
enum ChapterLookup { static func chapter(at time: Double, in chapters: [Chapter]) -> Chapter? }
```

### Mocks (`Mocks/`, Task 1A, final)

`SampleData` (static, realistic, built from fixture values: ≥12 videos incl. ids `z-Xl9tGqH14`, `mHrHLqQj7Ts`, `aqz-KE-bpKQ`, `dQw4w9WgXcQ`, `jNQXAC9IVRw`, `7pPUE6cGFwI`, `sgMfEq3pDE0`, one Short `gIjBeEvDXew`; channels Blender `UCSMOQeBJ2RAnuFungnQOxLg` and Blender Guru `UCOKHwx1VCdgnxwbjyb9Iu1g`; a playlist `PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B`; 5 comments; 3 chapters; 2 sponsor segments sponsor 30–45 s, selfpromo 120–130 s), and `MockYouTubeService`, `MockStreamResolver` (returns `hlsURL = https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8`, no formats), `MockCaptions`, `MockRSSFeed`, `MockAuth` (signIn returns `GoogleAccount(id: "mock", email: "you@example.com", name: "You")`), `MockAccountService`, `MockSponsorBlock`, `MockDeArrow` (better title only for `dQw4w9WgXcQ`), `MockSubscriptionFeed`, `MockHomeFeed`. All `public`, `Sendable`, with an optional artificial delay (`init(delay: Duration = .milliseconds(300))`).

### App layer contracts (Task 1B, final)

```swift
// App/Router.swift
enum AppTab: Hashable { case home, subscriptions, library, search }
enum Route: Hashable {
    case channel(id: String), playlist(id: String), accountPlaylist(PlaylistSummary), localPlaylist(id: UUID)
    case history, watchLater, likedVideos, accountPlaylists, downloads, subscriptionsManager, settings
    case searchResults(query: String)
}
@MainActor @Observable final class Router {
    var selectedTab: AppTab = .home
    var homePath: [Route] = []; var subscriptionsPath: [Route] = []; var libraryPath: [Route] = []; var searchPath: [Route] = []
    func push(_ route: Route)                          // onto the selected tab's path
    func popToRoot(_ tab: AppTab? = nil)
}

// App/AppEnvironment.swift  — injected with .environment(env); read with @Environment(AppEnvironment.self)
@MainActor @Observable final class AppEnvironment {
    let youTube: any YouTubeService; let streams: any StreamResolving; let captions: any CaptionsProviding
    let subscriptionFeed: any SubscriptionFeedProviding; let homeFeed: any HomeFeedProviding
    let sponsorBlock: any SponsorBlockProviding; let deArrow: any DeArrowProviding
    let auth: any GoogleAuthProviding; let account: any YouTubeAccountService
    let library: LibraryStore; let settingsStore: SettingsStore; let downloads: DownloadManager
    let player: PlayerController; let router: Router
    private(set) var googleAccount: GoogleAccount?
    var settings: AppSettings { get }                  // settingsStore.settings
    var contentFilter: ContentFilter { get }           // from settings + watched (finished) history ids
    static let shared: AppEnvironment                  // .live(), or .preview() when launched with -mockServices YES
    static func live() -> AppEnvironment; static func preview() -> AppEnvironment
    func open(_ video: VideoSummary, startAt: Double? = nil, queue: [VideoSummary] = [])   // → player.open
    func show(_ route: Route)                          // player.minimize() if expanded, then router.push
    func isSubscribed(_ channelID: String) -> Bool
    func toggleSubscription(_ channel: ChannelRef) async throws  // signed in: Data API (+ mirror in library); else local
    func refreshAccount() async                        // reads auth.currentAccount; when signed in, syncs Google subscriptions into library
    func signIn(authenticator: any WebAuthenticating) async throws
    func signOut() async                               // auth.signOut + library.convertGoogleSubscriptionsToLocal
    func handleOpenURL(_ url: URL) async               // YouTubeURL.resolveLocally ?? youTube.resolve → open video / show channel / playlist / searchResults;
                                                       // also noslop://tab/<home|subscriptions|library|search> and noslop://route/<settings|downloads|history|watchLater>
}
```

`.live()` wiring (exact): `URLSessionHTTPClient()`; `InnerTubeConfig` = settings override or `.fromLocale()`; `InnerTubeClient(http:config:)`; `InnerTubeYouTubeService(client:http:)`; `InnerTubeStreamResolver(client:)`; `CaptionsService(http:)`; `RSSFeedFetcher(http:)`; `GoogleOAuthService(http:store: KeychainTokenStore())`; `YouTubeDataAPIClient(http:auth:)`; `SubscriptionFeedService(rss:account:cacheURL: <Caches>/subscription-feed.json)`; `HomeFeedService(youTube:)`; `SponsorBlockClient(http:)`; `DeArrowClient(http:)`; `LibraryStore(directory: <Application Support>/NoSlop)`; `SettingsStore()`; `DownloadManager(rootDirectory: <Documents>/NoSlop Downloads, streams:)`; `PlayerController(...)` below.

```swift
// Player/PlayerController.swift — Task 1B stub (presentation only), Task 10 implements
@MainActor @Observable final class PlayerController {
    enum Presentation: Equatable { case hidden, expanded, minimized }
    enum State: Equatable { case idle, loading, playing, paused, buffering, ended, failed(String) }
    struct SkipNotice: Equatable, Identifiable { var id: String; var segment: SponsorSegment }
    init(streams: any StreamResolving, sponsorBlock: any SponsorBlockProviding, captions: any CaptionsProviding,
         library: LibraryStore, settingsStore: SettingsStore, downloads: DownloadManager)
    let avPlayer: AVPlayer
    private(set) var presentation: Presentation; private(set) var currentVideo: VideoSummary?; private(set) var streamInfo: StreamInfo?
    private(set) var state: State; private(set) var currentTime: Double; private(set) var duration: Double; private(set) var bufferedTime: Double
    private(set) var segments: [SponsorSegment]; private(set) var chapters: [Chapter]; private(set) var skipNotice: SkipNotice?
    private(set) var captionText: String?; private(set) var isPlayingOffline: Bool; private(set) var isPictureInPictureActive: Bool
    private(set) var queue: [VideoSummary]
    var isFullscreen: Bool; var rate: Float; var quality: QualityPreference; var selectedCaption: CaptionTrack?
    func open(_ video: VideoSummary, startAt: Double?, queue: [VideoSummary])
    func setChapters(_ chapters: [Chapter]); func setUpNext(_ videos: [VideoSummary])
    func play(); func pause(); func togglePlayPause(); func seek(to seconds: Double); func skip(by seconds: Double); func undoSkip()
    @discardableResult func playNext() -> Bool
    func expand(); func minimize(); func close(); func toggleFullscreen(); func startPictureInPicture()
}
```

View type names and initializers (placeholders by 1B, real by the owning task; signatures are fixed):

| View | Owner |
|---|---|
| `RootView()`, `RouteDestinationView(route: Route)` | 1B (final) |
| `VideoCardView(video:)`, `VideoRowView(video:)`, `ThumbnailView(video:)`, `RemoteImage(url:contentMode:)`, `ChannelAvatarView(url:size:)`, `SearchItemRow(item:)`, `PlaylistRowView(playlist:)`, `ChannelRowView(channel:)`, `VideoTitleText(video:lineLimit:)`, `SubscribeButton(channel:)`, `ErrorStateView(error:retry:)`, `EmptyStateView(title:systemImage:message:)`, `LoadingView()`, modifier `.videoContextMenu(_ video: VideoSummary)` | 1B (working basics) → 8 |
| `HomeView()`, `SubscriptionsView()`, `SearchView()`, `SearchResultsView(query:)`, `ChannelView(channelID:)`, `PlaylistView(playlistID:)` | 8 |
| `WatchDetailsView(video:)`, `LibraryView()`, `HistoryView()`, `WatchLaterView()`, `LocalPlaylistView(playlistID:)`, `LikedVideosView()`, `AccountPlaylistsView()`, `AccountPlaylistView(playlist:)`, `SubscriptionsManagerView()`, `DownloadsView()`, `SettingsView()`, `ASWebAuthenticator` (`WebAuthenticating`) | 9 |
| `PlayerOverlayContainer()`, `PlayerHostView()`, `MiniPlayerView()`, `VideoSurfaceView` | 10 |

`RootView` = `TabView(selection:)` with the four tabs (`Tab("Home", systemImage: "house", value: .home)`, `"Subscriptions"` `play.square.stack`, `"Library"` `books.vertical`, `Tab(value: .search, role: .search)`), each a `NavigationStack(path:)` bound to the router path with `.navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }`, plus `.overlay { PlayerOverlayContainer() }` and `.onOpenURL { url in Task { await env.handleOpenURL(url) } }`.

---

## Task 1A: NoSlopKit foundation (contracts, stubs, mocks, test support)

**Files:**
- Create: `NoSlopKit/Package.swift`
- Create: `NoSlopKit/Sources/NoSlopKit/Models/{Video,Channel,Playlist,Search,Watch,Comment,Stream,Account,Library,Download,SponsorBlock,Settings,HomeFeed,Errors}.swift`
- Create: `NoSlopKit/Sources/NoSlopKit/Support/{JSON,HTTPClient,InnerTubeText,DurationFormatter,TTLCache}.swift`, `Protocols/Services.swift`
- Create (stubs): every file listed for Tasks 2–7 and 10 in "File structure and ownership" (kit side), containing exactly the API in "Implementation types"
- Create: `NoSlopKit/Sources/NoSlopKit/Mocks/{SampleData,MockServices}.swift`
- Create: `NoSlopKit/Tests/NoSlopKitTests/Support/{FixtureLoader,MockHTTPClient}.swift`, `Foundation/{JSONTests,InnerTubeTextTests,ModelsTests,TTLCacheTests}.swift`

**Interfaces:**
- Consumes: fixtures in `NoSlopKit/Tests/NoSlopKitTests/Fixtures/` (already committed; resources via `.copy("Fixtures")`)
- Produces: everything in "Shared contracts", plus test helpers:
  - `enum Fixture { static func data(_ name: String) throws -> Data; static func json(_ name: String) throws -> JSON; static func url(_ name: String) throws -> URL }` (name includes extension; `Bundle.module`, subdirectory `Fixtures`)
  - `final class MockHTTPClient: HTTPClient, @unchecked Sendable` with `func enqueue(_ match: String, status: Int = 200, body: Data, headers: [String: String] = [:])` (first queued response whose `match` is a substring of the request URL; FIFO per match, reusable when only one left), `func enqueueError(_ match: String, _ error: Error)`, `var requests: [URLRequest] { get }` (thread-safe), and `func bodyJSON(of request: URLRequest) -> JSON?`; unmatched request → `NoSlopError.http(status: 404)`

- [ ] **Step 1: Write the failing foundation tests**

```swift
@Test func fixturesLoad() throws { #expect(try Fixture.data("search_blender_tutorial.json").count > 600_000) }
@Test func findAllCountsRenderers() throws {
    let j = try Fixture.json("search_blender_tutorial.json")
    #expect(j.findAll("videoRenderer").count == 17)
    #expect(j.findAll("shortsLockupViewModel").count == 5)
    #expect(j.first("videoRenderer")?["videoId"]?.string == "z-Xl9tGqH14")
}
@Test(arguments: [("2,763,792 views", 2763792), ("810K views", 810_000), ("1.25M subscribers", 1_250_000), ("1.5K videos", 1_500), ("No views", 0)])
func parseCount(text: String, value: Int) { #expect(InnerTubeText.parseCount(text) == value) }
@Test(arguments: [("4:19:10", 15550), ("4:40", 280), ("0:59", 59)]) func parseDuration(t: String, v: Int) { #expect(InnerTubeText.parseDuration(t) == v) }
@Test func parseDurationLive() { #expect(InnerTubeText.parseDuration("LIVE") == nil) }
@Test(arguments: [("PT1H2M3S", 3723), ("PT4M40S", 280), ("PT59S", 59), ("P0D", 0), ("P1DT1S", 86401)]) func iso(s: String, v: Int) { #expect(InnerTubeText.parseISO8601Duration(s) == v) }
@Test func textFromRunsSimpleTextAndContent() {
    #expect(InnerTubeText.text(["runs": [["text": "a"], ["text": "b"]]]) == "ab")
    #expect(InnerTubeText.text(["simpleText": "x"]) == "x"); #expect(InnerTubeText.text(["content": "y"]) == "y")
}
@Test func thumbnailsProtocolRelativeAndSorted() {
    let t = InnerTubeText.thumbnails(["thumbnails": [["url": "//yt3.ggpht.com/a=s176", "width": 176, "height": 176], ["url": "https://x/a=s88", "width": 88, "height": 88]]])
    #expect(t.map(\.width) == [88, 176]); #expect(t.last?.url.absoluteString == "https://yt3.ggpht.com/a=s176")
}
@Test func durationFormatter() { #expect(DurationFormatter.string(seconds: 5) == "0:05"); #expect(DurationFormatter.string(seconds: 280) == "4:40"); #expect(DurationFormatter.string(seconds: 3723) == "1:02:03") }
@Test func settingsDecodeEmptyObjectGivesDefaults() throws {
    let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(s == AppSettings()); #expect(s.segmentBehaviors[.sponsor] == .autoSkip); #expect(s.segmentBehaviors[.intro] == .showInBar)
}
@Test func historyFinished() {
    let v = VideoSummary(id: "a", title: "t")
    #expect(HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: 590, durationSeconds: 600).isFinished)
    #expect(!HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: 300, durationSeconds: 600).isFinished)
    #expect(!HistoryEntry(video: v, lastWatchedAt: .now, progressSeconds: 300, durationSeconds: nil).isFinished)
}
@Test func defaultThumbnails() { #expect(VideoSummary.defaultThumbnails(for: "abc").first?.url.absoluteString == "https://i.ytimg.com/vi/abc/mqdefault.jpg") }
@Test func thumbnailBest() { /* widths [168, 336, 480]: best(minWidth: 300)?.width == 336; best(minWidth: 1000)?.width == 480 */ }
@Test func downloadQualityKeys() { #expect(DownloadQuality.video(maxHeight: 720).key == "720"); #expect(DownloadQuality.audioOnly.label == "Audio only") }
@Test func ttlCacheExpires() async { /* now closure advanced past ttl → value(for:) == nil */ }
@Test func streamInfoExpiry() { /* expiresAt = t0 + 21540: isExpired(now: t0) false; isExpired(now: t0 + 21500) true (margin 120) */ }
```

- [ ] **Step 2: Run and see them fail to compile** — `swift test --package-path NoSlopKit` → errors for missing types.
- [ ] **Step 3: Write `Package.swift`, models, support, protocols, all stubs and mocks.** `Package.swift`: library `NoSlopKit`, target `NoSlopKit`, test target `NoSlopKitTests` with `resources: [.copy("Fixtures")]`, `swiftLanguageModes: [.v6]`. Stubs compile against the exact API above. In-memory `LibraryStore`/`SettingsStore`/`DownloadManager` work functionally (no persistence; `enqueue` appends a `.queued` item). Mocks return `SampleData` after the configured delay.
- [ ] **Step 4: Run tests** — `swift test --package-path NoSlopKit` → all foundation tests pass, zero warnings about Sendable in Models/Support.
- [ ] **Step 5: Commit** — `git add NoSlopKit && git commit -m "feat(kit): contracts, models, support, stubs, mocks"`

## Task 1B: App shell, project, design-system basics

**Files:**
- Create: `project.yml`, `Config/Base.xcconfig`, `Config/Local.xcconfig.example`, `scripts/{bootstrap,test,build}.sh`, `README.md` (skeleton: what it is, how to build, how to run tests)
- Create: `NoSlop/App/{NoSlopApp,AppDelegate,AppEnvironment,Router,RootView,RouteDestinationView}.swift`
- Create: `NoSlop/DesignSystem/{Theme,RemoteImage,ThumbnailView,VideoCardView,VideoRowView,ChannelAvatarView,SearchItemRow,PlaylistRowView,ChannelRowView,VideoTitleText,SubscribeButton,StateViews,VideoContextMenu,Formatting}.swift`
- Create (placeholders with the fixed type names): every view listed for Tasks 8, 9, 10 in the view table, under `NoSlop/Features/<Area>/` and `NoSlop/Player/`, plus `NoSlop/Player/PlayerController.swift` (stub: `open` sets `currentVideo` and `presentation = .expanded`; `minimize/expand/close` change `presentation`)
- Create: `NoSlop/Resources/Assets.xcassets` (`AppIcon` set with an empty 1024 slot, `AccentColor` #E62117 light / #FF4E45 dark)
- Generate and commit: `NoSlop.xcodeproj`

**Interfaces:**
- Consumes: all of Task 1A.
- Produces: "App layer contracts" above; `Theme` (`Theme.accent`, spacing constants `Theme.padding = 12`, `Theme.cornerRadius = 12`); `Formatting.relativeDate(_ date: Date) -> String` ("3 hours ago" via `RelativeDateTimeFormatter`, `.named`) and `Formatting.subtitle(for video: VideoSummary) -> String` ("Channel · 23M views · 11 years ago", skipping missing parts; uses `publishedText` or `relativeDate(publishedAt)`).

`project.yml` essentials: `options: { bundleIdPrefix: com.robinjungerich, deploymentTarget: { iOS: "18.0" }, defaultSourceDirectoryType: syncedFolder }`; `packages: { NoSlopKit: { path: NoSlopKit } }`; target `NoSlop` (application, iOS, `sources: [NoSlop]`, `dependencies: [{ package: NoSlopKit }]`, `configFiles` Base.xcconfig for Debug/Release); settings: `PRODUCT_BUNDLE_IDENTIFIER: com.robinjungerich.noslopyt`, `INFOPLIST_KEY_CFBundleDisplayName: "No Slop"`, `SWIFT_VERSION: 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY: YES`, `TARGETED_DEVICE_FAMILY: "1,2"`, `GENERATE_INFOPLIST_FILE: YES`, `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, `ENABLE_PREVIEWS: YES`; `info` properties: `UIBackgroundModes: [audio]`, `UIFileSharingEnabled: true`, `LSSupportsOpeningDocumentsInPlace: true`, `CFBundleURLTypes: [{ CFBundleURLSchemes: [noslop] }]`, `UILaunchScreen: {}`, `UISupportedInterfaceOrientations: [Portrait, LandscapeLeft, LandscapeRight]`, iPad all four, `ITSAppUsesNonExemptEncryption: false`. `Base.xcconfig` ends with `#include? "Local.xcconfig"`; `Local.xcconfig.example` documents `DEVELOPMENT_TEAM = YOURTEAMID`. Scheme `NoSlop`.

`NoSlopApp`: `@UIApplicationDelegateAdaptor(AppDelegate.self)`; `WindowGroup { RootView().environment(AppEnvironment.shared).tint(Theme.accent) }`; on launch, configure `URLCache.shared` (memory 64 MB, disk 512 MB) and `Task { await env.refreshAccount() }`. `AppDelegate`: forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `AppEnvironment.shared.downloads`; returns `.allButUpsideDown` on iPhone and `.all` on iPad from `supportedInterfaceOrientationsFor`.

Design-system basics must work with real data: `RemoteImage` loads through `URLSession.shared` (URLCache-backed) with an in-memory `NSCache` of decoded images; `ThumbnailView` is 16:9, `.fill`, with a duration badge (`DurationFormatter`), a "LIVE" badge, a red progress bar from `env.library.progress(for:)`, and a downloaded badge (`env.downloads.completedItem`); `VideoCardView` is a full-width thumbnail then avatar + `VideoTitleText` (2 lines) + subtitle; `VideoRowView` is a 160 pt-wide thumbnail on the left with title and subtitle on the right; `VideoTitleText` shows `video.title`, then the DeArrow title (`env.deArrow.betterTitle`) when `settings.deArrowTitles`; `SubscribeButton` shows "Subscribe" (filled, primary) or "Subscribed" (gray) and calls `env.toggleSubscription`; `ErrorStateView(error:retry:)` uses `(error as? LocalizedError)?.errorDescription` and shows an "Open on YouTube" button only when given a URL via an optional `openURL:` parameter defaulting to nil; `.videoContextMenu` offers Save to Watch Later, Add to playlist… (sheet listing local playlists plus "New playlist"), Download (menu of `.video(maxHeight: 720)`, `.video(maxHeight: 360)`, `.audioOnly`), Don't show this channel (appends to `settings.blockedChannels`), Share (`ShareLink(item: video.watchURL)`).

- [ ] **Step 1: Write `project.yml`, configs, scripts; run `xcodegen generate`** → `NoSlop.xcodeproj` created.
- [ ] **Step 2: Write the app shell, Router, AppEnvironment (live + preview wiring as specified), design-system basics, placeholders.** Placeholders render a title and the inputs they received (e.g. `Text("Channel \(channelID)")`) so navigation can be verified.
- [ ] **Step 3: Build** — app build command → `** BUILD SUCCEEDED **` with no errors.
- [ ] **Step 4: Smoke-run in a private simulator with `-mockServices YES`.** Expect the 4-tab bar. `noslop://watch?v=dQw4w9WgXcQ` sets the player presentation to expanded (placeholder overlay visible). `noslop://route/settings` pushes the settings placeholder. Take a screenshot to confirm, then delete the device.
- [ ] **Step 5: Commit** — `git add project.yml Config scripts README.md NoSlop NoSlop.xcodeproj && git commit -m "feat(app): project, app shell, router, environment, design-system basics"`

---

## Task 2: InnerTube transport, stream resolution, URLs, RSS, captions

**Files:**
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/InnerTube/{ClientProfile,InnerTubeConfig,InnerTubeClient,VisitorDataStore,InnerTubeYouTubeService,InnerTubeStreamResolver,YouTubeURL}.swift`, `InnerTube/Parsers/{PlayerResponseParser,SuggestionsParser,ResolveURLParser,SwJsDataParser}.swift`, `Feeds/{RSSParser,RSSFeedFetcher}.swift`, `Captions/{WebVTTParser,CaptionsService}.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/InnerTube/{TransportTests,PlayerResponseParserTests,StreamResolverTests,SuggestionsTests,YouTubeURLTests,ResolveURLTests,FacadeRequestTests}.swift`, `Feeds/RSSParserTests.swift`, `Captions/WebVTTParserTests.swift`, `Live/LiveSmokeTests.swift`

**Interfaces:**
- Consumes: `JSON`, `HTTPClient`, models; parser signatures of Tasks 3–4 (stubs in this worktree).
- Produces: `InnerTubeClient`, `InnerTubeYouTubeService`, `InnerTubeStreamResolver`, `CaptionsService`, `RSSFeedFetcher`, `YouTubeURL` with the exact API in "Implementation types".

- [ ] **Step 1: Write the failing tests**

```swift
// TransportTests
@Test func visitorDataFromSwJsData() throws {
    let text = String(decoding: try Fixture.data("sw_js_data.txt"), as: UTF8.self)
    #expect(SwJsDataParser.visitorData(from: text)?.hasPrefix("CgtTeW50aGV0aWNWaXNpdG9yRGF0YQ") == true)
}
@Test func playerRequestShape() async throws {
    // MockHTTP: "sw.js_data" → fixture; "youtubei/v1/player" → player_visionos_bigbuckbunny.json
    // InnerTubeClient(config: hl "en", gl "US", visitorStore: InMemoryVisitorDataStore())
    // post(endpoint: "player", profile: .visionOS, body: ["videoId": "aqz-KE-bpKQ"])
    // request URL == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false", method POST
    // headers: X-YouTube-Client-Name "101", X-YouTube-Client-Version "1.02", X-Goog-Visitor-Id == visitorData, Origin "https://www.youtube.com", User-Agent == ClientProfile.visionOS.userAgent
    // body.context.client: clientName "VISIONOS", clientVersion "1.02", deviceModel "RealityDevice17,1", hl "en", gl "US", visitorData; body.videoId "aqz-KE-bpKQ"
}
@Test func visitorDataCachedSevenDays() async throws { /* second call within 7 days → no new sw.js_data request; after 7 days → refetch */ }
@Test func visitorDataFallsBackToVisitorIdEndpoint() async throws { /* sw.js_data 500 → POST youtubei/v1/visitor_id (fixture visitor_id.json) → responseContext.visitorData */ }
@Test func httpErrorMaps() async throws { /* player 500 → NoSlopError.http(status: 500) */ }

// PlayerResponseParserTests (now = fixed Date)
@Test func bigBuckBunny() throws {
    let info = try PlayerResponseParser.parse(try Fixture.json("player_visionos_bigbuckbunny.json"), now: t0)
    #expect(info.videoID == "aqz-KE-bpKQ"); #expect(info.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
    #expect(info.lengthSeconds == 635); #expect(info.hlsURL?.host == "manifest.googlevideo.com")
    #expect(Set(info.formats.filter { $0.mimeType.contains("avc1") }.map(\.itag)) == [299, 298, 135, 134, 133, 160])
    #expect(Set(info.formats.filter { $0.itag == 140 }.map(\.isDRC)) == [false, true])
    #expect(info.formats.first { $0.itag == 140 && !$0.isDRC }?.approxDurationMs == 634_624)
    #expect(info.formats.first { $0.itag == 140 && !$0.isDRC }?.contentLength == 10_271_496)
    #expect(info.expiresAt == t0.addingTimeInterval(21540)); #expect(!info.isLive)
}
@Test func rickrollCaptions() throws {
    let info = try PlayerResponseParser.parse(try Fixture.json("player_visionos_rickroll.json"), now: t0)
    #expect(info.captions.count == 6); #expect(info.captions[0].languageCode == "en"); #expect(info.captions[0].name == "English")
    #expect(!info.captions[0].isAutoGenerated); #expect(info.captions[1].name == "English (auto-generated)"); #expect(info.captions[1].isAutoGenerated)
}
@Test func sabrOnlyIsUnplayable() { #expect(throws: NoSlopError.self) { try PlayerResponseParser.parse(try Fixture.json("player_ios_sabr_only.json"), now: t0) } }
@Test func botCheck() { /* {"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}} → throws .botCheck */ }
@Test func ageRestricted() { /* reason "Sign in to confirm your age" → .unplayable(reason: "Sign in to confirm your age") */ }

// StreamResolverTests
@Test func retriesOnceWithFreshVisitorDataOnBotCheck() async throws { /* responses: sw.js_data(vd1) → player(bot) → sw.js_data(vd2) → player(OK). Result OK; 2 player requests; 2nd has X-Goog-Visitor-Id == vd2 */ }
@Test func secondBotCheckThrowsBotCheck() async throws { /* player(bot) twice → throws .botCheck; exactly 2 player requests */ }

// SuggestionsTests
@Test func firefoxSuggestions() throws { let s = SuggestionsParser.parse(try Fixture.data("suggest_firefox.json")); #expect(s.count == 10); #expect(s.first == "blender tutorial") }

// YouTubeURLTests (table)
// "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s" → .video("dQw4w9WgXcQ", 42); "https://youtu.be/dQw4w9WgXcQ?t=1m5s" → .video(…, 65)
// "https://m.youtube.com/watch?v=jNQXAC9IVRw" → .video(…, nil); "https://www.youtube.com/shorts/gIjBeEvDXew" → .video("gIjBeEvDXew", nil)
// "https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg" → .channel; "https://www.youtube.com/playlist?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B" → .playlist
// "https://www.youtube.com/@BlenderOfficial" → nil (needs network); "noslop://watch?v=dQw4w9WgXcQ&t=10" → .video(…, 10)
// "noslop://channel/UCSMOQeBJ2RAnuFungnQOxLg" → .channel; "noslop://search?q=blender%20donut" → .search("blender donut"); "https://example.com/watch?v=x" → nil
// extractURL(from: "look https://youtu.be/dQw4w9WgXcQ !")?.absoluteString == "https://youtu.be/dQw4w9WgXcQ"
@Test func resolveHandle() throws { #expect(ResolveURLParser.parse(try Fixture.json("resolve_handle.json")) == .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")) }

// RSSParserTests
@Test func blenderFeed() throws {
    let v = RSSParser.parse(try Fixture.data("rss_blender.xml"))
    #expect(v.count == 15); #expect(v.filter(\.isShort).count == 2)
    #expect(v[0].id == "mHrHLqQj7Ts"); #expect(v[0].title == "Making of: The Blender Open Movies Exhibition")
    #expect(v[0].publishedAt == ISO8601DateFormatter().date(from: "2026-11-02T13:54:25Z")); #expect(v[0].viewCount == 9793)
    #expect(v[0].channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"))
    #expect(v[0].thumbnails.first?.url.absoluteString == "https://i2.ytimg.com/vi/mHrHLqQj7Ts/hqdefault.jpg")
}

// WebVTTParserTests
@Test func rickrollVTT() throws {
    let cues = WebVTTParser.parse(String(decoding: try Fixture.data("captions_rickroll.vtt"), as: UTF8.self))
    #expect(cues[0] == CaptionCue(start: 1.36, end: 3.04, text: "[♪♪♪]"))
    #expect(cues[1].start == 18.64); #expect(cues[1].text == "♪ We're no strangers to love ♪")
    #expect(cues[2].text == "♪ You know the rules\nand so do I ♪")
}

// FacadeRequestTests — request shapes only (parsers are stubs here)
// search(query: "blender", filter: SearchFilter(type: .video)) → POST "search", body.query == "blender", body.params == SearchParams.encode(...) (nil-safe)
// videoDetails(id:) → POST "next" with videoId; channel(id:) → POST "browse" with browseId and params == ChannelParser.tabParams[.videos]
// playlist(id: "PLx") → browseId "VLPLx"; suggestions → GET suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=en&gl=US&q=…
// resolve(url: @handle) → POST "navigation/resolve_url" with url

// Live/LiveSmokeTests — skipped unless NOSLOP_LIVE == "1"
// streams for "jNQXAC9IVRw": hlsURL != nil; GET hlsURL → 200 and body hasPrefix "#EXTM3U"; an avc1 format URL Range bytes=0-1023 → 206
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "Transport|PlayerResponse|StreamResolver|Suggestions|YouTubeURL|ResolveURL|RSS|WebVTT|FacadeRequest"` → failures (`notImplemented`).
- [ ] **Step 3: Implement.** Notes the tests don't fully pin:
  - `ClientProfile.web`: `WEB`, `2.20261030.02.00`, id 1, UA `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15,gzip(gfe)`, no extra fields. `.visionOS`: `VISIONOS`, `1.02`, id 101, UA `Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15`, extra `deviceMake: Apple, deviceModel: RealityDevice17,1, osName: visionOS, osVersion: 26.5.23O471`.
  - `InnerTubeConfig.fromLocale`: `hl = locale.language.languageCode?.identifier ?? "en"`, `gl = locale.region?.identifier ?? "US"`.
  - visitorData: `GET https://www.youtube.com/sw.js_data` (Safari UA). Strip the leading `)]}'`, parse, take `[0][2][0][0][13]`; fallback: the first string anywhere matching `^Cg[A-Za-z0-9_%-]{20,}$`; fallback: `POST visitor_id` (WEB profile, no visitorData) → `responseContext.visitorData`. Percent-decode. Cache 7 days in the `VisitorDataStoring`.
  - `player` body: `videoId`, `contentCheckOk: true`, `racyCheckOk: true`, `playbackContext.contentPlaybackContext.html5Preference = "HTML5_PREF_WANTS"`.
  - Parser playability: `OK` → continue; `LOGIN_REQUIRED` whose reason contains "bot" → `.botCheck`; any other status → `.unplayable(reason: reason ?? status)`. Formats from `streamingData.formats` (`isProgressive = true`) and `adaptiveFormats`, skipping entries without `url`. `isDRC = json["isDrc"] == true || url contains "xtags=drc"`. `expiresAt = now + (expiresInSeconds ?? 21540)`. No HLS and no formats → `.unplayable(reason: "No playable streams were returned for this video.")`. Captions: `captionTracks[].baseUrl`, `name` via `InnerTubeText.text`, `kind == "asr"` → auto-generated.
  - `InnerTubeStreamResolver`: on `.botCheck`, `visitorData(forceRefresh: true)` then retry once.
  - Facade: WEB profile for everything except `player`. `videoDetails` = `WatchMetadataParser.parse(json, videoID:)` (`nil` → `.decoding`) with `related`/`relatedContinuation` from `RelatedParser.parse(next:)`, cached 10 min in a `TTLCache`. `channel(id:)` browses with `params = ChannelParser.tabParams[.videos]`; `channelTab` uses that tab's params. `playlist` browses `"VL" + id`. `resolve` = `YouTubeURL.resolveLocally(url)` ?? `ResolveURLParser.parse(post("navigation/resolve_url", ["url": url]))`. Suggestions: `GET https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=<hl>&gl=<gl>&q=<q>`.
  - RSS with `XMLParser`: `yt:videoId`, `title`, `link[rel=alternate]@href` (contains `/shorts/` → `isShort`), `yt:channelId`, `author/name`, `published` (ISO 8601 with offset), `media:thumbnail@url`, `media:statistics@views`.
  - WebVTT: skip the `WEBVTT` header, `NOTE`/`STYLE`/`REGION` blocks and cue identifiers; timings `HH:MM:SS.mmm` or `MM:SS.mmm` (ignore cue settings); strip `<…>` tags; decode `&amp; &lt; &gt; &nbsp; &#39; &quot;`; join cue lines with `\n`. `CaptionsService` fetches `baseURL + "&fmt=vtt"`.
  - `YouTubeURL`: hosts `youtube.com`, `www.`, `m.`, `music.`, `youtube-nocookie.com`, `youtu.be`; paths `/watch`, `/shorts/<id>`, `/live/<id>`, `/embed/<id>`, `/channel/<UC…>`, `/playlist?list=`; `t`/`start` as `42`, `42s`, `1m5s`, `1h2m3s`; the `noslop://` forms from the tests. `extractURL` uses `NSDataDetector`.
- [ ] **Step 4: Run** — same filter → PASS; full `swift test --package-path NoSlopKit` passes (other tasks' stub tests aren't present); `NOSLOP_LIVE=1 swift test --package-path NoSlopKit --filter Live` passes on this Mac.
- [ ] **Step 5: Commit** — `git add` the Files above → `git commit -m "feat(kit): InnerTube transport, visionOS stream resolver, URLs, RSS, captions"`

## Task 3: Browse parsers (items, search, channel, playlist, related)

**Files:**
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/InnerTube/Parsers/{ItemParser,SearchParser,ChannelParser,PlaylistParser,RelatedParser}.swift`, `InnerTube/SearchParams.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/InnerTube/{SearchParserTests,SearchParamsTests,ChannelParserTests,PlaylistParserTests,RelatedParserTests,ItemParserRobustnessTests}.swift`

**Interfaces:**
- Consumes: `JSON`, `InnerTubeText`, models.
- Produces: parsers with the exact API in "Implementation types"; `ChannelParser.tabParams == [.videos: "EgZ2aWRlb3PyBgQKAjoA", .live: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D", .playlists: "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA"]`.

- [ ] **Step 1: Write the failing tests** (fixture values verified 2026-11-03)

```swift
@Test func searchInitialPage() throws {
    let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
    let videos = p.items.compactMap(\.video)
    #expect(videos.filter { !$0.isShort }.count == 17); #expect(videos.filter(\.isShort).count == 5)
    #expect(p.items.filter { if case .channel = $0 { true } else { false } }.count == 1)
    #expect(p.items.filter { if case .playlist = $0 { true } else { false } }.count == 1)
    #expect(p.items.count == 24); #expect(p.continuation != nil)
    let v = try #require(videos.first { !$0.isShort })
    #expect(v.id == "z-Xl9tGqH14"); #expect(v.title == "Beginner Blender Tutorial (2026)"); #expect(v.durationSeconds == 15550)
    #expect(v.viewCount == 2_763_792); #expect(v.viewCountText == "2,763,792 views"); #expect(v.publishedText == "9 months ago")
    #expect(v.channel?.name == "Blender Guru"); #expect(v.channel?.id == "UCOKHwx1VCdgnxwbjyb9Iu1g"); #expect(v.channel?.avatarURL != nil)
    let s = try #require(videos.first(where: \.isShort))
    #expect(s.id == "gIjBeEvDXew"); #expect(s.title == "Noob vs PRO: Realistic Clothes in Blender"); #expect(s.viewCountText == "810K views")
}
@Test func searchChannelQuirk() throws {
    // channelRenderer: subscriberCountText holds the @handle, videoCountText holds subscribers
    // → ChannelSummary(id "UCOKHwx1VCdgnxwbjyb9Iu1g", name "Blender Guru", handle "@blenderguru", subscriberCountText "3.45M subscribers")
}
@Test func searchPlaylistLockup() throws { /* playlist id "PLjEaoINr3zgEPv5y--4MKpciLaoQYZB1Z", title "Blender 4.0 Beginner Donut Tutorial (Old)", thumbnails non-empty */ }
@Test func searchContinuation() throws { let p = SearchParser.parse(try Fixture.json("search_blender_tutorial_cont.json")); #expect(p.items.compactMap(\.video).count == 19); #expect(p.continuation != nil) }
@Test func searchChannelsOnly() throws { /* search_channels_only.json → 20 channels, 0 videos */ }
@Test func searchPlaylistsOnly() throws { /* search_playlists_only.json → 20 playlists (17 PLAYLIST + 3 COURSE lockups) */ }

@Test(arguments: [
  (SearchFilter(), nil), (SearchFilter(type: .video), "EgIQAQ=="), (SearchFilter(type: .channel), "EgIQAg=="),
  (SearchFilter(type: .playlist), "EgIQAw=="), (SearchFilter(type: .video, sort: .uploadDate), "CAISAhAB"),
  (SearchFilter(sort: .viewCount), "CAM="), (SearchFilter(type: .video, duration: .long), "EgQQARgC"),
  (SearchFilter(type: .video, uploadDate: .today), "EgQIAhAB")])
func searchParams(filter: SearchFilter, expected: String?) { #expect(SearchParams.encode(filter) == expected) }

@Test func channelVideosTab() throws {
    let page = try #require(ChannelParser.parseChannelPage(try Fixture.json("channel_blender_videos.json")))
    #expect(page.header.id == "UCSMOQeBJ2RAnuFungnQOxLg"); #expect(page.header.name == "Blender"); #expect(page.header.handle == "@BlenderOfficial")
    #expect(page.header.subscriberCountText == "1.25M subscribers"); #expect(page.header.videoCountText == "1.5K videos")
    #expect(page.header.avatarURL != nil); #expect(page.header.bannerURL != nil); #expect(page.availableTabs == [.videos, .live, .playlists])
    #expect(page.videos.items.count == 30)
    let v = try #require(page.videos.items.first?.video)
    #expect(v.id == "mHrHLqQj7Ts"); #expect(v.title == "Making of: The Blender Open Movies Exhibition"); #expect(v.durationSeconds == 280)
    #expect(page.videos.continuation != nil)   // the grid's continuation, NOT the about-panel continuation (see notes)
}
@Test func channelShortsTabAllShort() throws { let p = ChannelParser.parseTab(try Fixture.json("channel_blender_shorts.json")); #expect(p.items.count == 35); #expect(p.items.allSatisfy { $0.video?.isShort == true }) }
@Test func channelPlaylistsTab() throws {
    let p = ChannelParser.parseTab(try Fixture.json("channel_blender_playlists.json")); #expect(p.items.count == 30)
    guard case .playlist(let pl) = p.items[0] else { Issue.record("expected playlist"); return }
    #expect(pl.id == "PLa1F2ddGya_-I9y1nXALrBqrZNdlUE012"); #expect(pl.title == "Blender Conference 2026")
}
@Test func channelLiveTab() throws { #expect(ChannelParser.parseTab(try Fixture.json("channel_blender_live.json")).items.count == 30) }

@Test func playlistPage() throws {
    let p = try #require(PlaylistParser.parse(try Fixture.json("playlist_sample.json"), playlistID: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"))
    #expect(p.info.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"); #expect(p.info.title == "Blender for Complete Beginners Tutorial Series")
    #expect(p.videos.items.count == 14); #expect(p.videos.items[0].id == "sgMfEq3pDE0")
    #expect(p.videos.items[0].title == "Part 1 - Blender for Complete Beginners Tutorial Series (Navigation & Shortcut Keys)")
    #expect(p.videos.continuation != nil)       // from continuationItemViewModel
}

@Test func relatedFromNext() throws {
    let p = RelatedParser.parse(next: try Fixture.json("next_aqz.json"))
    #expect(p.items.filter { !$0.isShort }.count == 20); #expect(p.items.filter(\.isShort).count == 6)
    #expect(p.items[0].id == "7pPUE6cGFwI"); #expect(p.items[0].title == "A Little Pony’s Big Heart"); #expect(p.continuation != nil)
}
@Test func relatedContinuation() throws { let p = RelatedParser.parseContinuation(try Fixture.json("next_aqz_related_cont.json")); #expect(p.items.count == 20); #expect(p.continuation != nil) }

@Test func mutatedRenderersAreSkipped() throws {
    // Take search_blender_tutorial.json, delete "videoId" from the first videoRenderer and "metadata" from the playlist lockup:
    // → parse does not crash, returns ≥ 22 items, and none has id "z-Xl9tGqH14"
}
@Test func emptyObjectYieldsEmptyPage() { #expect(SearchParser.parse([:]).items.isEmpty); #expect(ChannelParser.parseChannelPage([:]) == nil); #expect(RelatedParser.parse(next: [:]).items.isEmpty) }
@Test func adsNeverReturned() throws { /* no item id equals any id found under adSlotRenderer subtrees in search fixtures */ }
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "SearchParser|SearchParams|ChannelParser|PlaylistParser|RelatedParser|ItemParser"` → fail.
- [ ] **Step 3: Implement.** Explore the fixtures with `jq`/`node` one-liners rather than reading them whole (they are 0.2–1.6 MB). Notes:
  - **Scopes.** Search: `contents.twoColumnSearchResultsRenderer.primaryContents.sectionListRenderer.contents` (initial) or `onResponseReceivedCommands[].appendContinuationItemsAction.continuationItems` (continuation). Related: `contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results` (initial) or `onResponseReceivedEndpoints[].appendContinuationItemsAction.continuationItems`. Channel tab: the `tabRenderer` with `selected == true` → `content` (`richGridRenderer.contents`, or `sectionListRenderer` → `gridRenderer.items` / `itemSectionRenderer`); channel continuation: `onResponseReceivedActions[].appendContinuationItemsAction.continuationItems`. Playlist: the selected tab → `sectionListRenderer.contents[].itemSectionRenderer.contents`; continuation via `onResponseReceivedActions`.
  - **Continuation token.** Use the last `continuationItemRenderer.continuationEndpoint.continuationCommand.token`, or `continuationItemViewModel…continuationCommand.token` (playlists), **inside the scope only**. Pitfall: in `channel_blender_videos.json` the last `continuationCommand` in the whole document belongs to the "about" panel.
  - **Harvest.** Walk the scope in array order. Map and stop descending at `videoRenderer`, `compactVideoRenderer`, `gridVideoRenderer`, `playlistVideoRenderer`, `lockupViewModel`, `shortsLockupViewModel`, `reelItemRenderer`, `channelRenderer`, `gridChannelRenderer`, `playlistRenderer`. Never descend into ad or AI renderers, `horizontalCardListRenderer` (search refinement cards), `feedNudgeRenderer`, or `engagementPanelSectionListRenderer`.
  - **`videoRenderer`.** `videoId`; `title` runs; `lengthText` → `parseDuration`; `viewCountText` (simpleText or runs) → text and `parseCount`; `publishedTimeText`; `ownerText.runs[0]` → name, `navigationEndpoint.browseEndpoint.browseId`, and `canonicalBaseUrl` `/@x` → handle; avatar from `channelThumbnailSupportedRenderers.channelThumbnailWithLinkRenderer.thumbnail`; `thumbnail.thumbnails`. Badge style `BADGE_STYLE_TYPE_LIVE_NOW` → `isLive`; `upcomingEventData` → `isUpcoming`; style `BADGE_STYLE_TYPE_MEMBERS_ONLY` → `isMembersOnly`; `navigationEndpoint.reelWatchEndpoint`, or overlay `thumbnailOverlayTimeStatusRenderer.style == "SHORTS"` → `isShort`.
  - **`lockupViewModel` with `LOCKUP_CONTENT_TYPE_VIDEO`.** `contentId`; title `metadata.lockupMetadataViewModel.title.content`; avatar and channel id from `metadata.lockupMetadataViewModel.image.decoratedAvatarViewModel` (avatar `image.sources`; id = first `browseEndpoint.browseId` under it). Metadata rows `metadata.contentMetadataViewModel.metadataRows[].metadataParts[].text.content`: a part containing "view" or "watching" → views (`parseCount`); "ago", "Streamed", "Premiere" or "Scheduled" → `publishedText`; with ≥2 rows, the first row's first part is the channel name. Duration from `contentImage.thumbnailViewModel.overlays[].thumbnailBottomOverlayViewModel.badges[].thumbnailBadgeViewModel.text` (`"4:40"`); badge text "LIVE" or a `…_LIVE` badgeStyle → `isLive`; "Upcoming"/"Premiere" → `isUpcoming`; "Members only" → `isMembersOnly`. Thumbnails from `contentImage.thumbnailViewModel.image.sources`.
  - **`lockupViewModel` with `PLAYLIST`, `PODCAST` or `COURSE`** → `PlaylistSummary`. Thumbnail is under `contentImage.collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel`; video count from its overlay badge text ("12 videos" → `parseCount`); channel from the first metadata part when present.
  - **`shortsLockupViewModel`.** id = `onTap.innertubeCommand.reelWatchEndpoint.videoId` ?? the `entityId` suffix after `shorts-shelf-item-`; title `overlayMetadata.primaryText.content`; views `overlayMetadata.secondaryText.content`; `thumbnail.sources`; `isShort = true`.
  - **`channelRenderer`.** `channelId`, `title`; if `subscriberCountText` starts with "@", it is the handle and `videoCountText` is the subscriber count; avatar `thumbnail.thumbnails`; `descriptionSnippet`.
  - **Channel header.** From `header.pageHeaderRenderer.content.pageHeaderViewModel`: title `title.dynamicTextViewModel.text.content`; avatar `image.decoratedAvatarViewModel.avatar.avatarViewModel.image.sources`; banner `banner.imageBannerViewModel.image.sources`; metadata row parts → handle (starts with "@"), subscribers (contains "subscriber"), videos (contains "video"); description `description.descriptionPreviewViewModel.description.content`. id from `metadata.channelMetadataRenderer.externalId`.
  - **Tabs.** Map tabs by **params prefix**, not title (titles are localized): `EgZ2aWRlb3` → videos, `EgdzdHJlYW1z` → live, `EglwbGF5bGlzdH` → playlists. `availableTabs` is in that fixed order, filtered to those present.
  - **Search params protobuf.** Field 1 = sort (relevance 0 → omitted, uploadDate 2, viewCount 3). Field 2 = a filters message with field 1 upload date (lastHour 1, today 2, thisWeek 3, thisMonth 4, thisYear 5), field 2 type (video 1, channel 2, playlist 3), field 3 duration (short 1, long 2, medium 3). Encode varints, then standard base64 with padding. `nil` for the default filter.
- [ ] **Step 4: Run** — same filter → PASS; full package tests pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): search/channel/playlist/related parsers, search params"`

## Task 4: Watch-page and comments parsers

**Files:**
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/InnerTube/Parsers/{WatchMetadataParser,CommentsParser}.swift`
- Create fixture: `NoSlopKit/Tests/NoSlopKitTests/Fixtures/comments_replies_aqz.json` (capture live: POST `next` with WEB profile + a fresh visitorData and the first comment's replies continuation from `comments_aqz.json`; if the token expired, use a fresh `next` → comments → replies chain for `aqz-KE-bpKQ`; scrub any public IPv4 with `203.0.113.7`)
- Test: `NoSlopKit/Tests/NoSlopKitTests/InnerTube/{WatchMetadataParserTests,CommentsParserTests}.swift`

**Interfaces:**
- Consumes: `JSON`, `InnerTubeText`, models.
- Produces: `WatchMetadataParser.parse(_:videoID:) -> VideoDetails?` (with `related` empty) and `CommentsParser.parse(_:) -> CommentsPage`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func bigBuckBunnyMetadata() throws {
    let d = try #require(WatchMetadataParser.parse(try Fixture.json("next_aqz.json"), videoID: "aqz-KE-bpKQ"))
    #expect(d.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
    #expect(d.viewCountText == "23,500,582 views"); #expect(d.viewCount == 23_500_582); #expect(d.shortViewCountText == "23M views")
    #expect(d.dateText == "Nov 10, 2014"); #expect(d.relativeDateText == "11 years ago")
    #expect(d.channel.name == "Blender"); #expect(d.channel.id == "UCSMOQeBJ2RAnuFungnQOxLg"); #expect(d.channel.avatarURL != nil)
    #expect(d.subscriberCountText == "1.25M subscribers"); #expect(d.likeCountText == "110K"); #expect(d.likeCount != nil)
    #expect(d.description.text.hasPrefix("UHD High Frame rate version of the iconic short film by Blender, Big B"))
    #expect(d.description.text.utf16.count == 219); #expect(d.description.links.count == 2)
    #expect(d.description.links[0].range == 93..<133)
    guard case .url(let u) = d.description.links[0].target else { Issue.record("expected url"); return }
    #expect(u.host != "www.youtube.com")                // /redirect?…&q=<real> is unwrapped
    #expect(d.commentsContinuation != nil); #expect(d.chapters.isEmpty); #expect(!d.isLive); #expect(d.related.isEmpty)
}
@Test func rickrollLinks() throws {
    let d = try #require(WatchMetadataParser.parse(try Fixture.json("next_rickroll.json"), videoID: "dQw4w9WgXcQ"))
    #expect(d.title == "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)"); #expect(d.viewCountText == "1,833,297,545 views")
    #expect(d.description.links.count == 16)
    let first = d.description.links[0]; #expect(first.range == 180..<196)
    #expect(first.target == .hashtag("rickastleynever"))
    let u16 = Array(d.description.text.utf16)
    #expect(String(utf16CodeUnits: Array(u16[first.range]), count: 16).hasPrefix("#"))
}
@Test func chapters() throws {
    let d = try #require(WatchMetadataParser.parse(try Fixture.json("next_with_chapters.json"), videoID: "z-Xl9tGqH14"))
    #expect(d.chapters.count == 8); #expect(d.chapters[0] == Chapter(title: "Part 1 The Basics", startSeconds: 0, thumbnailURL: d.chapters[0].thumbnailURL))
    #expect(d.chapters[1].title == "Part 2 Basic Modelling"); #expect(d.chapters[1].startSeconds == 1696)
}
@Test func minimalNextStillParses() { /* {"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[{"videoPrimaryInfoRenderer":{"title":{"runs":[{"text":"T"}]}}}]}}}}} → title "T", channel name "" , no crash */ }

@Test func commentsFirstPage() throws {
    let p = CommentsParser.parse(try Fixture.json("comments_aqz.json"))
    #expect(p.comments.count == 20); #expect(p.totalCountText == "5,222 Comments"); #expect(p.continuation != nil)
    let c = p.comments[0]
    #expect(c.id == "UgxNivqkidvk9k_eR_B4AaABAg"); #expect(c.authorName == "@randomthef1rst")
    #expect(c.text.hasPrefix("Here after that one TikTok edit")); #expect(c.publishedText == "1 year ago")
    #expect(c.likeCountText == "790"); #expect(c.replyCount == 25); #expect(c.repliesContinuation != nil)
    #expect(p.sortOptions.count == 2); #expect(p.sortOptions.contains { $0.isSelected })
}
@Test func commentsContinuation() throws { #expect(CommentsParser.parse(try Fixture.json("comments_aqz_cont.json")).comments.count == 20) }
@Test func repliesPage() throws { let p = CommentsParser.parse(try Fixture.json("comments_replies_aqz.json")); #expect(!p.comments.isEmpty); #expect(p.comments.allSatisfy { $0.replyCount == 0 }) }
@Test func missingEntityMutationSkipsComment() throws { /* remove the first commentEntityPayload mutation → 19 comments, no crash */ }
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "WatchMetadata|CommentsParser"` → fail.
- [ ] **Step 3: Implement.** Notes:
  - Path: `contents.twoColumnWatchNextResults.results.results.contents[]`.
  - `videoPrimaryInfoRenderer`: `title`; `viewCount.videoViewCountRenderer.viewCount` / `.shortViewCount`; `isLive` from `videoViewCountRenderer.isLive`; `dateText`; `relativeDateText`. Likes from `videoActions.menuRenderer.topLevelButtons[].segmentedLikeDislikeButtonViewModel.likeButtonViewModel.likeButtonViewModel.toggleButtonViewModel.toggleButtonViewModel.defaultButtonViewModel.buttonViewModel.title` (`"110K"` → `parseCount`). Prefer the exact number in that button's `accessibilityText` when present ("…along with 110,123 other people").
  - `videoSecondaryInfoRenderer.owner.videoOwnerRenderer`: `title.runs[0]`, `navigationEndpoint.browseEndpoint.browseId` and `canonicalBaseUrl` (handle), `thumbnail.thumbnails`, `subscriberCountText`.
  - Description: `attributedDescription.content` + `commandRuns[{startIndex, length, onTap.innertubeCommand}]`, offsets in UTF-16. Command → target: `urlEndpoint.url` (unwrap `https://www.youtube.com/redirect?…&q=<real>`; `/hashtag/<tag>` → `.hashtag`); `watchEndpoint` with the same `videoId` → `.timestamp(startTimeSeconds ?? 0)`, otherwise `.video`; `browseEndpoint.browseId` `UC…` → `.channel`, `VL…` → `.playlist` (strip VL).
  - Chapters: `playerOverlays.playerOverlayRenderer.decoratedPlayerBarRenderer.decoratedPlayerBarRenderer.playerBar.multiMarkersPlayerBarRenderer.markersMap[]` with key `DESCRIPTION_CHAPTERS` or `AUTO_CHAPTERS` → `value.chapters[].chapterRenderer` (`title.simpleText`, `timeRangeStartMillis / 1000`, last `thumbnail.thumbnails`).
  - Comments token: the `itemSectionRenderer` with `sectionIdentifier == "comment-item-section"` → `continuationItemRenderer.continuationEndpoint.continuationCommand.token`.
  - Comments: build an entity map from `frameworkUpdates.entityBatchUpdate.mutations[]` (`entityKey` → payload). Items come from `onResponseReceivedEndpoints[]` → `reloadContinuationItemsCommand` or `appendContinuationItemsAction` → `continuationItems[]`. Each item is a `commentThreadRenderer` (→ `commentViewModel.commentViewModel`, `replies.commentRepliesRenderer` continuation token) or a bare `commentViewModel` (replies pages).
  - Comment fields from `commentEntityPayload` looked up by `commentViewModel.commentKey`: `properties.commentId`, `properties.content.content`, `properties.publishedTime`, `author.displayName`, `author.avatarThumbnailUrl`, `author.channelId`, `author.isCreator` → `isByUploader`, `toolbar.likeCountNotliked`, `toolbar.replyCount` (`Int` or 0). `pinnedText` present → `isPinned`; the `engagementToolbarStateEntityPayload` for `toolbarStateKey` with `heartState == "TOOLBAR_HEART_STATE_HEARTED"` → `isHearted`. Missing entity → skip the comment.
  - Header: `commentsHeaderRenderer.countText` runs joined; `sortMenu.sortFilterSubMenuRenderer.subMenuItems[]` → title, `selected`, `serviceEndpoint.continuationCommand.token`. Page continuation: the trailing `continuationItemRenderer` (`continuationEndpoint…token` or `button.buttonRenderer.command.continuationCommand.token`).
- [ ] **Step 4: Run** → PASS; full package tests pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): watch metadata, chapters, comments parsers"`

## Task 5: Google sign-in and YouTube Data API

**Files:**
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/Google/{GoogleOAuthConfig,PKCE,TokenStores,GoogleOAuthService,YouTubeDataAPIClient}.swift` (plus private helpers in `Google/`)
- Create fixtures: `NoSlopKit/Tests/NoSlopKitTests/Fixtures/dataapi_{subscriptions_page1,subscriptions_page2,liked_videos,playlists,playlist_items,videos_durations,error_quota}.json` (synthetic, shaped exactly like the YouTube Data API v3 reference responses)
- Test: `NoSlopKit/Tests/NoSlopKitTests/Google/{PKCETests,OAuthConfigTests,GoogleOAuthServiceTests,DataAPIClientTests}.swift`

**Interfaces:**
- Consumes: `HTTPClient`, `TokenStoring`, `WebAuthenticating`, models.
- Produces: `GoogleOAuthConfig`, `PKCE`, `KeychainTokenStore`, `InMemoryTokenStore`, `GoogleOAuthService`, `YouTubeDataAPIClient` with the exact API in "Implementation types".

- [ ] **Step 1: Write the failing tests**

```swift
@Test func rfc7636Vector() { #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM") }
@Test func verifierShape() { let v = PKCE.makeVerifier(); #expect(v.count == 64); #expect(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) }) }
@Test func configFromClientID() throws {
    let c = try #require(GoogleOAuthConfig(clientID: " 123-abc.apps.googleusercontent.com "))
    #expect(c.redirectScheme == "com.googleusercontent.apps.123-abc"); #expect(c.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    #expect(GoogleOAuthConfig(clientID: "nope") == nil)
    let items = URLComponents(url: c.authorizationURL(state: "S", codeChallenge: "C"), resolvingAgainstBaseURL: false)!.queryItems!
    #expect(items.first { $0.name == "response_type" }?.value == "code"); #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    #expect(items.first { $0.name == "scope" }?.value == "openid email profile https://www.googleapis.com/auth/youtube")
    #expect(items.first { $0.name == "state" }?.value == "S"); #expect(items.first { $0.name == "redirect_uri" }?.value == c.redirectURI)
}
@Test func signInExchangesCode() async throws {
    // FakeAuthenticator (@MainActor) captures the URL, returns "<redirectURI>?code=4/abc&state=<state from URL>"
    // MockHTTP "oauth2.googleapis.com/token" → {"access_token":"at","expires_in":3599,"refresh_token":"rt","scope":"…","token_type":"Bearer","id_token":"<header>.<base64url({"sub":"1234","email":"you@example.com","name":"You","picture":"https://p/x.jpg"})>.sig"}
    // → account == GoogleAccount(id: "1234", email: "you@example.com", name: "You", pictureURL: URL("https://p/x.jpg"))
    // token request: POST, Content-Type application/x-www-form-urlencoded, body has grant_type=authorization_code, code=4%2Fabc, code_verifier, client_id, redirect_uri
    // store.load()?.tokens.refreshToken == "rt"
}
@Test func stateMismatchFails() async { /* callback state "WRONG" → throws NoSlopError.oauth(_) */ }
@Test func errorCallbackFails() async { /* "?error=access_denied" → throws .oauth("access_denied") */ }
@Test func refreshWhenExpired() async throws { /* stored expiresAt in the past → accessToken() POSTs grant_type=refresh_token; returns new token; refresh token kept when the response omits it */ }
@Test func concurrentAccessTokenRefreshesOnce() async throws { /* two concurrent accessToken() on expired creds → exactly 1 token request */ }
@Test func invalidGrantSignsOut() async throws { /* refresh → 400 {"error":"invalid_grant"} → throws .notSignedIn; store cleared; currentAccount() == nil */ }
@Test func signOutRevokes() async throws { /* POST https://oauth2.googleapis.com/revoke?token=rt; store cleared even if revoke fails */ }

@Test func subscriptionsPaginate() async throws { /* page1 (nextPageToken "P2") + page2 → combined count; SubscribedChannel(id: snippet.resourceId.channelId, name: snippet.title, avatarURL: snippet.thumbnails.default.url, source: .google(subscriptionID: item.id)) */ }
@Test func likedVideosMapping() async throws { /* videos?myRating=like&part=snippet,contentDetails,statistics → durationSeconds from "PT4M40S" == 280, viewCount from statistics.viewCount */ }
@Test func playlistItemsSkipPrivateAndDeleted() async throws { /* titles "Private video" / "Deleted video" (no videoOwnerChannelId) skipped; Page.continuation == nextPageToken */ }
@Test func rateUsesPost() async throws { /* POST …/videos/rate?id=dQw4w9WgXcQ&rating=like → 204 */ }
@Test func unauthorizedRefreshesAndRetriesOnce() async throws { /* first 401 → token refresh → retry 200 */ }
@Test func quotaExceededMaps() async throws { /* 403 error_quota.json (reason "quotaExceeded") → throws .quotaExceeded */ }
@Test func durationsBatchFifty() async throws { /* 120 ids → 3 requests (50, 50, 20) */ }
@Test func unsubscribeNotFoundIsSuccess() async throws { /* DELETE → 404 subscriptionNotFound → no throw */ }
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "PKCE|OAuthConfig|GoogleOAuthService|DataAPIClient"` → fail.
- [ ] **Step 3: Implement.** Notes:
  - Endpoints: auth `https://accounts.google.com/o/oauth2/v2/auth`; token `https://oauth2.googleapis.com/token` (form-encoded, RFC 3986 unreserved set); revoke `https://oauth2.googleapis.com/revoke?token=…`.
  - Verifier: 64 random characters from `[A-Za-z0-9-._~]` (`SecRandomCopyBytes`); challenge = base64url(SHA-256(ASCII verifier)), no padding.
  - Account from the `id_token` payload (base64url with padding fixed); fall back to `GET https://openidconnect.googleapis.com/v1/userinfo`.
  - `GoogleOAuthService` is an actor. Concurrent refreshes share one in-flight `Task`. `accessToken()` refreshes when `isExpired(now:)`. `invalid_grant` → clear the store → `.notSignedIn`.
  - Keychain: `kSecClassGenericPassword`, service per init, account `"credentials"`, JSON-encoded `StoredCredentials`, `kSecAttrAccessibleAfterFirstUnlock`.
  - Data API base `https://www.googleapis.com/youtube/v3/`, `Authorization: Bearer`. Error JSON `error.errors[].reason` in `quotaExceeded`/`dailyLimitExceeded` → `.quotaExceeded`; 401 → one forced refresh + retry; other statuses → `.http(status:)`.
  - Calls:
    - subscriptions: `GET subscriptions?part=snippet&mine=true&maxResults=50&order=alphabetical[&pageToken]`, all pages.
    - subscribe: `POST subscriptions?part=snippet` with `{"snippet":{"resourceId":{"kind":"youtube#channel","channelId":…}}}` → `id`.
    - unsubscribe: `DELETE subscriptions?id=…`.
    - playlists: `GET playlists?part=snippet,contentDetails&mine=true&maxResults=50`, all pages → `PlaylistSummary(videoCount: contentDetails.itemCount)`.
    - playlistItems: `GET playlistItems?part=snippet,contentDetails&playlistId=…&maxResults=50[&pageToken]` → `VideoSummary(id: contentDetails.videoId, title, channel: (videoOwnerChannelId, videoOwnerChannelTitle), thumbnails, publishedAt: contentDetails.videoPublishedAt)`.
    - liked: `GET videos?part=snippet,contentDetails,statistics&myRating=like&maxResults=50[&pageToken]`.
    - getRating: `GET videos/getRating?id=` → `items[0].rating` (`unspecified` → `.none`).
    - rate: `POST videos/rate?id=&rating=`.
    - addToPlaylist: `POST playlistItems?part=snippet` with `{"snippet":{"playlistId":…,"resourceId":{"kind":"youtube#video","videoId":…}}}`.
    - durations: `GET videos?part=contentDetails&id=<≤50 comma-separated>&maxResults=50`.
- [ ] **Step 4: Run** → PASS; full package tests pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): Google OAuth (PKCE) and YouTube Data API client"`

## Task 6: Library, settings, filters, feeds, SponsorBlock, DeArrow

**Files:**
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/Library/{LibraryStore,SettingsStore,JSONFileStore}.swift`, `NoSlop/{ContentFilter,HashPrefix,SponsorBlockClient,DeArrowClient,SegmentSkipPlanner}.swift`, `Feeds/{SubscriptionFeedService,HomeFeedService}.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/Library/{LibraryStoreTests,SettingsStoreTests}.swift`, `NoSlop/{ContentFilterTests,SponsorBlockTests,SegmentSkipPlannerTests,DeArrowTests}.swift`, `Feeds/{SubscriptionFeedServiceTests,HomeFeedServiceTests}.swift`

**Interfaces:**
- Consumes: models, `HTTPClient`, `RSSFeedFetching`, `YouTubeAccountService`, `YouTubeService` (mocks from 1A, or small test doubles).
- Produces: the Task 6 API in "Implementation types".

- [ ] **Step 1: Write the failing tests**

```swift
// LibraryStoreTests (@MainActor, temp dir per test)
@Test func subscriptionsPersist() async { /* subscribe(Blender) → flush → new LibraryStore(directory: same) → isSubscribed("UCSMOQeBJ2RAnuFungnQOxLg") */ }
@Test func replaceGoogleSubscriptionsKeepsLocal() { /* local A, google B → replace([C(google), A(google)]) → A is .google, C added, B removed */ }
@Test func convertGoogleToLocal() { /* after convert, all sources .local, same ids */ }
@Test func recordProgressMovesToFront() { /* record v1, v2, then v1 → history.map(\.id) == ["v1","v2"]; v1 progress updated */ }
@Test func historyCappedAt5000() { /* 5001 records → 5000, oldest dropped */ }
@Test func searchHistoryDedupesCaseInsensitivelyCappedAt50() {}
@Test func playlistsCRUD() { /* create "Faves", add, remove, rename, delete; persisted across instances */ }
@Test func corruptLibraryFileIsMovedAside() async throws { /* write "{garbage" to history.json → init → history.isEmpty, file history.json.corrupt exists, subscriptions.json (valid) still loaded */ }

// SettingsStoreTests
@Test func decodesEmptySettingsObjectToDefaults() throws { /* defaults suite with "{}" under key → settings == AppSettings() */ }
@Test func decodesOldSettingsMissingNewKeys() throws { /* {"hideShorts":false} → hideShorts false, every other field default */ }
@Test func persistsOnChange() { /* set settings.autoplayNext = true → new store from same suite reads true */ }

// ContentFilterTests
// hideShorts drops isShort; hideMembersOnly drops isMembersOnly; hideLiveAndUpcoming drops isLive/isUpcoming;
// blockedChannels drops by channel id; blockedKeywords "minecraft" drops title "MINECRAFT Speedrun" (case/diacritic-insensitive), ignores blank keywords;
// hideWatchedInSubscriptions drops watched ids only in context .subscriptions; filter([SearchItem]) drops blocked .channel and playlists owned by blocked channels

// SponsorBlockTests
@Test func hashPrefix() { #expect(HashPrefix.sha256Prefix("dQw4w9WgXcQ") == "5f6b") }
@Test func segmentsFromPrefixResponse() async throws {
    // MockHTTP "api/skipSegments/" → sponsorblock_prefix.json (prefix 5f6b, 147 videos)
    // segments(videoID: "1H8_tk_dMLw") == [SponsorSegment(id: <UUID starting "e366ae05">, category: .sponsor, actionType: .skip, start: 3.662, end: 36.322)]
    // request path == "/api/skipSegments/<sha256Prefix("1H8_tk_dMLw")>", query has categories with all 9 raw values and actionTypes ["skip","mute","poi"]
}
@Test func noSegmentsForVideoNotInResponse() async throws { /* segments(videoID: "dQw4w9WgXcQ") with the same fixture → [] */ }
@Test func notFoundMeansNoSegments() async throws { /* 404 → [] */ }

// SegmentSkipPlannerTests
// autoSkip [10, 20): at 9.9 → nil; at 10.0 → segment; at 19.6 → nil (t must be < end - 0.5); alreadySkipped contains id → nil
// showInBar → never skipped, present in visibleSegments; ignore → absent from both; poi_highlight never auto-skipped; segments shorter than 1 s never skipped

// DeArrowTests
@Test func betterTitleForRickroll() async throws {
    // MockHTTP "api/branding/5f6b" → dearrow_prefix.json
    // betterTitle(videoID: "dQw4w9WgXcQ") == "Rick Astley - Never gonna give you up (official music video)"
}
@Test func titleRules() async throws { /* skips original == true; requires locked || votes >= 0; strips leading ">" and whitespace; none → nil */ }
@Test func cachesPerPrefix() async throws { /* second lookup with same prefix → no new request */ }

// SubscriptionFeedServiceTests
@Test func mergesSortsDedupes() async throws { /* 3 channels; RSS double returns overlapping videos → sorted by publishedAt desc, unique ids */ }
@Test func partialFailureStillReturns() async throws { /* one channel throws → others returned */ }
@Test func allFailThrows() async { /* every channel throws → throws */ }
@Test func fillsDurationsFromAccount() async throws { /* account double returns durations → items get durationSeconds; account throwing .notSignedIn → items unchanged, no throw */ }
@Test func cacheRoundTrip() async throws { /* after feed(), a new service with the same cacheURL returns the same items from cachedFeed() */ }

// HomeFeedServiceTests
@Test func interleavesRelatedOfRecentHistory() async { /* history [h1,h2,h3]; related(h1)=[a,b], related(h2)=[c,d], related(h3)=[e] → forYou starts [a,c,e,b,d] (before subscription inserts) */ }
@Test func excludesHistoryAndDuplicates() async {}
@Test func insertsFreshSubscriptionVideosEveryThirdSlot() async { /* subscription videos within 7 days, not in history, at indices 2, 5, 8… */ }
@Test func continueWatchingRules() async { /* progress >= 30 && !isFinished && !isShort; max 10; most recent first */ }
@Test func emptyHistoryUsesSubscriptions() async { /* forYou == first 60 subscription videos */ }
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "LibraryStore|SettingsStore|ContentFilter|SponsorBlock|SegmentSkip|DeArrow|SubscriptionFeed|HomeFeed"` → fail.
- [ ] **Step 3: Implement.** Notes:
  - `JSONFileStore` helper: `load<T: Decodable>(_ file: String, default: T) -> T` (decode failure → rename to `.corrupt`, return default) and `save` (`.atomic`, ISO 8601 dates).
  - LibraryStore files: `subscriptions.json`, `history.json`, `watch-later.json`, `playlists.json`, `search-history.json`. Load in `init`. Writes are debounced 0.5 s on a background task; `flush()` awaits them.
  - Settings: one JSON blob in `UserDefaults`, persisted on every `didSet`.
  - SponsorBlock: `GET {base}/api/skipSegments/{prefix}?categories=<JSON array>&actionTypes=["skip","mute","poi"]` (percent-encoded); keep entries whose `videoID` matches; unknown categories skipped; cache per video 1 h.
  - DeArrow: `GET {base}/api/branding/{prefix}` → object keyed by videoID. First `titles[]` entry with `original == false && (locked == true || votes >= 0)`, strip a leading `>`, trim. Cache the whole prefix response 1 h.
  - SubscriptionFeedService: a `TaskGroup` limited to `maxConcurrent`; per-channel RSS cache 15 min unless `forceRefresh`; durations from `account.durations` in batches of 50 for items without one (errors ignored); cache file written after each successful refresh.
  - HomeFeedService: seeds = most recent distinct non-Short history entries, up to `maxSeeds`; `videoDetails(id:)` fetched concurrently (errors ignored), first 12 related each; round-robin; dedupe; exclude history ids; subscription inserts at every third slot; cap 60.
- [ ] **Step 4: Run** → PASS; full package tests pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): library and settings persistence, filters, feeds, SponsorBlock, DeArrow"`

## Task 7: Downloads (chunked background downloads, muxing)

**Files:**
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/Downloads/{DownloadManager,DownloadEngine,FormatSelector,ChunkPlanner,MediaMuxer,DownloadTaskDescriptor}.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/Downloads/{FormatSelectorTests,ChunkPlannerTests,MediaMuxerTests,DownloadManagerTests,DescriptorTests,LiveDownloadTests}.swift`

**Interfaces:**
- Consumes: `StreamResolving`, `StreamInfo`, `StreamFormat`, models.
- Produces: the Task 7 API in "Implementation types".

- [ ] **Step 1: Write the failing tests**

```swift
// FormatSelectorTests — hand-built [StreamFormat] mirroring player_visionos_bigbuckbunny.json:
// avc1 299 1080p, 298 720p, 135 480p, 134 360p, 133 240p, 160 144p; vp9/av01 copies; audio 140 (isDRC false), 140 (isDRC true), 139, 251 opus
@Test func picks720() { /* .video(maxHeight: 720) → video.itag 298, audio itag 140 with isDRC == false */ }
@Test func picks1080() {}; @Test func picks360() {}
@Test func audioOnly() { /* video nil, audio 140 non-DRC */ }
@Test func fallsBackToDRCAudioWhenOnlyOption() {}
@Test func fallsBackToLowestAvc1WhenNoneUnderCap() { /* only 1080p avc1 available, maxHeight 360 → 1080p */ }
@Test func ignoresIncompatibleCodecs() { /* only vp9 + opus → nil */ }

@Test func chunkRanges() {
    #expect(ChunkPlanner.ranges(totalBytes: 26_214_400) == [0...10_485_759, 10_485_760...20_971_519, 20_971_520...26_214_399])
    #expect(ChunkPlanner.ranges(totalBytes: 0).isEmpty)
}
@Test func descriptorRoundTrip() { let d = DownloadTaskDescriptor(itemID: "dQw4w9WgXcQ-720", stream: .video, chunkIndex: 3); #expect(d.encoded == "dQw4w9WgXcQ-720|video|3"); #expect(DownloadTaskDescriptor(encoded: d.encoded) == d) }

@Test func zooClampedDuration() async throws {
    // fixtures zoo_video_144p.mp4 + zoo_audio.m4a (AVFoundation alone reports ~37.9 s / ~38.2 s for these)
    // mux(videoFile:audioFile:durationSeconds: 18.933, output: tmp.mp4) → AVURLAsset duration within 0.05 of 18.93; 1 video + 1 audio track
}
@Test func audioOnlyClampedDuration() async throws { /* mux(videoFile: nil, …, output: tmp.m4a) → duration ≈ 18.93 (not 38.17) */ }

// DownloadManagerTests (@MainActor) — sessionConfiguration: an ephemeral config whose protocolClasses = [StubURLProtocol] serving Range responses from fixture files
@Test func optionsFromStreamInfo() { /* availableOptions → labels ["1080p","720p","480p","360p","Audio only"], estimatedBytes = video + audio contentLength */ }
@Test func completesAndMuxes() async throws { /* enqueue zoo at .video(maxHeight: 144) with formats pointing at stubbed URLs → eventually .completed, file exists, progress 1, work dir removed */ }
@Test func chunkFailureMarksFailedAndCleansUp() async throws { /* stub returns 403 for chunk 1 (after retries) → .failed with errorMessage; no final file; work dir removed */ }
@Test func retryReResolvesStreams() async throws { /* failed item → retry → StreamResolving called again → completes */ }
@Test func restoredInFlightItemBecomesPaused() async throws { /* downloads.json with a .downloading item and no session tasks → after init: .paused */ }
@Test func deleteRemovesFileAndItem() async throws {}
@Test func persistsItems() async throws { /* new manager with same root sees completed items */ }

// LiveDownloadTests — skipped unless NOSLOP_LIVE == "1": real InnerTubeStreamResolver is NOT available here (stub) → resolve via a tiny inline visionOS player request, download jNQXAC9IVRw at 144p with an ephemeral session, check duration ≈ 19 s
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "FormatSelector|ChunkPlanner|MediaMuxer|DownloadManager|Descriptor"` → fail.
- [ ] **Step 3: Implement.** Notes:
  - Layout under `rootDirectory`: `downloads.json` (items); `.work/<itemID>/` for parts; finals `"<sanitized title> [<videoID>].mp4"` (or `.m4a`). Sanitize `/:\?%*|"<>` to `-`; max 80 characters. Set `isExcludedFromBackup = true`.
  - Session: `sessionConfiguration ?? .background(withIdentifier: "com.robinjungerich.noslopyt.downloads")` with `sessionSendsLaunchEvents = true`, `isDiscretionary = false`, `httpMaximumConnectionsPerHost = 4`.
  - One `downloadTask` per chunk with header `Range: bytes=a-b` and `taskDescription = DownloadTaskDescriptor.encoded`. In `didFinishDownloadingTo`, **move the file synchronously** (before returning) to `.work/<itemID>/<stream>.<index>.part`. Verify status 206 (or 200 for a single full-range chunk) and the expected byte count, otherwise count it as a failure. Retry a failed chunk at most twice.
  - Hop to the `@MainActor` manager for state changes. The delegate object is `@unchecked Sendable`, with a lock around its own state.
  - All parts present → `.merging` → concatenate in index order → `MediaMuxer.mux` with `durationSeconds = (video ?? audio).approxDurationMs / 1000` (fallback `StreamInfo.lengthSeconds`) → `.completed` → remove the work dir.
  - Progress = (completed chunk bytes + in-flight `totalBytesWritten`) / (video + audio `contentLength`).
  - `init` reconciles with `session.getAllTasks`: items in `.queued`/`.downloading`/`.merging` without tasks → `.paused`. `retry` re-resolves `StreamInfo`. `handleEventsForBackgroundURLSession` stores the completion handler and calls it from `urlSessionDidFinishEvents`.
  - `MediaMuxer`: `AVMutableComposition`. For each source, `insertTimeRange(CMTimeRange(start: .zero, duration: min(CMTime(seconds: durationSeconds, preferredTimescale: 600), track.timeRange.duration)))`, then export with `AVAssetExportPresetPassthrough` as `.mp4` (`.m4a` when there is no video) after removing any existing output. Use the async `export(to:as:)`.
- [ ] **Step 4: Run** → PASS; full package tests pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): chunked background downloads with duration-clamped muxing"`

## Task 8: Browse UI — design system polish, Home, Subscriptions, Search, Channel, Playlist, app icon

**Files:**
- Modify: `NoSlop/DesignSystem/*.swift` (keep every public name/initializer from the view table)
- Modify (replace placeholders): `NoSlop/Features/Home/*`, `NoSlop/Features/Subscriptions/*`, `NoSlop/Features/Search/*`, `NoSlop/Features/Channel/*`, `NoSlop/Features/Playlist/*` (views + `@Observable` view models in the same folders)
- Create: `NoSlop/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (+ `Contents.json`), generated by `scripts/make-icon.swift` (CoreGraphics, run with `swift scripts/make-icon.swift`)

**Interfaces:**
- Consumes: `AppEnvironment` (services, library, settings, `contentFilter`, `open`, `show`, `toggleSubscription`), `Router`, kit models.
- Produces: the Task 8 views in the view table.

Behaviour to build (spec "Experience"):
- **Home**: `env.homeFeed.homeFeed(history: env.library.history, subscriptionVideos: await env.subscriptionFeed.cachedFeed())`, filtered with `env.contentFilter`. Layout: "Continue watching" horizontal row of 260 pt cards with progress, then the vertical `VideoCardView` feed. Empty → welcome card (Search, Sign in with Google → Library, topic chips "Science", "Music", "Cooking", "Tech", "History", "Travel" → `env.show(.searchResults(query:))`). Pull to refresh. Toolbar: app wordmark "No Slop" leading, account avatar trailing (→ Library).
- **Subscriptions**: channel avatar strip (tap → channel), then the chronological feed (`feed(channels: env.library.subscriptions, forceRefresh:)`, cached first), filter `.subscriptions` context, pull to refresh, "Manage" → `.subscriptionsManager`. Empty → "Subscribe to channels to see their uploads here."
- **Search**: `.searchable` field with live suggestions (debounce 250 ms) and recent searches (`library.searchHistory`, clearable). A query that `YouTubeURL.extractURL` + `resolveLocally` / `youTube.resolve` recognises opens directly. Results with infinite scroll (`searchMore` when the last 5 rows appear). Filter sheet (type, sort, duration, upload date). Videos as `VideoCardView`, channels as `ChannelRowView`, playlists as `PlaylistRowView`. `SearchResultsView(query:)` reuses the results view.
- **Channel**: banner (aspect ~6:1), avatar, name, handle, "subscribers · videos", 3-line description (tap to expand), `SubscribeButton`; segmented tabs from `availableTabs`; infinite scroll with `channelMore`.
- **Playlist**: header (thumbnail, title, owner, count), "Play all" (`env.open(first, queue: rest)`), rows with infinite scroll.
- Every list: loading skeletons, `ErrorStateView` with Retry, `EmptyStateView`, `.videoContextMenu`, tap → `env.open(video, queue: [])`, channel tap → `env.show(.channel(id:))`.
- App icon: 1024×1024 opaque PNG. Rounded-square red gradient (#FF4E45 → #B3121A, top-left to bottom-right), a white rounded play triangle centred, and a small white four-point sparkle at top right. No text.

- [ ] **Step 1: Implement view models with `@Observable` and `async` loading via `.task {}`; keep business logic out of views.**
- [ ] **Step 2: Build** — app build command → `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Visual check** in a private simulator with `-mockServices YES`. Screens: Home, Subscriptions, Search with results (`noslop://search?q=blender`), Channel (`noslop://channel/UCSMOQeBJ2RAnuFungnQOxLg`), Playlist (`noslop://playlist/PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B`), in light and dark (`xcrun simctl ui <udid> appearance dark`). Fix anything clipped, misaligned or unreadable. Delete the device afterwards.
- [ ] **Step 4: Commit** — `git commit -m "feat(app): home, subscriptions, search, channel, playlist screens; design system; app icon"`

## Task 9: Watch details, Library, Downloads UI, Settings, Google sign-in UI

**Files:**
- Modify (replace placeholders): `NoSlop/Features/Watch/*` (`WatchDetailsView`, its view model, `DescriptionView`, `ChaptersView`, `CommentsSheet`, `DownloadOptionsSheet`, `AddToPlaylistSheet`), `NoSlop/Features/Library/*`, `NoSlop/Features/Downloads/*`, `NoSlop/Features/Settings/*` (incl. `GoogleSetupGuideView`), `NoSlop/Features/Account/*` (`ASWebAuthenticator`, `AccountHeaderView`)

**Interfaces:**
- Consumes: `AppEnvironment`, `PlayerController` public API (`setChapters`, `setUpNext`, `seek(to:)`, `open`), design-system views, kit models.
- Produces: the Task 9 views in the view table; `ASWebAuthenticator: WebAuthenticating`. It is `@MainActor final class`, uses `ASWebAuthenticationSession(url:callback: .customScheme(scheme))` with `prefersEphemeralWebBrowserSession = false`, provides a presentation anchor from the key window, and maps `.canceledLogin` → `NoSlopError.cancelled`.

Behaviour to build:
- **WatchDetailsView(video:)** shows the content under the player inside the expanded overlay. Loads `youTube.videoDetails(id:)`, then calls `player.setChapters` and `player.setUpNext(filtered related)`.
  - Title (DeArrow-aware, 2 lines, tap expands).
  - "views · date" line.
  - Channel row: avatar, name, subscribers, `SubscribeButton`; tap → `env.show(.channel)`.
  - Action chips: Like with count (when signed in: `account.rating`/`rate`; when signed out, tapping explains sign-in), Watch Later toggle, Save to playlist (`AddToPlaylistSheet`: local playlists, plus YouTube playlists when signed in → `account.addToPlaylist`), Download (`DownloadOptionsSheet` from `downloads.availableOptions(for: await streams.streamInfo)`, showing sizes as `ByteCountFormatter` strings; shows progress/"Downloaded" state when an item exists), Share.
  - Description card (collapsed 3 lines). Expanded, it renders an `AttributedString` with tappable links: timestamps → `player.seek`; video → `env.open`; channel → `env.show`; hashtag → `.searchResults`; url → `openURL`.
  - Chapters horizontal list (tap → seek). Comments teaser (count + first comment) → `CommentsSheet` (sort menu, infinite scroll, replies expand inline). Related list (`VideoRowView`) with `moreRelated` infinite scroll.
  - Errors: `ErrorStateView` with "Open on YouTube" (`video.watchURL`).
- **LibraryView**: `AccountHeaderView` (signed out: "Sign in with Google" → requires `settings.googleClientID`; when empty, opens `GoogleSetupGuideView`; signed in: avatar, name, email, Sign out). Rows: History, Watch Later, Downloads (with count), Your playlists (local, create/rename/delete), Liked videos and YouTube playlists (signed in only), Subscriptions (manager), Settings.
- History (grouped by day, swipe to remove, Clear all), Watch Later (reorderable, swipe to remove), LocalPlaylistView, LikedVideosView (paged `account.likedVideos`), AccountPlaylistsView and AccountPlaylistView (paged `playlistItems`), SubscriptionsManagerView (search filter, source badge "YouTube"/"Local", swipe to unsubscribe via `env.toggleSubscription`).
- **DownloadsView**: sections "Downloading" (progress bar, bytes, cancel), "Failed/Paused" (retry, delete), "Downloaded" (thumbnail, size, tap → `env.open`, swipe delete), storage total (`bytesOnDisk`).
- **SettingsView**: sections per spec "Experience → Settings", bound to `env.settingsStore.settings`.
  - Playback: Wi-Fi quality, cellular quality, default speed, autoplay next, background playback, auto PiP.
  - SponsorBlock: master toggle, per-category picker (Auto-skip / Show in bar / Ignore) with category colour dots.
  - De-clickbait titles.
  - Feed filters: toggles; blocked channels list with swipe to unblock; blocked keywords editor.
  - Account: client ID text field with validation via `GoogleOAuthConfig(clientID:)`; "How to set up Google sign-in" → `GoogleSetupGuideView`, which lists the spec's steps: create a project, enable YouTube Data API v3, consent screen with yourself as test user (or publish to avoid weekly re-login), iOS OAuth client with bundle ID `com.robinjungerich.noslopyt`, paste the client ID.
  - Storage: downloads size, Clear image cache (`URLCache.shared.removeAllCachedResponses()`), Clear watch history, Clear search history (confirmation dialogs).
  - About: version, credits, disclaimer.

- [ ] **Step 1: Implement views and view models.**
- [ ] **Step 2: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Visual check** in a private simulator with `-mockServices YES`. Watch details (`noslop://watch?v=dQw4w9WgXcQ`; under the Phase 1 placeholder overlay, temporarily present `WatchDetailsView` in a sheet via a `#if DEBUG` launch argument `-debugWatchDetails YES` handled inside your own files), Library, Downloads, Settings (`noslop://route/settings`), light and dark. Delete the device afterwards.
- [ ] **Step 4: Commit** — `git commit -m "feat(app): watch details, library, downloads, settings, Google sign-in UI"`

## Task 10: Player — playback, controls, background, PiP, Now Playing, captions, SponsorBlock, overlay

**Files:**
- Modify (replace stubs/placeholders): `NoSlop/Player/{PlayerController,PlayerOverlayContainer,PlayerHostView,MiniPlayerView,VideoSurfaceView,PlayerControlsView,SeekBarView,PlayerSettingsMenu,CaptionOverlayView,SkipNoticeView,NowPlayingCenter,AudioSessionController,PictureInPictureController}.swift`
- Modify (fill stubs): `NoSlopKit/Sources/NoSlopKit/Playback/{PlaybackRecovery,ChapterLookup}.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/Playback/{PlaybackRecoveryTests,ChapterLookupTests}.swift`

**Interfaces:**
- Consumes: `StreamResolving`, `SponsorBlockProviding`, `CaptionsProviding`, `SegmentSkipPlanner` (Task 6; a stub in this worktree, so the controller must work when it returns nil), `LibraryStore`, `SettingsStore`, `DownloadManager`, `WatchDetailsView(video:)` (Task 9; a placeholder here), kit models.
- Produces: the full `PlayerController` API (App layer contracts), `PlayerOverlayContainer()`, `PlayerHostView()`, `MiniPlayerView()`, `VideoSurfaceView`, `PlaybackRecovery`, `ChapterLookup`.

- [ ] **Step 1: Write the failing kit tests**

```swift
@Test func expiredURLReResolves() { #expect(PlaybackRecovery.action(for: .unknown, position: 42, streamExpiresAt: t0, now: t0.addingTimeInterval(10), attempt: 0) == .reresolveAndResume(at: 42)) }
@Test func forbiddenReResolves() { #expect(PlaybackRecovery.action(for: .forbidden, position: 10, streamExpiresAt: t0.addingTimeInterval(3600), now: t0, attempt: 0) == .reresolveAndResume(at: 10)) }
@Test func networkLossWaits() { #expect(PlaybackRecovery.action(for: .network, position: 5, streamExpiresAt: nil, now: t0, attempt: 0) == .waitForNetworkThenRetry(at: 5)) }
@Test func secondFailureShowsError() { #expect(PlaybackRecovery.action(for: .forbidden, position: 5, streamExpiresAt: nil, now: t0, attempt: 2) == .showError) }
@Test func decodeErrorShowsError() { #expect(PlaybackRecovery.action(for: .decode, position: 0, streamExpiresAt: nil, now: t0, attempt: 0) == .showError) }
@Test func chapterLookup() { /* chapters at 0, 60, 120: t 59.9 → first; t 60 → second; t 500 → third; [] → nil */ }
```

- [ ] **Step 2: Run** — `swift test --package-path NoSlopKit --filter "PlaybackRecovery|ChapterLookup"` → fail; then implement both → PASS.
- [ ] **Step 3: Implement `PlayerController`.**
  - `open`:
    1. Save progress for the previous video.
    2. Set `presentation = .expanded`, `state = .loading`.
    3. If `downloads.completedItem(videoID:)` exists, play its file (`isPlayingOffline = true`); otherwise `streams.streamInfo` → `AVPlayerItem(url: hlsURL)`. Fallback when there's no HLS: the best progressive `isAVFoundationCompatible` format.
    4. Start at `startAt` ?? the saved history progress (if > 10 s and not finished).
    5. Apply `rate` = `settings.defaultPlaybackRate`, and the quality cap (`preferredMaximumResolution` and `preferredPeakBitRate`, from `wifiQuality`/`cellularQuality` via `NWPathMonitor.isExpensive`).
    6. Load SponsorBlock segments when enabled and captions when `preferredCaptionLanguage` matches.
  - Periodic time observer (0.5 s):
    - `currentTime`, `bufferedTime` (`loadedTimeRanges`), captions (current cue), SponsorBlock auto-skip via `SegmentSkipPlanner` → `seek(to: end)` and set `skipNotice` (auto-dismiss 4 s; `undoSkip` seeks back to the segment start and remembers the id as skipped).
    - Save progress every 5 s and on pause, close and background.
  - Errors: map `AVPlayerItem.error` / `failedToPlayToEndTime` (an HTTP 403 in `errorLog().events` → `.forbidden`; `URLError` → `.network`) into `PlaybackRecovery.action`. Re-resolve → new item, seek to position.
  - End of item: `queue` first, then (autoplay on) the first unwatched up-next video, otherwise `.ended`.
  - Background, using `AudioSessionController` (`.playback`, `.moviePlayback`):
    - On `didEnterBackground` with `backgroundPlayback` on and PiP inactive → detach the player from the layer (keep playing). With `backgroundPlayback` off → pause.
    - On `willEnterForeground` → reattach.
    - `canStartPictureInPictureAutomaticallyFromInline = settings.autoPictureInPicture`.
  - `NowPlayingCenter`: title, channel, artwork (thumbnail), duration, elapsed, rate. Remote commands play/pause/toggle, skip ±10 s, `changePlaybackPosition`, next track (`playNext`).
  - `allowsExternalPlayback = true`.
- [ ] **Step 4: Implement the views.**
  - `PlayerOverlayContainer` (in `RootView`'s overlay). Hidden → nothing.
    - Expanded: full-screen panel over the tabs. `PlayerHostView` (16:9, safe-area top), then `WatchDetailsView(video:)` scrolling below. Drag down on the player > 120 pt or the chevron → minimize. Spring animations.
    - Minimized: a `MiniPlayerView` bar (64 pt: live video thumbnail-sized surface, title, channel, play/pause, close) pinned above the tab bar (`safeAreaInset` offset ≈ 49 pt + bottom inset). Tap → expand.
    - Fullscreen (`isFullscreen`, or landscape on iPhone): only `PlayerHostView`, edge to edge, black, status bar hidden, home indicator auto-hidden. `toggleFullscreen` requests landscape/portrait with `UIWindowScene.requestGeometryUpdate`.
  - `PlayerHostView`: `VideoSurfaceView` (`UIViewRepresentable` with an `AVPlayerLayer`, registering it with `PictureInPictureController`) plus `PlayerControlsView`.
    - Controls fade after 3 s while playing. Tap toggles them. Double-tap left/right half → `skip(by: ∓10)` with a ripple. Centre: play/pause and ±10 s. Top: chevron (minimize), title, AirPlay (`AVRoutePickerView`), captions toggle, settings menu (quality, speed 0.5/0.75/1/1.25/1.5/1.75/2, captions track). Bottom: `currentTime / duration` (`DurationFormatter`), `SeekBarView` (played red, buffered gray, SponsorBlock segments coloured by `category.colorHex`, chapter ticks, drag to scrub with a time bubble showing the chapter title), PiP and fullscreen buttons.
    - Buffering spinner; failed state with message, Retry and "Open on YouTube". `CaptionOverlayView` text on a translucent black background, bottom centre. `SkipNoticeView` "Skipped sponsor · Undo" capsule.
- [ ] **Step 5: Build and check playback in a private simulator with `-mockServices YES`** (`MockStreamResolver` → Apple's bipbop HLS stream; `MockSponsorBlock` segments at 30–45 s). `noslop://watch?v=aqz-KE-bpKQ` → video plays (take two screenshots 3 s apart; the frame changes and the time advances). Seek past 30 s → skip notice appears. Minimize → mini player visible above the tab bar. Delete the device.
- [ ] **Step 6: Commit** — `git commit -m "feat(app): player with HLS, background audio, PiP, Now Playing, captions, SponsorBlock, mini player"`

## Task 11: Integration — merge, wire, integration tests, README

**Files:**
- Merge: branches of Tasks 2–10 into `main`
- Modify: any file, only to fix integration compile/test failures (minimal changes; note each in the report)
- Create: `NoSlopKit/Tests/NoSlopKitTests/Integration/FacadeIntegrationTests.swift`
- Modify: `README.md` (final)

**Interfaces:**
- Consumes: everything.
- Produces: a `main` where `swift test --package-path NoSlopKit` and the app build both pass, and `.live()` uses only real services.

- [ ] **Step 1: Merge** each task branch (`git merge --no-ff <branch>`); resolve conflicts by keeping each owner's version of its own files.
- [ ] **Step 2: Write facade integration tests** (real parsers through `MockHTTPClient` + fixtures):

```swift
@Test func searchThroughFacade() async throws { /* InnerTubeYouTubeService.search("blender tutorial") with fixture → 24 items, first non-short video id "z-Xl9tGqH14" */ }
@Test func videoDetailsThroughFacade() async throws { /* next_aqz.json → title …, related 26 (6 shorts), comments token set */ }
@Test func channelThroughFacade() async throws { /* channel_blender_videos.json → header name "Blender", 30 videos */ }
@Test func playlistThroughFacade() async throws { /* playlist_sample.json → 14 videos */ }
@Test func commentsThroughFacade() async throws { /* comments_aqz.json → 20 comments */ }
```

- [ ] **Step 3: Run everything** — `swift test --package-path NoSlopKit` → all pass; `NOSLOP_LIVE=1 swift test --package-path NoSlopKit --filter Live` → pass; app build → `** BUILD SUCCEEDED **`, zero errors.
- [ ] **Step 4: README** — what the app does; requirements (Xcode 26.2+); `./scripts/bootstrap.sh`; open `NoSlop.xcodeproj`; set your team in `Config/Local.xcconfig` (copy the example); run on the simulator or your iPhone (free Apple ID: re-sign every 7 days; paid account: 1 year); Google sign-in setup steps (from the spec); running tests; how it works (visionOS client, HLS, visitorData); troubleshooting (bot check, unplayable videos, client version bumps in `ClientProfile.swift`); credits and disclaimer.
- [ ] **Step 5: Commit** — `git commit -m "chore: integrate parallel tasks, facade integration tests, README"`

## Task 12: QA in the simulator with live YouTube

**Files:**
- Modify: any file, only to fix defects found (each fix with a regression test where the logic lives in the kit)

**Interfaces:**
- Consumes: the integrated app.
- Produces: a defect list (found/fixed/open) in the final report, and screenshots in `docs/screenshots/`.

- [ ] **Step 1: Run the app with live services** on the iPhone 17 simulator. Walk through: Search "blender donut" → results without Shorts/ads → open a video → plays (HLS) within 5 s → seek, change speed, change quality → captions on a captioned video (`dQw4w9WgXcQ`) → minimize/expand → open channel from the watch page → subscribe locally → Subscriptions tab shows uploads → Home shows "Continue watching" and "For you" → download a video at 360p and play it with network disabled (simulator: turn off the Mac's Wi-Fi only if the owner agrees; otherwise verify `isPlayingOffline` by URL) → SponsorBlock skip on a video with sponsor segments (`1H8_tk_dMLw`) → background audio (`xcrun simctl` home button, audio keeps playing per logs/Now Playing) → Settings toggles persist across relaunch.
- [ ] **Step 2: Fix defects**, re-run the affected checks, `swift test`, app build.
- [ ] **Step 3: Save screenshots** (Home, Search, Watch, Channel, Library, Downloads, Settings, mini player, fullscreen) to `docs/screenshots/`.
- [ ] **Step 4: Commit** — `git commit -m "fix: QA defects; screenshots"`
