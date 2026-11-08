from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import probe
from tvprobe import http
from tvprobe.oauth import (ClientValues, DeviceCode, SignInError, Tokens, extract_client_values,
                           fetch_client_values, find_base_script_url, poll, refresh, request_device_code,
                           revoke, valid_token)
from tvprobe.state import State

CLIENT = ClientValues("ID", "SEC")
TOKENS = Tokens("A", "R", 5000.0, "s")


def answer(obj, status=200):
    def f(method, url, **kw):
        return http.Response(status, {}, json.dumps(obj).encode())
    return f


def code(interval=5, expires_in=1800, started_at=0.0):
    return DeviceCode("DEV", "ABC-DEF", "https://www.google.com/device", expires_in, interval, started_at)


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class ExtractTests(unittest.TestCase):
    def test_first_client_pair_wins(self):
        script = 'x;clientId:"ID1",k:"S1";y;clientId:"ID2",k:"S2"'
        self.assertEqual(extract_client_values(script), ClientValues("ID1", "S1"))

    def test_no_match_is_none(self):
        self.assertIsNone(extract_client_values("nothing here"))

    def test_base_script_is_found(self):
        html = '<script id="base-js" src="/s/_/kabuki/_/js/k=a/m=base"></script>'
        self.assertEqual(find_base_script_url(html), "https://www.youtube.com/s/_/kabuki/_/js/k=a/m=base")

    def test_base_script_with_other_attribute_order(self):
        html = '<script src="/s/x/m=base" nonce="n" id="base-js"></script>'
        self.assertEqual(find_base_script_url(html), "https://www.youtube.com/s/x/m=base")

    def test_no_base_script(self):
        self.assertIsNone(find_base_script_url("<html></html>"))

    def test_fetch_client_values_uses_cobalt_agent(self):
        seen = []

        def send(method, url, **kw):
            seen.append((url, (kw.get("headers") or {}).get("User-Agent")))
            if url.endswith("/tv"):
                return http.Response(200, {}, b'<script id="base-js" src="/s/m=base"></script>')
            return http.Response(200, {}, b'clientId:"ID1",k:"S1"')
        self.assertEqual(fetch_client_values(send=send), ClientValues("ID1", "S1"))
        self.assertEqual(seen[0][1], "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version")

    def test_fetch_fails_cleanly(self):
        with self.assertRaises(SignInError):
            fetch_client_values(send=lambda m, u, **kw: http.Response(500, {}, b""))


class DeviceCodeTests(unittest.TestCase):
    def test_request_sends_json_and_parses(self):
        seen = {}

        def send(method, url, **kw):
            seen["url"], seen["body"] = url, json.loads(kw["body"])
            return http.Response(200, {}, json.dumps({
                "device_code": "DEV", "user_code": "ABC-DEF", "verification_url": "https://www.google.com/device",
                "expires_in": 1800, "interval": 5}).encode())
        c = request_device_code(CLIENT, "d" * 32, send=send)
        self.assertEqual(seen["url"], "https://www.youtube.com/o/oauth2/device/code")
        self.assertEqual(seen["body"]["device_model"], "ytlr::")
        self.assertEqual(seen["body"]["device_id"], "d" * 32)
        self.assertEqual((c.user_code, c.interval, c.expires_in), ("ABC-DEF", 5, 1800))

    def test_request_error(self):
        with self.assertRaises(SignInError) as e:
            request_device_code(CLIENT, "d", send=answer({"error": "invalid_client"}, status=401))
        self.assertEqual(e.exception.reason, "invalid_client")


class PollTests(unittest.TestCase):
    def test_poll_honours_interval_and_slow_down(self):
        replies = iter([({"error": "authorization_pending"}, 428), ({"error": "slow_down"}, 403),
                        ({"error": "authorization_pending"}, 428),
                        ({"access_token": "A", "refresh_token": "R", "expires_in": 3600, "scope": "s"}, 200)])

        def scripted(method, url, **kw):
            obj, status = next(replies)
            return http.Response(status, {}, json.dumps(obj).encode())
        sleeps, clock = [], Clock()
        tokens = poll(CLIENT, code(interval=3), send=scripted, sleep=sleeps.append, now=clock)
        self.assertEqual(sleeps, [5, 10, 10])
        self.assertEqual(tokens.refresh_token, "R")
        self.assertEqual(tokens.expires_at, 3600)

    def test_never_waits_less_than_five_and_follows_a_longer_interval(self):
        replies = iter([({"error": "authorization_pending"}, 428), ({"access_token": "A", "refresh_token": "R",
                                                                       "expires_in": 10}, 200)])
        sleeps = []

        def scripted(method, url, **kw):
            obj, status = next(replies)
            return http.Response(status, {}, json.dumps(obj).encode())
        poll(CLIENT, code(interval=8), send=scripted, sleep=sleeps.append, now=Clock())
        self.assertEqual(sleeps, [8])

    def test_poll_stops_on_denied_and_expired(self):
        for error in ("access_denied", "expired_token"):
            with self.assertRaises(SignInError) as e:
                poll(CLIENT, code(), send=answer({"error": error}, status=403), sleep=lambda s: None, now=Clock())
            self.assertEqual(e.exception.reason, error)

    def test_poll_ends_at_the_deadline(self):
        clock = Clock()

        def sleep(s):
            clock.t += s
        with self.assertRaises(SignInError) as e:
            poll(CLIENT, code(expires_in=12), send=answer({"error": "authorization_pending"}, status=428),
                 sleep=sleep, now=clock)
        self.assertEqual(e.exception.reason, "expired_token")

    def test_poll_unknown_error_stops(self):
        with self.assertRaises(SignInError) as e:
            poll(CLIENT, code(), send=answer({"error": "invalid_grant"}, status=400), sleep=lambda s: None,
                 now=Clock())
        self.assertEqual(e.exception.reason, "invalid_grant")


class RefreshTests(unittest.TestCase):
    def test_refresh_keeps_a_returned_refresh_token(self):
        new = refresh(CLIENT, TOKENS, send=answer({"access_token": "A2", "expires_in": 3600, "refresh_token": "R2"}),
                      now=lambda: 1000)
        self.assertEqual((new.access_token, new.refresh_token, new.expires_at), ("A2", "R2", 4600))

    def test_refresh_without_one_keeps_the_old(self):
        new = refresh(CLIENT, TOKENS, send=answer({"access_token": "A2", "expires_in": 3600}), now=lambda: 1000)
        self.assertEqual(new.refresh_token, TOKENS.refresh_token)

    def test_refresh_error(self):
        with self.assertRaises(SignInError) as e:
            refresh(CLIENT, TOKENS, send=answer({"error": "invalid_grant"}, status=400), now=lambda: 0)
        self.assertEqual(e.exception.reason, "invalid_grant")

    def test_repr_shows_no_values(self):
        self.assertNotIn("R", repr(Tokens("A", "R", 0, "s")).replace("Tokens", ""))
        for obj in (CLIENT, code(), TOKENS):
            text = repr(obj)
            for secret in ("SEC", "DEV", "ID", "ABC-DEF", "'A'", "'R'"):
                self.assertNotIn(secret, text.replace("ClientValues", "").replace("DeviceCode", ""))


class RevokeTests(unittest.TestCase):
    def test_first_url_is_form_second_is_json(self):
        seen = []

        def send(method, url, **kw):
            seen.append((url, kw.get("headers", {}).get("Content-Type"), kw["body"]))
            return http.Response(400 if len(seen) == 1 else 200, {}, b"")
        self.assertTrue(revoke(TOKENS, send=send))
        self.assertEqual(seen[0][0], "https://oauth2.googleapis.com/revoke")
        self.assertEqual(seen[0][1], "application/x-www-form-urlencoded")
        self.assertEqual(seen[0][2], b"token=R")
        self.assertEqual(seen[1][0], "https://www.youtube.com/o/oauth2/revoke")
        self.assertEqual(json.loads(seen[1][2]), {"token": "R"})

    def test_none_answering_is_false(self):
        self.assertFalse(revoke(TOKENS, send=lambda m, u, **kw: http.Response(400, {}, b"")))


class ValidTokenTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.st = State(Path(self.td.name) / "s")
        self.st.write_json("client.json", {"client_id": "ID", "client_secret": "SEC"})

    def test_fresh_token_is_returned_without_a_request(self):
        self.st.write_json("tokens.json", {"access_token": "A", "refresh_token": "R", "expires_at": 2000, "scope": "s"})

        def boom(*a, **k):
            raise AssertionError("no request expected")
        self.assertEqual(valid_token(self.st, send=boom, now=lambda: 1000), "A")

    def test_token_near_expiry_is_refreshed_and_stored(self):
        self.st.write_json("tokens.json", {"access_token": "A", "refresh_token": "R", "expires_at": 1200, "scope": "s"})
        got = valid_token(self.st, send=answer({"access_token": "A2", "expires_in": 3600}), now=lambda: 1000)
        self.assertEqual(got, "A2")
        self.assertEqual(self.st.read_json("tokens.json")["access_token"], "A2")
        self.assertEqual(self.st.read_json("tokens.json")["refresh_token"], "R")

    def test_missing_tokens(self):
        with self.assertRaises(SignInError):
            valid_token(self.st, send=answer({}), now=lambda: 0)


class CliTests(unittest.TestCase):
    def run_cli(self, argv, send, st):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            c = probe.main(argv, state=st, send=send)
        return c, out.getvalue(), err.getvalue()

    def test_start_wait_refresh_revoke(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")

            def send(method, url, **kw):
                if url.endswith("/tv"):
                    return http.Response(200, {}, b'<script id="base-js" src="/s/m=base"></script>')
                if url.endswith("m=base"):
                    return http.Response(200, {}, b'clientId:"ID1",k:"SEC1"')
                if url.endswith("/device/code"):
                    return http.Response(200, {}, json.dumps({
                        "device_code": "DEVSECRET", "user_code": "ABC-DEF",
                        "verification_url": "https://www.google.com/device", "expires_in": 1800,
                        "interval": 5}).encode())
                if url.endswith("/oauth2/token"):
                    return http.Response(200, {}, json.dumps({
                        "access_token": "ya29.TOKSECRET", "refresh_token": "1//REFSECRET", "expires_in": 3600,
                        "scope": "s"}).encode())
                return http.Response(200, {}, b"")
            c, out, err = self.run_cli(["signin", "start"], send, st)
            self.assertEqual(c, 0, err)
            self.assertIn("ABC-DEF", out)
            self.assertIn("https://www.google.com/device?user_code=ABC-DEF", out)
            self.assertIn("30", out)
            device_id = st.read_json("device.json")["device_id"]
            self.assertRegex(device_id, "^[0-9a-f]{32}$")
            c, out, err = self.run_cli(["signin", "wait"], send, st)
            self.assertEqual(c, 0, err)
            self.assertIn("connected", out)
            self.assertIn("3600", out)
            c, out, err = self.run_cli(["refresh"], send, st)
            self.assertEqual(c, 0, err)
            self.assertIn("3600", out)
            blob = out + err + (st.path("log.jsonl").read_text() if st.path("log.jsonl").exists() else "")
            for secret in ("DEVSECRET", "TOKSECRET", "REFSECRET", "SEC1", "ID1"):
                self.assertNotIn(secret, blob)
            c, out, err = self.run_cli(["revoke"], send, st)
            self.assertEqual(c, 0, err)
            self.assertFalse(st.root.exists())

    def test_revoke_without_tokens_still_wipes_the_folder(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            st.write_json("client.json", {"client_id": "ID1", "client_secret": "SEC1"})
            st.write_json("device.json", {"device_code": "DEVSECRET"})
            calls = []

            def send(method, url, **kw):
                calls.append(url)
                return http.Response(200, {}, b"")
            c, out, err = self.run_cli(["revoke"], send, st)
            self.assertEqual(c, 0, err)
            self.assertIn("no tokens to revoke", out)
            self.assertEqual(calls, [])
            self.assertFalse(st.root.exists())

    def test_revoke_with_malformed_tokens_still_wipes_the_folder(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            st.write_json("tokens.json", {"access_token": "x"})
            c, out, err = self.run_cli(["revoke"], lambda m, u, **kw: http.Response(200, {}, b""), st)
            self.assertEqual(c, 0, err)
            self.assertFalse(st.root.exists())

    def test_revoke_fails_loudly_when_the_folder_cannot_be_removed(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            st.write_json("client.json", {"client_id": "ID1", "client_secret": "SEC1"})
            with mock.patch("tvprobe.state.shutil.rmtree"):
                c, out, err = self.run_cli(["revoke"], lambda m, u, **kw: http.Response(200, {}, b""), st)
            self.assertNotEqual(c, 0)
            self.assertNotIn("state folder removed", out)
            self.assertTrue(st.root.exists())

    def test_second_start_keeps_the_device_id(self):
        with tempfile.TemporaryDirectory() as td:
            st = State(Path(td) / "s")
            st.write_json("device.json", {"device_id": "f" * 32})

            def send(method, url, **kw):
                if url.endswith("/tv"):
                    return http.Response(200, {}, b'<script id="base-js" src="/s/m=base"></script>')
                if url.endswith("m=base"):
                    return http.Response(200, {}, b'clientId:"ID1",k:"S1"')
                return http.Response(200, {}, json.dumps({
                    "device_code": "D", "user_code": "U", "verification_url": "v", "expires_in": 60,
                    "interval": 5}).encode())
            self.run_cli(["signin", "start"], send, st)
            self.assertEqual(st.read_json("device.json")["device_id"], "f" * 32)


if __name__ == "__main__":
    unittest.main()
