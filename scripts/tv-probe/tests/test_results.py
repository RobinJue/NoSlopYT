from __future__ import annotations

import unittest

from tvprobe.results import summarize


def home(ok, ts):
    return {"event": "home_try", "ts": ts, "try_passes": ok, "visible_unique": 12 if ok else 3}


def report(video, ts, auth="on"):
    return {"event": "report_pings", "ts": ts, "video": video, "playback": 204, "watchtime": 204, "auth": auth}


def found(video, ts, ok=True):
    return {"event": "history", "ts": ts, "video": video, "status": 200, "found": ok}


LOG_TWO_HOME_PASSES_OF_THREE = [home(True, 1), home(False, 2), home(True, 3)]
LOG_THREE_REPORTS_FOUND = [report("a", 100), found("a", 220), report("b", 300), found("b", 330),
                           report("c", 400), found("c", 600)]
LOG_FEEDBACK_OK = [{"event": "feedback", "ts": 700, "kind": "not-interested", "status": 200}]


class SummaryTests(unittest.TestCase):
    def test_summary_applies_the_pass_rules(self):
        text = summarize(LOG_TWO_HOME_PASSES_OF_THREE + LOG_THREE_REPORTS_FOUND + LOG_FEEDBACK_OK)
        self.assertIn("Home: pass (2 of 3 tries)", text)
        self.assertIn("Reporting: pass (3 of 3 videos found in history within 5 minutes)", text)
        self.assertIn("Card actions: pass", text)

    def test_one_home_pass_fails(self):
        text = summarize([home(True, 1), home(False, 2), home(False, 3)])
        self.assertIn("Home: fail (1 of 3 tries)", text)

    def test_a_history_hit_after_five_minutes_does_not_count(self):
        log = [report("a", 0), found("a", 301), report("b", 10), found("b", 20), report("c", 30), found("c", 40)]
        self.assertIn("Reporting: fail (2 of 3 videos", summarize(log))

    def test_a_hit_for_another_video_does_not_count(self):
        log = [report("a", 0), found("b", 20)]
        self.assertIn("Reporting: fail (0 of 1", summarize(log))

    def test_fewer_than_three_reports_is_not_a_pass(self):
        log = [report("a", 0), found("a", 20), report("b", 30), found("b", 40)]
        text = summarize(log)
        self.assertIn("Reporting: fail (2 of 2", text)

    def test_later_variants_do_not_change_the_verdict(self):
        log = LOG_THREE_REPORTS_FOUND + [report("d", 1000, auth="off"), found("d", 1010, ok=False)]
        text = summarize(log)
        self.assertIn("Reporting: pass (3 of 3", text)
        self.assertIn("auth on pings off", text)

    def test_feedback_with_an_error_or_non_200_fails(self):
        self.assertIn("Card actions: fail", summarize([{"event": "feedback", "status": 400}]))
        self.assertIn("Card actions: fail", summarize([{"event": "feedback", "status": 200, "error": True}]))

    def test_nothing_run_says_so(self):
        text = summarize([])
        for name in ("Home", "Reporting", "Card actions"):
            self.assertIn("%s: not run" % name, text)

    def test_up_next_is_listed_when_run(self):
        text = summarize([{"event": "next", "ts": 1, "signed_status": 200, "anon_status": 200, "overlap": 0.4,
                           "signed_logged_in": True}])
        self.assertIn("Up next", text)
        self.assertIn("40%", text)


if __name__ == "__main__":
    unittest.main()
