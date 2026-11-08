"""Signed versus anonymous Up next: shelf titles, video ids and how much the two lists share."""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import re
from typing import List, Optional

from . import innertube, oauth
from .home import _dig, _text, parse_home

_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{1,20}$")


@dataclass(repr=False)
class NextSummary:
    logged_in: Optional[bool]
    shelf_titles: List[str] = field(default_factory=list)
    video_ids: List[str] = field(default_factory=list)

    def __repr__(self) -> str:  # counts only
        return "NextSummary(logged_in=%s, shelves=%d, videos=%d)" % (
            self.logged_in, len(self.shelf_titles), len(self.video_ids))


def _shelf_titles(node, out: List[str]) -> None:
    """Titles of every shelf, in order. Never enters an ad."""
    if isinstance(node, list):
        for item in node:
            _shelf_titles(item, out)
    elif isinstance(node, dict):
        for key, val in node.items():
            if key == "adSlotRenderer":
                continue
            if key == "shelfRenderer" and isinstance(val, dict):
                title = _text(val.get("headline")) or _text(val.get("title"))
                if title:
                    out.append(title)
            _shelf_titles(val, out)


def parse_next(reply: dict) -> NextSummary:
    """Reuse the Home walker for tiles (it skips ads and non-videos) and add the shelf titles."""
    page = parse_home(reply)
    ids: List[str] = []
    for tile in page.tiles:
        if tile.video_id not in ids:
            ids.append(tile.video_id)
    titles: List[str] = []
    _shelf_titles(_dig(reply, "contents"), titles)
    return NextSummary(page.logged_in, titles, ids)


def overlap(a: List[str], b: List[str]) -> float:
    """The share of a that is also in b."""
    if not a:
        return 0.0
    other = set(b)
    return sum(1 for x in a if x in other) / len(a)


def run_next(args, state, send, out=print) -> int:
    if not _VIDEO_ID.match(args.video):
        raise ValueError("--video must be a YouTube video id")
    token = oauth.valid_token(state, send=send)
    body = {"context": innertube.context("tv"), "videoId": args.video}
    s_status, s_reply = innertube.post("next", body, token=token, send=send)
    if s_reply is not None:
        state.write_json("captures/next-signed.json", s_reply)
    if s_reply is None or s_status != 200:
        out(json.dumps({"signed_status": s_status, "json": s_reply is not None}))
        return 1
    a_status, a_reply = innertube.post("next", {"context": innertube.context("tv"), "videoId": args.video},
                                       token=None, send=send)
    if a_reply is not None:
        state.write_json("captures/next-anon.json", a_reply)
    signed = parse_next(s_reply)
    anon = parse_next(a_reply) if a_reply is not None and a_status == 200 else NextSummary(None)
    share = overlap(signed.video_ids, anon.video_ids)
    out(json.dumps({"signed": True, "status": s_status, "logged_in": signed.logged_in,
                    "shelves": signed.shelf_titles, "videos": len(signed.video_ids)}))
    out(json.dumps({"signed": False, "status": a_status, "logged_in": anon.logged_in,
                    "shelves": anon.shelf_titles, "videos": len(anon.video_ids)}))
    out(json.dumps({"overlap": round(share, 3)}))
    state.log("next", signed_status=s_status, anon_status=a_status, signed_logged_in=signed.logged_in,
              signed_videos=len(signed.video_ids), anon_videos=len(anon.video_ids), overlap=round(share, 3))
    return 0
