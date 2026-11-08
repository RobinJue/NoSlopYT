"""TV-client sign-in: client values, device code, polling, refresh, revoke. Values come from the research notes
(YouTube.js and SmartTube's MediaServiceCore, both MIT)."""
from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass
from typing import Optional
from urllib.parse import quote, urljoin

TV_PAGE = "https://www.youtube.com/tv"
TV_PAGE_USER_AGENT = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
DEVICE_CODE_URL = "https://www.youtube.com/o/oauth2/device/code"   # JSON body
TOKEN_URL = "https://www.youtube.com/o/oauth2/token"               # JSON body
DEVICE_GRANT = "http://oauth.net/grant_type/device/1.0"
SCOPE = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
DEVICE_MODEL = "ytlr::"
REVOKE_URLS = ("https://oauth2.googleapis.com/revoke", "https://www.youtube.com/o/oauth2/revoke")
CLIENT_PATTERN = r'clientId:"(?P<id>[^"]+)",[^"]*?:"(?P<secret>[^"]+)"'   # YouTube.js; first match only

MIN_WAIT = 5
SLOW_DOWN_EXTRA = 5
REFRESH_MARGIN = 300
_JSON = {"Content-Type": "application/json"}


@dataclass(repr=False)
class ClientValues:
    client_id: str
    client_secret: str

    def __repr__(self) -> str:
        return "ClientValues(...)"


@dataclass(repr=False)
class DeviceCode:
    device_code: str
    user_code: str
    verification_url: str
    expires_in: int
    interval: int
    started_at: float

    def __repr__(self) -> str:
        return "DeviceCode(...)"


@dataclass(repr=False)
class Tokens:
    access_token: str
    refresh_token: str
    expires_at: float
    scope: str

    def __repr__(self) -> str:
        return "Tokens(...)"


class SignInError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def find_base_script_url(tv_html: str) -> Optional[str]:
    for tag in re.findall(r"<script\b[^>]*>", tv_html):
        if re.search(r'\bid="base-js"', tag):
            m = re.search(r'\bsrc="([^"]+)"', tag)
            if m:
                return urljoin("https://www.youtube.com/", m.group(1))
    return None


def extract_client_values(script: str) -> Optional[ClientValues]:
    m = re.search(CLIENT_PATTERN, script)
    return ClientValues(m.group("id"), m.group("secret")) if m else None


def _json(resp) -> dict:
    try:
        obj = json.loads(resp.body.decode("utf-8", "replace"))
    except ValueError:
        return {}
    return obj if isinstance(obj, dict) else {}


def _reason(obj: dict, status: int) -> str:
    err = obj.get("error")
    return err if isinstance(err, str) and len(err) <= 40 else "http_%d" % status


def fetch_client_values(*, send) -> ClientValues:
    page = send("GET", TV_PAGE, headers={"User-Agent": TV_PAGE_USER_AGENT})
    if page.status != 200:
        raise SignInError("tv_page_http_%d" % page.status)
    url = find_base_script_url(page.body.decode("utf-8", "replace"))
    if url is None:
        raise SignInError("base_script_not_found")
    script = send("GET", url, headers={"User-Agent": TV_PAGE_USER_AGENT})
    if script.status != 200:
        raise SignInError("base_script_http_%d" % script.status)
    values = extract_client_values(script.body.decode("utf-8", "replace"))
    if values is None:
        raise SignInError("client_values_not_found")
    return values


def request_device_code(client: ClientValues, device_id: str, *, send, now=time.time) -> DeviceCode:
    body = json.dumps({"client_id": client.client_id, "scope": SCOPE, "device_id": device_id,
                       "device_model": DEVICE_MODEL}).encode()
    resp = send("POST", DEVICE_CODE_URL, headers=_JSON, body=body)
    obj = _json(resp)
    if resp.status != 200 or "device_code" not in obj:
        raise SignInError(_reason(obj, resp.status))
    try:
        return DeviceCode(str(obj["device_code"]), str(obj["user_code"]), str(obj["verification_url"]),
                          int(obj["expires_in"]), int(obj.get("interval", MIN_WAIT)), now())
    except (KeyError, ValueError, TypeError):
        raise SignInError("bad_device_code_reply")


def _tokens_from(obj: dict, fallback_refresh: Optional[str], fallback_scope: str, now) -> Tokens:
    access = obj.get("access_token")
    if not isinstance(access, str) or not access:
        raise SignInError("no_access_token")
    refresh_token = obj.get("refresh_token") or fallback_refresh
    if not isinstance(refresh_token, str) or not refresh_token:
        raise SignInError("no_refresh_token")
    try:
        lifetime = float(obj.get("expires_in", 0))
    except (TypeError, ValueError):
        raise SignInError("bad_expires_in")
    return Tokens(access, refresh_token, now() + lifetime, str(obj.get("scope") or fallback_scope))


def poll(client: ClientValues, code: DeviceCode, *, send, sleep=time.sleep, now=time.time) -> Tokens:
    """Poll the token endpoint. Waits max(5, interval) seconds between polls, plus 5 for each slow_down so far."""
    body = json.dumps({"client_id": client.client_id, "client_secret": client.client_secret,
                       "code": code.device_code, "grant_type": DEVICE_GRANT}).encode()
    deadline = code.started_at + code.expires_in
    slow_downs = 0
    while True:
        if now() >= deadline:
            raise SignInError("expired_token")
        resp = send("POST", TOKEN_URL, headers=_JSON, body=body)
        obj = _json(resp)
        error = obj.get("error")
        if error is None and "access_token" in obj:
            return _tokens_from(obj, None, SCOPE, now)
        if error == "slow_down":
            slow_downs += 1
        elif error != "authorization_pending":
            raise SignInError(_reason(obj, resp.status))
        sleep(max(MIN_WAIT, code.interval) + SLOW_DOWN_EXTRA * slow_downs)


def refresh(client: ClientValues, tokens: Tokens, *, send, now=time.time) -> Tokens:
    body = json.dumps({"client_id": client.client_id, "client_secret": client.client_secret,
                       "refresh_token": tokens.refresh_token, "grant_type": "refresh_token"}).encode()
    resp = send("POST", TOKEN_URL, headers=_JSON, body=body)
    obj = _json(resp)
    if resp.status != 200 or "error" in obj:
        raise SignInError(_reason(obj, resp.status))
    return _tokens_from(obj, tokens.refresh_token, tokens.scope, now)


def revoke(tokens: Tokens, *, send) -> bool:
    """Try both revoke endpoints; True when one answered 200."""
    ok = False
    form = {"Content-Type": "application/x-www-form-urlencoded"}
    attempts = ((REVOKE_URLS[0], form, ("token=" + quote(tokens.refresh_token, safe="")).encode()),
                (REVOKE_URLS[1], _JSON, json.dumps({"token": tokens.refresh_token}).encode()))
    for url, headers, body in attempts:
        try:
            if send("POST", url, headers=headers, body=body).status == 200:
                ok = True
                break
        except Exception:
            continue
    return ok


def load_client(state) -> ClientValues:
    data = state.read_json("client.json")
    if not data:
        raise SignInError("no_client_values")
    return ClientValues(data["client_id"], data["client_secret"])


def load_tokens(state) -> Tokens:
    data = state.read_json("tokens.json")
    if not data:
        raise SignInError("not_signed_in")
    return Tokens(data["access_token"], data["refresh_token"], float(data["expires_at"]), data.get("scope", ""))


def save_tokens(state, tokens: Tokens) -> None:
    state.write_json("tokens.json", {"access_token": tokens.access_token, "refresh_token": tokens.refresh_token,
                                     "expires_at": tokens.expires_at, "scope": tokens.scope})


def valid_token(state, *, send, now=time.time) -> str:
    """The access token, refreshed first when under 300 s are left."""
    tokens = load_tokens(state)
    if tokens.expires_at - now() < REFRESH_MARGIN:
        tokens = refresh(load_client(state), tokens, send=send, now=now)
        save_tokens(state, tokens)
        state.log("refresh", status=200)
    return tokens.access_token
