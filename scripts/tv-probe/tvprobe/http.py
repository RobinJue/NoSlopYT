"""Guarded transport: three allowed hosts, https only, no redirects, no cookies, never raises on HTTP errors."""
from __future__ import annotations

import urllib.error
import urllib.request
from typing import NamedTuple, Optional
from urllib.parse import urlsplit

ALLOWED_HOSTS = frozenset({"www.youtube.com", "youtubei.googleapis.com", "oauth2.googleapis.com"})


class NotAllowed(Exception):
    pass


class Response(NamedTuple):
    status: int
    headers: dict
    body: bytes


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)  # no HTTPCookieProcessor: no cookies are kept


def _check(url: str) -> None:
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.username is not None or parts.password is not None:
        raise NotAllowed("only plain https URLs are allowed")
    try:
        port = parts.port
    except ValueError:
        raise NotAllowed("bad port")
    if port not in (None, 443) or (parts.hostname or "") not in ALLOWED_HOSTS:
        raise NotAllowed("host not on the allow-list: %s" % (parts.hostname,))


def send(method: str, url: str, *, headers: Optional[dict] = None, body: Optional[bytes] = None,
         timeout: float = 30) -> Response:
    _check(url)
    req = urllib.request.Request(url, data=body, method=method, headers=dict(headers or {}))
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            return Response(resp.status, dict(resp.headers.items()), resp.read())
    except urllib.error.HTTPError as e:
        try:
            data = e.read()
        except Exception:
            data = b""
        return Response(e.code, dict(e.headers.items()) if e.headers else {}, data)


_SENSITIVE = frozenset({"authorization", "cookie", "set-cookie", "x-goog-visitor-id", "x-goog-authuser"})


def redact(headers: dict) -> dict:
    return {k: ("<redacted>" if k.lower() in _SENSITIVE else v) for k, v in headers.items()}
