from __future__ import annotations

import contextlib
import io
import json
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from urllib.parse import urlsplit

import probe
from tvprobe import http, innertube
from tvprobe.home import HomePage, Tile, home_try_passes, noslop_visible, parse_home
from tvprobe.state import State

FIX = Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIX / name).read_text())


def tile(vid, **kw):
    base = dict(video_id=vid, title="t", channel_name="c", duration_text="4:00", is_short=False, is_live=False,
                is_upcoming=False, is_members_only=False, is_paid=False, percent_watched=None, panel=None)
    base.update(kw)
    return Tile(**base)


def page_with(n, *, start=0, repeat_first=False, logged_in=True):
    shift = 5 if repeat_first else 0  # a repeat page: one id seen on page 1, the others new
    tiles = [tile("v%03d" % (start + shift + i)) for i in range(n)]
    if repeat_first:
        tiles[0] = tile("v000")
    return HomePage(logged_in=logged_in, tiles=tiles)


def many_videos_page():
    return page_with(20, start=100)


class WalkerTests(unittest.TestCase):
    def test_a_full_page_keeps_only_real_videos(self):
        page = parse_home(load("home_mixed.json"))
        self.assertEqual([t.video_id for t in page.tiles if not t.is_short],
                         ["vidLIVE0001", "vidMEMBER01", "vidPLAIN001"])
        self.assertEqual(page.skipped["adSlotRenderer"], 1)
        self.assertNotIn("vidAD00001", [t.video_id for t in page.tiles])
        self.assertTrue(page.logged_in)
        self.assertEqual(page.section_continuation, "SECTIONCONT-1")
        self.assertEqual(len(page.shelf_continuations), 1)
        self.assertEqual(page.skipped["gridButtonRenderer"], 1)

    def test_shorts_channels_and_edu_are_not_videos(self):
        page = parse_home(load("home_mixed.json"))
        shorts = sorted(t.video_id for t in page.tiles if t.is_short)
        self.assertEqual(shorts, ["vidLOCKSH01", "vidSHORT001", "vidSHORT002"])
        self.assertNotIn("UCchannel001", [t.video_id for t in page.tiles])
        self.assertNotIn("vidEDU00001", [t.video_id for t in page.tiles])

    def test_flags_come_from_overlays_and_badges(self):
        by_id = {t.video_id: t for t in parse_home(load("home_mixed.json")).tiles}
        self.assertTrue(by_id["vidLIVE0001"].is_live)
        self.assertIsNone(by_id["vidLIVE0001"].duration_text)
        self.assertFalse(by_id["vidLIVE0001"].is_short)
        self.assertTrue(by_id["vidMEMBER01"].is_members_only)
        plain = by_id["vidPLAIN001"]
        self.assertEqual((plain.title, plain.channel_name, plain.duration_text, plain.percent_watched),
                         ("Plain video", "Some Channel", "4:00", 40))
        self.assertFalse(plain.is_members_only or plain.is_paid)
        self.assertEqual(plain.panel, ("PAcontext_menu", "FAKEPARAMS-vidPLAIN001"))

    def test_a_ypc_badge_marks_a_tile_paid(self):
        reply = load("home_mixed.json")
        shelf = reply["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]["content"][
            "sectionListRenderer"]["contents"][2]["shelfRenderer"]["content"]["horizontalListRenderer"]["items"]
        shelf[2]["tileRenderer"]["metadata"]["tileMetadataRenderer"]["lines"][0]["lineRenderer"]["items"].append(
            {"lineItemRenderer": {"badge": {"metadataBadgeRenderer": {"style": "BADGE_STYLE_TYPE_YPC"}}}})
        by_id = {t.video_id: t for t in parse_home(reply).tiles}
        self.assertTrue(by_id["vidPLAIN001"].is_paid)

    def test_a_tile_without_duration_that_is_not_live_is_a_short(self):
        self.assertTrue(parse_home(load("home_short_no_duration.json")).tiles[0].is_short)

    def test_an_ad_inside_a_shelf_is_skipped_and_not_walked(self):
        reply = load("home_mixed.json")
        sections = reply["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]["content"][
            "sectionListRenderer"]["contents"]
        ad = sections.pop(0)
        sections[1]["shelfRenderer"]["content"]["horizontalListRenderer"]["items"].insert(0, ad)
        page = parse_home(reply)
        self.assertEqual(page.skipped["adSlotRenderer"], 1)
        self.assertNotIn("vidAD00001", [t.video_id for t in page.tiles])

    def test_unknown_renderers_are_counted_not_taken_for_videos(self):
        reply = load("home_mixed.json")
        sections = reply["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]["content"][
            "sectionListRenderer"]["contents"]
        sections.append({"mysteryRenderer": {"tileRenderer": {"contentId": "vidHIDDEN01"}}})
        page = parse_home(reply)
        self.assertEqual(page.unknown["mysteryRenderer"], 1)
        self.assertNotIn("vidHIDDEN01", [t.video_id for t in page.tiles])

    def test_a_section_continuation_reply_parses(self):
        page = parse_home(load("home_section_continuation.json"))
        self.assertEqual([t.video_id for t in page.tiles], ["vidNEXT0001", "vidNEXT0002"])
        self.assertEqual(page.section_continuation, "SECTIONCONT-2")

    def test_a_shelf_continuation_reply_parses(self):
        page = parse_home(load("home_shelf_continuation.json"))
        self.assertEqual([t.video_id for t in page.tiles], ["vidMORE0001"])
        self.assertIsNone(page.section_continuation)

    def test_logged_in_is_none_when_the_flag_is_missing(self):
        self.assertIsNone(parse_home({"contents": {}}).logged_in)

    def test_reprs_hide_params_and_continuations(self):
        page = parse_home(load("home_mixed.json"))
        text = repr(page) + repr(page.tiles)
        for secret in ("FAKEPARAMS", "SECTIONCONT", "SHELFCONT"):
            self.assertNotIn(secret, text)


class PassCheckTests(unittest.TestCase):
    def test_filters_match_noslop_defaults(self):
        t = tile("v")
        self.assertTrue(noslop_visible(t))
        self.assertFalse(noslop_visible(replace(t, is_short=True)))
        self.assertFalse(noslop_visible(replace(t, is_members_only=True)))
        self.assertFalse(noslop_visible(replace(t, is_paid=True)))
        self.assertTrue(noslop_visible(replace(t, is_live=True)))

    def test_a_signed_out_page_never_passes(self):
        nudge = parse_home(load("home_signed_out.json"))
        self.assertFalse(nudge.logged_in)
        self.assertEqual(home_try_passes([nudge] + [many_videos_page()] * 2), (False, 0))

    def test_a_page_with_unknown_login_never_passes(self):
        self.assertEqual(home_try_passes([page_with(20, logged_in=None)]), (False, 0))

    def test_eight_unique_visible_videos_within_three_pages_pass(self):
        self.assertEqual(home_try_passes([page_with(5), page_with(3, repeat_first=True), page_with(1, start=50)]),
                         (True, 8))

    def test_seven_do_not_pass(self):
        self.assertEqual(home_try_passes([page_with(5), page_with(3, repeat_first=True)]), (False, 7))

    def test_a_fourth_page_does_not_count(self):
        pages = [page_with(2), page_with(2, start=10), page_with(2, start=20), page_with(9, start=30)]
        self.assertEqual(home_try_passes(pages), (False, 6))

    def test_hidden_tiles_do_not_count(self):
        shorts = HomePage(True, [tile("s%d" % i, is_short=True) for i in range(12)])
        self.assertEqual(home_try_passes([shorts]), (False, 0))


class InnertubeTests(unittest.TestCase):
    def test_legacy_profile_names_its_source(self):
        self.assertTrue(innertube.PROFILES["legacy"].client_version.startswith("5."))
        self.assertIn("Cobalt", innertube.PROFILES["legacy"].user_agent)
        self.assertTrue(innertube.PROFILES["tv"].client_version.startswith("7."))

    def test_full_and_minimal_contexts(self):
        full = innertube.context("tv", visitor="FAKEVISITOR")["client"]
        self.assertEqual(full["clientName"], "TVHTML5")
        self.assertEqual(full["clientScreen"], "WATCH")
        self.assertEqual(full["tvAppInfo"]["appQuality"], "TV_APP_QUALITY_FULL_ANIMATION")
        self.assertTrue(full["tvAppInfo"]["zylonLeftNav"])
        self.assertEqual(full["visitorData"], "FAKEVISITOR")
        self.assertNotIn("visitorData", innertube.context("tv")["client"])
        minimal = innertube.context("tv", variant="minimal")["client"]
        self.assertEqual(sorted(minimal), ["clientName", "clientVersion", "gl", "hl"])

    def test_post_headers_and_url(self):
        seen = {}

        def send(method, url, **kw):
            seen.update(method=method, url=url, headers=kw["headers"], body=kw["body"])
            return http.Response(200, {}, b'{"a": 1}')
        status, data = innertube.post("browse", {"x": 1}, token="FAKETOKEN", visitor="FAKEVISITOR",
                                      host="youtubei.googleapis.com", send=send)
        self.assertEqual((status, data), (200, {"a": 1}))
        self.assertEqual(urlsplit(seen["url"]).netloc, "youtubei.googleapis.com")
        self.assertNotIn("key=", seen["url"])
        h = seen["headers"]
        self.assertEqual(h["Authorization"], "Bearer FAKETOKEN")
        self.assertEqual(h["X-Goog-Visitor-Id"], "FAKEVISITOR")
        self.assertEqual(h["Referer"], "https://www.youtube.com/tv")
        self.assertEqual(h["Content-Type"], "application/json")
        self.assertEqual(h["User-Agent"], innertube.PROFILES["tv"].user_agent)

    def test_post_without_token_or_visitor_sends_neither_header(self):
        seen = {}

        def send(method, url, **kw):
            seen.update(kw["headers"])
            return http.Response(200, {}, b"{}")
        innertube.post("next", {}, token=None, send=send)
        self.assertNotIn("Authorization", seen)
        self.assertNotIn("X-Goog-Visitor-Id", seen)

    def test_non_json_and_redirects_give_none(self):
        self.assertEqual(innertube.post("browse", {}, token=None,
                                        send=lambda *a, **k: http.Response(200, {}, b"<html>"))[1], None)
        self.assertEqual(innertube.post("browse", {}, token=None,
                                        send=lambda *a, **k: http.Response(302, {}, b"{}")), (302, None))


class HomeCommandTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.state = State(Path(self.td.name) / "s")
        self.state.write_json("tokens.json", {"access_token": "ya29.FAKEACCESS", "refresh_token": "1//FAKEREFRESH",
                                              "expires_at": time.time() + 3000, "scope": "s"})
        self.calls = []

    def fake(self, replies):
        def send(method, url, **kw):
            self.calls.append((method, url, kw.get("headers") or {}, kw.get("body")))
            reply = replies.pop(0)
            return http.Response(200, {}, json.dumps(reply).encode())
        return send

    def run_cli(self, argv, send):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = probe.main(argv, state=self.state, send=send)
        return code, out.getvalue(), err.getvalue()

    def three_pages(self):
        first = load("home_mixed.json")
        return [first, load("home_section_continuation.json"), load("home_section_continuation.json")]

    def test_home_follows_the_section_continuation_and_prints_counts_only(self):
        replies = self.three_pages()
        code, out, err = self.run_cli(["home", "--capture", "t1"], self.fake(replies))
        self.assertEqual(code, 0, err)
        lines = [json.loads(l) for l in out.strip().splitlines()]
        self.assertEqual(len(lines), 4)
        self.assertTrue(lines[0]["logged_in"])
        self.assertEqual(lines[0]["shorts"], 3)
        self.assertTrue(lines[0]["continuation"])
        self.assertEqual(lines[-1], {"try_passes": False, "visible_unique": 4})
        for secret in ("FAKEACCESS", "FAKEREFRESH", "SECTIONCONT", "SHELFCONT", "FAKEPARAMS"):
            self.assertNotIn(secret, out + err)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(json.loads(self.calls[1][3])["continuation"], "SECTIONCONT-1")
        self.assertEqual(json.loads(self.calls[0][3])["browseId"], "FEwhat_to_watch")
        self.assertEqual(self.calls[0][2]["Authorization"], "Bearer ya29.FAKEACCESS")
        self.assertEqual(self.state.read_json("captures/t1-2.json")["responseContext"]["serviceTrackingParams"][1]
                         ["service"], "GFEEDBACK")

    def test_shelf_fetches_one_shelf_continuation_and_does_not_count_it(self):
        replies = [load("home_mixed.json"), load("home_shelf_continuation.json")]
        code, out, err = self.run_cli(["home", "--pages", "1", "--shelf", "--capture", "t2"], self.fake(replies))
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(self.calls[1][3])["continuation"], "SHELFCONT-1")
        self.assertIsNotNone(self.state.read_json("captures/t2-shelf.json"))
        self.assertEqual(json.loads(out.strip().splitlines()[-1])["visible_unique"], 2)

    def test_options_choose_host_context_and_browse_id(self):
        replies = [load("home_signed_out.json")]
        code, out, err = self.run_cli(["home", "--host", "googleapis", "--context", "minimal",
                                       "--browse-id", "default", "--pages", "1"], self.fake(replies))
        self.assertEqual(code, 0, err)
        self.assertEqual(urlsplit(self.calls[0][1]).netloc, "youtubei.googleapis.com")
        body = json.loads(self.calls[0][3])
        self.assertEqual(body["browseId"], "default")
        self.assertNotIn("clientScreen", body["context"]["client"])
        self.assertEqual(json.loads(out.strip().splitlines()[-1]), {"try_passes": False, "visible_unique": 0})

    def test_visitor_first_sends_the_reply_value_on_continuations(self):
        first = load("home_mixed.json")
        first["responseContext"]["visitorData"] = "FAKEVISITORDATA"
        replies = [first, load("home_section_continuation.json")]
        code, out, err = self.run_cli(["home", "--pages", "2", "--visitor", "first"], self.fake(replies))
        self.assertEqual(code, 0, err)
        self.assertNotIn("X-Goog-Visitor-Id", self.calls[0][2])
        self.assertEqual(self.calls[1][2]["X-Goog-Visitor-Id"], "FAKEVISITORDATA")
        self.assertEqual(json.loads(self.calls[1][3])["context"]["client"]["visitorData"], "FAKEVISITORDATA")
        self.assertNotIn("FAKEVISITORDATA", out + err)

    def test_visitor_tv_reads_the_tv_page(self):
        calls = []

        def send(method, url, **kw):
            calls.append((method, url))
            if method == "GET":
                return http.Response(200, {}, b'... "visitorData":"FAKEVISITORFROMTV" ...')
            return http.Response(200, {}, json.dumps(load("home_signed_out.json")).encode())
        code, out, err = self.run_cli(["home", "--pages", "1", "--visitor", "tv"], send)
        self.assertEqual(code, 0, err)
        self.assertEqual(calls[0], ("GET", "https://www.youtube.com/tv"))
        self.assertNotIn("FAKEVISITORFROMTV", out + err)

    def test_an_http_error_stops_without_echoing_the_body(self):
        def send(method, url, **kw):
            return http.Response(400, {}, b'{"error": "ya29.LEAK"}')
        code, out, err = self.run_cli(["home"], send)
        self.assertEqual(code, 0)
        self.assertIn('"status": 400', out)
        self.assertNotIn("LEAK", out + err)

    def test_a_bad_capture_name_is_refused(self):
        code, out, err = self.run_cli(["home", "--capture", "../x"], self.fake([]))
        self.assertEqual(code, 1)
        self.assertEqual(self.calls, [])

    def test_the_log_holds_counts_not_secrets(self):
        self.run_cli(["home", "--pages", "1"], self.fake([load("home_mixed.json")]))
        text = (self.state.root / "log.jsonl").read_text()
        for secret in ("FAKEACCESS", "SECTIONCONT", "FAKEPARAMS"):
            self.assertNotIn(secret, text)
        self.assertIn("home_try", text)


class ScrubbedFlagTests(unittest.TestCase):
    def test_the_logged_in_flag_left_by_scrub_is_read(self):
        self.assertIs(parse_home({"_loggedIn": True}).logged_in, True)
        self.assertIs(parse_home({"_loggedIn": False}).logged_in, False)


if __name__ == "__main__":
    unittest.main()
