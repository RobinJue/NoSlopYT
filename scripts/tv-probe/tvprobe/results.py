"""The results summary: each design pass rule, the tries behind it and the verdict."""
from __future__ import annotations

from typing import List

WINDOW_SECONDS = 300
HOME_TRIES_NEEDED = 2
REPORTS_NEEDED = 3


HOME_DEFAULTS = (("browse_id", "FEwhat_to_watch"), ("host", "www"), ("context", "full"), ("policy", "none"))


def _variant_flags(e: dict) -> List[str]:
    """The non-default request options of a home try; events without the fields count as default."""
    return ["%s %s" % ({"policy": "visitor"}.get(k, k.replace("_", " ")), e[k]) for k, d in HOME_DEFAULTS if e.get(k) not in (None, d)]


def _home(log: List[dict]) -> List[str]:
    tries = [e for e in log if e.get("event") == "home_try"]
    if not tries:
        return ["Home: not run"]
    default = [e for e in tries if not _variant_flags(e)]
    variants = [e for e in tries if _variant_flags(e)]
    extra = ["- informational variant (%s): %s" % (", ".join(_variant_flags(e)),
                                                  "pass" if e.get("try_passes") is True else "fail")
             for e in variants]
    if not default:
        return ["Home: not run (no default tries)"] + extra
    # a try counts only when page 1 was signed in with 8 visible videos AND the continuation worked
    passed = sum(1 for e in default if e.get("try_passes") is True and e.get("continuation_ok") is True)
    ok = passed >= HOME_TRIES_NEEDED
    lines = ["Home: %s (%d of %d tries)" % ("pass" if ok else "fail", passed, len(default))]
    best = max((e.get("visible_unique") or 0) for e in default)
    lines.append("- most visible videos in one try: %d (needs 8 within 3 pages)" % best)
    return lines + extra


def _credited(report: dict, histories: List[dict]) -> bool:
    for h in histories:
        if h.get("found") is not True:
            continue
        same = report.get("video") is None or h.get("video") is None or report["video"] == h["video"]
        delta = (h.get("ts") or 0) - (report.get("ts") or 0)
        if same and 0 <= delta <= WINDOW_SECONDS:
            return True
    return False


def _reporting(log: List[dict]) -> List[str]:
    reports = sorted((e for e in log if e.get("event") in ("report_pings", "report")), key=lambda e: e.get("ts", 0))
    histories = [e for e in log if e.get("event") == "history"]
    if not reports:
        return ["Reporting: not run"]

    def sent(e: dict) -> bool:
        return all(200 <= (e.get(k) if isinstance(e.get(k), int) else 200) < 300 for k in ("playback", "watchtime"))

    verdict, extra, seen = [], [], set()
    for r in reports:
        # a failed ping attempt neither joins the verdict nor blocks a retry of the same video
        if sent(r) and len(verdict) < REPORTS_NEEDED and r.get("video") not in seen:
            seen.add(r.get("video"))
            verdict.append(r)
        else:
            extra.append(r)
    found = sum(1 for r in verdict if sent(r) and _credited(r, histories))
    ok = len(verdict) >= REPORTS_NEEDED and found == len(verdict)
    lines = ["Reporting: %s (%d of %d videos found in history within 5 minutes)" % (
        "pass" if ok else "fail", found, len(verdict))]
    for r in extra:
        variant = []
        if r.get("auth") == "off":
            variant.append("auth on pings off")
        if r.get("sts") == "off":
            variant.append("sts off")
        lines.append("- informational run (%s): %s" % (
            ", ".join(variant) or "default", "found" if sent(r) and _credited(r, histories) else "not found"))
    return lines


def _cards(log: List[dict]) -> List[str]:
    sent = [e for e in log if e.get("event") == "feedback"]
    if not sent:
        return ["Card actions: not run"]
    menu_ok = any(e.get("event") == "menu" and e.get("status") == 200 and e.get("not_interested") is True
                  and e.get("dont_recommend") is True for e in log)
    fed_ok = any(e.get("status") == 200 and e.get("json") is True and not e.get("error")
                 and e.get("is_processed") is not False for e in sent)
    lines = ["Card actions: %s (%d feedback call%s)" % ("pass" if menu_ok and fed_ok else "fail", len(sent),
                                                        "" if len(sent) == 1 else "s")]
    if not menu_ok:
        lines.append("- no menu showed both Not interested and Don't recommend")
    if not fed_ok:
        lines.append("- no feedback call was accepted (200, JSON, no error, not unprocessed)")
    return lines


def _next(log: List[dict]) -> List[str]:
    runs = [e for e in log if e.get("event") == "next"]
    if not runs:
        return ["Up next: not run"]
    last = runs[-1]
    return ["Up next (informational): signed status %s, logged in %s, %s%% of the signed list also in the "
            "anonymous list" % (last.get("signed_status"), last.get("signed_logged_in"),
                                round(100 * (last.get("overlap") or 0)))]


def summarize(log_lines: List[dict]) -> str:
    """A Markdown block with each pass rule, the tries behind it and the verdict."""
    parts = ["## Phase 0 pass rules", ""]
    for block in (_home(log_lines), _reporting(log_lines), _cards(log_lines), _next(log_lines)):
        parts.append("- " + block[0])
        parts.extend("  " + line for line in block[1:])
    return "\n".join(parts) + "\n"
