from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import probe
from tvprobe import http
from tvprobe.state import State

BODY = b'{"error":"x","access_token":"ya29.SECRET","refresh_token":"1//SECRET"}'


def fake_500(method, url, **kw):
    return http.Response(500, {}, BODY)


def run_cli(argv, *, send, tokens=None, handlers=None):
    with tempfile.TemporaryDirectory() as td:
        st = State(Path(td) / "s")
        if tokens is not None:
            st.write_json("tokens.json", tokens)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            if handlers:
                with mock.patch.dict(probe.HANDLERS, handlers):
                    code = probe.main(argv, state=st, send=send)
            else:
                code = probe.main(argv, state=st, send=send)
        return code, out.getvalue(), err.getvalue()


class CliSecretTests(unittest.TestCase):
    def test_failures_print_no_secret(self):
        code, out, err = run_cli(["refresh"], send=fake_500,
                                 tokens={"access_token": "ya29.SECRET", "refresh_token": "1//SECRET"})
        self.assertNotIn("SECRET", out + err)

    def test_an_error_echoing_the_body_prints_no_secret(self):
        def handler(args, state, send):
            r = send("GET", "https://www.youtube.com/x")
            raise RuntimeError("HTTP %d: %s" % (r.status, r.body.decode()))
        code, out, err = run_cli(["refresh"], send=fake_500, handlers={"refresh": handler})
        self.assertEqual(code, 1)
        self.assertNotIn("SECRET", out + err)
        self.assertIn("RuntimeError", err)

    def test_long_opaque_values_and_prefixes_are_filtered(self):
        def handler(args, state, send):
            raise ValueError("bad " + "A" * 60 + " and 1//0abc and ya29.zzz ok")
        code, out, err = run_cli(["home"], send=fake_500, handlers={"home": handler})
        self.assertNotIn("A" * 41, err)
        self.assertNotIn("0abc", err)
        self.assertNotIn("zzz", err)
        self.assertIn("ValueError", err)

    def test_dataclass_repr_with_a_token_is_filtered(self):
        def handler(args, state, send):
            raise RuntimeError(repr({"t": "ya29.SECRET"}))
        code, out, err = run_cli(["menu"], send=fake_500, handlers={"menu": handler})
        self.assertNotIn("SECRET", err)

    def test_later_subcommands_exist_and_are_not_implemented_yet(self):
        for sub in ("home", "menu", "feedback", "report", "history", "next", "fixture", "results"):
            code, out, err = run_cli(sub.split(), send=fake_500)
            self.assertEqual(code, 2, sub)
            self.assertIn("not implemented", out + err)


if __name__ == "__main__":
    unittest.main()
