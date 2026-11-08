from __future__ import annotations

import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tvprobe.state import State, default_root


class StateTests(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = self._td.name
        self.addCleanup(self._td.cleanup)

    def test_folder_and_files_are_private(self):
        st = State(Path(self.tmp) / "probe")
        st.write_json("tokens.json", {"a": 1})
        self.assertEqual(stat.S_IMODE(os.stat(st.root).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(st.path("tokens.json")).st_mode), 0o600)

    def test_log_refuses_secret_field_names(self):
        for name in ("access_token", "Secret", "device_code", "visitorData", "cookie", "panel_params"):
            with self.assertRaises(ValueError):
                State(Path(self.tmp) / "p").log("signin", **{name: "x"})

    def test_log_appends_json_lines_privately(self):
        st = State(Path(self.tmp) / "p")
        st.log("a", status=200)
        st.log("b", status=500)
        lines = st.path("log.jsonl").read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(stat.S_IMODE(os.stat(st.path("log.jsonl")).st_mode), 0o600)

    def test_read_json_default(self):
        st = State(Path(self.tmp) / "p")
        self.assertEqual(st.read_json("nope.json", {"d": 1}), {"d": 1})
        st.write_json("x.json", [1, 2])
        self.assertEqual(st.read_json("x.json"), [1, 2])

    def test_wipe_removes_everything(self):
        st = State(Path(self.tmp) / "p")
        st.write_json("tokens.json", {})
        st.wipe()
        self.assertFalse(st.root.exists())

    def test_names_cannot_escape_the_folder(self):
        st = State(Path(self.tmp) / "p")
        with self.assertRaises(ValueError):
            st.path("../evil.json")
        with self.assertRaises(ValueError):
            st.path("/etc/passwd")

    def test_default_root_honours_env(self):
        old = os.environ.get("NOSLOP_PROBE_DIR")
        os.environ["NOSLOP_PROBE_DIR"] = "/x/y"
        try:
            self.assertEqual(default_root(), Path("/x/y"))
        finally:
            if old is None:
                del os.environ["NOSLOP_PROBE_DIR"]
            else:
                os.environ["NOSLOP_PROBE_DIR"] = old

    def test_default_root_without_env(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("NOSLOP_PROBE_DIR", None)
            self.assertEqual(default_root(), Path.home() / ".noslop-tv-probe")
