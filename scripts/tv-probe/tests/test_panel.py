from __future__ import annotations

import contextlib
import io
import json
import tempfile
import time
import unittest
from pathlib import Path

import probe
from tvprobe import http
from tvprobe.panel import PanelFindings, parse_panel
from tvprobe.state import State

FIX = Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIX / name).read_text())


class ParseTests(unittest.TestCase):
    def test_both_actions_are_found_by_structure(self):
        f = parse_panel(load("panel_menu.json"))
        self.assertEqual((f.not_interested, f.dont_recommend, f.channel_id, f.handle, f.ambiguous),
                         ("NI", "DR", "UCabcdefghijklmnopqrstuv", "@somechannel", False))

    def test_two_candidates_are_ambiguous_and_send_nothing(self):
        f = parse_panel(load("panel_two_feedback_rows.json"))
        self.assertTrue(f.ambiguous)
        self.assertIsNone(f.not_interested)
        self.assertIsNone(f.dont_recommend)

    def test_a_row_without_a_dismissal_is_not_not_interested(self):
        reply = {"a": {"feedbackEndpoint": {"feedbackToken": "X"}}}
        f = parse_panel(reply)
        self.assertEqual((f.not_interested, f.dont_recommend, f.ambiguous), (None, None, False))

    def test_an_empty_reply_finds_nothing(self):
        f = parse_panel({})
        self.assertEqual((f.not_interested, f.dont_recommend, f.channel_id, f.handle), (None, None, None, None))

    def test_a_hide_enclosing_follow_up_counts_as_a_dismissal(self):
        reply = {"a": {"feedbackEndpoint": {"feedbackToken": "NI", "uiActions": {"hideEnclosingContainer": True}}}}
        self.assertEqual(parse_panel(reply).not_interested, "NI")

    def test_two_different_channel_ids_leave_the_channel_unknown(self):
        reply = {"a": {"browseEndpoint": {"browseId": "UCabcdefghijklmnopqrstuv"}},
                 "b": {"browseEndpoint": {"browseId": "UCzzzzzzzzzzzzzzzzzzzzzz"}},
                 "c": {"browseEndpoint": {"browseId": "UCabcdefghijklmnopqrstuv"}}}
        self.assertIsNone(parse_panel(reply).channel_id)
        same = {"a": reply["a"], "c": reply["c"]}
        self.assertEqual(parse_panel(same).channel_id, "UCabcdefghijklmnopqrstuv")

    def test_repr_hides_the_tokens(self):
        text = repr(PanelFindings("SECRETNI", "SECRETDR", None, None, False))
        self.assertIn("not_interested=yes", text)
        self.assertIn("dont_recommend=yes", text)
        self.assertNotIn("SECRETNI", text)
        self.assertNotIn("SECRETDR", text)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.state = State(Path(self.td.name) / "s")
        self.state.write_json("tokens.json", {"access_token": "ya29.FAKEACCESS", "refresh_token": "1//FAKEREFRESH",
                                              "expires_at": time.time() + 3000, "scope": "s"})
        self.state.write_json("captures/h-1.json", load("home_mixed.json"))
        self.calls = []

    def fake(self, replies):
        def send(method, url, **kw):
            self.calls.append((method, url, kw.get("headers") or {}, kw.get("body")))
            status, reply = replies.pop(0)
            return http.Response(status, {}, json.dumps(reply).encode())
        return send

    def run_cli(self, argv, send):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = probe.main(argv, state=self.state, send=send)
        return code, out.getvalue(), err.getvalue()

    def test_menu_posts_the_tile_panel_and_prints_presence_only(self):
        code, out, err = self.run_cli(["menu", "--video", "vidPLAIN001"], self.fake([(200, load("panel_menu.json"))]))
        self.assertEqual(code, 0, err)
        self.assertIn("/youtubei/v1/get_panel", self.calls[0][1])
        body = json.loads(self.calls[0][3])
        self.assertEqual(body["params"], "FAKEPARAMS-vidPLAIN001")
        self.assertTrue(body["panelId"])
        line = json.loads(out)
        self.assertEqual((line["not_interested"], line["dont_recommend"], line["handle"]), (True, True, "@somechannel"))
        for secret in ("FAKEPARAMS", "FAKEACCESS", '"NI"', '"DR"'):
            self.assertNotIn(secret, out + err)
        self.assertIsNotNone(self.state.read_json("captures/panel-vidPLAIN001.json"))

    def test_menu_without_a_capture_of_the_video_fails_cleanly(self):
        code, out, err = self.run_cli(["menu", "--video", "vidNONE0001"], self.fake([]))
        self.assertEqual(code, 1)
        self.assertEqual(self.calls, [])

    def test_feedback_not_interested_posts_the_token_and_prints_keys(self):
        replies = [(200, load("panel_menu.json")), (200, {"feedbackResponses": [{"isProcessed": True}]})]
        code, out, err = self.run_cli(["feedback", "--video", "vidPLAIN001", "--kind", "not-interested"],
                                      self.fake(replies))
        self.assertEqual(code, 0, err)
        self.assertIn("/youtubei/v1/feedback", self.calls[1][1])
        self.assertEqual(json.loads(self.calls[1][3])["feedbackTokens"], ["NI"])
        last = json.loads(out.strip().splitlines()[-1])
        self.assertEqual((last["status"], last["keys"], last["is_processed"]), (200, ["feedbackResponses"], [True]))

    def test_dont_recommend_needs_the_matching_channel_id(self):
        for extra in ([], ["--confirm-channel", "UCwrongwrongwrongwrongxx"]):
            self.calls.clear()
            code, out, err = self.run_cli(
                ["feedback", "--video", "vidPLAIN001", "--kind", "dont-recommend"] + extra,
                self.fake([(200, load("panel_menu.json"))]))
            self.assertEqual(code, 2)
            self.assertEqual(len(self.calls), 1)  # the panel call only; no feedback post

    def test_dont_recommend_with_the_matching_channel_id_posts(self):
        replies = [(200, load("panel_menu.json")), (200, {})]
        code, out, err = self.run_cli(["feedback", "--video", "vidPLAIN001", "--kind", "dont-recommend",
                                       "--confirm-channel", "UCabcdefghijklmnopqrstuv"], self.fake(replies))
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(self.calls[1][3])["feedbackTokens"], ["DR"])

    def test_ambiguous_panel_sends_no_feedback(self):
        code, out, err = self.run_cli(["feedback", "--video", "vidPLAIN001", "--kind", "not-interested"],
                                      self.fake([(200, load("panel_two_feedback_rows.json"))]))
        self.assertEqual(code, 2)
        self.assertEqual(len(self.calls), 1)


if __name__ == "__main__":
    unittest.main()
