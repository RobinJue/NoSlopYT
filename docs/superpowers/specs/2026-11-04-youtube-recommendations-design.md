# YouTube recommendations — Design

Date: 2026-11-04, updated 2026-11-08 · Status: approved by the owner on 2026-11-08. Next: the Phase 0 plan, docs/superpowers/plans/2026-11-08-youtube-recommendations-phase0.md. Decisions the owner made are marked *owner*; everything else is the designer's call unless it says *builder*.

Companion: [research notes](2026-11-04-youtube-recommendations-research.md) (what the open-source apps do today, with dates and sources). App spec: [2026-11-03-noslop-design.md](2026-11-03-noslop-design.md).

## Read this first: what changed since the conversation

The picture agreed on 4 Nov still holds, but the research found four things that make it smaller or shakier:

1. **Reporting what you watch is the shakiest part.** It needs a second, signed request to YouTube for every reported video, made with an old YouTube-on-TV client version that YouTube has not switched off yet. On Android TV the same method broke three times in 2026, once for four weeks (3 Aug to 1 Sep). A watch reported later (for example after watching offline) will most likely show in YouTube's history at the time it is sent, not when it was watched.
2. **"Not interested" and "Don't recommend channel" only work on cards that came from YouTube's Home.** YouTube hands out the needed token only there, and since mid-September only through one extra request per card. Search results, Up next and library rows cannot send it, so blocking a channel tells YouTube only when the block is made from one of YouTube's Home cards.
3. **Home cards no longer carry a channel id.** Since mid-September YouTube's TV cards show the channel's name, but the id needs that extra request. So blocked channels are matched by name on those cards.
4. **Nobody has shown that the signed-in Up next is personal.** It stays a debug-only experiment.

Nothing signed in has been tried yet: the research could only read other apps' code and make anonymous requests. So the work starts with a short test run with a real Google account (Phase 0), and each feature ships only if its test passes.

## Intent

The owner wants YouTube's real recommendations in No Slop, without ads (*owner*, original request: "log in via my Google account and then get the actual videos, just without the ads"). The on-device "For you" mix is not the same thing. The official YouTube Data API has no recommendations (the home feed was removed in 2016, related videos in August 2023), so the only working route is the one Smart Tube BDP (iPhone), SmartTube (Android TV) and the Kodi YouTube add-on use: sign in as YouTube's TV app and ask YouTube's TV interface for the Home feed.

*Owner* (4 Nov): it is worth letting YouTube see what is watched in No Slop, because that is what keeps the Home feed fresh.
*Owner* (4 Nov): the TV sign-in sits next to the existing Google sign-in, which keeps handling subscriptions, playlists, liked videos and likes.

## Goals

1. An optional connection, "YouTube recommendations", signed in with YouTube's TV code flow: No Slop shows a code, the owner enters it on Google's page. Nothing changes until the owner connects.
2. While connected, Home shows the account's real YouTube Home feed with No Slop's filters on top (Shorts, members-only, the live and upcoming setting, blocked channels and keywords, De-clickbait titles) and Continue watching on top as today. When YouTube's feed fails, is empty or is too thin after filtering, Home shows today's on-device mix and says so.
3. While connected and reporting is on, a video watched for 30 seconds in No Slop is reported to the account (and how far it got), so it appears in the account's YouTube history and shapes Home.
4. "Not interested" on YouTube Home cards, and "Don't recommend channel" sent to YouTube when the owner blocks a channel from a YouTube Home card.
5. A debug-only experiment that compares YouTube's signed-in Up next with today's related list.
6. Everything else stays as it is and anonymous: search, channels, playlists, related videos, comments, playback, downloads, and the Google (Data API) sign-in.

## Non-goals

- Replacing the Google sign-in, or moving subscriptions, playlists, liked videos or likes to the TV connection (*owner*: next to it).
- Signed-in search, channel pages, comments or related videos. Playback stays on the anonymous visionOS stream; the signed player request in Reporting is only for YouTube's tracking values.
- Showing the account's YouTube history, Watch Later or playlists through the TV connection.
- Brand-account channel switching: v1 uses the account's main identity. *Owner* (8 Nov): the owner watches YouTube as the Google account itself, not as a Brand Account, so this is enough.
- Changing the account's YouTube settings. If watch history is paused on YouTube, reports silently do nothing; that stays YouTube's setting.
- A server or remote configuration. Fixing a client version is a rebuild, as it is for the anonymous profiles today.
- App Store distribution (unchanged: the app is installed from Xcode).

## Anti-goals

- Any ad, sponsored tile, promo shelf, Premium upsell, Short, or paid or rental item from YouTube's Home reaching the screen.
- The TV token or any signed-in data reaching the anonymous requests (search, browse, player, related, comments, thumbnails), or the anonymous identity (visitorData) riding on signed-in requests.
- Playback waiting for, stuttering because of, or failing because of account traffic.
- Home showing an error screen or going blank because YouTube's feed failed.
- Reporting what the owner did not watch: previews, autoplay stopped before 30 seconds, Shorts, live streams, the seeds of the on-device mix.
- Firing the tracking commands that come with Home cards (impression, visibility, ad and inline-preview pings).
- Tokens, device codes or raw signed-in responses in logs, error text or committed fixtures.
- Anything the TV connection does changing the Google sign-in (signing out, googleAccount state, the subscriptions it syncs), or the reverse.

## Constraints

- Everything in the app spec's "Platform & stack" still holds: iOS 18+, Swift 6.2, Apple frameworks only, logic in NoSlopKit tested with Swift Testing, XcodeGen synced folders.
- The owner's Mac is a fanless MacBook Air: one simulator at a time, -jobs 4, at most two agents building at once.
- The build starts after Phase 4 has landed (final review fixes and live QA), because this touches the same Home, player and environment code.
- This reverses written promises, so the app spec and README change in the same work (see "Spec and README amendments").
- The route is unofficial and can break at any time: every part fails soft and can be switched off on its own.

## How it works

### The connection

- **Sign-in.** YouTube's TV device-code flow: request a code, show it, poll until the owner approves it on Google's page, on the phone or any other device. The research notes list the endpoints, scopes and client values the open-source apps use today. The build uses one endpoint family (provisionally YouTube's own youtube.com/o/oauth2 pair) and Phase 0 confirms it.
- **Client values.** YouTube TV's OAuth client values are read from the public youtube.com/tv page when needed (first sign-in, or after an invalid_client answer), accepted only after a code request with them succeeds, and stored with the credentials, so a refresh never needs the page. Nothing is hard-coded in the repo. (Alternative if reading the page proves flaky: a bundled pair, as Smart Tube BDP and Kodi do.)
- **The code sheet.** The code in large type, Copy Code, "Open Google's page" (the server's verification_url with ?user_code= appended, opened in Safari; a youtube.com/qr link would open the YouTube app instead), a countdown, and Cancel. Poll at the server's interval (at least 5 s, 5 s more after slow_down) and at once when the app returns to the foreground; ask for a new code when it expires; stop when the owner declines. The sheet says that Google's page will name "YouTube on TV", not No Slop.
- **Storage.** Its own Keychain item (service com.robinjungerich.noslopyt.youtube-tv, available after first unlock, not synced): tokens, expiry, the client values, the account name if known, the date connected. Refresh before use when less than about 5 minutes are left, one refresh at a time, and keep a new refresh token if a refresh returns one. invalid_grant, invalid_client or unauthorized_client from the token endpoint means the connection ended: clear it, show Reconnect, and Home falls back. Network errors never clear anything.
- **Which account.** The account's main identity. Show "Connected" and the account name when YouTube's account list gives it cheaply. Say that this connection can be a different Google account from the Google sign-in.
- **Disconnect.** Confirm ("Home goes back to the mix made on this device."), try to revoke the grant (Google's documented revoke endpoint, then YouTube's), delete the Keychain item and every account-bound thing (YouTube's cached Home, card handles, pending reports), and, when the revoke was not confirmed, show where to remove "YouTube TV" from the Google Account's third-party connections.
- **Where it shows.** A row in Library's first section, under the Google sign-in header, and a Settings section after Account. Both say plainly: optional, unofficial, YouTube's TV sign-in, separate from the Google sign-in. Settings also shows a status line (last Home source, last report result) and the three switches described below (YouTube's Home, the card actions, reporting).

### The TV transport

- One new NoSlopKit actor is the only code that sets an Authorization header for this connection. It has its own cookie-free URLSession (from a new public factory beside the existing default session), an allow-list of hosts (YouTube's InnerTube and stats endpoints, the OAuth endpoints), and logs nothing.
- It never uses the anonymous InnerTubeClient, its visitorData (noslop.visitorData) or its caches, and InnerTubeClient gets no auth option. A kit test pins that anonymous requests carry no Authorization header and no cookies.
- Client constants live in one config type: a "TV" profile (TVHTML5 7.x, a Fire TV Cobalt user agent) for Home, card menus, feedback and next; a "legacy TV" profile (TVHTML5 5.x, an old Cobalt user agent) for the reporting player request; the host (www.youtube.com); the Home browse id; the visitorData policy. All provisional until Phase 0. README Troubleshooting tells the owner how to bump them, as it does for the anonymous profiles.
- Empty or 204 bodies count as success where no body is needed; non-JSON or redirected replies are failures; a 401 triggers one refresh and a retry, then Reconnect; 429 and 5xx back off.

### Home

- When connected and "Show YouTube's Home" is on (default on), Home shows Continue watching from local history at once and asks YouTube, with a budget of about 8 seconds. The decision is a pure NoSlopKit type: in go YouTube's pages, the filter and the local history; out come the source, the videos and a notice.
- YouTube's feed is used when at least 8 videos remain within up to 3 pages after No Slop's filters and after dropping videos that are in Continue watching or finished (finished by local history, or YouTube's own progress of 95% or more). Otherwise Home shows the on-device mix with a small notice: "Showing the mix made on this device. YouTube's Home didn't load." with Retry. One source per load, never mixed.
- Paging: YouTube's continuations go through the existing FeedPages and FeedFooter, filtered, so scrolling loads more until YouTube's feed ends.
- Freshness: YouTube's answer is kept in memory for about 20 minutes (YouTube's own hint is 1200 s). It refreshes on pull to refresh, when the app returns after that time, and on connect and disconnect, but not on every history change, which would reshuffle the feed under the owner's thumb. No disk copy in v1.
- Parsing (field paths are confirmed in Phase 0): keep only video tiles. Skip ads at any depth, promo and upsell shelves, channel, topic and button tiles, paid or rental items, and anything unknown (counted by a debug counter). Shorts are recognised by every known marker and, as a fallback, by a missing duration on a tile that is not live. isLive, isUpcoming and isMembersOnly come from YouTube's own badges.
- Blocked channels: YouTube's cards name the channel but carry no id, so ContentFilter also matches a blocked channel by @handle or normalised name when a video has no channel id (rare wrong matches accepted). Blocking from such a card first looks up the channel id through the existing anonymous video details (cached 10 minutes).
- The tracking commands that come with cards are never fired, and raw replies are never logged or stored.

### Not interested and Don't recommend channel

- Each YouTube Home card gets a handle (YouTube's panel id and params), kept by video id in a side table for the session only, never in VideoSummary, which is saved to disk. Cleared on disconnect.
- The video menu shows "Not interested" only on cards that have a handle. Tapping it removes the card at once (a session list of dismissed ids that the filter honours), then asks YouTube in the background for that card's menu, finds the Not interested action by its structure, and sends it. No follow-up reasons, no undo.
- Blocking a channel from a YouTube Home card also sends "Don't recommend channel" for that card, but only after the card's menu names the same channel (its channel id, or its name when the card has no id); blocks made anywhere else stay local. Reason: YouTube's side cannot be undone from No Slop and applies to the whole account, including the official app, so it must never hit a different channel that happens to share a name. No pending flag.
- One switch covers both card actions, "Tell YouTube when I hide a video or a channel from Home", default on when connected.
- A failure never undoes the local action; Settings shows the last result.

### Reporting what you watch

- **When.** Once per viewing, after 30 seconds of played media time: pauses, seeks, SponsorBlock skips and loading do not count, and a resumed video counts from where it resumed. A video shorter than 30 seconds counts when it ends. Never for live streams or Shorts. A viewing starts only when the player starts a video, not on a quality change or a recovery. The counting is a pure kit type tested with tick patterns, like ProgressSaveThrottle.
- **What.** (1) Write a pending entry to its own file in Application Support before any network call, so a kill loses nothing. (2) One signed player request for that video with the legacy TV profile, only to get YouTube's tracking values for the account (ei, vm, of); the tracking values of No Slop's anonymous playback are not credited. (3) The playback ping, then a watchtime ping up to the current position, with a new 16-character client playback nonce (cpn) for this viewing. (4) Remove the entry.
- **How far.** The same tracking values serve the whole viewing: a watchtime ping about every 4 minutes while playing, and a closing one when the viewing ends (another video, close, the end, the app going to the background). Within the last 5% of the video, the "finished" pair. This also moves the account's resume point on YouTube.
- **Offline or failed sends.** Entries stay queued (at most 50, at most 7 days old) and are replayed with a fresh signed request on launch, when the app returns to the foreground, after a successful Home load, and when the player sees the network come back. YouTube will most likely date them at replay time.
- **Never on the player's path.** The hook returns at once; the work runs in a low-priority task; one report in flight per viewing; each report is bound to the token that started it, and the queue is dropped on disconnect.
- **Kill switch.** Three refusals in a row (bot check, unplayable, missing tracking values) pause reporting until the next launch and show it in Settings. Its own switch, "Send what I watch to YouTube", default on when connected.
- **Checking it works.** A debug-only "check history" action reads the account's history list with the TV connection and looks for the video. It is for Phase 0 and QA, not for normal use.

### Up next experiment (debug builds only)

For the playing video, also fetch YouTube's signed-in Up next and log it beside today's related list (account-type shelves, overlap). No change to the UI. The owner looks at five videos and decides; only if it is clearly theirs does a follow-up design replace the related list.

## Phase 0: test with a real account before building

Before any app code, a one-off probe (a small script on the Mac, not part of the app) runs once. The owner only approves the code in a browser, signed in to the throwaway Google account described below; the probe never sees a password.

1. Sign-in: request a code, approve it, get the tokens, refresh once; note what Google's page says.
2. Home: both browse ids; record the layout of page 1, one section continuation and one shelf continuation, and turn them into scrubbed fixtures for the parser tests.
3. Card menu: open one card's menu; send "Not interested" for one video.
4. Reporting: the signed legacy player request; the pings after 30 seconds; the history list a few minutes later; variants with and without signatureTimestamp and with and without the Authorization header on pings; one replay hours later to see the date YouTube shows.
5. Up next: one signed next beside an anonymous one.

The probe prints only status codes, key names and counts. Raw captures stay outside the repo and are deleted at the end; agents and fixtures only ever see scrubbed copies (no tokens, account ids, visitorData, IP addresses, and, for captures from the owner's main account, no real titles or channel names either). The grant is revoked afterwards.

Pass rules, written before the run:
- **Home** passes when a signed-in reply (YouTube marks it logged in) parses into real video tiles with a working continuation, and at least 8 videos remain after No Slop's filters within 3 pages, on at least 2 of 3 tries spread over a day (a thin or empty reply is tried again, since real users saw those on 26 to 30 Oct). Whether it is personal is the owner's call, comparing it with the official app's Home for the same account; that comparison also chooses the visitorData policy and the browse id.
- **Reporting** passes when the test video shows in the account's history list within 5 minutes, for 3 different videos in a row. An extra step the probe proves necessary (for example reading the web player's signatureTimestamp) is acceptable; the probe records the smallest working variant.
- **Card actions** pass when the card's menu yields both actions and YouTube accepts the feedback call without an error; a dismissed video that still comes back later is noted, not a failure, because YouTube honours these loosely.

Go or no-go: if Home does not pass, the feature stops there. Reporting and the card actions ship only if they pass; otherwise Home ships without them (and without reporting it may grow stale). The owner sees the Phase 0 results before anything is built, and the build plan is written only after the real captures exist.

*Owner* (8 Nov): the probe runs on a throwaway Google account, so it carries the account risk. The owner creates it and, before the run, watches about ten videos on one topic with it in a browser, so the probe can tell whether Home is personal. The owner's main account comes in only at the supervised connect at the end.

Later, on a real iPhone with a debug build: the Safari handoff of the code page, and whether the phone's networks trigger bot checks on signed requests. The last step of the build is a supervised first connect with the owner's real account on their iPhone; if that fails, the feature stays in the code with its entry points hidden until it is fixed.

## Spec and README amendments (part of this work)

- App spec, non-goal "YouTube's personalized algorithmic home feed": becomes a goal of the optional connection.
- App spec, anti-goal "we never scrape with their cookies or impersonate the official app with their credentials; account features use only the official YouTube Data API with OAuth": keep "never scrape with cookies", and add the scoped exception: the optional YouTube recommendations connection signs in as YouTube's TV app (*owner*'s decision, 4 Nov 2026), only for Home, card feedback and watch reports.
- App spec, anti-goal on watch history: still true. Reports go only to YouTube, only while connected and only with reporting on.
- README: a section "YouTube recommendations (optional)" beside "Sign in with Google"; correct the lines that say the app never shows YouTube's personalised Home and that only official APIs are used; How it works; Troubleshooting (TV profile versions); the Feed filters footer; any welcome text that only offers the Google sign-in.

## Risks the owner accepts

- It is against YouTube's terms, and Google can restrict the account or close the route. No verified bans were found for this route; yt-dlp's maintainers say it carries the same risk as using cookies.
- It can break any day (several breaks in 2024 to 2026). Home falls back; reporting pauses.
- The grant gives the app full YouTube access for that account (it is YouTube TV's grant). It is kept in the Keychain and can be revoked.
- The TV connection can be a different account from the Google sign-in, and Home, subscriptions and likes then disagree.

## Success looks like

- Connected, Home shows the account's own YouTube recommendations, close to the official app's Home at topic level, with no Shorts, ads, upsells, blocked channels or keywords.
- If reporting passed Phase 0: a video watched 30 seconds in No Slop shows in the account's YouTube history within a few minutes, and Home follows over time.
- Not interested removes a card at once, and YouTube took it in the Phase 0 check.
- When YouTube's route fails, Home quietly shows the on-device mix with a small notice, playback is unaffected, and Settings says what happened.
- After Disconnect, no token or account data is left on the device.

## Left to the builder

- Type and file names (suggested: a new NoSlopKit/Sources/NoSlopKit/Recommendations folder; new protocols, mocks and tests in new files), exact UI copy in the app's plain style, parser field paths after Phase 0, cache, budget and back-off values within the ranges above.
- The debug tooling: a mock connection that approves itself after a delay, a mock Home with a Short, a members-only, a live and a blocked-channel video, a recording reporter, launch flags and -uiScript steps in the existing style.
- The test design: hand-built fixtures first, scrubbed real ones after Phase 0; kit tests for sign-in (pending, slow_down, expired, declined, invalid_grant, one refresh at a time), the transport (allow-list, header only on TV requests, empty bodies), the parsers, the card-menu parsing, the 30-second tracker, the queue, the Home source decision, and that anonymous requests stay clean.
