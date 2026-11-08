#!/usr/bin/env python3
"""No Slop Phase 0 probe CLI. Run with: /usr/bin/python3 -I scripts/tv-probe/probe.py <command>."""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I does not add the script folder

from tvprobe import home, http, oauth, panel, report, results, scrub, upnext  # noqa: E402
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


def _signin(args, state, send) -> int:
    if args.action == "start":
        client = oauth.fetch_client_values(send=send)
        state.write_json("client.json", {"client_id": client.client_id, "client_secret": client.client_secret})
        device = state.read_json("device.json") or {}
        device_id = device.get("device_id") or secrets.token_hex(16)
        code = oauth.request_device_code(client, device_id, send=send)
        state.write_json("device.json", {
            "device_id": device_id, "device_code": code.device_code, "user_code": code.user_code,
            "verification_url": code.verification_url, "expires_in": code.expires_in,
            "interval": code.interval, "started_at": code.started_at})
        state.log("signin_start", status=200)
        print(code.user_code)
        print(code.verification_url + "?user_code=" + code.user_code)
        print("expires in %d minutes" % (code.expires_in // 60))
        return 0
    client = oauth.load_client(state)
    data = state.read_json("device.json")
    if not data or "device_code" not in data:
        raise oauth.SignInError("no_pending_code")
    code = oauth.DeviceCode(data["device_code"], data["user_code"], data["verification_url"],
                            int(data["expires_in"]), int(data["interval"]), float(data["started_at"]))
    tokens = oauth.poll(client, code, send=send)
    oauth.save_tokens(state, tokens)
    state.log("signin_wait", status=200)
    print("connected")
    print("access token lifetime: %d seconds" % round(tokens.expires_at - time.time()))
    return 0


def _refresh(args, state, send) -> int:
    tokens = oauth.refresh(oauth.load_client(state), oauth.load_tokens(state), send=send)
    oauth.save_tokens(state, tokens)
    state.log("refresh", status=200)
    print("refreshed")
    print("access token lifetime: %d seconds" % round(tokens.expires_at - time.time()))
    return 0


def _revoke(args, state, send) -> int:
    try:
        try:
            tokens = oauth.load_tokens(state)
        except (oauth.SignInError, KeyError, TypeError, ValueError):
            tokens = None  # never signed in, code not approved, or a damaged file: still wipe below
        if tokens is None:
            print("no tokens to revoke")
        else:
            answered = []
            for url in oauth.REVOKE_URLS:
                if oauth.revoke(tokens, send=_only(send, url)):
                    answered.append(url)
            state.log("revoke", answered=len(answered))
            print("revoke answered 200 at: %s" % (", ".join(answered) if answered else "none"))
    finally:
        try:
            state.wipe()
            gone = not state.root.exists()
        except (OSError, ValueError) as e:
            print("state folder NOT removed: %s" % safe_message(str(e)), file=sys.stderr)
            gone = False
    if not gone:
        return 1
    print("state folder removed")
    return 0


def _only(send, url):
    """A transport that sends only to one revoke URL, so each endpoint is reported separately."""
    def one(method, target, **kw):
        if target != url:
            return http.Response(0, {}, b"")
        return send(method, target, **kw)
    return one


_CAPTURE = re.compile(r"^[A-Za-z0-9_-]{1,60}$")


def _mask(text: str) -> str:
    return text[:3] + "***"


def _fixture(args, state, send) -> int:
    """Write a scrubbed, pretty copy of one capture, only when the leak check finds nothing."""
    if not _CAPTURE.match(args.capture):
        raise ValueError("--capture takes letters, digits, - and _ only")
    raw = state.read_json("captures/%s.json" % args.capture)
    if raw is None:
        raise FileNotFoundError("no capture named %s" % args.capture)
    text = json.dumps(scrub.scrub(raw, hide_titles=args.hide_titles), indent=2, ensure_ascii=False) + "\n"
    found = scrub.leaks(text)
    if found:
        print("refused: %d possible leak%s: %s" % (len(found), "" if len(found) == 1 else "s",
                                                   ", ".join(_mask(x) for x in found[:10])))
        return 2
    dest = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        f.write(text)
    print("wrote %s (%d bytes)" % (args.out, len(text)))
    return 0


def _results(args, state, send) -> int:
    lines = []
    path = state.path("log.jsonl")
    if path.exists():
        for raw in path.read_text().splitlines():
            try:
                lines.append(json.loads(raw))
            except ValueError:
                continue
    print(results.summarize(lines), end="")
    return 0


# Later tasks replace entries: handler(args, state, send) -> int
HANDLERS = {name: _not_implemented for name in COMMANDS}
HANDLERS.update({"signin": _signin, "refresh": _refresh, "revoke": _revoke, "home": home.run_home,
                 "menu": panel.run_menu, "feedback": panel.run_feedback,
                 "report": report.run_report, "history": report.run_history, "next": upnext.run_next,
                 "fixture": _fixture, "results": _results})


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="probe.py", description="No Slop Phase 0 signed-in probe")
    sub = parser.add_subparsers(dest="command", required=True)
    signin = sub.add_parser("signin", help="TV code sign-in")
    signin.add_argument("action", choices=("start", "wait"))
    for name in COMMANDS[1:]:
        p = sub.add_parser(name)
        if name == "home":
            p.add_argument("--browse-id", choices=("FEwhat_to_watch", "default"), default="FEwhat_to_watch")
            p.add_argument("--host", choices=("www", "googleapis"), default="www")
            p.add_argument("--context", choices=("full", "minimal"), default="full")
            p.add_argument("--visitor", choices=("none", "first", "tv"), default="none")
            p.add_argument("--pages", type=int, default=3)
            p.add_argument("--shelf", action="store_true")
            p.add_argument("--capture", metavar="NAME")
        if name in ("menu", "feedback"):
            p.add_argument("--video", required=True)
        if name in ("report", "history"):
            p.add_argument("--video", required=True)
        if name == "report":
            p.add_argument("--sts", choices=("on", "off"), default="on")
            p.add_argument("--auth-on-pings", choices=("on", "off"), default="on")
            p.add_argument("--delay", type=float, default=30)
            p.add_argument("--force", action="store_true")
        if name == "next":
            p.add_argument("--video", required=True)
        if name == "fixture":
            p.add_argument("--capture", required=True, metavar="NAME")
            p.add_argument("--out", required=True, metavar="PATH")
            p.add_argument("--hide-titles", action="store_true")
        if name == "feedback":
            p.add_argument("--kind", choices=("not-interested", "dont-recommend"), required=True)
            p.add_argument("--confirm-channel", metavar="ID")
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
