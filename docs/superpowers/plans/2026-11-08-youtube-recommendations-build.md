# YouTube Recommendations Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An optional "YouTube recommendations" connection in No Slop: YouTube's TV code sign-in next to the Google sign-in, YouTube's own Home feed (filtered, with the on-device mix as fallback), "Not interested" and "Don't recommend channel" from Home cards, reporting what is watched, and an in-app Diagnostics screen, ready for the owner to test with their actual account.

**Architecture:** A new NoSlopKit folder `Recommendations/` holds everything that talks to YouTube's TV interface: a config type, one `TVClient` actor that is the only place an Authorization header is set (own cookie-free session, host allow-list), the device-code auth service with its own Keychain item, the Home and panel parsers, the recommendations service with a recipe ladder, the watch tracker, queue and reporter. The app adds environment state, the connect UI, a Home branch, a menu item, player hooks and the Diagnostics screen. The Mac probe `scripts/tv-probe/` is the tested reference for every request shape and parsing rule: port from it.

**Tech Stack:** Swift 6.2 (Swift 6 language mode in the kit, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in the app), SwiftUI, iOS 18+, Swift Testing, XcodeGen synced folders, no third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-04-youtube-recommendations-design.md` (approved; Phase 0 replaced by this build and its "Diagnostics" section), with `docs/superpowers/specs/2026-11-04-youtube-recommendations-research.md`. Reference implementation: `scripts/tv-probe/tvprobe/*.py` and its tests.

## Global Constraints

- iOS 18+, Swift 6.2, Apple frameworks only; kit logic tested with Swift Testing (`./scripts/test.sh` or `swift test --package-path NoSlopKit -j 4`); the app target has no unit tests, so every decision lives in the kit.
- Anonymous traffic stays as it is: `InnerTubeClient` gets no auth option; nothing of the TV connection (token, its visitorData, its replies) reaches anonymous requests or their caches, and `noslop.visitorData` never rides on TV requests.
- The Authorization header is set only inside `TVClient`, only for hosts in `TVClientConfig.allowedHosts` = `www.youtube.com`, `youtubei.googleapis.com`, `oauth2.googleapis.com`.
- Tokens, device codes, client secrets, visitorData, feedback tokens, panel params and tracking values are never logged, never in error text, never in Diagnostics except as presence flags, never in committed fixtures.
- Playback never waits for, or fails because of, account traffic: player hooks return at once; network work runs in low-priority tasks.
- Home never shows an error screen because of YouTube: it falls back to the on-device mix with a notice.
- No ad, sponsored tile, promo or upsell shelf, Short or paid item from YouTube's Home reaches the screen; tracking commands that come with cards are never requested.
- The Google (Data API) sign-in, its Keychain item `com.robinjungerich.noslopyt.google` and `googleAccount` are untouched; neither connection changes the other.
- Error messages are short plain sentences pinned by tests, never Google sign-in wording for the TV connection.
- Every new `AppSettings` key is read in the lenient `init(from:)` and covered by the restart test.
- New files only where possible; shared files (`AppEnvironment.swift`, `Services.swift`, `MockServices.swift`, `Settings.swift`) change minimally and additively.
- Commits: conventional messages; last line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` after a blank line; never stage `.claude/` or `.compliify/`. Before each commit: the full kit suite and the arm64 check build (`xcodebuild -project NoSlop.xcodeproj -scheme NoSlop -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build -quiet -jobs 4`) with zero errors and zero warnings.
- The owner's Mac is a fanless MacBook Air: `-j 4` and `-jobs 4`, one build at a time per engineer, at most one private simulator at a time, never the owner's "BL-4".

Constants (from the probe, which copied them from MIT and Unlicense sources):

```swift
TVClientConfig.tvClientVersion      = "7.20260901.15.00"
TVClientConfig.tvUserAgent          = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
TVClientConfig.legacyClientVersion  = "5.20260901"
TVClientConfig.legacyUserAgent      = "Mozilla/5.0 (DirectFB; Linux x86_64) Cobalt/4.13031-qa (unlike Gecko) Starboard/1"
TVClientConfig.referer              = "https://www.youtube.com/tv"
TVAuth.deviceCodeURL = "https://www.youtube.com/o/oauth2/device/code"   // JSON body
TVAuth.tokenURL      = "https://www.youtube.com/o/oauth2/token"         // JSON body
TVAuth.deviceGrant   = "http://oauth.net/grant_type/device/1.0"
TVAuth.scope         = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
TVAuth.deviceModel   = "ytlr::"
TVAuth.revokeURLs    = ["https://oauth2.googleapis.com/revoke", "https://www.youtube.com/o/oauth2/revoke"]
TVAuth.tvPage        = "https://www.youtube.com/tv"   // client values: <script id="base-js">, first match of the YouTube.js pattern
TVKeychain.service   = "com.robinjungerich.noslopyt.youtube-tv"
```

## Review Focus

1. A TV token or TV visitorData on an anonymous request, or a Google token on a TV request: pinned in Task 1 (`anonymousRequestsCarryNoAuthorizationOrCookies`, `tvRequestsUseOnlyTheTVToken`).
2. YouTube's Home failing, signed out, empty or thin, and Home going blank or stuck on placeholders: pinned in Task 5 (`HomeSourceDecision` falls back) and Task 6 (the budget).
3. An ad, promo, Short (including one without markers) or paid item counted as a video: pinned in Task 4.
4. Reporting stalling or breaking playback, or reporting a video twice per viewing: pinned in Task 8 (tracker fires once per viewing) and Task 10 (hooks never await).
5. Disconnect leaving anything behind (tokens, card handles, cached Home, pending reports): pinned in Task 3 (`disconnectClearsTheStore`), Task 5 (`clearAccountDataForgetsHandlesAndCache`) and Task 9 (`disconnectDropsThePendingReports`).

---

## Part A: Foundation (one engineer at a time, in order)

### Task 1: TV transport and config

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/TVClientConfig.swift`, `NoSlopKit/Sources/NoSlopKit/Recommendations/TVClient.swift`
- Modify: `NoSlopKit/Sources/NoSlopKit/Support/HTTPClient.swift` (add `public static func isolated() -> URLSessionHTTPClient`)
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/TVClientTests.swift`, `NoSlopKit/Tests/NoSlopKitTests/InnerTube/AnonymousRequestsTests.swift`

**Interfaces:**
- Produces: `public enum TVProfile: Sendable { case tv, legacy }` with `clientVersion`, `userAgent`; `public enum TVClientConfig` with the constants above, `allowedHosts: Set<String>`, `homeRecipes: [TVHomeRecipe]` (Task 5 uses it) and `static func context(_ profile: TVProfile, visitorData: String?, language: String, region: String) -> JSON` (the probe's `innertube.context(variant: "full")`).
- Produces: `public protocol TVTokenProviding: Sendable { func accessToken() async throws -> String; func refreshAfterUnauthorized() async throws -> String }` (Task 2's auth service conforms).
- Produces: `public actor TVClient { public init(http: any HTTPClient, tokens: any TVTokenProviding); public func post(_ endpoint: String, body: JSON, profile: TVProfile = .tv, host: String = "www.youtube.com", visitorData: String? = nil) async throws -> JSON?; public func get(_ url: URL, profile: TVProfile, authorized: Bool) async throws -> Int }`. `post` sends to `https://<host>/youtubei/v1/<endpoint>?prettyPrint=false` with `Content-Type: application/json`, the profile's User-Agent, `Referer`, `Authorization: Bearer <token>` and `X-Goog-Visitor-Id` when given, no `key`; an empty or 204 body returns nil; a 401 calls `refreshAfterUnauthorized()` once and retries, a second 401 throws `NoSlopError.recommendationsNotConnected`; other non-2xx throw `NoSlopError.http(status:)`; a host outside `allowedHosts` throws before anything is sent. `get` returns the status only (for pings) and sends the token only when `authorized`.

- [ ] **Step 1: Write the failing tests** with `MockHTTPClient`: `tvRequestsCarryTheBearerAndTheTVHeaders` (exact URL, method, the five headers, no `key=`), `aHostOutsideTheAllowListIsRefused` (no request recorded), `anEmptyBodyIsNotAnError`, `a401RefreshesOnceThenFails` (two requests, the second with the refreshed token; a second 401 throws `.recommendationsNotConnected`), `tvRequestsUseOnlyTheTVToken`, and in `AnonymousRequestsTests` `anonymousRequestsCarryNoAuthorizationOrCookies` (drive `InnerTubeClient.post` and assert no `Authorization` and no `Cookie` header on what was sent).
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement** `TVClientConfig`, `TVClient` and `URLSessionHTTPClient.isolated()` (a second session from the same cookie-free, cache-free configuration as the default one).
- [ ] **Step 4: Run the full kit suite and the check build.**
- [ ] **Step 5: Commit** `feat(recommendations): TV client config and the only Authorization-carrying transport`.

### Task 2: TV sign-in and its Keychain item

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/TVAuthService.swift`, `TVCredentials.swift`, `NoSlopKit/Sources/NoSlopKit/Protocols/Recommendations.swift`
- Modify: `NoSlopKit/Sources/NoSlopKit/Models/Errors.swift` (add `.recommendationsNotConnected`), `NoSlopKit/Tests/NoSlopKitTests/Foundation/ModelsTests.swift` (its pinned text)
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/TVAuthServiceTests.swift`, `TVTokenStoreTests.swift`

**Interfaces:**
- Consumes: `TVClientConfig`, `TVTokenProviding` (Task 1).
- Produces: `public struct TVCredentials: Codable, Sendable` (accessToken, refreshToken, expiresAt, scope, clientID, clientSecret, accountName: String?, connectedAt; `description` shows no secrets); `public protocol TVTokenStoring: Sendable` (`load() throws -> TVCredentials?`, `save(_:) throws`, `clear() throws`) with `KeychainTVTokenStore(service: TVKeychain.service)` (after first unlock, not synced) and `InMemoryTVTokenStore`.
- Produces: `public struct TVAccount: Sendable, Equatable { public let name: String?; public let connectedAt: Date }`; `public struct TVSignInPrompt: Sendable { public let userCode: String; public let verificationURL: URL; public let expiresAt: Date }` (the device code stays internal).
- Produces: `public protocol RecommendationsAuthProviding: TVTokenProviding { func currentAccount() async -> TVAccount?; func beginSignIn() async throws -> TVSignInPrompt; func completeSignIn(_ prompt: TVSignInPrompt) async throws -> TVAccount; func secondsLeft() async -> Int?; func disconnect() async -> Bool }` in `Protocols/Recommendations.swift`; `public actor TVAuthService: RecommendationsAuthProviding` with `init(http: any HTTPClient, store: any TVTokenStoring, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`.

Behaviour (port `scripts/tv-probe/tvprobe/oauth.py`): client values from the TV page (Cobalt user agent, `base-js` script, first pattern match), cached with the credentials; a random device id per install under `noslop.tvDeviceID`; `beginSignIn` returns the server's `verification_url` + `?user_code=`; `completeSignIn` polls at `max(5, interval)` seconds plus 5 per `slow_down`, decides from the JSON `error` field whatever the status, throws `.oauth("The code expired. Start again.")` or `.oauth("The sign-in was declined.")`, stops at expiry, honours cancellation; tokens refresh when under 300 s are left, one refresh at a time; a refresh that returns a refresh token keeps it; `invalid_grant`, `invalid_client` or `unauthorized_client` clear the store and throw `.recommendationsNotConnected`; network errors never clear; `accountName` comes from `POST account/accounts_list` with the TV context when it answers (best effort); `disconnect` tries both revoke URLs (form `token=` then JSON `{"token":...}`), clears the store whatever they answer and returns whether one said 200.

- [ ] **Step 1: Write the failing tests** (`MockHTTPClient`, injected clock and sleep): `theFirstClientPairWins`, `pollingHonoursIntervalAndSlowDown` (sleeps 5, 10, 10 for replies pending, slow_down, pending, 200 with interval 3), `aDeclinedOrExpiredCodeStops` (exact messages), `aRefreshKeepsANewRefreshToken`, `concurrentCallersShareOneRefresh` (two `accessToken()` calls near expiry, one token request), `anEndedGrantClearsTheStoreAndSaysNotConnected`, `aNetworkErrorNeverClearsTheStore`, `disconnectClearsTheStoreEvenWhenRevokeFails`, `credentialsDescriptionShowsNoSecrets`; in `TVTokenStoreTests` the in-memory round trip and, gated like the existing Keychain suite, the Keychain round trip on a unique service name.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full kit suite and the check build.**
- [ ] **Step 5: Commit** `feat(recommendations): YouTube TV code sign-in with its own Keychain item`.

### Task 3: App wiring, connect UI, settings and the Diagnostics screen

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/RecommendationsStatus.swift`, `NoSlopKit/Sources/NoSlopKit/Mocks/MockRecommendations.swift`, `NoSlop/Features/Recommendations/RecommendationsConnectFlow.swift`, `RecommendationsCodeSheet.swift`, `RecommendationsRow.swift`, `RecommendationsSettingsSection.swift`, `RecommendationsDiagnosticsView.swift`
- Modify: `NoSlopKit/Sources/NoSlopKit/Protocols/Recommendations.swift`, `NoSlopKit/Sources/NoSlopKit/Models/Settings.swift`, `NoSlop/App/AppEnvironment.swift`, `NoSlop/Features/Library/LibraryView.swift` (first section, under `AccountHeaderView()`), `NoSlop/Features/Settings/SettingsView.swift` (after `AccountSettingsSection()`), `NoSlop/DesignSystem/DebugLaunchHooks.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/MockRecommendationsTests.swift`, `NoSlopKit/Tests/NoSlopKitTests/Library/SettingsStoreTests.swift`, `Foundation/ModelsTests.swift`

**Interfaces:**
- Produces (kit, `RecommendationsStatus.swift`): `public struct HomeLoadReport: Codable, Sendable, Equatable` (recipe: String, status: Int?, loggedIn: Bool?, videos: Int, shorts: Int, skipped: [String: Int], unknown: [String: Int], usedYouTube: Bool, at: Date); `public struct CardActionReport` (kind: String, status: Int?, accepted: Bool, at: Date); `public struct WatchReportOutcome` (status: String, playerStatus: String?, hasEI: Bool, hasVM: Bool, hasOF: Bool, pingStatuses: [Int], at: Date); `public struct RecommendationsDiagnostics: Codable, Sendable, Equatable` (lastHome, lastCardAction, lastReport, pausedReporting: Bool, tokenSecondsLeft: Int?).
- Produces (kit, in `Protocols/Recommendations.swift`):
  - `public struct TVHomePage: Sendable { public var loggedIn: Bool?; public var videos: [VideoSummary]; public var cardIDs: Set<String>; public var continuation: String?; public var report: HomeLoadReport }`
  - `public protocol RecommendationsProviding: Sendable { func homePage(continuation: String?) async throws -> TVHomePage; func notInterested(videoID: String) async throws; func dontRecommendChannel(videoID: String, channelID: String?, channelName: String) async throws -> Bool; func diagnostics() async -> RecommendationsDiagnostics; func diagnosticsSample() async -> JSON; func clearAccountData() async }`
  - `public struct WatchViewing: Sendable, Hashable { public let id: UUID; public let videoID: String; public let lengthSeconds: Double }`; `public enum WatchEvent: Sendable { case qualified(position: Double), progress(position: Double), ended(position: Double, finished: Bool) }`
  - `public protocol WatchReporting: Sendable { func record(_ event: WatchEvent, for viewing: WatchViewing) async; func replayPending() async; func outcome() async -> WatchReportOutcome?; func isPaused() async -> Bool; func clearAccountData() async }`
  - Placeholders for Part A only: `public struct UnavailableRecommendations: RecommendationsProviding` (throws `.recommendationsNotConnected`, empty diagnostics) and `public struct NoWatchReporter: WatchReporting` (does nothing). Parts B and C replace them in `live()`.
- Produces (kit mocks): `public actor MockRecommendationsAuth: RecommendationsAuthProviding` (`init(connected: Bool = false, delay: Duration = .seconds(2))`; `beginSignIn` returns code `"MOCK-CODE"` with `https://www.google.com/device?user_code=MOCK-CODE`; `completeSignIn` succeeds after `delay`, account name "Mock Account"); `public actor MockRecommendations: RecommendationsProviding` (page 1 built from `SampleData` plus, built inside the mock, one Short, one members-only, one live and one video of a channel named "Blocked Example", all in `cardIDs`, a continuation to a page 2; records card actions); `public actor MockWatchReporter: WatchReporting` (records events).
- Produces (settings): `AppSettings.showYouTubeHome = true`, `tellYouTubeAboutHiding = true`, `sendWatchesToYouTube = true`, read leniently.
- Produces (app): on `AppEnvironment` new init parameters `recommendationsAuth: any RecommendationsAuthProviding`, `recommendations: any RecommendationsProviding`, `watchReporter: any WatchReporting`; state `private(set) var recommendationsAccount: TVAccount?`, `var recommendationCardIDs: Set<String> = []`, `var recommendationsDiagnostics = RecommendationsDiagnostics()`; methods `refreshRecommendationsAccount() async` (at launch, Keychain only), `disconnectRecommendations() async -> Bool` (calls `disconnect`, `clearAccountData` on both services, empties `recommendationCardIDs`, sets the account nil, refreshes Home), `refreshRecommendationsDiagnostics() async`. A TV failure never calls `reconcileGoogleAccount`; a Google sign-out never touches the TV connection. `live()` builds `TVAuthService(http: URLSessionHTTPClient.isolated(), store: KeychainTVTokenStore())`, `UnavailableRecommendations()` and `NoWatchReporter()`, the last two on separate lines with a comment line between them (Parts B and C each replace one of those lines and must not touch the other); `preview()` builds the three mocks in both its `#if DEBUG` and `#else` branches, with DEBUG flags `-recommendationsConnected YES` and `-recommendationsDelay <seconds>` documented in `DebugLaunchHooks.swift`.
- UI: `RecommendationsConnectFlow` (@MainActor @Observable: prompt, isWorking, errorMessage, connect(using:), cancel()) drives `RecommendationsCodeSheet` (code in large type, Copy Code, "Open Google's page" via `openURL`, a countdown to `expiresAt`, Cancel; the line "Google's page will say YouTube on TV. That's expected."; polling resumes at once when the scene becomes active; closing the sheet cancels). `RecommendationsRow` in Library: disconnected "YouTube recommendations" with "Connect to see your own YouTube Home here" and a Connect button; connected "Connected" plus the account name when known. `RecommendationsSettingsSection` ("YouTube recommendations"): status, Connect or Disconnect (confirmation: "Disconnect YouTube recommendations? Home goes back to the mix made on this device."), the three switches with the labels "Show YouTube's Home", "Tell YouTube when I hide a video or a channel from Home", "Send what I watch to YouTube", a link to Diagnostics, and the footer "Uses YouTube's TV sign-in, not an official API, separate from the Google sign-in above. It can be another Google account and it can stop working when YouTube changes something." `RecommendationsDiagnosticsView` lists `RecommendationsDiagnostics` in plain rows (presence flags only) and a "Save diagnostics" button that writes `JSON` from `diagnosticsSample()` to `Documents/Diagnostics/recommendations-<yyyyMMdd-HHmmss>.json` and says where. Rows stack at accessibility sizes, like the other Settings rows.

- [ ] **Step 1: Write the failing kit tests:** `MockRecommendationsTests` (the mock connect finishes after its delay; page 1 holds the four special videos in `cardIDs`; card actions are recorded), the settings restart test extended with the three keys, defaults in `ModelsTests`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement** the kit types, the environment wiring and the five views.
- [ ] **Step 4: Run the full kit suite and the check build.** Then in one private iPhone 17 simulator with `-mockServices YES`: connect from Library (the sheet shows MOCK-CODE and the countdown, then Connected after about 2 s), the Settings section with its switches, Disconnect with its confirmation, the Diagnostics screen and Save diagnostics (the file appears), at normal and accessibility-extra-extra-extra-large text, light and dark. Screenshots under `.build/screens/`.
- [ ] **Step 5: Commit** `feat(recommendations): connect YouTube recommendations from Library and Settings, diagnostics screen`.

## Part B: Home and card actions (lane H; runs beside Part C)

### Task 4: TV Home parser

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/TVHomeParser.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/TVHomeParserTests.swift`, hand-built fixtures `NoSlopKit/Tests/NoSlopKitTests/Fixtures/tvsynthetic_home_mixed.json`, `tvsynthetic_home_signed_out.json`, `tvsynthetic_home_section_cont.json`, `tvsynthetic_home_lockups.json` (adapt the probe's `scripts/tv-probe/tests/fixtures/` JSON; never real captures)

**Interfaces:**
- Produces: `public struct TVCardHandle: Sendable, Hashable { public let panelID: String; public let params: String }` (its `description` hides both); `public struct TVHomeParse: Sendable { public var loggedIn: Bool?; public var videos: [VideoSummary]; public var handles: [String: TVCardHandle]; public var sectionContinuation: String?; public var shorts: Int; public var skipped: [String: Int]; public var unknown: [String: Int] }`; `public enum TVHomeParser { public static func parse(_ reply: JSON) -> TVHomeParse }` for first pages and section continuations.

Rules (port `tvprobe/home.py`): find `tvSurfaceContentRenderer` wherever it sits; walk `sectionListRenderer` (or `sectionListContinuation`) shelves; never descend into `adSlotRenderer`; skip `promoShelfRenderer`, shelves with `tvhtml5Metadata.hideLogo`, `gridButtonRenderer`, `searchBarRenderer`, `feedNudgeRenderer`, channel and EDU tiles, paid items (YPC badge); accept `tileRenderer` video tiles and `lockupViewModel` video lockups; Shorts by shelf type, content type, style, `reelWatchEndpoint`, overlay style, `LOCKUP_CONTENT_TYPE_SHORT`, or a missing duration on a tile that is not live (Shorts are counted, not returned); `isLive`/`isUpcoming` from the overlay style, members-only from badges; channel name from `lines[0]` when present, channel id nil unless the tile has one; `logged_in` from the `GFEEDBACK` param; the panel handle from `onLongPressCommand.showEngagementPanelEndpoint` (`identifier.tag`, `globalConfiguration.params`); unknown renderer names counted.

- [ ] **Step 1: Write the failing tests:** `aMixedPageKeepsOnlyRealVideos` (the ad's inner tile is not a video; the members-only and live tiles are videos with their flags; the Short shelf is counted in `shorts`), `aTileWithoutDurationThatIsNotLiveIsAShort`, `aSignedOutPageSaysSo` (`loggedIn == false`, no videos), `lockupsAreReadToo`, `aSectionContinuationIsReadWithItsNextToken`, `cardHandlesAreKeptPerVideo`, `unknownRenderersAreCountedNotShown`.
- [ ] **Step 2: Run them and see them fail.** **Step 3: Implement.** **Step 4: Full kit suite.** **Step 5: Commit** `feat(recommendations): tolerant parser for YouTube's TV Home`.

### Task 5: Recommendations service, recipe ladder, Home decision, diagnostics sample

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/RecommendationsService.swift`, `HomeSourceDecision.swift`, `TVScrubber.swift`
- Modify: `NoSlop/App/AppEnvironment.swift` (`live()` uses `RecommendationsService` instead of `UnavailableRecommendations`)
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/RecommendationsServiceTests.swift`, `HomeSourceDecisionTests.swift`, `TVScrubberTests.swift`

**Interfaces:**
- Consumes: `TVClient` (Task 1), `TVHomeParser` (Task 4), `RecommendationsProviding` (Task 3).
- Produces: `public struct TVHomeRecipe: Sendable, Hashable { public let browseID: String; public let host: String }` with `TVClientConfig.homeRecipes = [("FEwhat_to_watch", "www.youtube.com"), ("default", "www.youtube.com"), ("FEwhat_to_watch", "youtubei.googleapis.com")]`; `public actor RecommendationsService: RecommendationsProviding` with `init(client: TVClient, language: String, region: String)`.
- Produces: `public enum HomeSourceDecision { public static func decide(pages: [TVHomePage], filter: (VideoSummary) -> Bool, excluded: Set<String>) -> Result }` with `public struct Result: Sendable { public let useYouTube: Bool; public let videos: [VideoSummary]; public let continuation: String? }`: YouTube is used when page 1 is logged in and at least 8 unique videos pass `filter` and are not in `excluded` within the given pages (at most 3).
- Produces: `public enum TVScrubber { public static func scrub(_ reply: JSON) -> JSON; public static func leaks(_ text: String) -> [String] }` (port of `tvprobe/scrub.py`).

Behaviour: `homePage(continuation: nil)` tries the remembered recipe first, then the ladder, and uses the first recipe whose reply parses as logged in with at least one video; it remembers it in memory (and in UserDefaults `noslop.tvHomeRecipe`); continuations go to the recipe's host with the visitorData of the first reply; handles from every page are kept in the actor (cleared on `clearAccountData`); the last three raw replies are kept in memory only for `diagnosticsSample()`, which returns them scrubbed; `diagnostics()` fills `lastHome` (and the other fields Parts B and C report); each call records a `HomeLoadReport`.

- [ ] **Step 1: Write the failing tests:** `theLadderMovesOnFromASignedOutReply` (first recipe signed out, second has videos: the second is used and remembered), `aRememberedRecipeIsTriedFirst`, `continuationsUseTheFirstRepliesVisitorData`, `diagnosticsSampleIsScrubbed` (no token-like strings, no IPs, `TVScrubber.leaks` is empty), `clearAccountDataForgetsHandlesAndCache`, decision tests `eightVisibleVideosUseYouTube`, `aThinOrSignedOutHomeFallsBack`, `continueWatchingVideosAreNotCounted`.
- [ ] **Step 2: Run them and see them fail.** **Step 3: Implement.** **Step 4: Full kit suite and check build.** **Step 5: Commit** `feat(recommendations): Home with a recipe ladder, the source decision and scrubbed diagnostics`.

### Task 6: Home in the app, blocked channels by name

**Files:**
- Modify: `NoSlop/Features/Home/HomeViewModel.swift`, `NoSlop/Features/Home/HomeView.swift`, `NoSlopKit/Sources/NoSlopKit/NoSlop/ContentFilter.swift`, `NoSlopKit/Sources/NoSlopKit/Models/Library.swift` (`BlockedChannel` gains an optional `handle`, decoded leniently), `NoSlop/DesignSystem/VideoContextMenu.swift` (`ChannelBlocking.block` resolves a missing channel id through `env.youTube.videoDetails(id:)` before blocking)
- Test: `NoSlopKit/Tests/NoSlopKitTests/NoSlop/ContentFilterTests.swift`, `Foundation/ModelsTests.swift`

**Interfaces:**
- Consumes: `env.recommendations.homePage`, `HomeSourceDecision`, `env.recommendationsAccount`, `settings.showYouTubeHome`.
- Behaviour: when connected and the switch is on, `HomeViewModel.run` shows Continue watching from history at once, asks YouTube for up to 3 pages within about 8 seconds, decides with `HomeSourceDecision` (filter = `env.contentFilter`, excluded = Continue watching ids plus finished videos), and either publishes YouTube's videos (and `env.recommendationCardIDs`) or falls through to today's on-device path with the notice "Showing the mix made on this device. YouTube's Home didn't load." (Retry) through the existing `RefreshFailureBanner`. YouTube's result is kept about 20 minutes; it refreshes on pull to refresh, on returning after that time, and on connect and disconnect, not on history changes. Further pages come through `FeedPages`/`FeedFooter` with the same filter. Every load updates `env.recommendationsDiagnostics`. `ContentFilter` also hides a video whose `channel?.id` is nil (or empty) when its channel name (normalised: lowercased, trimmed, folded diacritics) or handle matches a blocked channel.

- [ ] **Step 1: Write the failing kit tests:** `aBlockedChannelHidesItsVideosByNameWhenTheIDIsMissing`, `aBlockByIDDoesNotHideAnotherChannelWithTheSameNameThatHasAnID`, `blockedChannelsWithoutAHandleStillDecode`.
- [ ] **Step 2: Run them and see them fail.** **Step 3: Implement** the kit change and the app branch. **Step 4: Full kit suite, check build,** then a simulator check with `-mockServices YES -recommendationsConnected YES`: Home shows the mock YouTube Home without the Short, the members-only video and the "Blocked Example" channel once it is blocked; Continue watching on top; scrolling loads page 2; with `-recommendationsConnected YES -mockOffline YES` the notice and the on-device mix appear. **Step 5: Commit** `feat(home): YouTube's Home when connected, with the on-device mix as fallback`.

### Task 7: Not interested and Don't recommend channel

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/TVPanelParser.swift`
- Modify: `RecommendationsService.swift` (the two card actions), `NoSlop/DesignSystem/VideoContextMenu.swift` (menu item and the block hook), `NoSlop/Features/Home/HomeViewModel.swift` (dismissed ids)
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/TVPanelParserTests.swift`, `RecommendationsServiceTests.swift`, fixture `tvsynthetic_panel_menu.json`

**Interfaces:**
- Produces: `public struct TVPanelFindings: Sendable { public let notInterested: String?; public let dontRecommend: String?; public let channelID: String?; public let channelName: String?; public let handle: String?; public let ambiguous: Bool }` (description hides the tokens); `public enum TVPanelParser { public static func parse(_ reply: JSON) -> TVPanelFindings }` (port of `tvprobe/panel.py`, including its rule for the dismissal follow-up and for several channel candidates).
- Behaviour: `notInterested(videoID:)` posts `get_panel` with the card's handle, then `feedback` with the Not interested token; `dontRecommendChannel` does the same with the Don't recommend token only when the panel's channel id equals `channelID`, or, when `channelID` is nil, the panel's channel name equals `channelName`; otherwise it sends nothing and returns false; both record a `CardActionReport`; a video without a handle throws `NoSlopError.unavailable(reason: "YouTube didn't offer this for that video.")`. In the app, the video menu shows "Not interested" (system image `hand.thumbsdown`) only when connected, the switch is on and the video id is in `env.recommendationCardIDs`; it hides the card at once (a session set of dismissed ids honoured by Home's filter) and sends in a low-priority task; blocking a channel from a menu whose video is in `recommendationCardIDs` also sends Don't recommend in the background; nothing undoes the local action, and the result goes to Diagnostics.

- [ ] **Step 1: Write the failing tests:** `bothActionsAreFoundByStructure`, `twoCandidatesAreAmbiguousAndSendNothing`, `notInterestedSendsThePanelsToken` (exact `get_panel` and `feedback` bodies), `dontRecommendRefusesAnotherChannel`.
- [ ] **Step 2: Run them and see them fail.** **Step 3: Implement.** **Step 4: Full kit suite, check build,** simulator check with mocks (the menu item appears only on mock YouTube cards; the card disappears; the mock records the action; Diagnostics shows it). **Step 5: Commit** `feat(recommendations): Not interested and Don't recommend channel from Home cards`.

## Part C: Reporting (lane R; runs beside Part B)

### Task 8: Watch tracker and the pending queue

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/WatchReportTracker.swift`, `PendingWatchReports.swift`
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/WatchReportTrackerTests.swift`, `PendingWatchReportsTests.swift`

**Interfaces:**
- Produces: `public struct WatchReportTracker: Sendable, Equatable { public init(lengthSeconds: Double, isLive: Bool, isShort: Bool); public mutating func tick(position: Double, isPlaying: Bool) -> WatchEvent? }`: adds played media time only for steps between 0 and 2 seconds while playing (seeks, skips, pauses and stalls add nothing), returns `.qualified(position:)` once when 30 s are played (or at the end for a video shorter than 30 s), then `.progress(position:)` every 240 s of played time, never anything for live streams or Shorts; `public func closing(position: Double) -> WatchEvent?` returns `.ended(position:, finished:)` when qualified (`finished` within the last 5% of the length).
- Produces: `public final class PendingWatchReports: @unchecked Sendable` over a JSON file (`init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init)`; `add(_ entry: PendingWatchReport)`, `all() -> [PendingWatchReport]`, `remove(id:)`, `removeAll()`), written synchronously on every change with atomic writes, lenient decoding, at most 50 entries, entries older than 7 days dropped; `public struct PendingWatchReport: Codable, Sendable, Identifiable` (id: UUID, videoID, lengthSeconds, position, finished, createdAt).

- [ ] **Step 1: Write the failing tests:** `thirtySecondsOfPlayingQualifyOnce` (0.5 s ticks), `seeksAndSkipsDoNotCount` (a jump of 60 s adds nothing), `pausesDoNotCount`, `aShortVideoQualifiesAtItsEnd`, `liveStreamsAndShortsNeverReport`, `progressEveryFourMinutes`, `closingSaysFinishedInTheLastFivePercent`; `PendingWatchReportsTests`: survives reopening, caps at 50, drops entries older than 7 days, a damaged file starts empty without crashing.
- [ ] **Step 2: Run them and see them fail.** **Step 3: Implement.** **Step 4: Full kit suite.** **Step 5: Commit** `feat(recommendations): played-time watch tracker and the pending report queue`.

### Task 9: Watch reporter

**Files:**
- Create: `NoSlopKit/Sources/NoSlopKit/Recommendations/TVWatchReporter.swift`, `TVTracking.swift`
- Modify: `NoSlop/App/AppEnvironment.swift` (`live()` uses `TVWatchReporter` instead of `NoWatchReporter`)
- Test: `NoSlopKit/Tests/NoSlopKitTests/Recommendations/TVWatchReporterTests.swift`, `TVTrackingTests.swift`, fixture `tvsynthetic_player_signed.json`

**Interfaces:**
- Produces: `public enum TVTracking { public static func signatureTimestamp(fromHomepage html: String) -> Int?; public static func values(fromPlayer reply: JSON) -> (status: String?, playbackURL: URL?, watchtimeURL: URL?, hasEI: Bool, hasVM: Bool, hasOF: Bool); public static func pingURL(base: URL, kind: Kind, docid: String, length: Double, cpn: String, cmt: Double, st: Double?, et: Double?, final: Bool) -> URL; public static func newCPN() -> String }` (port of `tvprobe/report.py`: keep every base query item, set `ns=yt`, `ver=2`, three-decimal times, `final=1` only when final, host www.youtube.com).
- Produces: `public actor TVWatchReporter: WatchReporting` with `init(client: TVClient, http: any HTTPClient, queue: PendingWatchReports, isEnabled: @escaping @Sendable () async -> Bool, now: @escaping @Sendable () -> Date = Date.init)`.
- Behaviour: on `.qualified` for a viewing: write a pending entry first; fetch the STS from `https://www.youtube.com/` (anonymous, cached one hour); one signed `player` request with the legacy profile (`videoId`, `racyCheckOk`, `contentCheckOk`, `playbackContext.contentPlaybackContext {html5Preference: "HTML5_PREF_WANTS", signatureTimestamp}`); require status OK and ei, vm and of; then the playback ping (`cmt=0`) and a watchtime ping (`st=0`, `et=cmt=position`) with a new cpn kept for this viewing, the Bearer header, the legacy user agent and the referer; on 2xx remove the entry. `.progress` and `.ended` send watchtime pings on the same tracking values (`st` = the last `et`), `.ended(finished: true)` sends the final pair. One report in flight per viewing; a different viewing gets its own player request; nothing carries over between videos. A network error keeps the entry for `replayPending()`, which re-mints per entry and sends one watchtime ping from 0 to the stored position (plus the final pair when finished). Three refusals in a row (not OK, missing values, or a non-2xx ping) pause reporting until the next launch (`isPaused()`), shown in Diagnostics. `isEnabled` false (switch off or not connected) sends nothing and queues nothing. `clearAccountData()` empties the queue and forgets the tracking values.

- [ ] **Step 1: Write the failing tests** (`MockHTTPClient` and a `TVClient` with an in-memory token provider): `aQualifiedViewingMintsOnceAndPingsInOrder` (exact order: homepage, player, playback ping, watchtime ping; exact ping query items), `theStsIsCachedForAnHour`, `aRefusalSendsNoPingsAndCountsTowardsThePause` (third refusal pauses), `aNetworkErrorKeepsTheEntryForReplay`, `replayMintsAFreshSessionPerEntry`, `progressAndClosingReuseTheViewingsTrackingValues`, `aDifferentViewingNeverReusesTrackingValues`, `aDisabledReporterSendsNothing`, `disconnectDropsThePendingReports`; `TVTrackingTests`: the ping URL cases of the probe's `test_report.py`, `newCPN` format, STS parsing.
- [ ] **Step 2: Run them and see them fail.** **Step 3: Implement.** **Step 4: Full kit suite and check build.** **Step 5: Commit** `feat(recommendations): report watched videos to the connected account`.

### Task 10: Player hooks and replay triggers

**Files:**
- Create: `NoSlop/App/AppEnvironment+WatchReports.swift` (the report closure and the replay triggers, so lane H's edits of `AppEnvironment.swift` do not collide)
- Modify: `NoSlop/Player/PlayerController.swift` (a `WatchReportTracker` per viewing), `NoSlop/App/AppEnvironment.swift` (only the line that hands the closure to the player, the way `detailsNeeded` is handed), `NoSlop/App/NoSlopApp.swift` (launch and scene-active replay)
- Test: kit tests from Task 8 cover the counting; the app wiring is verified by the build and the simulator.

**Interfaces:**
- Consumes: `WatchReportTracker`, `WatchViewing`, `WatchEvent`, `env.watchReporter`.
- Behaviour: `start(...)` creates a new `WatchViewing` and tracker (not on quality changes or recoveries); `tick` feeds the tracker and, when it returns an event, calls the report closure, which does `Task(priority: .utility) { await watchReporter.record(event, for: viewing) }` and returns at once; the closing event is sent when a viewing ends (another video starts, close, end of item, the app going to the background). Replay runs at launch, when the app becomes active, after a successful YouTube Home load, and when the player's network monitor sees the network come back. Diagnostics read `outcome()` and `isPaused()`.

- [ ] **Step 1: Implement** the hooks (nothing in them awaits or touches player state).
- [ ] **Step 2: Full kit suite and check build;** simulator check with `-mockServices YES -recommendationsConnected YES` and a `-playerScript` that plays 40 s then seeks and ends: the mock reporter's log lines show one `qualified`, then `ended`; playback never stalls.
- [ ] **Step 3: Commit** `feat(player): report watched videos when YouTube recommendations are connected`.

## Part D: Docs and the hand-over check

### Task 11: README, spec and the final mock run

**Files:**
- Modify: `README.md` (a section "YouTube recommendations (optional)" next to "Sign in with Google": what it does, how to connect, what is sent where, the three switches, Diagnostics and Save diagnostics, the risks; correct the lines that say the app never shows YouTube's personalised Home and that only official APIs are used; How it works; Troubleshooting for the TV client versions in `TVClientConfig`), `docs/superpowers/specs/2026-11-03-noslop-design.md` (the amendments listed in the recommendations design), `NoSlop/DesignSystem/DebugLaunchHooks.swift` (all new flags documented)

- [ ] **Step 1: Update the docs** so every statement is true for the code.
- [ ] **Step 2: Full kit suite twice, xcodegen with no diff, the check build;** one simulator pass with mocks over the whole flow (connect, Home, Not interested, a watched video reported, Diagnostics, Save diagnostics, Disconnect and Home back to the mix).
- [ ] **Step 3: Commit** `docs: YouTube recommendations in the README and the app spec`.
