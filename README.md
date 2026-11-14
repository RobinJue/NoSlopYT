# No Slop

A personal YouTube client for iPhone and iPad that feels like the real app, with none of the slop: no ads, no
Shorts, no sponsor reads, no clickbait, no algorithmic rabbit holes. Background playback, Picture in Picture and
downloads for offline viewing come free. It is installed from Xcode, not from the App Store, and has no server
component: everything runs on the phone. It can optionally show your own YouTube Home, see "YouTube recommendations
(optional)" below.

Design: [`docs/superpowers/specs/2026-11-03-noslop-design.md`](docs/superpowers/specs/2026-11-03-noslop-design.md)
· Plan: [`docs/superpowers/plans/2026-11-03-noslop-app.md`](docs/superpowers/plans/2026-11-03-noslop-app.md)

## What it does, and what it doesn't

**It does**

- Plays any public YouTube video ad-free, up to 1080p60, on a watch page like YouTube's: channel and Subscribe,
  description with clickable links, timestamps and chapters, comments with replies, related videos, captions.
  Captions follow the style you chose under Settings > Accessibility > Subtitles & Captioning, and the text size.
- Keeps playing with the screen locked or the app in the background, in Picture in Picture, on AirPlay, with the
  lock-screen controls. It resumes where you left off. While VoiceOver or Switch Control runs, the player's controls
  stay on screen instead of fading out, and a skipped segment is announced, with its Undo left up for ten seconds.
- Plays a public YouTube playlist (from search, a channel or a link) with "Play all" on its page, or from a tap on one
  of its rows. Your YouTube playlists and liked videos (signed in), the playlists on the device and Watch Later work
  the same way. The whole list is queued, also a long one: the part that is not loaded yet is fetched while the queue
  runs low, and your feed filters apply to it.
- While a queue plays, the watch page has a "Playing from Liked videos" section (the name of the list the queue came
  from) above Up next. It shows where the video is in the queue ("3 of 14", "3 of 51" while the pages of a playlist that states its size are still coming, or "3 of 100+" while more of the list is
  still to be fetched) and up to three of the videos that come next; a tap on one skips ahead to it. A queue without a
  name (Watch Later, a playlist on the device) reads "Playing from your queue". The Next button in the player controls
  starts the next queued video. When nothing is queued but the list goes on, it waits for the next page (the button
  shows a spinner, and pressing it again changes nothing); when the list is over, it starts the first video in Up next
  that you have not watched (no Short, live or upcoming video, and nothing your feed filters hide), also when Autoplay
  next video is off. Next, like autoplay, never offers a video that already started since the player was opened,
  even one you left after a few seconds. The lock screen's Next does the same. Next is off when there is nothing to
  start. There is no Previous.
- A video that YouTube will not hand out (private, removed, age-restricted, not playable) does not end a queue or
  autoplay. When the queue, autoplay or Next started it, the player shows the reason for two seconds ("Going on to the
  next video…") and starts the next one, at once when the app is not on screen. This happens for up to three videos
  in a row, never for a video you opened yourself, and never for a failure that Retry could fix (no connection, a
  busy server): that stays on its error screen. With Autoplay next video off, a failure where only a suggestion would
  follow also stays; its Next video button starts it.
- Scans a video at 2× while you hold it: hold the left half to go back, the right half to go forward, and let go to carry
  on from there (a double-tap on a half still jumps 10 seconds). Going forward is playback at twice the speed; going back
  steps the playhead, because YouTube's streams do not reliably play in reverse, so it can look choppier. A live stream
  cannot be scanned.
- Shows the whole picture: a video that does not match the shape of the screen gets black bars and is never zoomed in or
  cropped. The gear menu of a video has "Zoom to fill" to crop it to the player instead, for that video only.
- Downloads videos (pick a quality, or audio only) for offline viewing. Downloads continue while the app is in the
  background, and the files show up in the Files app. A download also keeps its video's SponsorBlock segments,
  chapters and captions, so offline it still skips sponsors, shows segments and chapter marks in the seek bar, and has
  captions.
- Skips sponsor, self-promotion and interaction-reminder segments (SponsorBlock; each category can also be shown in
  the seek bar or ignored, and a highlight, which is a moment and not a stretch, shows as a tick in the seek bar),
  swaps clickbait titles for the plain ones written by the DeArrow community, and lets you block channels and
  keywords. A blocked keyword of up to three letters A-Z or digits, such as "AI", matches whole words only; longer
  ones, and words in other scripts, also match inside words.
- Has feed filters in Settings to hide Shorts and members-only videos (both on by default), live and upcoming
  streams, and watched videos in Subscriptions. Members-only and live or upcoming videos are hidden where YouTube
  marks them: in search, on channel pages and in suggestions. The Subscriptions tab and the uploads on Home come from
  the channels' feeds, which carry no such marks.
- Works completely **anonymously** until you connect something: search, watch, channels, playlists, subscriptions kept on the device, history,
  Watch Later, your own playlists, and a "For you" home feed computed on the device from your history and
  subscriptions. Copy a YouTube link and paste it into the Search field to open it.
- Optionally signs in with your Google account, to bring your real YouTube subscriptions, playlists and liked
  videos, and to subscribe, like and add to playlists on your account. See "Sign in with Google" below.
- Optionally connects to YouTube the way YouTube's TV app does, to show your own YouTube Home, to tell YouTube when
  you hide a video or a channel there, and to tell YouTube what you watched. This is separate from the Google sign-in,
  off until you connect, and unofficial. See "YouTube recommendations (optional)" below.

**It doesn't**

- Show ads, promoted items or AI summary blocks, anywhere. There is no Shorts tab, and, with Settings > Feed filters >
  Hide Shorts on (the default), Shorts are filtered out of Home, Subscriptions, search, channels, playlists,
  suggested videos and your liked videos and YouTube playlists. (Those two come from the YouTube Data API, which has
  no Short marker, so there a video of a minute or less counts as a Short.) Your history, Watch Later, your own
  playlists and downloads show everything you put there. A Shorts link opens as an ordinary video.
- Contain any analytics, crash reporter, tracker or third-party package. Apple frameworks only. The only servers it
  talks to are YouTube and Google (for the videos, and for your account when you sign in or connect), plus SponsorBlock and
  DeArrow, which are asked about a short hash of a video ID, never the ID itself.
- Store or send cookies in its requests to YouTube's and Google's APIs (browsing, stream addresses, suggestions,
  captions, feeds, your account, the YouTube connection); thumbnails, avatars and lock-screen artwork, the video stream, downloads and
  Google's sign-in page are not API requests, and are left to the system's default cookie handling.
- Do live chat, post comments, upload, YouTube Music, Kids, notifications or Chromecast.
- Show YouTube's personalised Home unless you connect to YouTube (see "YouTube recommendations (optional)" below).
  Without the connection, Home is a "For you" feed computed on the device. Nothing is sent to YouTube about what you
  watch or hide, unless that connection is on.
- Play age-restricted or "made for kids" videos: YouTube does not hand those out to this kind of client. The app
  shows YouTube's own reason and an "Open on YouTube" button.
- Open a second window on iPad: the navigation, the player and Picture in Picture are shared by the whole app, so it
  has one window. (Split View and Slide Over with other apps work.)
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
secret and the app never sees your password).

**By default** the sign-in goes through the Google project of the app's author: press **Sign in with Google** in the
Library, there is nothing to set up. Its OAuth client ID is one constant, `GoogleOAuthConfig.sharedClientID` (a client
ID is public by design, so it lives in the source). While that project is unverified, Google says "Google hasn't
verified this app" and lets at most 100 accounts through; that is expected. The project's YouTube Data API quota
(10,000 units a day) is shared by everyone who uses it, and the app says so when it runs out. The author's project sees
how many requests are made and how many accounts signed in, not what you watch, and no token ever reaches the author.

**Your own project** (**Settings > Account > Use my own Google project**): nothing goes through anyone else's project
and the quota is yours alone. Use it if you build the app under another bundle ID, or if the shared project's limit is
used up. It takes about five minutes, once. The same steps are in the app, under Settings > Account > "How to set up
Google sign-in". An account set up before this setting existed, with its own client ID typed in, keeps using it.

1. In the [Google Cloud console](https://console.cloud.google.com/projectcreate), create a project (any name).
2. Under **APIs & Services > Library**, find **YouTube Data API v3** and press **Enable**. (Signing in works without
   this step, but nothing else does; see Troubleshooting if the app says the API isn't turned on.)
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

What you get once signed in: your subscriptions (kept in sync at launch and when you pull to refresh on Home,
Subscriptions or in the Library), your YouTube playlists and liked videos, and Subscribe, Like and Add to playlist
acting on your real account. The app asks for the scope `https://www.googleapis.com/auth/youtube`, plus
`openid email profile` to show who is signed in. The default quota of 10,000 units a day is plenty for one person
(in your own project; the shared project's is shared).

- The tokens live in the iPhone's Keychain. Signing out in the app forgets them and asks Google to revoke the
  grant; your subscriptions stay on the device as local ones, so the feed never empties.
- If Google ends the session by itself (the 7-day limit above, or you revoked access at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions)), the app shows the signed-out state
  and keeps your data. It notices the next time it talks to your account, which includes a pull to refresh on Home
  or Subscriptions. Sign in again to bring the account back.

## YouTube recommendations (optional)

Without this, Home is the "For you" feed the app computes on the device. With it, Home shows YouTube's own Home for
your account, the way the YouTube app on a TV does, still without Shorts, ads, promoted shelves, blocked channels or
blocked keywords. It is separate from "Sign in with Google": it does not need a Google Cloud project, and it can be
another Google account than the one you signed in with there (then Home, subscriptions and likes disagree).

**Connect.** In the Library, press **Connect** on the "YouTube recommendations" row (or use **Settings > YouTube
recommendations > Connect**). The app shows a code. Press **Open Google's page** (or open the page yourself on any
device), enter the code and approve. Google's page says **YouTube on TV**, not No Slop: that is expected, because this
is YouTube's TV sign-in. The app asks Google every few seconds and notices the approval by itself, and the row
then says Connected. A code works for a few minutes; if it expires, Cancel and start again.

**What is sent where.** While you are connected, and only with the switch for it on, these go to YouTube (and
Google's sign-in servers for the connection itself), signed in as that account:

- Home and its further pages (switch **Show YouTube's Home**, on by default).
- **Not interested** in the menu of a card on YouTube's Home, and "Don't show this channel" on such a card, which also
  sends YouTube "Don't recommend channel" (only when the card's menu names the same channel). Both also take the card
  away on the device (switch **Tell YouTube when I hide a video or a channel from Home**, on by default). Blocking a
  channel anywhere else only blocks it on the device. What YouTube is told cannot be undone from this app, and it
  applies to the whole account, also in the official YouTube app.
- A watch report for a video you played for 30 seconds (a video shorter than that: to its end), with a progress ping
  every few minutes and when you stop; never for live streams or Shorts (switch **Send what I watch to YouTube**, on
  by default). It lets YouTube put the video in the account's history and learn from it. It is sent after the video
  has started and never holds up the player. Reports that could not be sent (no connection) are kept on the device,
  at most 50 and for at most 7 days, and are sent when the app starts, becomes active, the network is back, or
  YouTube's Home has loaded. If YouTube refuses three reports in a row, reporting pauses until the next launch, and
  Diagnostics says so.

Everything else (search, watching, channels, comments, suggestions, SponsorBlock, DeArrow) stays anonymous and does
not touch the connection. The connection's tokens live in their own Keychain item. If YouTube's Home cannot be loaded,
or has too few videos left after the filters, Home shows the on-device mix instead, with a notice and Retry.

**Diagnostics.** **Settings > YouTube recommendations > Diagnostics** shows the last Home load (which request was
used, the status, whether YouTube saw you as signed in, the counts of videos, Shorts and skipped items, and which source
Home showed), the last card action, the last watch report (the status of each step and which of YouTube's tracking
values were present, never the values) and how long the access token is valid. **Save diagnostics** writes a short
JSON file with the same flags and counts and YouTube's recent Home replies, scrubbed: no token or account details, and
video titles and channel names replaced by numbered labels, but the video and channel ids are kept so a problem can be
traced. It goes to `Documents/Diagnostics/` in the app's folder (it is deleted when you disconnect). It shows in the Files app under On My iPhone > No Slop > Diagnostics, so you can send it over when
something does not work.

**Disconnect.** **Settings > YouTube recommendations > Disconnect** (it asks first). The app asks Google to revoke the
grant, deletes the tokens, YouTube's Home, the card handles and the unsent reports from the device, and Home goes
back to the on-device mix. If you want to be sure the grant is gone, open
[myaccount.google.com/permissions](https://myaccount.google.com/permissions) (Google Account > Security > Your
connections to third-party apps and services) and remove **YouTube TV** there. If YouTube ends the connection by
itself, the app shows it as disconnected and Home falls back.

**The risks, plainly.**

- It is unofficial. The app signs in and asks for Home the way YouTube's TV app does, with the TV app's identity, not
  through an official API. That is against YouTube's terms, and Google could restrict the account or close this route.
  No bans are known for it, but that is no promise.
- It can break any day. YouTube changes this interface from time to time. Home then falls back to the on-device mix
  and reporting pauses; playback is not affected. See Troubleshooting for the versions to bump.
- The grant is YouTube TV's grant, which gives the app full access to that YouTube account, until you disconnect or
  remove it as described above.
- It can be another account than the Google sign-in, and what you do here shapes that account's recommendations in
  the official YouTube app too.

## Tests

The logic lives in the local Swift package `NoSlopKit` and is tested on macOS, without a simulator:

```sh
./scripts/test.sh                                # swift test --package-path NoSlopKit
./scripts/test.sh --filter ContentFilter         # extra arguments go to swift test
NOSLOP_LIVE=1 ./scripts/test.sh --filter 'LiveSmokeTests|LiveDownloadTests'    # opt-in tests against the real YouTube
```

The parsers are tested against real YouTube responses captured on 2026-11-03 and 2026-11-04 (`NoSlopKit/Tests/NoSlopKitTests/Fixtures/`).
The suites `LiveSmokeTests` and `LiveDownloadTests` are skipped unless `NOSLOP_LIVE=1` is set: they make a handful of
real requests (a stream, captions, an RSS feed, suggestions, a `@handle`, a visitor token, a small download) and may
fail when YouTube rate-limits you or changes. `--filter` is a substring match on the test names, so `--filter Live` would
also run the ordinary unit tests that have "Live" in a suite or test name (live streams, live state; they use mocks and
always run). The filter above selects only the two opt-in suites. The app target itself has no test target; it is checked
by building it and by running it with the mock services ("Debug launch arguments and app links").

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
  full speed, and the chunks keep arriving while the app is in the background or has been ended by the system. If you
  swipe the app away in the app switcher, iOS cancels the transfers and does not start the app again, so nothing
  downloads until you open it (see Troubleshooting). Video and audio are then muxed on the device with
  `AVMutableComposition` and a passthrough `AVAssetExportSession`, nothing is re-encoded; at most two exports run at
  a time, however many downloads finish together. AVFoundation reports twice the real length for YouTube's
  fragmented MP4 files, so both tracks are cut to the true duration (the format's `approxDurationMs`, else the
  video's length), for audio-only downloads too. A half-written file never counts as finished. Merging needs room
  for a second copy of the video, so before it fetches anything the app checks the free space and refuses a download
  that would not fit, saying how much it needs and how much is free. A download that fails keeps what it fetched, and
  so does a merge that the system interrupted: Retry only fetches or merges what is missing. Retry throws the parts
  away only when YouTube rules on the video itself (private, removed, not playable); a failed lookup of the stream
  addresses (no connection, a captive portal's page, an HTTP error, an answer without streams) keeps them, and so does
  a plan that cannot be written on a full device.
- **Offline extras.** Offline the player cannot ask SponsorBlock, the watch page or the caption service, so a download
  keeps their answers. When it starts (the phone is online then) the app also fetches the video's SponsorBlock segments
  (every category, so your settings still decide when the video plays; not asked while SponsorBlock is off in Settings),
  its chapters and the text of up to three caption tracks, the one captions open with first. They are kept per video,
  not per quality, in `.extras/<video id>.json` in the downloads folder. `.extras` starts with a dot, like `.work` where
  the parts of unfinished downloads go, so the Files app does not list it; the file goes with the last download of the
  video. The extras file is written in the background, so keeping a long list of captions does not
  stall the screen. The fetch is best effort: it waits at most eight seconds (each lookup gets six) before the first part of the
  video is requested, leaves out what did not arrive and never fails the download. The whole start of a download
  (stream addresses, free-space check, this fetch) runs on running time borrowed from iOS, so leaving the app right
  after you tap Download does not hold it up. A download then plays offline with sponsor skipping, the segments and
  chapter marks in the seek bar, and the captions button with the kept text. (The chapter list under the video belongs
  to the watch page and still needs a connection.) When a download plays with a connection, the live answers win and
  are written back to the extras file: that is how a download that lacks some of this gets it, the first time it plays
  online. A caption track you open then is kept too, up to six in all.
- **YouTube recommendations** use a second, separate client, `TVClient` in `NoSlopKit/Sources/NoSlopKit/Recommendations/`.
  It signs in with YouTube's TV device-code flow (the code, then polling until you approve), is the only code that sets
  an `Authorization` header, uses its own cookie-free session, and may only talk to `www.youtube.com`,
  `youtubei.googleapis.com` and `oauth2.googleapis.com`. It never uses the anonymous InnerTube client, its visitorData
  or its caches, and the anonymous requests stay free of credentials and cookies. Home is asked as the TV interface
  (`TVHomeParser` keeps only video tiles and drops ads, shelves, Shorts and anything unknown) with a short ladder of
  request forms, and the one that worked is remembered. Home uses YouTube's feed when at least 8 videos are left within
  up to 3 pages after the filters and the videos already in Continue watching or finished; otherwise it shows the
  on-device mix. A watch report is a signed player request (as the older TV client) to get YouTube's tracking values,
  then a playback ping and watch-time pings; it is written to a file on the device first and removed when sent. The
  tracking commands that come with cards are never fired, and raw replies are never logged.
- **SponsorBlock and DeArrow** are asked the privacy-preserving way: the app sends only the first 4 hex characters
  of the SHA-256 of the video ID to `sponsor.ajay.app`, the server answers for every video that shares that prefix,
  and the app keeps the entry for its own video. The server never learns what you watch. A DeArrow lookup that fails
  (no connection, a timeout, a busy server) is not an answer: the original title shows, the same video is not asked
  about again for a minute, and the app asks again when the connection comes back or De-clickbait titles is switched
  on. A SponsorBlock lookup that fails is tried again twice, after 3 and 10 seconds; switching SponsorBlock off in
  Settings ends a lookup that is waiting for its next try, and an answer that arrives after that is dropped.
- **Your data** stays on the device: subscriptions, history, Watch Later, playlists and recent searches are JSON
  files in Application Support, written half a second after a change, at once when the app leaves the foreground, and
  when iOS announces that it is about to end the app (an app that plays in the background can get that notice when it
  is force-quit): the player saves the position first, so the video resumes where it stopped, and the write waits at
  most two seconds for a write that is still running; settings are in `UserDefaults`; the Google tokens are in the
  Keychain; downloads are in Documents. A file that is damaged is moved aside as `<name>.corrupt` instead of being
  deleted, a file that exists but cannot be read (the phone was restarted and not unlocked yet, and iOS started the app in the
  background for a finished download) is left untouched and nothing is saved over it until it can be read: once the
  phone is unlocked the app reads the library files, the settings and the Google account again and merges what changed
  meanwhile, and a write that fails (the disk is full) is tried again, and a setting that an older save does not have yet takes its default.

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

There are more Debug-only launch arguments (slow or offline mock connections, seeded history and downloads, scripted
player and UI steps). They are documented in the source and not listed here. Most are in
`NoSlop/DesignSystem/DebugLaunchHooks.swift`; the steps of the player script (`-playerScript`) are in
`NoSlop/Player/PlayerDebugScript.swift`, those of the UI script (`-uiScript`) in
`NoSlop/DesignSystem/DebugUIScript.swift`.

The app understands the links below. It registers the `noslop://` scheme, so those links also open No Slop from other
apps (iOS asks to confirm), and the YouTube ones open when you paste them into the Search field:

| Link | Opens |
|---|---|
| `noslop://watch?v=<id>[&t=<seconds>][&list=<playlist>]` | a video, optionally from a time (`90`, `1m30s` and `1h2m3s` all work); a time that cannot be read is ignored, and the video opens from where you left off (or from the start). With `list=` the video plays as part of that playlist ("Playing from <playlist>", the next videos of the playlist follow); a playlist that cannot be loaded, such as a generated Mix, leaves the video playing alone |
| `noslop://channel/<id>`, `noslop://playlist/<id>` | a channel (`UC...`), a playlist |
| `noslop://search?q=<text>` | search results (`+` is a space, `%2B` a plus sign) |
| `noslop://tab/<home\|subscriptions\|library\|search>` | a tab |
| `noslop://route/<settings\|downloads\|history\|watchLater\|likedVideos\|accountPlaylists\|subscriptionsManager>` | a screen on the selected tab |
| `https://www.youtube.com/watch?v=<id>&t=42s`, `https://youtu.be/<id>?t=1m5s`, `/shorts/<id>`, `/live/<id>`, `/embed/<id>` | a video (a Short opens as a normal video). A `/watch` or `youtu.be` link with `&list=<playlist>` plays the video in that playlist; `/shorts`, `/live` and `/embed` links ignore `list=` |
| `https://www.youtube.com/@handle`, `/channel/<id>`, `/playlist?list=<id>`, `/results?search_query=<text>` | a channel (a handle is resolved by YouTube, so it needs the network; if you open another link or go elsewhere before the answer arrives, the channel does not open), a playlist, a search |

A link the app cannot open (not a YouTube link, a video ID of the wrong length, a missing part) opens nothing and
shows a plain "Can't open this link" message. When the link was a web link, the message also offers "Open on YouTube",
which opens that link in the browser or the YouTube app.

## Troubleshooting

- **"YouTube asked to confirm you're not a bot."** YouTube rejected the visitor token. The app already retried once
  with a fresh one. Try again in a minute, or tap "Open on YouTube".
- **A video says it is unavailable, private, age-restricted or made for kids.** The message is YouTube's own reason.
  These videos cannot be played through this kind of client, and asking again gets the same answer, so the player shows
  no Retry for them, only "Open on YouTube", which opens them in the YouTube app or in Safari (the chevron at the top
  still minimizes the player), and "Next video" when there is one. Other screens that ask YouTube about such a video,
  such as the Download sheet, say "Not available" with the reason and no Retry. Retry stays for failures that can pass:
  no connection, a busy server, a bot check, and a live event or premiere that has not begun yet. In a queue or
  autoplay the player goes on to the next video by itself (see the feature list). The mini player then shows a warning
  on the thumbnail and "Couldn't play" under the title, and its play button is a Retry button, or is off when Retry
  would not help. At large text sizes the error screen's buttons stack instead of sitting in a row.
- **Playback stops after a long pause or a lost connection.** The app re-resolves the stream (or waits for the
  connection) and resumes once; if playback fails again it shows the error with a Retry button. A stream that this
  device cannot decode gets no Retry, since fresh addresses would not help; for a download that cannot be played, Retry
  streams the video instead.
- **A download failed or is paused.** Tap Retry: it asks YouTube for fresh stream addresses and reuses the parts
  that are still good, so only what is missing is fetched again. When a stream address stops working (it expired, or
  the phone left the Wi-Fi it was made for), the app asks YouTube for new ones by itself once before it gives up.
  "There isn't enough free space" means the download, plus a second copy for the merge, would not fit: free some
  space and tap Retry, the parts that were fetched are kept, also when the phone was too full to write the download's plan.
  A Retry whose lookup of stream addresses fails (no connection, a captive portal) keeps them too; only a video that
  YouTube calls private, removed or not playable loses its parts.
- **A download stopped after you swiped the app away.** iOS cancels the background transfers of an app that was
  force-quit and does not start it again. Open No Slop: the parts that were already fetched are kept, and if the row
  says Paused, tap Retry.
- **A download plays offline without sponsor skipping, chapter marks or captions.** They are fetched when the download
  starts, so they are missing if SponsorBlock was off then, if a service was too slow to answer, and for a download
  made by an older version of the app. Play it once with a connection (SponsorBlock on): the app asks again and keeps
  what it gets; for captions, the track you open.
- **A title is still the clickbait one.** DeArrow has no better title for every video, and Settings > Titles >
  De-clickbait titles has to be on. If DeArrow could not be reached, the original shows for now: the app asks again when
  the connection comes back, when you switch the setting on, and when the title comes into view again after a minute.
- **Lists are empty, videos do not load, or everything fails after a while.** YouTube's web API is unofficial and
  changes. The client versions the app presents itself with live in
  `NoSlopKit/Sources/NoSlopKit/InnerTube/ClientProfile.swift` (`ClientProfile.web` and `ClientProfile.visionOS`:
  the `clientVersion` and the user agent, and for visionOS the `osVersion` in `extraClientFields`). When YouTube
  starts refusing an old version, bump those values to current ones (open-source clients such as yt-dlp list them),
  run `./scripts/test.sh` and `NOSLOP_LIVE=1 ./scripts/test.sh --filter 'LiveSmokeTests|LiveDownloadTests'`, and run the app again.
- **YouTube recommendations stopped working: Home shows the on-device mix with a notice, or watches are not reported.**
  This interface is unofficial and changes. Look at Settings > YouTube recommendations > Diagnostics first. The
  versions the app presents itself with live in `NoSlopKit/Sources/NoSlopKit/Recommendations/TVClientConfig.swift`:
  `tvClientVersion` and `tvUserAgent` (Home, card actions), `legacyClientVersion` and `legacyUserAgent` (the player
  request of the watch reports), `referer`, and `homeRecipes` (the Home requests tried in turn). When YouTube starts
  refusing an old version, bump them to the current TV values (open-source TV clients list them), run
  `./scripts/test.sh`, and disconnect and connect again if Home stays on the mix. A "Signed in on YouTube: no" in Diagnostics means
  YouTube answered as for a signed-out viewer.
- **Google sign-in is blocked, or you are signed out every week.** See "Sign in with Google": add yourself as a test
  user, or publish the consent screen to stop the 7-day sign-out.
- **"Google's daily limit for this sign-in's project is used up."** The shared project's quota is shared by everyone
  who signs in with it. Try again tomorrow, or switch to your own project (Settings > Account > Use my own Google
  project).
- **"The YouTube Data API isn't turned on for the Google project behind this sign-in."** Signing in works without it;
  everything that uses your account does not. With your own project: open the Google Cloud project that owns your OAuth client, go to **APIs & Services >
  Library**, enable **YouTube Data API v3**, wait a minute (a change takes that long to spread), then pull down in
  the Library to bring your subscriptions. The app shows this message right after you sign in when the subscriptions
  could not be imported, and wherever a screen needs your account.
- **The app stops opening after a week** (free Apple ID): run it from Xcode again.

## Layout

| Path | What |
|---|---|
| `NoSlopKit/` | Swift package: InnerTube client and parsers, Google OAuth and Data API, feeds, library, downloads, SponsorBlock, DeArrow, mocks |
| `NoSlop/App/` | App entry point, `AppEnvironment` (composition root), `AppLink` (the `noslop://` links), `Router`, `RootView`, `BackgroundPersistence` |
| `NoSlop/DesignSystem/` | Shared views: thumbnails, video cards and rows, subscribe button, empty/error states |
| `NoSlop/Features/` | The screens: Home, Subscriptions, Search, Channel, Playlist, Watch, Library, Downloads, Settings, Account, Recommendations |
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
you. Only the optional Google sign-in uses an official API (the YouTube Data API, with the author's Google project or your own). The
optional YouTube recommendations connection is not official: it presents itself to YouTube as YouTube's TV app, which
is also against YouTube's terms, and may get the account restricted.

The app says the same in **Library > Legal notice** (with the data it keeps and where it sends requests), and
**Library > Source code** opens the repository, <https://github.com/RobinJue/NoSlopYT>. That address is one constant,
`ProjectLinks.repository` in `NoSlop/App/ProjectLinks.swift`.

## Support

No Slop is free to use, and nothing in it is behind a payment. If you like it, you can
[buy me a coffee](https://buymeacoffee.com/robinjue). That is a gift, not a purchase: it unlocks nothing, and the
app has the same link under **Library > Buy me a coffee**.
