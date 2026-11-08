# YouTube Recommendations Phase 0 (signed-in probe) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small command-line probe on the Mac that signs in to a throwaway Google account with YouTube's TV code flow, tries Home, the card menu, watch reporting and Up next against real YouTube, prints only status codes, key names and counts, turns captures into scrubbed fixtures, and checks the design's pass rules.

**Architecture:** A Python 3 package `scripts/tv-probe/tvprobe/` (standard library only) with one module per concern and an injectable `send` transport so every rule is unit-tested offline; a CLI `scripts/tv-probe/probe.py` with one subcommand per Phase 0 step; all secrets and raw captures live in a private state folder outside the repo. Tasks 1 to 6 build the probe; Task 7 is the run itself, which needs the owner.

**Tech Stack:** Apple's `/usr/bin/python3` (3.9.6, its LibreSSL trusts the system certificates; the python.org 3.13 on this Mac fails HTTPS with CERTIFICATE_VERIFY_FAILED), `unittest`, `urllib.request`, `json`, `secrets`, `re`, `dataclasses`.

**Spec:** `docs/superpowers/specs/2026-11-04-youtube-recommendations-design.md` (section "Phase 0") and its companion `docs/superpowers/specs/2026-11-04-youtube-recommendations-research.md` (request shapes, field paths, sources). Executors read both.

## Global Constraints

- The probe never prints, logs or commits: access or refresh tokens, the device code, the TV client id or secret, visitorData values, feedback tokens or panel params, the ei/vm/of values, or cookies. It prints the user code (the owner needs it) and presence flags ("ei: yes").
- Raw captures and all secrets stay in the state folder: `$NOSLOP_PROBE_DIR`, default `~/.noslop-tv-probe`, created with mode 0700, files 0600. It is deleted by `probe.py revoke` at the end.
- Committed fixtures are scrubbed copies only (no tokens, account ids, visitorData, IP addresses); `probe.py fixture` refuses to write a file in which the leak check finds anything.
- Requests go only to `www.youtube.com`, `youtubei.googleapis.com` and `oauth2.googleapis.com`; anything else raises before a socket opens. Redirects are not followed.
- Tracking commands that ride along with Home cards (impression, visibility, ad and inline-preview URLs) are never requested. The only pings sent are the playback and watchtime pings of `probe.py report`.
- Python 3.9 compatible (`from __future__ import annotations`, no `match`), standard library only, run with `/usr/bin/python3 -I`.
- Copy no code from GPL projects (Smart Tube BDP, the Kodi add-on, Opaline, TizenTube); constants and patterns may come from MIT or Unlicense sources (YouTube.js, SmartTube's MediaServiceCore, yt-dlp), with the source named in a comment.
- The owner's Mac is a fanless MacBook Air: no builds are needed here; keep runs short.
- Tests: `/usr/bin/python3 -I -m unittest discover -s scripts/tv-probe/tests -t scripts/tv-probe -v` must pass before every commit.
- Commits: conventional messages; last line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` after a blank line; never stage `.claude/` or `.compliify/`.

## Review Focus

1. A secret printed by an error path (an HTTP error body echoed, a traceback with a request, a repr of a dataclass holding a token): the CLI must still print nothing secret. Test in Task 1.
2. A signed-out or nudge-only Home reply counted as a pass: `home_try_passes` must fail when page 1 is not logged in, whatever its tiles. Test in Task 3.
3. An ad's inner tile counted as a video: the walker never descends into `adSlotRenderer`. Test in Task 3.
4. A history entry from an earlier report counted as a fresh pass: `report` refuses a video id it already reported unless `--force`. Test in Task 5.
5. Polling faster than allowed (ignoring `interval` or `slow_down`), which Google answers with rate limits: the poll loop never waits less than 5 s and adds 5 s after each `slow_down`. Test in Task 2.

---

### Task 1: Probe foundation (state folder, guarded transport, CLI skeleton)

**Files:**
- Create: `scripts/tv-probe/probe.py`, `scripts/tv-probe/tvprobe/__init__.py`, `scripts/tv-probe/tvprobe/state.py`, `scripts/tv-probe/tvprobe/http.py`, `scripts/tv-probe/README.md`
- Test: `scripts/tv-probe/tests/__init__.py`, `scripts/tv-probe/tests/test_state.py`, `scripts/tv-probe/tests/test_http.py`, `scripts/tv-probe/tests/test_cli_secrets.py`

**Interfaces:**
- Produces: `state.default_root() -> Path`; `class State(root: Path)` with `path(name: str) -> Path`, `write_json(name: str, obj) -> None`, `read_json(name: str, default=None)`, `log(event: str, **fields) -> None` (appends one JSON line to `log.jsonl`), `wipe() -> None`.
- Produces: `http.ALLOWED_HOSTS: frozenset[str]`, `class NotAllowed(Exception)`, `Response(status: int, headers: dict, body: bytes)` (a NamedTuple), `send(method: str, url: str, *, headers: dict | None = None, body: bytes | None = None, timeout: float = 30) -> Response`, `redact(headers: dict) -> dict`.
- Produces: `probe.main(argv: list[str], *, state: State | None = None, send=http.send) -> int`; every module function that talks to the network takes `send` as a keyword parameter.

- [ ] **Step 1: Write the failing tests**

```python
# test_state.py
def test_folder_and_files_are_private(self):
    st = State(Path(self.tmp) / "probe")
    st.write_json("tokens.json", {"a": 1})
    self.assertEqual(stat.S_IMODE(os.stat(st.root).st_mode), 0o700)
    self.assertEqual(stat.S_IMODE(os.stat(st.path("tokens.json")).st_mode), 0o600)

def test_log_refuses_secret_field_names(self):
    with self.assertRaises(ValueError):
        State(Path(self.tmp) / "p").log("signin", access_token="x")

def test_wipe_removes_everything(self):
    st = State(Path(self.tmp) / "p"); st.write_json("tokens.json", {}); st.wipe()
    self.assertFalse(st.root.exists())

# test_http.py
def test_other_hosts_are_refused_before_any_request(self):
    with self.assertRaises(NotAllowed):
        send("GET", "https://example.com/")

def test_redact_hides_authorization(self):
    self.assertEqual(redact({"Authorization": "Bearer abc"})["Authorization"], "<redacted>")

# test_cli_secrets.py: a fake send that answers every request with HTTP 500 and the body
# b'{"error":"x","access_token":"ya29.SECRET","refresh_token":"1//SECRET"}'
def test_failures_print_no_secret(self):
    out = run_cli(["refresh"], send=fake_500, tokens={"access_token": "ya29.SECRET", "refresh_token": "1//SECRET"})
    self.assertNotIn("SECRET", out.stdout + out.stderr)
```

`log` refuses any field whose name contains `token`, `secret`, `code`, `visitor`, `cookie` or `params` (case-insensitive).

- [ ] **Step 2: Run the tests and see them fail** (`/usr/bin/python3 -I -m unittest discover -s scripts/tv-probe/tests -t scripts/tv-probe -v`: import errors).

- [ ] **Step 3: Implement `state.py`, `http.py` and the CLI skeleton.** `send` uses `urllib.request` with an opener whose redirect handler returns 3xx responses instead of following them, sets no cookies, and converts `HTTPError` into a `Response`. `probe.main` builds an `argparse` parser with the subcommands `signin`, `refresh`, `home`, `menu`, `feedback`, `report`, `history`, `next`, `fixture`, `results`, `revoke` (later tasks fill them in; until then each prints "not implemented" and returns 2), catches every exception at the top and prints only its class name and a message that has passed through a filter removing anything that looks like a token (strings starting `ya29.` or `1//`, and any value longer than 40 characters without spaces). `scripts/tv-probe/README.md` says what the probe is for, the state folder, and the run order of Task 7 in five lines.

- [ ] **Step 4: Run the tests and see them pass.**

- [ ] **Step 5: Commit** `scripts/tv-probe/` with `chore(probe): Phase 0 probe foundation (private state folder, host allow-list, secret-free errors)`.

### Task 2: Sign-in (TV client values, device code, refresh, revoke)

**Files:**
- Create: `scripts/tv-probe/tvprobe/oauth.py`
- Modify: `scripts/tv-probe/probe.py` (subcommands `signin start`, `signin wait`, `refresh`, `revoke`)
- Test: `scripts/tv-probe/tests/test_oauth.py`

**Interfaces:**
- Consumes: `State`, `send` (Task 1).
- Produces: dataclasses `ClientValues(client_id: str, client_secret: str)`, `DeviceCode(device_code: str, user_code: str, verification_url: str, expires_in: int, interval: int, started_at: float)`, `Tokens(access_token: str, refresh_token: str, expires_at: float, scope: str)`, each with a `__repr__` that shows no values; `class SignInError(Exception)` with `.reason: str`; `find_base_script_url(tv_html: str) -> str | None`; `extract_client_values(script: str) -> ClientValues | None`; `fetch_client_values(*, send) -> ClientValues`; `request_device_code(client: ClientValues, device_id: str, *, send) -> DeviceCode`; `poll(client: ClientValues, code: DeviceCode, *, send, sleep=time.sleep, now=time.time) -> Tokens`; `refresh(client: ClientValues, tokens: Tokens, *, send, now=time.time) -> Tokens`; `revoke(tokens: Tokens, *, send) -> bool`; `valid_token(state: State, *, send, now=time.time) -> str` (refreshes when under 300 s are left; used by every later task).

Constants (from the research notes; YouTube.js and SmartTube are MIT):

```python
TV_PAGE = "https://www.youtube.com/tv"
TV_PAGE_USER_AGENT = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
DEVICE_CODE_URL = "https://www.youtube.com/o/oauth2/device/code"   # JSON body
TOKEN_URL = "https://www.youtube.com/o/oauth2/token"               # JSON body
DEVICE_GRANT = "http://oauth.net/grant_type/device/1.0"
SCOPE = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
DEVICE_MODEL = "ytlr::"
REVOKE_URLS = ("https://oauth2.googleapis.com/revoke", "https://www.youtube.com/o/oauth2/revoke")
CLIENT_PATTERN = r'clientId:"(?P<id>[^"]+)",[^"]*?:"(?P<secret>[^"]+)"'   # YouTube.js; first match only
```

- [ ] **Step 1: Write the failing tests**

```python
def test_first_client_pair_wins(self):
    script = 'x;clientId:"ID1",k:"S1";y;clientId:"ID2",k:"S2"'
    self.assertEqual(extract_client_values(script), ClientValues("ID1", "S1"))

def test_base_script_is_found(self):
    html = '<script id="base-js" src="/s/_/kabuki/_/js/k=a/m=base"></script>'
    self.assertEqual(find_base_script_url(html), "https://www.youtube.com/s/_/kabuki/_/js/k=a/m=base")

def test_poll_honours_interval_and_slow_down(self):
    # fake token endpoint: pending (HTTP 428), slow_down (HTTP 403), then 200 with tokens; interval=3 from the server
    tokens = poll(CLIENT, code(interval=3), send=scripted, sleep=sleeps.append, now=clock)
    self.assertEqual(sleeps, [5, 10, 10])
    self.assertEqual(tokens.refresh_token, "R")

def test_poll_stops_on_denied_and_expired(self):
    for error in ("access_denied", "expired_token"):
        with self.assertRaises(SignInError) as e:
            poll(CLIENT, code(), send=answer({"error": error}, status=403), sleep=lambda s: None, now=clock)
        self.assertEqual(e.exception.reason, error)

def test_refresh_keeps_a_returned_refresh_token(self):
    new = refresh(CLIENT, TOKENS, send=answer({"access_token": "A2", "expires_in": 3600, "refresh_token": "R2"}), now=lambda: 1000)
    self.assertEqual((new.access_token, new.refresh_token, new.expires_at), ("A2", "R2", 4600))

def test_refresh_without_one_keeps_the_old(self):
    new = refresh(CLIENT, TOKENS, send=answer({"access_token": "A2", "expires_in": 3600}), now=lambda: 1000)
    self.assertEqual(new.refresh_token, TOKENS.refresh_token)

def test_repr_shows_no_values(self):
    self.assertNotIn("R", repr(Tokens("A", "R", 0, "s")).replace("Tokens", ""))
```

Decide the error from the JSON `error` field whatever the HTTP status; `authorization_pending` keeps polling; the wait is `max(5, interval)` seconds, plus 5 for each `slow_down` so far; polling ends at `started_at + expires_in`.

- [ ] **Step 2: Run the tests and see them fail.**

- [ ] **Step 3: Implement `oauth.py` and the subcommands.** `signin start` fetches the client values (TV page with `TV_PAGE_USER_AGENT`, then the base script, first match), makes a random 32-hex `device_id` once per state folder, requests a device code, stores `client.json` and `device.json`, and prints exactly: the user code, `verification_url + "?user_code=" + user_code`, and the minutes until it expires. `signin wait` polls and stores `tokens.json`, then prints `connected` and the access token's lifetime in seconds. `refresh` refreshes and prints the new lifetime. `revoke` tries each `REVOKE_URLS` entry (form `token=<refresh token>` for the first, JSON `{"token": ...}` for the second), prints which answered 200, then wipes the state folder. Every step logs one event with statuses only.

- [ ] **Step 4: Run the tests and see them pass.**

- [ ] **Step 5: Commit** with `feat(probe): TV device-code sign-in, refresh and revoke`.

### Task 3: Home (TV requests, the tolerant walker, the pass check)

**Files:**
- Create: `scripts/tv-probe/tvprobe/innertube.py`, `scripts/tv-probe/tvprobe/home.py`
- Modify: `scripts/tv-probe/probe.py` (subcommand `home`)
- Test: `scripts/tv-probe/tests/test_home.py`, `scripts/tv-probe/tests/fixtures/` (hand-built JSON only)

**Interfaces:**
- Consumes: `valid_token` (Task 2), `State`, `send`.
- Produces: `innertube.PROFILES: dict[str, Profile]` with `Profile(client_version: str, user_agent: str)`; `innertube.context(profile: str, *, variant: str = "full", visitor: str | None = None) -> dict`; `innertube.post(endpoint: str, body: dict, *, token: str | None, profile: str = "tv", host: str = "www.youtube.com", visitor: str | None = None, send) -> tuple[int, dict | None]` (None for a non-JSON or 3xx reply).
- Produces: dataclass `Tile(video_id: str, title: str, channel_name: str | None, duration_text: str | None, is_short: bool, is_live: bool, is_upcoming: bool, is_members_only: bool, is_paid: bool, percent_watched: int | None, panel: tuple[str, str] | None)` with a `__repr__` that hides `panel`; dataclass `HomePage(logged_in: bool | None, tiles: list[Tile], skipped: Counter, unknown: Counter, section_continuation: str | None, shelf_continuations: list[str])`; `parse_home(reply: dict) -> HomePage` (first pages and both continuation shapes); `noslop_visible(tile: Tile) -> bool`; `home_try_passes(pages: list[HomePage]) -> tuple[bool, int]`.

Constants:

```python
PROFILES = {
    "tv": Profile("7.20260901.15.00", "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"),
    # TV_DOWNGRADED in SmartTube's MediaServiceCore (MIT): copy its exact old-Cobalt user agent from
    # DefaultHeaders / AppClient at master, and name the commit in a comment.
    "legacy": Profile("5.20260901", "<old Cobalt user agent from MediaServiceCore>"),
}
HOSTS = {"www": "www.youtube.com", "googleapis": "youtubei.googleapis.com"}
```

`context(variant="full")` follows SmartTube's TV browse body (clientName "TVHTML5", clientVersion, clientScreen "WATCH", userAgent, hl "en", gl "US", tvAppInfo {appQuality "TV_APP_QUALITY_FULL_ANIMATION", zylonLeftNav true}, plus `visitorData` when given); `variant="minimal"` is only clientName, clientVersion, hl, gl. `post` adds `Content-Type: application/json`, the profile's User-Agent, `Referer: https://www.youtube.com/tv`, `Authorization: Bearer <token>` when a token is given, `X-Goog-Visitor-Id` when a visitor is given, and no `key`.

- [ ] **Step 1: Write the failing tests** against hand-built JSON in `tests/fixtures/` (shaped from the research notes' paths: `contents.tvBrowseRenderer.content.tvSurfaceContentRenderer.content.sectionListRenderer.contents[] -> shelfRenderer -> content.horizontalListRenderer.items[] -> tileRenderer`).

```python
def test_a_full_page_keeps_only_real_videos(self):
    page = parse_home(load("home_mixed.json"))
    # home_mixed.json: one adSlotRenderer whose fulfillment holds a tileRenderer; a SHORTS shelf with 2 tiles;
    # a GRID_XL shelf with 3 video tiles (one LIVE overlay, one members-only badge, one plain);
    # a CHANNEL tile; an EDU tile; a lockupViewModel of LOCKUP_CONTENT_TYPE_SHORT; a gridButtonRenderer;
    # a section continuation and one shelf continuation; GFEEDBACK logged_in=1 in serviceTrackingParams.
    self.assertEqual([t.video_id for t in page.tiles if not t.is_short], ["vidLIVE0001", "vidMEMBER01", "vidPLAIN001"])
    self.assertEqual(page.skipped["adSlotRenderer"], 1)
    self.assertTrue(page.logged_in)
    self.assertIsNotNone(page.section_continuation)
    self.assertEqual(len(page.shelf_continuations), 1)

def test_a_tile_without_duration_that_is_not_live_is_a_short(self):
    self.assertTrue(parse_home(load("home_short_no_duration.json")).tiles[0].is_short)

def test_filters_match_noslop_defaults(self):
    t = Tile("v", "t", "c", "4:00", False, False, False, False, False, None, None)
    self.assertTrue(noslop_visible(t))
    self.assertFalse(noslop_visible(replace(t, is_short=True)))
    self.assertFalse(noslop_visible(replace(t, is_members_only=True)))
    self.assertFalse(noslop_visible(replace(t, is_paid=True)))
    self.assertTrue(noslop_visible(replace(t, is_live=True)))   # "hide live/upcoming" is off by default

def test_a_signed_out_page_never_passes(self):
    nudge = parse_home(load("home_signed_out.json"))   # searchBarRenderer + feedNudgeRenderer, logged_in=0
    self.assertFalse(nudge.logged_in)
    self.assertEqual(home_try_passes([nudge] + [many_videos_page()] * 2), (False, 0))

def test_eight_unique_visible_videos_within_three_pages_pass(self):
    self.assertEqual(home_try_passes([page_with(5), page_with(3, repeat_first=True), page_with(1)])[0], True)
```

`logged_in` comes from the `GFEEDBACK` service's `logged_in` param in `responseContext.serviceTrackingParams` ("1" true, "0" false, missing None). Unknown renderer names are counted in `unknown`, never treated as videos. `is_paid` is a YPC badge on the tile. `home_try_passes` counts unique ids of visible tiles over at most the first 3 pages and needs page 1 logged in.

- [ ] **Step 2: Run the tests and see them fail.**

- [ ] **Step 3: Implement `innertube.py`, `home.py` and `probe.py home`.** Options: `--browse-id FEwhat_to_watch|default` (default FEwhat_to_watch), `--host www|googleapis` (default www), `--context full|minimal` (default full), `--visitor none|first|tv` (none: no visitorData; first: take `responseContext.visitorData` of the first reply and send it on the continuations; tv: read it from the TV page), `--pages N` (default 3, following the section continuation), `--shelf` (also fetches the first shelf continuation of page 1 once, so its reply can become a fixture), `--capture NAME` (stores every raw reply under `captures/NAME-<n>.json` in the state folder). It prints one JSON object per page (logged_in, counts of tiles, Shorts, skipped and unknown renderer names, continuation present) and then `{"try_passes": bool, "visible_unique": n}`, and logs the same. It never requests any URL found inside a reply.

- [ ] **Step 4: Run the tests and see them pass.**

- [ ] **Step 5: Commit** with `feat(probe): signed TV Home browse, tolerant tile walker and the Home pass check`.

### Task 4: Card menu and feedback

**Files:**
- Create: `scripts/tv-probe/tvprobe/panel.py`
- Modify: `scripts/tv-probe/probe.py` (subcommands `menu`, `feedback`)
- Test: `scripts/tv-probe/tests/test_panel.py` (+ hand-built `tests/fixtures/panel_menu.json`)

**Interfaces:**
- Consumes: `Tile.panel` from the last Home capture (Task 3), `innertube.post`, `valid_token`.
- Produces: dataclass `PanelFindings(not_interested: str | None, dont_recommend: str | None, channel_id: str | None, handle: str | None, ambiguous: bool)` (repr hides the two tokens); `parse_panel(reply: dict) -> PanelFindings`.

- [ ] **Step 1: Write the failing tests**

```python
def test_both_actions_are_found_by_structure(self):
    f = parse_panel(load("panel_menu.json"))
    # panel_menu.json: content.engagementPanelSectionListRenderer.content.listViewModel.listItems[] with Play,
    # Save to Watch later, Go to channel (browseEndpoint UCabcdefghijklmnopqrstuv), Not interested
    # (onTap.innertubeCommand.feedbackEndpoint.feedbackToken "NI" with a dismissal follow-up action) and
    # Don't recommend channel (openPopupAction -> confirm button feedbackEndpoint.feedbackToken "DR");
    # header subtitle "Some Channel • @somechannel".
    self.assertEqual((f.not_interested, f.dont_recommend, f.channel_id, f.handle, f.ambiguous),
                     ("NI", "DR", "UCabcdefghijklmnopqrstuv", "@somechannel", False))

def test_two_candidates_are_ambiguous_and_send_nothing(self):
    f = parse_panel(load("panel_two_feedback_rows.json"))
    self.assertTrue(f.ambiguous)
    self.assertIsNone(f.not_interested)
```

Not interested is the row whose own `feedbackEndpoint` carries a dismissal follow-up; Don't recommend channel is the `feedbackEndpoint` inside an `openPopupAction`'s confirm button. More than one candidate of a kind sets `ambiguous` and both tokens to None.

- [ ] **Step 2: Run the tests and see them fail.**

- [ ] **Step 3: Implement `panel.py`, `probe.py menu --video <id>` and `probe.py feedback --video <id> --kind not-interested|dont-recommend`.** `menu` takes the tile's panel id and params from the latest Home capture, calls `get_panel` (`{context, panelId, params}`), stores the raw reply as a capture, and prints which actions, channel id and handle were found (presence only for tokens). `feedback` re-runs `menu` for that video, then posts `{context, feedbackTokens: [token]}` to `feedback`, prints the status and the top-level keys of the reply (for example whether `feedbackResponses[].isProcessed` exists and its value), and logs it. `dont-recommend` refuses unless `--confirm-channel <id>` equals the panel's channel id (the design's rule).

- [ ] **Step 4: Run the tests and see them pass.**

- [ ] **Step 5: Commit** with `feat(probe): card menu through get_panel and Not interested / Don't recommend feedback`.

### Task 5: Watch reporting and the history check

**Files:**
- Create: `scripts/tv-probe/tvprobe/report.py`
- Modify: `scripts/tv-probe/probe.py` (subcommands `report`, `history`)
- Test: `scripts/tv-probe/tests/test_report.py` (+ hand-built `tests/fixtures/player_signed.json`, `history_grid.json`, `history_tabs.json`)

**Interfaces:**
- Consumes: `innertube.post` with profile `legacy`, `valid_token`, `State`.
- Produces: `signature_timestamp(*, send) -> int | None` (GET `https://www.youtube.com/` with a desktop Safari user agent, first match of `"STS":(\d+)`); dataclass `PlayerTracking(status: str, has_ei: bool, has_vm: bool, has_of: bool, playback_url: str | None, watchtime_url: str | None, length: float | None)` (repr hides the URLs); `tracking_from_player(reply: dict) -> PlayerTracking`; `new_cpn() -> str`; `ping_url(base_url: str, *, kind: str, docid: str, length: float, cpn: str, cmt: float, st: float | None = None, et: float | None = None, final: bool = False) -> str`; `history_has(reply: dict, video_id: str) -> tuple[bool, int | None]`.

- [ ] **Step 1: Write the failing tests**

```python
def test_ping_keeps_the_base_items_and_moves_to_www(self):
    base = "https://s.youtube.com/api/stats/watchtime?cl=1&docid=v&ei=E&el=leanback&of=O&plid=P&vm=V&len=60"
    url = ping_url(base, kind="watchtime", docid="v", length=60.0, cpn="c" * 16, cmt=30.0, st=0.0, et=30.0)
    q = parse_qs(urlparse(url).query)
    self.assertTrue(url.startswith("https://www.youtube.com/api/stats/watchtime?"))
    for key in ("cl", "ei", "el", "of", "plid", "vm"):
        self.assertIn(key, q)
    self.assertEqual((q["ns"], q["ver"], q["cmt"], q["st"], q["et"]), (["yt"], ["2"], ["30.000"], ["0.000"], ["30.000"]))
    self.assertNotIn("final", q)

def test_final_ping_says_so(self):
    self.assertIn("final=1", ping_url(BASE, kind="watchtime", docid="v", length=60.0, cpn="c" * 16, cmt=60.0, st=0.0, et=60.0, final=True))

def test_cpn_has_sixteen_allowed_characters(self):
    self.assertRegex(new_cpn(), r"^[A-Za-z0-9_-]{16}$")

def test_tracking_needs_ei_vm_and_of(self):
    t = tracking_from_player(load("player_signed.json"))   # playabilityStatus OK + playbackTracking with ei, vm, of
    self.assertEqual((t.status, t.has_ei, t.has_vm, t.has_of), ("OK", True, True, True))

def test_history_finds_the_video_in_both_layouts(self):
    self.assertEqual(history_has(load("history_grid.json"), "vidWATCHED1"), (True, 50))
    self.assertEqual(history_has(load("history_tabs.json"), "vidWATCHED1")[0], True)
    self.assertEqual(history_has(load("history_grid.json"), "vidNOTTHERE"), (False, None))

def test_a_video_is_reported_once_unless_forced(self):
    # probe.main(["report", "--video", "v1", "--delay", "0"]) twice with a fake send: the second exits 2 and
    # sends nothing; with "--force" it reports again.
```

- [ ] **Step 2: Run the tests and see them fail.**

- [ ] **Step 3: Implement `report.py`, `probe.py report` and `probe.py history`.** `report --video <id> [--sts on|off] [--auth-on-pings on|off] [--delay SECONDS] [--force]` (defaults on, on, 30): mints a signed `player` request (legacy profile, body `{context, videoId, racyCheckOk: true, contentCheckOk: true}` plus `playbackContext.contentPlaybackContext {html5Preference: "HTML5_PREF_WANTS", signatureTimestamp}` when `--sts on`), prints the playability status and the presence flags, waits `--delay` seconds, sends the playback ping (`cmt=0`) and then the watchtime ping (`st=0`, `et=cmt=delay`), each with the profile's user agent, `Referer: https://www.youtube.com/tv` and, when `--auth-on-pings on`, the Bearer header; prints both statuses; records the video id and the time in `reported.json`. `history --video <id>` browses `FEhistory` signed (tv profile) and prints `{"found": bool, "percent": n}`; the runner calls it a few minutes after a report.

- [ ] **Step 4: Run the tests and see them pass.**

- [ ] **Step 5: Commit** with `feat(probe): signed tracking request, playback and watchtime pings, history check`.

### Task 6: Up next, scrubbed fixtures and the results summary

**Files:**
- Create: `scripts/tv-probe/tvprobe/upnext.py`, `scripts/tv-probe/tvprobe/scrub.py`, `scripts/tv-probe/tvprobe/results.py`
- Modify: `scripts/tv-probe/probe.py` (subcommands `next`, `fixture`, `results`)
- Test: `scripts/tv-probe/tests/test_scrub.py`, `scripts/tv-probe/tests/test_upnext.py`, `scripts/tv-probe/tests/test_results.py`

**Interfaces:**
- Consumes: captures and `log.jsonl` in the state folder; `innertube.post`.
- Produces: `parse_next(reply: dict) -> NextSummary(logged_in: bool | None, shelf_titles: list[str], video_ids: list[str])`; `overlap(a: list[str], b: list[str]) -> float` (share of `a` also in `b`); `scrub(obj, *, hide_titles: bool = False)` (returns a new object); `leaks(text: str) -> list[str]`; `summarize(log_lines: list[dict]) -> str` (a Markdown block with each pass rule, the tries behind it and the verdict).

- [ ] **Step 1: Write the failing tests**

```python
def test_scrub_removes_every_secret_class(self):
    raw = {"responseContext": {"visitorData": "CgtABC", "serviceTrackingParams": [{"service": "GFEEDBACK"}]},
           "trackingParams": "T", "x": {"clickTrackingParams": "C", "continuation": "CONT", "feedbackToken": "F",
           "url": "https://rr1---sn-abc.googlevideo.com/videoplayback?ip=81.2.3.4&id=1", "params": "P"},
           "frameworkUpdates": {"big": 1}}
    out = json.dumps(scrub(raw))
    for secret in ("CgtABC", "\"T\"", "\"C\"", "CONT", "\"F\"", "81.2.3.4", "googlevideo", "\"P\"", "frameworkUpdates"):
        self.assertNotIn(secret, out)
    self.assertEqual(leaks(out), [])

def test_continuations_keep_a_placeholder(self):
    self.assertEqual(scrub({"continuation": "CONT"}), {"continuation": "CONTINUATION_1"})

def test_leaks_catches_tokens_and_addresses(self):
    self.assertEqual(sorted(leaks('{"a":"ya29.xyz","b":"1//0abc","c":"10.0.0.7","d":"203.0.113.7"}')),
                     ["10.0.0.7", "1//0abc", "ya29.xyz"])

def test_overlap(self):
    self.assertEqual(overlap(["a", "b", "c", "d"], ["b", "d", "x"]), 0.5)

def test_summary_applies_the_pass_rules(self):
    text = summarize(LOG_TWO_HOME_PASSES_OF_THREE + LOG_THREE_REPORTS_FOUND + LOG_FEEDBACK_OK)
    self.assertIn("Home: pass (2 of 3 tries)", text)
    self.assertIn("Reporting: pass (3 of 3 videos found in history within 5 minutes)", text)
    self.assertIn("Card actions: pass", text)
```

`scrub` replaces every value under keys matching `token`, `Token`, `params`, `Params`, `visitorData`, `serializedShareEntity` with a placeholder, numbers continuation tokens `CONTINUATION_<n>` in order, replaces googlevideo, `s.youtube.com` and `/api/stats/` URLs with `https://example.invalid/`, replaces IPv4 addresses with `203.0.113.7`, drops `frameworkUpdates` and `responseContext.serviceTrackingParams` (keeping a top-level `"_loggedIn": true|false|null` so tests still know), and with `hide_titles` also replaces titles and channel names with `Title N` and `Channel N`. `leaks` finds `ya29.`, `1//`, `Bearer `, and IPv4 addresses other than 203.0.113.7.

- [ ] **Step 2: Run the tests and see them fail.**

- [ ] **Step 3: Implement the three modules and the subcommands.** `next --video <id>` posts `next` signed and anonymously (same tv profile and context), prints both summaries and the overlap. `fixture --capture <NAME-n> --out <repo path> [--hide-titles]` writes the scrubbed, pretty-printed JSON only if `leaks` finds nothing (otherwise it exits 2 and lists what it found, masked). `results` prints `summarize` over `log.jsonl`. Home tries are judged by `try_passes`; reporting by a `history` event with `found: true` within 300 s of its `report` event; card actions by a feedback event with HTTP 200 and no `error` key.

- [ ] **Step 4: Run the tests and see them pass.**

- [ ] **Step 5: Commit** with `feat(probe): Up next comparison, scrubbed fixtures with a leak check, pass-rule summary`.

### Task 7: The Phase 0 run (needs the owner)

**Files:**
- Create: `NoSlopKit/Tests/NoSlopKitTests/Fixtures/tv_home_page1.json`, `tv_home_section_cont.json`, `tv_home_shelf_cont.json`, `tv_panel_menu.json`, `tv_player_signed.json`, `tv_history.json`, `tv_next_signed.json` (scrubbed, through `probe.py fixture` only)
- Create: `docs/superpowers/specs/2026-11-08-youtube-recommendations-phase0-results.md`

- [ ] **Step 1: Owner preparation.** The owner creates a new Google account, turns YouTube watch history on, and watches about ten videos on one topic with it in a browser (so its Home can be personal). The orchestrator asks for this and waits for "ready".
- [ ] **Step 2: Sign in.** `/usr/bin/python3 -I scripts/tv-probe/probe.py signin start`; the orchestrator gives the owner the code and the link; the owner approves it in any browser while signed in to the throwaway account and notes what Google's page says (expected "YouTube on TV"); then `signin wait`, then `refresh` once.
- [ ] **Step 3: Home, first try.** `home --capture home1 --shelf` with the defaults; then once each `--browse-id default`, `--host googleapis`, `--context minimal`, `--visitor first`, `--visitor tv`. The owner compares page 1 with the official YouTube app's Home on the same throwaway account and says whether it looks like the same, personal feed.
- [ ] **Step 4: Card menu.** `menu --video <a video from home1>`, then `feedback --video <same> --kind not-interested`. No `dont-recommend` on this account unless the owner asks.
- [ ] **Step 5: Reporting.** The pass rule first: three videos never watched on this account, one after another, each `report --video <id>` with the defaults, then `history --video <id>` after 2 and 5 minutes. Then, only if those pass, two more fresh videos to find the smallest working variant: one with `--sts off`, one with `--auth-on-pings off`; these are informational and do not change the verdict. The log records which variant credited.
- [ ] **Step 6: Up next.** `next --video <a video of the seeded topic>`.
- [ ] **Step 7: Home, second and third try, and the late replay.** `home --capture home2` and `home --capture home3` hours apart; at the last one, `report --video <a fourth fresh id> --delay 0` once more and check the date the video shows under in the account's history (the owner looks at youtube.com/feed/history on the throwaway account).
- [ ] **Step 8: Fixtures.** Write the seven fixtures with `probe.py fixture` from the captures (titles kept: they come from the throwaway account); read each one before committing.
- [ ] **Step 9: Results.** `probe.py results`; write `docs/superpowers/specs/2026-11-08-youtube-recommendations-phase0-results.md` with the summary, the owner's personalisation verdict, the smallest working request variants (host, browse id, context, visitor policy, STS, ping header), what Google's page said, the access-token lifetime, and the go or no-go for each feature as the design defines it.
- [ ] **Step 10: Revoke and clean up.** `probe.py revoke` (wipes the state folder); confirm the folder is gone; the owner removes "YouTube TV" from the throwaway account's third-party connections if `revoke` did not get a 200.
- [ ] **Step 11: Commit** the fixtures and the results document with `docs(phase0): signed-in probe results and scrubbed TV fixtures`, then show the owner the results before any build plan is written.
