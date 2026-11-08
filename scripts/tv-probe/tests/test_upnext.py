from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import probe
from tvprobe import http
from tvprobe.state import State
from tvprobe.upnext import parse_next


def tile(vid):
    return {"tileRenderer": {"contentType": "TILE_CONTENT_TYPE_VIDEO",
                             "onSelectCommand": {"watchEndpoint": {"videoId": vid}},
                             "metadata": {"tileMetadataRenderer": {"title": {"simpleText": "T " + vid}}},
                             "header": {"tileHeaderRenderer": {"thumbnailOverlays": [
                                 {"thumbnailOverlayTimeStatusRenderer": {"text": {"simpleText": "5:00"}}}]}}}}


def shelf(title, vids):
    return {"shelfRenderer": {"headline": {"simpleText": title},
                              "content": {"horizontalListRenderer": {"items": [tile(v) for v in vids]}}}}


def reply(logged_in, shelves):
    ctx = {}
    if logged_in is not None:
        ctx = {"serviceTrackingParams": [{"service": "GFEEDBACK",
                                          "params": [{"key": "logged_in", "value": "1" if logged_in else "0"}]}]}
    return {"responseContext": ctx, "contents": {"singleColumnWatchNextResults": {"pivot": {
        "sectionListRenderer": {"contents": shelves}}}}}


class ParseNextTests(unittest.TestCase):
    def test_titles_ids_and_login(self):
        s = parse_next(reply(True, [shelf("Watch it again", ["a", "b"]), shelf("More recommended for you", ["c"])]))
        self.assertIs(s.logged_in, True)
        self.assertEqual(s.shelf_titles, ["Watch it again", "More recommended for you"])
        self.assertEqual(s.video_ids, ["a", "b", "c"])

    def test_duplicates_collapse_in_order(self):
        s = parse_next(reply(False, [shelf("A", ["a", "b"]), shelf("B", ["b", "c"])]))
        self.assertIs(s.logged_in, False)
        self.assertEqual(s.video_ids, ["a", "b", "c"])

    def test_unknown_login_and_empty_reply(self):
        s = parse_next({})
        self.assertEqual((s.logged_in, s.shelf_titles, s.video_ids), (None, [], []))

    def test_an_ad_inner_tile_is_not_a_video(self):
        ad = {"adSlotRenderer": {"fulfillmentContent": tile("ad1")}}
        s = parse_next(reply(True, [{"shelfRenderer": {"content": {"horizontalListRenderer": {
            "items": [ad, tile("a")]}}}}]))
        self.assertEqual(s.video_ids, ["a"])

    def test_the_summary_repr_shows_no_ids(self):
        self.assertNotIn("abc", repr(parse_next(reply(True, [shelf("S", ["abc"])]))))


def run(argv, replies, *, tokens=True):
    calls = []

    def send(method, url, **kw):
        calls.append((url, kw.get("headers") or {}))
        status, body = replies.pop(0)
        return http.Response(status, {}, json.dumps(body).encode())

    with tempfile.TemporaryDirectory() as td:
        st = State(Path(td) / "s")
        if tokens:
            st.write_json("tokens.json", {"access_token": "ya29.FAKE", "refresh_token": "1//FAKE",
                                          "expires_at": 4102444800, "scope": "x"})
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = probe.main(argv, state=st, send=send)
        captures = sorted(p.name for p in (Path(td) / "s" / "captures").glob("*")) if (
            Path(td) / "s" / "captures").exists() else []
        log = (Path(td) / "s" / "log.jsonl").read_text() if (Path(td) / "s" / "log.jsonl").exists() else ""
        return code, out.getvalue(), err.getvalue(), calls, captures, log


class NextCommandTests(unittest.TestCase):
    def test_next_posts_signed_then_anonymous_and_prints_counts_only(self):
        signed = reply(True, [shelf("Watch it again", ["a", "b", "c", "d"])])
        anon = reply(False, [shelf("Related", ["b", "d", "x"])])
        code, out, err, calls, captures, log = run(["next", "--video", "vid1"], [(200, signed), (200, anon)])
        self.assertEqual(code, 0, err)
        self.assertEqual(len(calls), 2)
        self.assertIn("Authorization", calls[0][1])
        self.assertNotIn("Authorization", calls[1][1])
        self.assertIn("/youtubei/v1/next", calls[0][0])
        self.assertIn("Watch it again", out)
        self.assertIn("0.5", out)
        for hidden in ("ya29", "FAKE", "T a"):
            self.assertNotIn(hidden, out + log)
        self.assertEqual(captures, ["next-anon.json", "next-signed.json"])
        self.assertIn('"event": "next"', log)

    def test_next_rejects_a_bad_video_id(self):
        code, out, err, calls, _, _ = run(["next", "--video", "a b"], [])
        self.assertEqual(code, 1)
        self.assertEqual(calls, [])

    def test_next_fails_when_the_signed_call_fails(self):
        code, out, err, calls, _, _ = run(["next", "--video", "v"], [(500, {})])
        self.assertEqual(code, 1)


class FixtureCommandTests(unittest.TestCase):
    def _run(self, capture_obj, extra=()):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            st.write_json("captures/home1-1.json", capture_obj)
            dest = Path(td) / "out" / "fx.json"
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = probe.main(["fixture", "--capture", "home1-1", "--out", str(dest)] + list(extra),
                                  state=st, send=lambda *a, **k: None)
            text = dest.read_text() if dest.exists() else None
            return code, out.getvalue() + err.getvalue(), text

    def test_writes_a_scrubbed_pretty_file(self):
        code, said, text = self._run({"continuation": "CONT", "trackingParams": "TP", "x": [1]})
        self.assertEqual(code, 0, said)
        self.assertNotIn("CONT\"", text)
        self.assertIn("CONTINUATION_1", text)
        self.assertIn("\n  ", text)

    def test_refuses_when_the_leak_check_finds_something(self):
        code, said, text = self._run({"note": "Bearer abc.def and ya29.SECRETVALUE"})
        self.assertEqual(code, 2)
        self.assertIsNone(text)
        self.assertNotIn("SECRETVALUE", said)
        self.assertNotIn("abc.def", said)

    def test_missing_capture_is_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = probe.main(["fixture", "--capture", "nope", "--out", str(Path(td) / "f.json")], state=st,
                                  send=lambda *a, **k: None)
            self.assertEqual(code, 1)

    def test_capture_name_cannot_escape_the_folder(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                code = probe.main(["fixture", "--capture", "../x", "--out", str(Path(td) / "f.json")], state=st,
                                  send=lambda *a, **k: None)
            self.assertEqual(code, 1)

    def test_hide_titles_flag(self):
        code, said, text = self._run({"title": {"simpleText": "Real"}}, ["--hide-titles"])
        self.assertEqual(code, 0, said)
        self.assertNotIn("Real", text)


class ResultsCommandTests(unittest.TestCase):
    def test_results_prints_the_summary(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            st.log("home_try", try_passes=True, visible_unique=10, continuation_ok=True)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = probe.main(["results"], state=st, send=lambda *a, **k: None)
            self.assertEqual(code, 0)
            self.assertIn("Home: fail (1 of 1 tries)", out.getvalue())


if __name__ == "__main__":
    unittest.main()
