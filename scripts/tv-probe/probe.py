#!/usr/bin/env python3
"""No Slop Phase 0 probe CLI. Run with: /usr/bin/python3 -I scripts/tv-probe/probe.py <command>."""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I does not add the script folder

from tvprobe import http  # noqa: E402
from tvprobe.state import State, default_root  # noqa: E402

COMMANDS = ("signin", "refresh", "home", "menu", "feedback", "report", "history", "next", "fixture", "results",
            "revoke")

_PREFIXED = re.compile(r"(ya29\.|1//)\S*")
_LONG = re.compile(r"\S{41,}")


def safe_message(text: str) -> str:
    """Remove anything that looks like a token from an error message."""
    text = _PREFIXED.sub("<hidden>", text)
    return _LONG.sub("<hidden>", text)


def _not_implemented(args, state, send) -> int:
    print("not implemented")
    return 2


# Later tasks replace entries: handler(args, state, send) -> int
HANDLERS = {name: _not_implemented for name in COMMANDS}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="probe.py", description="No Slop Phase 0 signed-in probe")
    sub = parser.add_subparsers(dest="command", required=True)
    signin = sub.add_parser("signin", help="TV code sign-in")
    signin.add_argument("action", choices=("start", "wait"))
    for name in COMMANDS[1:]:
        sub.add_parser(name)
    return parser


def main(argv, *, state=None, send=http.send) -> int:
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2
    try:
        st = state if state is not None else State(default_root())
        return HANDLERS[args.command](args, st, send)
    except Exception as e:  # never show a traceback: it could carry a request
        print("%s: %s" % (type(e).__name__, safe_message(str(e))), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
