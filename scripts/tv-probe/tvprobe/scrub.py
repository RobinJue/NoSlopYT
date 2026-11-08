"""Scrubbed copies of captures: nothing secret, nothing that identifies the account, plus a leak check."""
from __future__ import annotations

import re
from typing import Dict, List, Optional

PLACEHOLDER = "REDACTED"
SAFE_IP = "203.0.113.7"
_SECRET_KEY = re.compile(r"token|params|visitordata|serializedshareentity|datasyncid|delegatedsessionid|"
                         r"gaiaid|accountname", re.IGNORECASE)
_DROPPED = frozenset({"frameworkUpdates"})
_TRACKING_URL = re.compile(r"https?://[^\s\"'<>]*?(?:googlevideo\.com|s\.youtube\.com|/api/stats/)[^\s\"'<>]*")
_IPV4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\.?\d)")
_TITLE_KEYS = frozenset({"title", "headline"})
_CHANNEL_KEYS = frozenset({"shortBylineText", "longBylineText", "ownerText", "channelName"})
_TEXT_KEYS = ("simpleText", "text", "content")


def _logged_in(reply: dict) -> Optional[bool]:
    ctx = reply.get("responseContext")
    for svc in (ctx.get("serviceTrackingParams") if isinstance(ctx, dict) else None) or []:
        if isinstance(svc, dict) and svc.get("service") == "GFEEDBACK":
            for p in svc.get("params") or []:
                if isinstance(p, dict) and p.get("key") == "logged_in":
                    if str(p.get("value")) == "1":
                        return True
                    if str(p.get("value")) == "0":
                        return False
    return None


class _Scrubber:
    def __init__(self, hide_titles: bool) -> None:
        self.hide_titles = hide_titles
        self.continuations: Dict[str, str] = {}
        self.names: Dict[str, Dict[str, str]] = {"Title": {}, "Channel": {}}

    def _label(self, kind: str, original: str) -> str:
        known = self.names[kind]
        if original not in known:
            known[original] = "%s %d" % (kind, len(known) + 1)
        return known[original]

    def _string(self, text: str) -> str:
        text = _TRACKING_URL.sub("https://example.invalid/", text)
        return _IPV4.sub(SAFE_IP, text)

    def _blank(self, node):
        """Every string below a secret key is replaced, whatever the shape."""
        if isinstance(node, dict):
            return {k: self._blank(v) for k, v in node.items()}
        if isinstance(node, list):
            return [self._blank(v) for v in node]
        return PLACEHOLDER if isinstance(node, str) else node

    def _relabel(self, node, kind: str):
        """Replace the text under a title or channel node (simpleText, runs, content)."""
        if isinstance(node, str):
            return self._label(kind, node)
        if isinstance(node, list):
            return [self._relabel(v, kind) for v in node]
        if isinstance(node, dict):
            return {k: (self._relabel(v, kind) if k in _TEXT_KEYS or k == "runs" else self.walk(v))
                    for k, v in node.items()}
        return node

    def walk(self, node, key: str = ""):
        if isinstance(node, dict):
            out = {}
            for k, v in node.items():
                if k in _DROPPED:
                    continue
                if k == "serviceTrackingParams" and key == "responseContext":
                    continue
                if _SECRET_KEY.search(k):
                    out[k] = self._blank(v)
                elif k == "continuation" and isinstance(v, str):
                    out[k] = self.continuations.setdefault(v, "CONTINUATION_%d" % (len(self.continuations) + 1))
                elif self.hide_titles and k in _TITLE_KEYS:
                    out[k] = self._relabel(v, "Title")
                elif self.hide_titles and k in _CHANNEL_KEYS:
                    out[k] = self._relabel(v, "Channel")
                elif self.hide_titles and k == "lines" and isinstance(v, list) and v:
                    out[k] = [self._channel_line(v[0])] + [self.walk(x, k) for x in v[1:]]
                else:
                    out[k] = self.walk(v, k)
            return out
        if isinstance(node, list):
            return [self.walk(v, key) for v in node]
        if isinstance(node, str):
            return self._string(node)
        return node

    def _channel_line(self, line):
        """The first metadata line of a tile is its channel name."""
        if not isinstance(line, dict):
            return self.walk(line)
        out = {}
        for k, v in line.items():
            out[k] = self._relabel(v, "Channel") if k == "text" else self._channel_line(v) if isinstance(v, dict) \
                else [self._channel_line(x) for x in v] if isinstance(v, list) else v
        return out


def scrub(obj, *, hide_titles: bool = False):
    """A new object without tokens, params, visitorData, tracking URLs, IP addresses or the account's ids."""
    result = _Scrubber(hide_titles).walk(obj)
    if isinstance(obj, dict) and "responseContext" in obj and isinstance(result, dict):
        result["_loggedIn"] = _logged_in(obj)
    return result


_LEAK_PATTERNS = (re.compile(r"ya29\.[A-Za-z0-9._-]+"), re.compile(r"(?<![\w/:.])1//[A-Za-z0-9._-]+"),
                  re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]+"))


def leaks(text: str) -> List[str]:
    """Token prefixes, bearer headers and IPv4 addresses other than the documentation address."""
    found: List[str] = []
    for pattern in _LEAK_PATTERNS:
        found.extend(m.group(0) for m in pattern.finditer(text))
    found.extend(m.group(0) for m in _IPV4.finditer(text) if m.group(0) != SAFE_IP)
    return found
