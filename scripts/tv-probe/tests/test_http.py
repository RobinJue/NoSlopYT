from __future__ import annotations

import unittest
from unittest import mock

from tvprobe import http
from tvprobe.http import NotAllowed, Response, redact, send


class HttpTests(unittest.TestCase):
    def test_other_hosts_are_refused_before_any_request(self):
        with mock.patch("urllib.request.OpenerDirector.open") as opened:
            for url in ("https://example.com/", "https://www.youtube.com.evil.com/", "http://www.youtube.com/",
                        "https://user@evil.com@www.youtube.com/x"):
                with self.assertRaises(NotAllowed):
                    send("GET", url)
            opened.assert_not_called()

    def test_allowed_hosts(self):
        self.assertEqual(http.ALLOWED_HOSTS, frozenset(
            {"www.youtube.com", "youtubei.googleapis.com", "oauth2.googleapis.com"}))

    def test_redact_hides_authorization(self):
        self.assertEqual(redact({"Authorization": "Bearer abc"})["Authorization"], "<redacted>")
        self.assertEqual(redact({"authorization": "x", "Cookie": "c", "A": "b"})["A"], "b")
        self.assertEqual(redact({"Cookie": "c"})["Cookie"], "<redacted>")

    def test_redirects_are_not_followed(self):
        self.assertIsNone(http._NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://x/"))

    def test_response_is_a_named_tuple(self):
        r = Response(200, {}, b"x")
        self.assertEqual((r.status, r.body), (200, b"x"))
