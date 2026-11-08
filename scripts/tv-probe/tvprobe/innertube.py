"""InnerTube request pieces for the TV client: profiles, the context body and a POST helper."""
from __future__ import annotations

import json
from typing import NamedTuple, Optional, Tuple

from . import http


class Profile(NamedTuple):
    client_version: str
    user_agent: str


PROFILES = {
    "tv": Profile("7.20260901.15.00", "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"),
    # TV_DOWNGRADED in SmartTube's MediaServiceCore (MIT), commit db543d4d5d639cbf3084e3870b0dac6e4e2524a1:
    # DefaultHeaders.kt USER_AGENT_TV_DOWNGRADED = USER_AGENT_COBALT_1 (old 5-digit timestamp format, non-tcl player).
    "legacy": Profile("5.20260901",
                      "Mozilla/5.0 (DirectFB; Linux x86_64) Cobalt/4.13031-qa (unlike Gecko) Starboard/1"),
}
HOSTS = {"www": "www.youtube.com", "googleapis": "youtubei.googleapis.com"}
REFERER = "https://www.youtube.com/tv"


def context(profile: str, *, variant: str = "full", visitor: Optional[str] = None) -> dict:
    """The request context. "full" follows SmartTube's TV browse body, "minimal" is the smallest guess."""
    p = PROFILES[profile]
    if variant == "minimal":
        client = {"clientName": "TVHTML5", "clientVersion": p.client_version, "hl": "en", "gl": "US"}
    else:
        client = {
            "clientName": "TVHTML5",
            "clientVersion": p.client_version,
            "clientScreen": "WATCH",
            "userAgent": p.user_agent,
            "hl": "en",
            "gl": "US",
            "tvAppInfo": {"appQuality": "TV_APP_QUALITY_FULL_ANIMATION", "zylonLeftNav": True},
        }
    if visitor and variant != "minimal":
        client["visitorData"] = visitor
    return {"client": client}


def post(endpoint: str, body: dict, *, token: Optional[str], profile: str = "tv", host: str = "www.youtube.com",
         visitor: Optional[str] = None, send) -> Tuple[int, Optional[dict]]:
    """POST /youtubei/v1/<endpoint>. Returns (status, parsed JSON object or None for non-JSON or a redirect)."""
    headers = {
        "Content-Type": "application/json",
        "User-Agent": PROFILES[profile].user_agent,
        "Referer": REFERER,
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    if visitor:
        headers["X-Goog-Visitor-Id"] = visitor
    url = "https://%s/youtubei/v1/%s?prettyPrint=false" % (host, endpoint)
    resp = send("POST", url, headers=headers, body=json.dumps(body).encode())
    if 300 <= resp.status < 400:
        return resp.status, None
    try:
        data = json.loads(resp.body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return resp.status, None
    return resp.status, data if isinstance(data, dict) else None
