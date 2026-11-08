"""Watch reporting: a signed player request, the playback and watchtime pings, and the history check."""
from __future__ import annotations

from dataclasses import dataclass
import json
import re
import secrets
import time
from typing import Optional, Tuple
from urllib.parse import parse_qsl, urlencode, urlparse

from . import innertube, oauth

SAFARI_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
             "Version/17.0 Safari/605.1.15")
_STS = re.compile(r'"STS":(\d+)')
_CPN_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{1,20}$")


def signature_timestamp(*, send) -> Optional[int]:
    """The web player's signatureTimestamp: first "STS":<digits> on the youtube.com home page."""
    resp = send("GET", "https://www.youtube.com/", headers={"User-Agent": SAFARI_UA})
    if resp.status != 200:
        return None
    m = _STS.search(resp.body.decode("utf-8", "replace"))
    return int(m.group(1)) if m else None


@dataclass(repr=False)
class PlayerTracking:
    status: str
    has_ei: bool
    has_vm: bool
    has_of: bool
    playback_url: Optional[str]
    watchtime_url: Optional[str]
    length: Optional[float]

    def __repr__(self) -> str:  # the URLs carry ei, vm and of: never shown
        return "PlayerTracking(status=%r, ei=%s, vm=%s, of=%s, playback_url=%s, watchtime_url=%s, length=%r)" % (
            self.status, "yes" if self.has_ei else "no", "yes" if self.has_vm else "no",
            "yes" if self.has_of else "no", "yes" if self.playback_url else "no",
            "yes" if self.watchtime_url else "no", self.length)


def _base_url(reply: dict, key: str) -> Optional[str]:
    node = (reply.get("playbackTracking") or {}).get(key)
    url = node.get("baseUrl") if isinstance(node, dict) else None
    return url if isinstance(url, str) and url else None


def tracking_from_player(reply: dict) -> PlayerTracking:
    status = (reply.get("playabilityStatus") or {}).get("status")
    playback, watchtime = _base_url(reply, "videostatsPlaybackUrl"), _base_url(reply, "videostatsWatchtimeUrl")
    keys = set()
    length = None
    for url in (playback, watchtime):
        if url:
            query = dict(parse_qsl(urlparse(url).query, keep_blank_values=True))
            keys.update(k for k, v in query.items() if v)
            if length is None and re.match(r"^\d+(\.\d+)?$", query.get("len", "")):
                length = float(query["len"])
    details = reply.get("videoDetails") or {}
    secs = details.get("lengthSeconds") if isinstance(details, dict) else None
    if isinstance(secs, str) and secs.isdigit():
        length = float(secs)
    return PlayerTracking(status if isinstance(status, str) else "UNKNOWN", "ei" in keys, "vm" in keys,
                          "of" in keys, playback, watchtime, length)


def new_cpn() -> str:
    return "".join(secrets.choice(_CPN_ALPHABET) for _ in range(16))


def ping_url(base_url: str, *, kind: str, docid: str, length: float, cpn: str, cmt: float,
             st: Optional[float] = None, et: Optional[float] = None, final: bool = False) -> str:
    """Keep every item of the base URL, set the reporting items, and send it to www.youtube.com."""
    own = {"ns": "yt", "ver": "2", "docid": docid, "len": "%.3f" % length, "cmt": "%.3f" % cmt, "cpn": cpn}
    if st is not None:
        own["st"] = "%.3f" % st
    if et is not None:
        own["et"] = "%.3f" % et
    if final:
        own["final"] = "1"
    replaced = set(own) | {"final", "st", "et"}
    items = [(k, v) for k, v in parse_qsl(urlparse(base_url).query, keep_blank_values=True) if k not in replaced]
    items.extend(own.items())
    return "https://www.youtube.com/api/stats/%s?%s" % (kind, urlencode(items))


def _walk_tiles(node, out: list) -> None:
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "adSlotRenderer":
                continue
            if key == "tileRenderer" and isinstance(val, dict):
                out.append(val)
            _walk_tiles(val, out)
    elif isinstance(node, list):
        for item in node:
            _walk_tiles(item, out)


def _find_percent(node) -> Optional[int]:
    if isinstance(node, dict):
        rp = node.get("thumbnailOverlayResumePlaybackRenderer")
        if isinstance(rp, dict) and isinstance(rp.get("percentDurationWatched"), int):
            return rp["percentDurationWatched"]
        for val in node.values():
            found = _find_percent(val)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _find_percent(item)
            if found is not None:
                return found
    return None


def history_has(reply: dict, video_id: str) -> Tuple[bool, Optional[int]]:
    tiles: list = []
    _walk_tiles(reply, tiles)
    for tile in tiles:
        watch = (tile.get("onSelectCommand") or {}).get("watchEndpoint") or {}
        if tile.get("contentId") == video_id or watch.get("videoId") == video_id:
            return True, _find_percent(tile)
    return False, None


def _check_video(video: str) -> None:
    if not _VIDEO_ID.match(video):
        raise ValueError("--video takes a YouTube video id")


def run_report(args, state, send, out=print) -> int:
    _check_video(args.video)
    reported = state.read_json("reported.json") or {}
    if args.video in reported and not args.force:
        out(json.dumps({"refused": "already reported", "video": args.video}))
        return 2
    token = oauth.valid_token(state, send=send)
    profile = innertube.PROFILES["legacy"]
    body = {"context": innertube.context("legacy"), "videoId": args.video,
            "racyCheckOk": True, "contentCheckOk": True}
    sts = None
    if args.sts == "on":
        sts = signature_timestamp(send=send)
        playback_ctx = {"html5Preference": "HTML5_PREF_WANTS"}
        if sts is not None:
            playback_ctx["signatureTimestamp"] = sts
        body["playbackContext"] = {"contentPlaybackContext": playback_ctx}
    status, reply = innertube.post("player", body, token=token, profile="legacy", send=send)
    if reply is None:
        out(json.dumps({"player_status": status, "json": False}))
        return 1
    t = tracking_from_player(reply)
    out(json.dumps({"player_status": status, "playability": t.status, "sts": sts is not None, "ei": t.has_ei,
                    "vm": t.has_vm, "of": t.has_of, "playback_url": t.playback_url is not None,
                    "watchtime_url": t.watchtime_url is not None}))
    state.log("report_player", status=status, playability=t.status, ei=t.has_ei, vm=t.has_vm, of=t.has_of)
    if status != 200 or not (t.playback_url and t.watchtime_url):
        return 1
    length = t.length or 0.0
    cpn = new_cpn()
    headers = {"User-Agent": profile.user_agent, "Referer": innertube.REFERER}
    if args.auth_on_pings == "on":
        headers["Authorization"] = "Bearer " + token
    first = send("GET", ping_url(t.playback_url, kind="playback", docid=args.video, length=length, cpn=cpn,
                                 cmt=0.0), headers=dict(headers))
    if args.delay > 0:
        time.sleep(args.delay)
    second = send("GET", ping_url(t.watchtime_url, kind="watchtime", docid=args.video, length=length, cpn=cpn,
                                  cmt=float(args.delay), st=0.0, et=float(args.delay)), headers=dict(headers))
    out(json.dumps({"playback_ping": first.status, "watchtime_ping": second.status}))
    state.log("report_pings", playback=first.status, watchtime=second.status, auth=args.auth_on_pings)
    reported[args.video] = time.time()
    state.write_json("reported.json", reported)
    return 0


def run_history(args, state, send, out=print) -> int:
    _check_video(args.video)
    token = oauth.valid_token(state, send=send)
    body = {"context": innertube.context("tv"), "browseId": "FEhistory"}
    status, reply = innertube.post("browse", body, token=token, send=send)
    if reply is None or status != 200:
        out(json.dumps({"status": status, "json": reply is not None}))
        return 1
    found, percent = history_has(reply, args.video)
    out(json.dumps({"found": found, "percent": percent}))
    state.log("history", status=status, found=found, percent=percent)
    return 0
