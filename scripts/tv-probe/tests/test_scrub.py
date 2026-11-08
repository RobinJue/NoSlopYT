from __future__ import annotations

import json
import unittest

from tvprobe.scrub import leaks, scrub
from tvprobe.upnext import overlap


class ScrubTests(unittest.TestCase):
    def test_scrub_removes_every_secret_class(self):
        raw = {"responseContext": {"visitorData": "CgtABC", "serviceTrackingParams": [{"service": "GFEEDBACK"}]},
               "trackingParams": "T", "x": {"clickTrackingParams": "C", "continuation": "CONT", "feedbackToken": "F",
               "url": "https://rr1---sn-abc.googlevideo.com/videoplayback?ip=81.2.3.4&id=1", "params": "P"},
               "frameworkUpdates": {"big": 1}}
        out = json.dumps(scrub(raw))
        for secret in ("CgtABC", "\"T\"", "\"C\"", "CONT\"", "\"F\"", "81.2.3.4", "googlevideo", "\"P\"",
                       "frameworkUpdates", "serviceTrackingParams"):
            self.assertNotIn(secret, out)
        self.assertEqual(leaks(out), [])

    def test_continuations_keep_a_placeholder(self):
        self.assertEqual(scrub({"continuation": "CONT"}), {"continuation": "CONTINUATION_1"})

    def test_continuations_are_numbered_in_order(self):
        out = scrub({"a": {"continuation": "X"}, "b": [{"continuation": "Y"}]})
        self.assertEqual(out, {"a": {"continuation": "CONTINUATION_1"}, "b": [{"continuation": "CONTINUATION_2"}]})

    def test_input_is_not_changed(self):
        raw = {"continuation": "CONT", "n": {"params": "P"}}
        scrub(raw)
        self.assertEqual(raw, {"continuation": "CONT", "n": {"params": "P"}})

    def test_logged_in_flag_survives(self):
        def reply(value):
            return {"responseContext": {"serviceTrackingParams": [
                {"service": "GFEEDBACK", "params": [{"key": "logged_in", "value": value}]}]}}
        self.assertIs(scrub(reply("1"))["_loggedIn"], True)
        self.assertIs(scrub(reply("0"))["_loggedIn"], False)
        self.assertIsNone(scrub({"responseContext": {}})["_loggedIn"])

    def test_other_urls_stay_and_stats_urls_go(self):
        out = scrub({"u": "https://i.ytimg.com/vi/a/hq.jpg", "s": "https://s.youtube.com/api/stats/playback?ei=E",
                     "w": "https://www.youtube.com/api/stats/x?a=1"})
        self.assertEqual(out["u"], "https://i.ytimg.com/vi/a/hq.jpg")
        self.assertEqual(out["s"], "https://example.invalid/")
        self.assertEqual(out["w"], "https://example.invalid/")

    def test_nested_token_containers_are_hidden(self):
        out = json.dumps(scrub({"feedbackTokens": ["AAA", "BBB"], "continuationCommand": {"token": "TTT"}}))
        for secret in ("AAA", "BBB", "TTT"):
            self.assertNotIn(secret, out)

    def test_ip_addresses_are_replaced_but_versions_stay(self):
        out = scrub({"a": "from 81.2.3.4 now", "v": "7.20260901.15.00"})
        self.assertEqual(out["a"], "from 203.0.113.7 now")
        self.assertEqual(out["v"], "7.20260901.15.00")

    def test_titles_and_channels_can_be_hidden(self):
        raw = {"metadata": {"tileMetadataRenderer": {
            "title": {"simpleText": "Real Title"},
            "lines": [{"lineRenderer": {"items": [{"lineItemRenderer": {"text": {"runs": [{"text": "Real Channel"}]}}}]}},
                      {"lineRenderer": {"items": [{"lineItemRenderer": {"text": {"simpleText": "1M views"}}}]}}]}}}
        shown = json.dumps(scrub(raw))
        self.assertIn("Real Title", shown)
        hidden = json.dumps(scrub(raw, hide_titles=True))
        self.assertNotIn("Real Title", hidden)
        self.assertNotIn("Real Channel", hidden)
        self.assertIn("Title 1", hidden)
        self.assertIn("Channel 1", hidden)
        self.assertIn("1M views", hidden)


class LeakTests(unittest.TestCase):
    def test_leaks_catches_tokens_and_addresses(self):
        self.assertEqual(sorted(leaks('{"a":"ya29.xyz","b":"1//0abc","c":"10.0.0.7","d":"203.0.113.7"}')),
                         ["1//0abc", "10.0.0.7", "ya29.xyz"])

    def test_leaks_catches_a_bearer_header(self):
        self.assertEqual(leaks('{"h":"Bearer abc.def"}'), ["Bearer abc.def"])

    def test_clean_text_has_no_leaks(self):
        self.assertEqual(leaks('{"v":"7.20260901.15.00","u":"https://example.invalid/"}'), [])


class OverlapTests(unittest.TestCase):
    def test_overlap(self):
        self.assertEqual(overlap(["a", "b", "c", "d"], ["b", "d", "x"]), 0.5)

    def test_overlap_of_nothing_is_zero(self):
        self.assertEqual(overlap([], ["a"]), 0.0)


if __name__ == "__main__":
    unittest.main()
