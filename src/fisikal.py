"""Fisikal schedule/booking API client.

All calls go through the logged-in BrowserContext's request context so the
session cookies set during egym login are sent automatically. Every call echoes
the page's CSRF token as X-CSRF-Token (required by the Rails backend).

Endpoints (from the HAR):
    GET    /api/web/schedule/occurrences            -> list classes (json filter)
    POST   /api/web/schedule/occurrences/{id}/join  -> book  (body json={"lock_version":N})
    DELETE /api/web/schedule/occurrences/{id}/cancel-> cancel (body json={})
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from playwright.sync_api import BrowserContext

BASE = "https://ymca-silicon-valley.fisikal.com/api/web/schedule/occurrences"

# Statuses the web UI requests when listing the schedule.
_LIST_STATUSES = ["Rescheduled", "Scheduled", "Reminded", "Completed",
                  "Requested", "Counted", "Verified"]

_WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


def _headers(csrf: str) -> dict:
    return {
        "x-csrf-token": csrf,
        "x-requested-with": "XMLHttpRequest",
        "accept": "*/*",
        "referer": "https://ymca-silicon-valley.fisikal.com/",
    }


def list_occurrences(context: BrowserContext, csrf: str,
                     since: datetime, till: datetime,
                     location_ids: list[int] | None = None) -> list[dict]:
    """Return the list of occurrence dicts in [since, till] (UTC datetimes)."""
    flt = {"filter": [
        {"by": "status", "with": _LIST_STATUSES},
        {"by": "since", "with": since.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
        {"by": "till", "with": till.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
    ]}
    if location_ids:
        flt["filter"].append({"by": "location_id", "with": location_ids})

    resp = context.request.get(
        BASE,
        params={"json": json.dumps(flt), "all_service_categories": "true"},
        headers=_headers(csrf),
    )
    if not resp.ok:
        raise RuntimeError(f"list_occurrences failed {resp.status}: {resp.text()[:300]}")
    return resp.json().get("data", [])


def find_matches(occs: list[dict], name: str, weekday: str, start_hhmm: str,
                 tz: str, sub_location: str | None = None,
                 trainer: str | None = None) -> list[dict]:
    """All occurrences matching a recurring class, sorted by occurs_at ascending.

    Matches on service_title (case-insensitive), local weekday, and local start
    time. Optional sub_location / trainer substrings disambiguate duplicates.
    """
    zone = ZoneInfo(tz)
    target_dow = _WEEKDAYS[weekday.lower()[:3]]
    want_h, want_m = (int(x) for x in start_hhmm.split(":"))
    name_l = name.strip().lower()

    out = []
    for o in occs:
        if (o.get("service_title") or "").strip().lower() != name_l:
            continue
        occurs = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00")).astimezone(zone)
        if occurs.weekday() != target_dow or occurs.hour != want_h or occurs.minute != want_m:
            continue
        if sub_location and sub_location.lower() not in (o.get("sub_location_name") or "").lower():
            continue
        if trainer and trainer.lower() not in (o.get("trainer_name") or "").lower():
            continue
        out.append(o)
    out.sort(key=lambda o: o["occurs_at"])
    return out


def join(context: BrowserContext, csrf: str, occurrence_id: int, lock_version: int):
    """POST a booking. Returns the Playwright APIResponse."""
    return context.request.post(
        f"{BASE}/{occurrence_id}/join",
        form={"json": json.dumps({"lock_version": lock_version})},
        headers=_headers(csrf),
    )


def cancel(context: BrowserContext, csrf: str, occurrence_id: int):
    """Cancel a booking (DELETE .../cancel with body json={}). Returns APIResponse."""
    return context.request.delete(
        f"{BASE}/{occurrence_id}/cancel",
        form={"json": json.dumps({})},
        headers=_headers(csrf),
    )


def parse_join_result(resp) -> tuple[bool, str, list[dict]]:
    """Interpret a /join response -> (success, message, errors).

    Success = HTTP 2xx AND occurrence_client.errors is empty.
    """
    try:
        body = resp.json()
    except Exception:
        return resp.ok, f"HTTP {resp.status}", []
    oc = body.get("occurrence_client", {}) if isinstance(body, dict) else {}
    errors = oc.get("errors") or []
    if resp.ok and not errors:
        return True, f"booked (occurrence_client id={oc.get('id')})", []
    types = ", ".join(e.get("type", "?") for e in errors) or f"HTTP {resp.status}"
    return False, types, errors


# Error types that mean "retry" (transient / we're a hair early) vs "stop".
# Confirmed live: a booking attempt before the window opens returns
# "advance_time_restriction" — retry until it clears.
RETRYABLE_ERROR_TYPES = {
    "advance_time_restriction",                       # booking not open yet
    "lock_version_conflict", "stale_object", "optimistic_lock",
}
# Lock-conflict types need a fresh lock_version before retrying.
LOCK_CONFLICT_TYPES = {"lock_version_conflict", "stale_object", "optimistic_lock"}
TERMINAL_ERROR_TYPES = {
    "spare_schedule_violation",  # conflicts with another booking you hold
    "already_joined", "full", "no_spaces", "group_is_full",
}
