from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import probe
from tvprobe import http
from tvprobe.report import (history_has, new_cpn, ping_url, signature_timestamp, tracking_from_player)
from tvprobe.state import State

FIX = Path(__file__).parent / "fixtures"
BASE = "https://s.youtube.com/api/stats/watchtime?cl=1&docid=v&ei=E&el=leanback&of=O&plid=P&vm=V&len=60"


def load(name):
    return json.loads((FIX / name).read_text())


class PingTests(unittest.TestCase):
    def test_ping_keeps_the_base_items_and_moves_to_www(self):
        url = ping_url(BASE, kind="watchtime", docid="v", length=60.0, cpn="c" * 16, cmt=30.0, st=0.0, et=30.0)
        q = parse_qs(urlparse(url).query)
        self.assertTrue(url.startswith("https://www.youtube.com/api/stats/watchtime?"))
        for key in ("cl", "ei", "el", "of", "plid", "vm"):
            self.assertIn(key, q)
        self.assertEqual((q["ns"], q["ver"], q["cmt"], q["st"], q["et"]),
                         (["yt"], ["2"], ["30.000"], ["0.000"], ["30.000"]))
        self.assertNotIn("final", q)

    def test_final_ping_says_so(self):
        self.assertIn("final=1", ping_url(BASE, kind="watchtime", docid="v", length=60.0, cpn="c" * 16,
                                          cmt=60.0, st=0.0, et=60.0, final=True))

    def test_playback_ping_has_no_st_or_et(self):
        url = ping_url(BASE.replace("watchtime", "playback"), kind="playback", docid="v", length=60.0,
                       cpn="c" * 16, cmt=0.0)
        q = parse_qs(urlparse(url).query)
        self.assertTrue(url.startswith("https://www.youtube.com/api/stats/playback?"))
        self.assertNotIn("st", q)
        self.assertNotIn("et", q)

    def test_cpn_has_sixteen_allowed_characters(self):
        self.assertRegex(new_cpn(), r"^[A-Za-z0-9_-]{16}$")


class ParseTests(unittest.TestCase):
    def test_tracking_needs_ei_vm_and_of(self):
        t = tracking_from_player(load("player_signed.json"))
        self.assertEqual((t.status, t.has_ei, t.has_vm, t.has_of), ("OK", True, True, True))
        self.assertEqual(t.length, 60.0)
        self.assertNotIn("FAKE", repr(t))
        self.assertNotIn("youtube.com", repr(t))

    def test_missing_tracking_is_reported_as_missing(self):
        t = tracking_from_player({"playabilityStatus": {"status": "LOGIN_REQUIRED"}})
        self.assertEqual((t.status, t.has_ei, t.has_vm, t.has_of, t.playback_url), ("LOGIN_REQUIRED", False, False, False, None))

    def test_history_finds_the_video_in_both_layouts(self):
        self.assertEqual(history_has(load("history_grid.json"), "vidWATCHED1"), (True, 50))
        self.assertEqual(history_has(load("history_tabs.json"), "vidWATCHED1")[0], True)
        self.assertEqual(history_has(load("history_grid.json"), "vidNOTTHERE"), (False, None))

    def test_signature_timestamp(self):
        def send(method, url, **kw):
            self.assertEqual(url, "https://www.youtube.com/")
            return http.Response(200, {}, b'x"STS":20758,"y"STS":1')
        self.assertEqual(signature_timestamp(send=send), 20758)
        self.assertIsNone(signature_timestamp(send=lambda m, u, **kw: http.Response(200, {}, b"none")))
        self.assertIsNone(signature_timestamp(send=lambda m, u, **kw: http.Response(500, {}, b'"STS":1')))


def run_cli(argv, *, send, st):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = probe.main(argv, state=st, send=send)
    return code, out.getvalue(), err.getvalue()


class CliTests(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.st = State(Path(self._td.name) / "s")
        self.st.write_json("tokens.json", {"access_token": "ya29.FAKE", "refresh_token": "1//FAKE",
                                           "expires_at": 4102444800, "scope": "x"})
        self.calls = []

    def send(self, method, url, **kw):
        self.calls.append((method, url, kw))
        if url == "https://www.youtube.com/":
            return http.Response(200, {}, b'"STS":20758')
        if "/youtubei/v1/player" in url:
            return http.Response(200, {}, json.dumps(load("player_signed.json")).encode())
        if "/youtubei/v1/browse" in url:
            return http.Response(200, {}, json.dumps(load("history_grid.json")).encode())
        return http.Response(200, {}, b"")

    def test_a_video_is_reported_once_unless_forced(self):
        code, out, err = run_cli(["report", "--video", "v1", "--delay", "0"], send=self.send, st=self.st)
        self.assertEqual(code, 0, out + err)
        pings = [c for c in self.calls if "/api/stats/" in c[1]]
        self.assertEqual([urlparse(c[1]).path for c in pings], ["/api/stats/playback", "/api/stats/watchtime"])
        self.assertEqual(pings[0][2]["headers"]["Authorization"], "Bearer ya29.FAKE")
        self.assertEqual(pings[0][2]["headers"]["Referer"], "https://www.youtube.com/tv")
        self.assertNotIn("FAKE", out + err)
        self.assertIn("v1", self.st.read_json("reported.json"))
        n = len(self.calls)
        code, out, err = run_cli(["report", "--video", "v1", "--delay", "0"], send=self.send, st=self.st)
        self.assertEqual(code, 2)
        self.assertEqual(len(self.calls), n)
        code, out, err = run_cli(["report", "--video", "v1", "--delay", "0", "--force"], send=self.send, st=self.st)
        self.assertEqual(code, 0)
        self.assertGreater(len(self.calls), n)

    def test_options_off_drop_sts_and_pings_auth(self):
        code, out, err = run_cli(["report", "--video", "v2", "--delay", "0", "--sts", "off",
                                  "--auth-on-pings", "off"], send=self.send, st=self.st)
        self.assertEqual(code, 0, out + err)
        self.assertFalse(any(c[1] == "https://www.youtube.com/" for c in self.calls))
        player = [c for c in self.calls if "/youtubei/v1/player" in c[1]][0]
        self.assertNotIn("signatureTimestamp", player[2]["body"].decode())
        for c in self.calls:
            if "/api/stats/" in c[1]:
                self.assertNotIn("Authorization", c[2]["headers"])

    def test_no_tracking_sends_no_pings_and_records_nothing(self):
        def send(method, url, **kw):
            if "/youtubei/v1/player" in url:
                return http.Response(200, {}, b'{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}')
            return http.Response(200, {}, b'"STS":1')
        code, out, err = run_cli(["report", "--video", "v3", "--delay", "0"], send=send, st=self.st)
        self.assertEqual(code, 1)
        self.assertIn("LOGIN_REQUIRED", out)
        self.assertIsNone(self.st.read_json("reported.json"))

    def test_failed_pings_exit_1_and_record_nothing(self):
        for bad in (403, 429, 302):
            def send(method, url, _bad=bad, **kw):
                if "/api/stats/" in url:
                    return http.Response(_bad, {}, b"")
                return self.send(method, url, **kw)
            code, out, err = run_cli(["report", "--video", "v4", "--delay", "0"], send=send, st=self.st)
            self.assertEqual(code, 1, bad)
            self.assertIsNone(self.st.read_json("reported.json"), bad)

    def test_a_second_ping_failure_alone_also_fails(self):
        def send(method, url, **kw):
            if "/api/stats/watchtime" in url:
                return http.Response(403, {}, b"")
            return self.send(method, url, **kw)
        code, out, err = run_cli(["report", "--video", "v4", "--delay", "0"], send=send, st=self.st)
        self.assertEqual(code, 1)
        self.assertIsNone(self.st.read_json("reported.json"))

    def test_tracking_without_ei_sends_no_pings(self):
        reply = load("player_signed.json")
        raw = json.dumps(reply).replace("ei=", "xx=").encode()
        def send(method, url, **kw):
            self.calls.append((method, url, kw))
            if "/youtubei/v1/player" in url:
                return http.Response(200, {}, raw)
            return http.Response(200, {}, b'"STS":1')
        code, out, err = run_cli(["report", "--video", "v5", "--delay", "0"], send=send, st=self.st)
        self.assertEqual(code, 1)
        self.assertFalse(any("/api/stats/" in c[1] for c in self.calls))
        self.assertIsNone(self.st.read_json("reported.json"))

    def test_history_prints_found_and_percent(self):
        code, out, err = run_cli(["history", "--video", "vidWATCHED1"], send=self.send, st=self.st)
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out.strip().splitlines()[-1]), {"found": True, "percent": 50})
        self.assertNotIn("FAKE", out)

    def test_history_log_names_the_video_for_the_results_summary(self):
        run_cli(["history", "--video", "vidWATCHED1"], send=self.send, st=self.st)
        lines = [json.loads(x) for x in (self.st.root / "log.jsonl").read_text().splitlines()]
        self.assertEqual([e["video"] for e in lines if e["event"] == "history"], ["vidWATCHED1"])


if __name__ == "__main__":
    unittest.main()
