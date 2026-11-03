# No Slop

A personal YouTube client for iPhone and iPad that feels like the real app, with none of the slop: no ads, no
Shorts, no sponsor reads, no clickbait, no algorithmic rabbit holes. Background playback, Picture in Picture and
downloads for offline viewing come free. It is installed from Xcode, not from the App Store, and has no server
component: everything runs on the phone.

Design: [`docs/superpowers/specs/2026-11-03-noslop-design.md`](docs/superpowers/specs/2026-11-03-noslop-design.md)
· Plan: [`docs/superpowers/plans/2026-11-03-noslop-app.md`](docs/superpowers/plans/2026-11-03-noslop-app.md)

## What it does, and what it doesn't

**It does**

- Plays any public YouTube video ad-free, up to 1080p60, on a watch page like YouTube's: channel and Subscribe,
  description with clickable links, timestamps and chapters, comments with replies, related videos, captions.
- Keeps playing with the screen locked or the app in the background, in Picture in Picture, on AirPlay, with the
  lock-screen controls. It resumes where you left off.
- Downloads videos (pick a quality, or audio only) for offline viewing. Downloads continue while the app is in the
  background, and the files show up in the Files app.
- Skips sponsor, self-promotion and interaction-reminder segments (SponsorBlock; each category can also be shown in
  the seek bar or ignored), swaps clickbait titles for the plain ones written by the DeArrow community, and lets
  you block channels and keywords.
- Works completely **anonymously**: search, watch, channels, playlists, subscriptions kept on the device, history,
  Watch Later, your own playlists, and a "For you" home feed computed on the device from your history and
  subscriptions. Copy a YouTube link and paste it into the Search field to open it.
- Optionally signs in with your Google account, to bring your real YouTube subscriptions, playlists and liked
  videos, and to subscribe, like and add to playlists on your account. See "Sign in with Google" below.

**It doesn't**

- Show ads, promoted items, Shorts or AI summary blocks, anywhere. There is no Shorts tab, and Shorts are filtered
  out of every list. A Shorts link opens as an ordinary video.
- Contain any analytics, crash reporter, tracker or third-party package. Apple frameworks only. The only servers it
  talks to are YouTube and Google (for the videos, and for your account when you sign in), plus SponsorBlock and
  DeArrow, which are asked about a short hash of a video ID, never the ID itself.
- Do live chat, post comments, upload, YouTube Music, Kids, notifications or Chromecast.
- Show YouTube's personalised home feed: Google does not offer it to third-party apps.
- Play age-restricted or "made for kids" videos: YouTube does not hand those out to this kind of client. The app
  shows YouTube's own reason and an "Open on YouTube" button.
- Need a server or an App Store build: it is installed from Xcode onto your own devices.

## Requirements

- A Mac with Xcode 26.2 or newer (Swift 6.2). The app targets iOS 18.0 and later, iPhone and iPad.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer to generate the Xcode project:
  `brew install xcodegen`.
- No third-party packages: Apple frameworks only.
- To run on a real iPhone: an Apple ID (a free one is enough).

## Build and run

```sh
./scripts/bootstrap.sh        # generates NoSlop.xcodeproj from project.yml
open NoSlop.xcodeproj
```

The generated project is committed, so you only need `./scripts/bootstrap.sh` when `NoSlop.xcodeproj` is missing or
after you change `project.yml`. The Xcode project uses synced folders: adding or removing files under `NoSlop/`
needs no regeneration.

**On the simulator:** pick an iPhone or iPad simulator in Xcode and press Run. No signing setup is needed.

**On your iPhone:**

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (it is git-ignored) and replace `YOURTEAMID`
   with your Apple Developer Team ID (ten characters), for example `DEVELOPMENT_TEAM = A1B2C3D4E5`. You find it in
   Xcode > Settings > Accounts > select your team; a free Apple ID has a team too.
2. Connect the phone, turn on Developer Mode on it (Settings > Privacy & Security > Developer Mode), choose it as
   the run destination in Xcode and press Run.
3. The first launch is blocked until you trust your developer profile on the phone (Settings > General > VPN &
   Device Management).

With a **free Apple ID** the app's signature lasts 7 days: after that it no longer opens, and you run it from Xcode
again to re-sign it (your data stays). With a **paid** Apple Developer Program account it lasts a year.

If Xcode says it cannot register the bundle ID `com.robinjungerich.noslopyt` for your team, choose a bundle ID of
your own in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`), run `./scripts/bootstrap.sh` again, and use that same ID
when you create the Google OAuth client below.

From the command line, without code signing, for the simulator:

```sh
./scripts/build.sh                                                     # builds into .build/DerivedData
DESTINATION='platform=iOS Simulator,id=<udid>' ./scripts/build.sh      # for one specific simulator
```

## Sign in with Google (optional)

Everything except your own YouTube account works without this. Signing in uses the official YouTube Data API with
Google's OAuth sign-in (authorization code with PKCE, in the system's web sign-in session; there is no client
secret and the app never sees your password). Because you create the Google project yourself, nothing goes through
anyone else's servers. It takes about five minutes, once. The same steps are in the app, under Settings > Account >
"How to set up Google sign-in".

1. In the [Google Cloud console](https://console.cloud.google.com/projectcreate), create a project (any name).
2. Under **APIs & Services > Library**, find **YouTube Data API v3** and press **Enable**.
3. Under **OAuth consent screen** (Google Auth platform), choose **External** and fill in an app name and your
   email. Either add your own Google account as a **test user**, or publish the app (**In production**).
   - In Testing mode Google ends the sign-in every 7 days, so you would sign in again each week.
   - Publishing avoids that. Verification is not needed for personal use; Google only shows an "unverified app"
     notice when you sign in.
4. Under **Credentials**, choose **Create credentials > OAuth client ID**, set the application type to **iOS** and
   enter the bundle ID `com.robinjungerich.noslopyt` (or your own, see above).
5. Copy the client ID (it ends in `.apps.googleusercontent.com`) and paste it into **Settings > Account** in the
   app, then tap **Sign in with Google**. (Library > Settings reaches that screen. The redirect address is derived
   from the client ID by the app, so there is nothing else to configure.)

What you get once signed in: your subscriptions (kept in sync at launch and when you pull to refresh), your YouTube
playlists and liked videos, and Subscribe, Like and Add to playlist acting on your real account. The app asks for
the scope `https://www.googleapis.com/auth/youtube`, plus `openid email profile` to show who is signed in. The
default quota of 10,000 units a day is plenty for one person.

- The tokens live in the iPhone's Keychain. Signing out in the app forgets them and asks Google to revoke the
  grant; your subscriptions stay on the device as local ones, so the feed never empties.
- If Google ends the session by itself (the 7-day limit above, or you revoked access at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions)), the app shows the signed-out state
  and keeps your data. Sign in again to bring the account back.

## Tests

The logic lives in the local Swift package `NoSlopKit` and is tested on macOS, without a simulator:

```sh
./scripts/test.sh                                # swift test --package-path NoSlopKit
./scripts/test.sh --filter ContentFilter         # extra arguments go to swift test
NOSLOP_LIVE=1 ./scripts/test.sh --filter Live    # opt-in tests against the real YouTube
```

The parsers are tested against real YouTube responses captured on 2026-11-03 (`NoSlopKit/Tests/NoSlopKitTests/Fixtures/`).
The suites `LiveSmokeTests` and `LiveDownloadTests` are skipped unless `NOSLOP_LIVE=1` is set: they make a handful of
real requests (a stream, captions, an RSS feed, suggestions, a `@handle`, a visitor token, a small download) and may
fail when YouTube rate-limits you or changes. `--filter Live` selects them, together with a few ordinary parser tests
that have "Live" in their name and always run. The app target itself has no test target; it is checked by building it
and by running it with the mock services (next section).

## How it works

- **Browsing** uses YouTube's own web API, InnerTube (`https://www.youtube.com/youtubei/v1/<endpoint>`), as the
  `WEB` client: `search`, `next` (the watch page, related videos, comments), `browse` (channels, playlists) and
  `navigation/resolve_url` (for `@handle` links). The parsers drop ads and AI summary blocks, mark Shorts so they
  can be hidden, and skip anything they do not recognise, so a response in a changed shape usually gives a shorter
  or empty list instead of breaking the screen. Search suggestions come from `suggestqueries.google.com`; the
  subscription feed is built from each channel's public RSS feed.
- **Playback** asks the `player` endpoint as the **visionOS** client. That client needs no proof-of-origin token and
  no JavaScript deciphering, and it hands back an **HLS** master playlist (H.264 up to 1080p60, AAC audio) that
  `AVPlayer` plays directly. That is why background audio, Picture in Picture, AirPlay and the lock-screen controls
  work like they do in any native player. The stream addresses expire after about six hours; the player asks for
  fresh ones and carries on at the same position.
- **visitorData** is mandatory: without it `player` answers "Sign in to confirm you're not a bot". The app gets a
  visitor token from `https://www.youtube.com/sw.js_data` (falling back to `youtubei/v1/visitor_id`), keeps it for 7
  days, and sends it with every request (`context.client.visitorData` and `X-Goog-Visitor-Id`). When YouTube still
  refuses, the app fetches a fresh token and tries once more before it shows the message.
- **Downloads** are plain H.264 video and AAC audio files fetched with HTTP Range requests of 10 MiB each, one
  `URLSession` task per chunk on a background session: a single long request is throttled to a crawl, ranges run at
  full speed, and the chunks keep arriving while the app is suspended or was killed. Video and audio are then muxed
  on the device with `AVMutableComposition` and a passthrough `AVAssetExportSession`, nothing is re-encoded.
  AVFoundation reports twice the real length for YouTube's fragmented MP4 files, so both tracks are cut to the true
  duration (the format's `approxDurationMs`, else the video's length), for audio-only downloads too. A half-written
  file never counts as finished. Merging needs room for a second copy of the video.
- **SponsorBlock and DeArrow** are asked the privacy-preserving way: the app sends only the first 4 hex characters
  of the SHA-256 of the video ID to `sponsor.ajay.app`, the server answers for every video that shares that prefix,
  and the app keeps the entry for its own video. The server never learns what you watch.
- **Your data** stays on the device: subscriptions, history, Watch Later, playlists and recent searches are JSON
  files in Application Support, written half a second after a change and at once when the app leaves the foreground;
  settings are in `UserDefaults`; the Google tokens are in the Keychain; downloads are in Documents. A file that
  cannot be read is moved aside as `<name>.corrupt` instead of being deleted, and a setting that an older save does
  not have yet takes its default.

## Debug launch arguments and app links

These launch arguments work in Debug builds only (they are compiled out of Release builds). In Xcode, add them under
Product > Scheme > Edit Scheme > Run > Arguments (the scheme already lists `-mockServices YES`, unticked).

- `-mockServices YES` runs on canned sample data instead of YouTube, with a throw-away library and settings that
  never touch your real ones. The mock player plays Apple's bipbop test stream, SponsorBlock has segments at 30-45 s
  and 120-130 s, and downloads do not work (the mock has no downloadable formats).
- `-openURL '<link>'` opens an app link right after launch. Several links go in one argument, separated by
  ` | ` (space, pipe, space); they are handled in order, about 1.5 s apart. It exists because `xcrun simctl openurl`
  asks "Open in No Slop?" for custom schemes on iOS 26.

```sh
xcrun simctl launch booted com.robinjungerich.noslopyt -mockServices YES \
  -openURL 'noslop://watch?v=aqz-KE-bpKQ&t=100 | noslop://tab/library'
```

The app understands the links below. It registers the `noslop://` scheme, so those links also open No Slop from other
apps (iOS asks to confirm), and the YouTube ones open when you paste them into the Search field:

| Link | Opens |
|---|---|
| `noslop://watch?v=<id>[&t=<seconds>]` | a video, optionally from a time (`90`, `1m30s` and `1h2m3s` all work) |
| `noslop://channel/<id>`, `noslop://playlist/<id>` | a channel (`UC...`), a playlist |
| `noslop://search?q=<text>` | search results |
| `noslop://tab/<home\|subscriptions\|library\|search>` | a tab |
| `noslop://route/<settings\|downloads\|history\|watchLater\|likedVideos\|accountPlaylists\|subscriptionsManager>` | a screen on the selected tab |
| `https://www.youtube.com/watch?v=<id>&t=42s`, `https://youtu.be/<id>?t=1m5s`, `/shorts/<id>`, `/live/<id>`, `/embed/<id>` | a video (a Short opens as a normal video) |
| `https://www.youtube.com/@handle`, `/channel/<id>`, `/playlist?list=<id>`, `/results?search_query=<text>` | a channel (a handle is resolved by YouTube, so it needs the network), a playlist, a search |

A link the app cannot open (not a YouTube link, a video ID of the wrong length, a missing part) opens nothing and
shows a plain "Can't open this link" message.

## Troubleshooting

- **"YouTube asked to confirm you're not a bot."** YouTube rejected the visitor token. The app already retried once
  with a fresh one. Try again in a minute, or tap "Open on YouTube".
- **A video says it is unavailable, private, age-restricted or made for kids.** The message is YouTube's own reason.
  These videos cannot be played through this kind of client; "Open on YouTube" opens them in the YouTube app or in
  Safari.
- **Playback stops after a long pause or a lost connection.** The app re-resolves the stream and resumes; if that
  fails twice it shows the error with a Retry button.
- **A download failed or is paused.** Tap Retry: it asks YouTube for fresh stream addresses and reuses the parts
  that are still good. A nearly full device cannot merge a download.
- **Lists are empty, videos do not load, or everything fails after a while.** YouTube's web API is unofficial and
  changes. The client versions the app presents itself with live in
  `NoSlopKit/Sources/NoSlopKit/InnerTube/ClientProfile.swift` (`ClientProfile.web` and `ClientProfile.visionOS`:
  the `clientVersion` and the user agent, and for visionOS the `osVersion` in `extraClientFields`). When YouTube
  starts refusing an old version, bump those values to current ones (open-source clients such as yt-dlp list them),
  run `./scripts/test.sh` and `NOSLOP_LIVE=1 ./scripts/test.sh --filter Live`, and run the app again.
- **Google sign-in is blocked, or you are signed out every week.** See "Sign in with Google": add yourself as a test
  user, or publish the consent screen to stop the 7-day sign-out.
- **The app stops opening after a week** (free Apple ID): run it from Xcode again.

## Layout

| Path | What |
|---|---|
| `NoSlopKit/` | Swift package: InnerTube client and parsers, Google OAuth and Data API, feeds, library, downloads, SponsorBlock, DeArrow, mocks |
| `NoSlop/App/` | App entry point, `AppEnvironment` (composition root), `AppLink` (the `noslop://` links), `Router`, `RootView`, `BackgroundPersistence` |
| `NoSlop/DesignSystem/` | Shared views: thumbnails, video cards and rows, subscribe button, empty/error states |
| `NoSlop/Features/` | The screens: Home, Subscriptions, Search, Channel, Playlist, Watch, Library, Downloads, Settings, Account |
| `NoSlop/Player/` | The AVPlayer-based player and its overlay |
| `project.yml`, `Config/` | XcodeGen spec and build configuration |
| `scripts/` | `bootstrap.sh`, `build.sh`, `test.sh` |

## Credits and disclaimer

SponsorBlock (skip segments) and DeArrow (better titles) are by Ajay Ramachandran and their communities
([sponsor.ajay.app](https://sponsor.ajay.app/), [dearrow.ajay.app](https://dearrow.ajay.app/)). Their data is
licensed CC BY-NC-SA 4.0, which is one more reason to keep this app non-commercial.

No Slop is a personal project, made for the author's own use, and is not affiliated with, endorsed by or sponsored by
YouTube or Google. It reaches YouTube through the same web interfaces the website uses, not through an official API,
and it plays videos without ads. That may go against YouTube's Terms of Service, and YouTube can change or block it
at any time. If you use it, you do so at your own risk and you are responsible for following the terms that apply to
you. Only the optional account features use an official API (the YouTube Data API, with your own Google project).
