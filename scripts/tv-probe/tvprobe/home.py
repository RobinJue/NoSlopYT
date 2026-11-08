"""Signed TV Home: a tolerant walker that keeps only real video tiles, and the Home pass check."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
import json
import re
from typing import List, Optional, Tuple

from . import innertube, oauth

# Renderers that are never videos. They are counted, never walked into (an ad's inner tile looks real).
_NOT_VIDEOS = frozenset({"adSlotRenderer", "promoShelfRenderer", "gridButtonRenderer", "searchBarRenderer",
                         "feedNudgeRenderer"})
_SECTION_LISTS = frozenset({"sectionListRenderer", "sectionListContinuation"})
_ITEM_LISTS = {"horizontalListRenderer": "items", "horizontalListContinuation": "items",
               "gridRenderer": "items", "verticalListRenderer": "items"}
_SHELF_LISTS = frozenset({"horizontalListRenderer", "horizontalListContinuation"})
MIN_VISIBLE = 8
MAX_PAGES = 3


@dataclass(repr=False)
class Tile:
    video_id: str
    title: str
    channel_name: Optional[str]
    duration_text: Optional[str]
    is_short: bool
    is_live: bool
    is_upcoming: bool
    is_members_only: bool
    is_paid: bool
    percent_watched: Optional[int]
    panel: Optional[Tuple[str, str]]

    def __repr__(self) -> str:  # the panel params are request material: never shown
        return "Tile(video_id=%r, short=%s, live=%s, panel=%s)" % (
            self.video_id, self.is_short, self.is_live, "yes" if self.panel else "no")


@dataclass(repr=False)
class HomePage:
    logged_in: Optional[bool]
    tiles: List[Tile] = field(default_factory=list)
    skipped: Counter = field(default_factory=Counter)
    unknown: Counter = field(default_factory=Counter)
    section_continuation: Optional[str] = None
    shelf_continuations: List[str] = field(default_factory=list)

    def __repr__(self) -> str:  # continuation tokens are never shown
        return "HomePage(logged_in=%s, tiles=%d, section_continuation=%s, shelf_continuations=%d)" % (
            self.logged_in, len(self.tiles), "yes" if self.section_continuation else "no",
            len(self.shelf_continuations))


def _text(node) -> Optional[str]:
    if not isinstance(node, dict):
        return None
    if isinstance(node.get("simpleText"), str):
        return node["simpleText"]
    runs = node.get("runs")
    if isinstance(runs, list):
        return "".join(r.get("text", "") for r in runs if isinstance(r, dict)) or None
    if isinstance(node.get("content"), str):
        return node["content"]
    return None


def _dig(node, *path):
    for key in path:
        if isinstance(key, int):
            if not isinstance(node, list) or key >= len(node):
                return None
            node = node[key]
        else:
            if not isinstance(node, dict):
                return None
            node = node.get(key)
    return node


def _scan_flags(node, found: set) -> None:
    """Collect markers from style/icon values and key names anywhere inside a tile."""
    if isinstance(node, dict):
        for key, val in node.items():
            if "ypc" in key.lower():
                found.add("paid")
            if key in ("style", "iconType", "icon", "type") and isinstance(val, str):
                up = val.upper()
                if "MEMBERS" in up or "SPONSORS_ONLY" in up:
                    found.add("members")
                if "YPC" in up:
                    found.add("paid")
            _scan_flags(val, found)
    elif isinstance(node, list):
        for item in node:
            _scan_flags(item, found)


def _first_str(*values) -> Optional[str]:
    for v in values:
        if isinstance(v, str) and v:
            return v
    return None


def _tile_video_id(tile: dict) -> Optional[str]:
    return _first_str(_dig(tile, "onSelectCommand", "watchEndpoint", "videoId"),
                      _dig(tile, "onSelectCommand", "reelWatchEndpoint", "videoId"), tile.get("contentId"))


def _panel(tile: dict) -> Optional[Tuple[str, str]]:
    ep = _dig(tile, "onLongPressCommand", "showEngagementPanelEndpoint")
    tag = _dig(ep, "identifier", "tag")
    params = _dig(ep, "globalConfiguration", "params")
    if isinstance(tag, str) and isinstance(params, str) and tag and params:
        return (tag, params)
    return None


class _Walker:
    def __init__(self) -> None:
        self.page = HomePage(logged_in=None)
        self._short_depth = 0

    # ---- generic descent over the wrappers above the lists ----
    def walk(self, node) -> None:
        if isinstance(node, list):
            for item in node:
                self.walk(item)
        elif isinstance(node, dict):
            for key, val in node.items():
                self.visit(key, val, in_list=False)

    def visit(self, key: str, val, *, in_list: bool) -> None:
        if key in _NOT_VIDEOS:
            self.page.skipped[key] += 1
        elif key == "shelfRenderer":
            self.shelf(val)
        elif key == "tileRenderer":
            self.tile(val)
        elif key == "lockupViewModel":
            self.lockup(val)
        elif key in _SECTION_LISTS:
            self.section_list(val)
        elif key in _ITEM_LISTS:
            self.item_list(key, val)
        elif key == "_loggedIn" and isinstance(val, bool):  # left by scrub in committed fixtures
            self.page.logged_in = val
        elif key == "responseContext":
            self.response_context(val)
        elif in_list:
            self.page.unknown[key] += 1
        else:
            self.walk(val)

    def response_context(self, ctx) -> None:
        for svc in _dig(ctx, "serviceTrackingParams") or []:
            if isinstance(svc, dict) and svc.get("service") == "GFEEDBACK":
                for p in svc.get("params") or []:
                    if isinstance(p, dict) and p.get("key") == "logged_in":
                        if str(p.get("value")) == "1":
                            self.page.logged_in = True
                        elif str(p.get("value")) == "0":
                            self.page.logged_in = False

    def section_list(self, node) -> None:
        if not isinstance(node, dict):
            return
        token = _dig(node, "continuations", 0, "nextContinuationData", "continuation")
        if isinstance(token, str) and self.page.section_continuation is None:
            self.page.section_continuation = token
        self.walk_items(node.get("contents"))

    def item_list(self, key: str, node) -> None:
        if not isinstance(node, dict):
            return
        if key in _SHELF_LISTS:
            token = _dig(node, "continuations", 0, "nextContinuationData", "continuation")
            if isinstance(token, str):
                self.page.shelf_continuations.append(token)
        self.walk_items(node.get(_ITEM_LISTS[key]))

    def walk_items(self, items) -> None:
        if not isinstance(items, list):
            return
        for item in items:
            if isinstance(item, dict):
                for key, val in item.items():
                    self.visit(key, val, in_list=True)

    def shelf(self, shelf) -> None:
        if not isinstance(shelf, dict):
            return
        kind = str(shelf.get("tvhtml5ShelfRendererType") or "")
        if _dig(shelf, "tvhtml5Metadata", "hideLogo"):
            self.page.skipped["upsellShelf"] += 1
            return
        if "EDU" in kind:
            self.page.skipped["shelf:EDU"] += 1
            return
        shorts = "SHORTS" in kind
        self._short_depth += 1 if shorts else 0
        try:
            self.walk(shelf.get("content"))
        finally:
            self._short_depth -= 1 if shorts else 0

    # ---- tiles ----
    def tile(self, tile) -> None:
        if not isinstance(tile, dict):
            return
        ctype = str(tile.get("contentType") or "")
        vid = _tile_video_id(tile)
        short_type = "SHORT" in ctype or "REEL" in ctype or "SHORTS" in str(tile.get("style") or "")
        if ctype and ctype != "TILE_CONTENT_TYPE_VIDEO" and not short_type:
            self.page.skipped["tile:" + ctype.replace("TILE_CONTENT_TYPE_", "")] += 1
            return
        if not vid:
            self.page.unknown["tileRenderer"] += 1
            return
        overlays = _dig(tile, "header", "tileHeaderRenderer", "thumbnailOverlays") or tile.get("thumbnailOverlays") or []
        duration, style, percent = None, "", None
        for ov in overlays:
            if not isinstance(ov, dict):
                continue
            ts = ov.get("thumbnailOverlayTimeStatusRenderer")
            if isinstance(ts, dict):
                style = str(ts.get("style") or "").upper()
                duration = _text(ts.get("text"))
            rp = ov.get("thumbnailOverlayResumePlaybackRenderer")
            if isinstance(rp, dict) and isinstance(rp.get("percentDurationWatched"), int):
                percent = rp["percentDurationWatched"]
        live, upcoming = style == "LIVE", style == "UPCOMING"
        if live or upcoming or style == "SHORTS":
            duration = None if (live or upcoming) else duration
        short = (short_type or style == "SHORTS" or self._short_depth > 0
                 or (not duration and not live and not upcoming))
        lines = _dig(tile, "metadata", "tileMetadataRenderer", "lines") or []
        channel = _text(_dig(lines, 0, "lineRenderer", "items", 0, "lineItemRenderer", "text"))
        flags: set = set()
        _scan_flags(tile.get("metadata"), flags)
        _scan_flags(tile.get("header"), flags)
        self.page.tiles.append(Tile(
            video_id=vid,
            title=_text(_dig(tile, "metadata", "tileMetadataRenderer", "title")) or "",
            channel_name=channel, duration_text=duration, is_short=short, is_live=live, is_upcoming=upcoming,
            is_members_only="members" in flags, is_paid="paid" in flags, percent_watched=percent,
            panel=_panel(tile)))

    def lockup(self, node) -> None:
        if not isinstance(node, dict):
            return
        ctype = str(node.get("contentType") or "")
        vid = node.get("contentId")
        if not isinstance(vid, str) or not vid:
            self.page.unknown["lockupViewModel"] += 1
            return
        short = "SHORT" in ctype
        if ctype and not short and ctype != "LOCKUP_CONTENT_TYPE_VIDEO":
            self.page.skipped["lockup:" + ctype.replace("LOCKUP_CONTENT_TYPE_", "")] += 1
            return
        flags: set = set()
        _scan_flags(node.get("metadata"), flags)
        title = _text(_dig(node, "metadata", "lockupMetadataViewModel", "title")) or ""
        self.page.tiles.append(Tile(vid, title, None, None, short or self._short_depth > 0, False, False,
                                    "members" in flags, "paid" in flags, None, None))


def parse_home(reply: dict) -> HomePage:
    """Parse a first page or either continuation shape into the tiles that are real videos."""
    w = _Walker()
    w.walk(reply)
    return w.page


def noslop_visible(tile: Tile) -> bool:
    """No Slop's default filters: no Shorts, members-only or paid items (live and upcoming stay)."""
    return not (tile.is_short or tile.is_members_only or tile.is_paid)


def home_try_passes(pages: List[HomePage]) -> Tuple[bool, int]:
    """One try passes when page 1 is logged in and the first 3 pages hold at least 8 unique visible videos."""
    if not pages or pages[0].logged_in is not True:
        return (False, 0)
    seen = set()
    for page in pages[:MAX_PAGES]:
        for tile in page.tiles:
            if noslop_visible(tile):
                seen.add(tile.video_id)
    return (len(seen) >= MIN_VISIBLE, len(seen))


_TV_VISITOR = re.compile(r'"visitorData"\s*:\s*"([^"]+)"')
_CAPTURE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,40}$")


def _tv_visitor(send) -> Optional[str]:
    """visitorData from the TV page (policy "tv")."""
    resp = send("GET", "https://www.youtube.com/tv", headers={"User-Agent": innertube.PROFILES["tv"].user_agent})
    m = _TV_VISITOR.search(resp.body.decode("utf-8", "replace"))
    return m.group(1) if m else None


def _summary(page: HomePage, status: int, label: str) -> dict:
    return {
        label: True, "status": status, "logged_in": page.logged_in, "tiles": len(page.tiles),
        "shorts": sum(1 for t in page.tiles if t.is_short),
        "visible": sum(1 for t in page.tiles if noslop_visible(t)),
        "skipped": dict(page.skipped), "unknown": dict(page.unknown),
        "continuation": page.section_continuation is not None,
        "shelf_continuations": len(page.shelf_continuations),
    }


def run_home(args, state, send, out=print) -> int:
    """probe.py home: fetch up to N pages (and optionally one shelf continuation); print counts only."""
    if args.capture is not None and not _CAPTURE_NAME.match(args.capture):
        raise ValueError("--capture takes letters, digits, - and _ only")
    token = oauth.valid_token(state, send=send)
    host = innertube.HOSTS[args.host]
    visitor = _tv_visitor(send) if args.visitor == "tv" else None

    def call(body_extra: dict, n: int, label: str):
        nonlocal visitor
        body = {"context": innertube.context("tv", variant=args.context, visitor=visitor)}
        body.update(body_extra)
        status, reply = innertube.post("browse", body, token=token, host=host, visitor=visitor, send=send)
        if reply is not None and args.capture:
            state.write_json("captures/%s-%s.json" % (args.capture, label), reply)
        if reply is None:
            out(json.dumps({"page": n, "status": status, "json": False}))
            return None
        if args.visitor == "first" and visitor is None:
            visitor = _dig(reply, "responseContext", "visitorData") or None
        page = parse_home(reply)
        summary = _summary(page, status, "page" if label.isdigit() else "shelf")
        summary["n"] = n
        out(json.dumps(summary))
        state.log("home", page=label, status=status, logged_in=page.logged_in, tiles=len(page.tiles),
                  continuation=page.section_continuation is not None)
        return page if status == 200 else None

    pages: List[HomePage] = []
    page = call({"browseId": args.browse_id}, 1, "1")
    next_token = None
    if page is not None:
        pages.append(page)
        next_token = page.section_continuation
        if args.shelf and page.shelf_continuations:
            call({"continuation": page.shelf_continuations[0]}, 1, "shelf")
    for n in range(2, args.pages + 1):
        if not next_token:
            break
        page = call({"continuation": next_token}, n, str(n))
        if page is None:
            break
        pages.append(page)
        next_token = page.section_continuation
    passed, count = home_try_passes(pages)
    out(json.dumps({"try_passes": passed, "visible_unique": count}))
    state.log("home_try", try_passes=passed, visible_unique=count)
    return 0
