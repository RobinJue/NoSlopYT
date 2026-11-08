"""Card menu: find "Not interested" and "Don't recommend channel" in a get_panel reply, by structure."""
from __future__ import annotations

from dataclasses import dataclass
import json
import re
from typing import List, Optional

from . import home, innertube, oauth

_CHANNEL_ID = re.compile(r"^UC[A-Za-z0-9_-]{22}$")
_HANDLE = re.compile(r"•\s*(@[\w.\-]+)")
_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{1,20}$")


@dataclass(repr=False)
class PanelFindings:
    not_interested: Optional[str]
    dont_recommend: Optional[str]
    channel_id: Optional[str]
    handle: Optional[str]
    ambiguous: bool

    def __repr__(self) -> str:  # the feedback tokens are never shown
        return "PanelFindings(not_interested=%s, dont_recommend=%s, channel_id=%r, handle=%r, ambiguous=%s)" % (
            "yes" if self.not_interested else "no", "yes" if self.dont_recommend else "no",
            self.channel_id, self.handle, self.ambiguous)


def _has_dismissal(node) -> bool:
    """A dismissal follow-up: any key inside the node that names removing or replacing the card."""
    if isinstance(node, dict):
        for key, val in node.items():
            low = key.lower()
            if "dismiss" in low or "replaceenclosing" in low or "removefeedback" in low or "removecomponent" in low \
                    or "hideenclosing" in low or "uiactions" in low:
                return True
            if _has_dismissal(val):
                return True
    elif isinstance(node, list):
        return any(_has_dismissal(v) for v in node)
    return False


def _walk(node, in_popup: bool, out_ni: List[str], out_dr: List[str], strings: List[str], ids: List[str]) -> None:
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "feedbackEndpoint" and isinstance(val, dict):
                token = val.get("feedbackToken")
                if isinstance(token, str) and token:
                    if in_popup:
                        out_dr.append(token)
                    elif _has_dismissal(val):
                        out_ni.append(token)
                continue
            if key == "browseEndpoint" and isinstance(val, dict):
                bid = val.get("browseId")
                if isinstance(bid, str) and _CHANNEL_ID.match(bid):
                    ids.append(bid)
            _walk(val, in_popup or key == "openPopupAction", out_ni, out_dr, strings, ids)
    elif isinstance(node, list):
        for item in node:
            _walk(item, in_popup, out_ni, out_dr, strings, ids)
    elif isinstance(node, str):
        strings.append(node)


def parse_panel(reply: dict) -> PanelFindings:
    """More than one candidate of a kind sets ambiguous and both tokens to None."""
    ni: List[str] = []
    dr: List[str] = []
    strings: List[str] = []
    ids: List[str] = []
    _walk(reply, False, ni, dr, strings, ids)
    ni, dr = list(dict.fromkeys(ni)), list(dict.fromkeys(dr))
    handle = None
    for s in strings:
        m = _HANDLE.search(s)
        if m:
            handle = m.group(1)
            break
    distinct = list(dict.fromkeys(ids))
    channel = distinct[0] if len(distinct) == 1 else None  # several channels: unknown, so Don't recommend fails closed
    if len(ni) > 1 or len(dr) > 1:
        return PanelFindings(None, None, channel, handle, True)
    return PanelFindings(ni[0] if ni else None, dr[0] if dr else None, channel, handle, False)


def _find_tile(state, video_id: str):
    """The tile of the newest Home capture that holds the video (panel captures are skipped)."""
    folder = state.path("captures")
    if not folder.is_dir():
        return None
    files = sorted((p for p in folder.glob("*.json") if not p.name.startswith("panel-")),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    for p in files:
        reply = state.read_json("captures/" + p.name)
        if not isinstance(reply, dict):
            continue
        for tile in home.parse_home(reply).tiles:
            if tile.video_id == video_id and tile.panel:
                return tile
    return None


def fetch_menu(args, state, send, token):
    """get_panel for the video's tile. Returns (status, PanelFindings or None)."""
    if not _VIDEO_ID.match(args.video):
        raise ValueError("--video takes a video id")
    tile = _find_tile(state, args.video)
    if tile is None:
        raise ValueError("no Home capture holds a tile with a menu for that video (run home --capture first)")
    panel_id, params = tile.panel
    body = {"context": innertube.context("tv"), "panelId": panel_id, "params": params}
    status, reply = innertube.post("get_panel", body, token=token, send=send)
    if reply is None:
        return status, None
    state.write_json("captures/panel-%s.json" % args.video, reply)
    return status, parse_panel(reply)


def _findings_line(status: int, f: Optional[PanelFindings]) -> dict:
    if f is None:
        return {"status": status, "json": False}
    return {"status": status, "not_interested": f.not_interested is not None,
            "dont_recommend": f.dont_recommend is not None, "channel_id": f.channel_id, "handle": f.handle,
            "ambiguous": f.ambiguous}


def run_menu(args, state, send, out=print) -> int:
    token = oauth.valid_token(state, send=send)
    status, f = fetch_menu(args, state, send, token)
    line = _findings_line(status, f)
    out(json.dumps(line))
    state.log("menu", status=status, ambiguous=bool(f and f.ambiguous))
    return 0 if f is not None and status == 200 else 1


def run_feedback(args, state, send, out=print) -> int:
    token = oauth.valid_token(state, send=send)
    status, f = fetch_menu(args, state, send, token)
    out(json.dumps(_findings_line(status, f)))
    if f is None or status != 200:
        return 1
    if f.ambiguous:
        out(json.dumps({"sent": False, "reason": "ambiguous"}))
        return 2
    if args.kind == "dont-recommend":
        if not args.confirm_channel or args.confirm_channel != f.channel_id:
            out(json.dumps({"sent": False, "reason": "--confirm-channel must equal the panel's channel id"}))
            return 2
        feedback_token = f.dont_recommend
    else:
        feedback_token = f.not_interested
    if feedback_token is None:
        out(json.dumps({"sent": False, "reason": "action not found"}))
        return 2
    body = {"context": innertube.context("tv"), "feedbackTokens": [feedback_token]}
    fstatus, reply = innertube.post("feedback", body, token=token, send=send)
    summary = {"sent": True, "kind": args.kind, "status": fstatus, "json": reply is not None}
    if reply is not None:
        summary["keys"] = sorted(reply.keys())
        responses = reply.get("feedbackResponses")
        if isinstance(responses, list):
            summary["is_processed"] = [r.get("isProcessed") if isinstance(r, dict) else None for r in responses]
    out(json.dumps(summary))
    state.log("feedback", kind=args.kind, status=fstatus)
    return 0 if fstatus == 200 else 1
