"""Record how fast every class fills, and publish per-class fill stats.

Fisikal stamps each occurrence with `full_group_at` when it fills, so "how long
did it take to fill" is (full_group_at - booking-open instant) — no sampling at
the opening second needed. Run daily (schedule-snapshot.yml); the first run
backfills the ~4 past weeks the API still serves.

Writes to the private repo:
  fill_history.json  every group-class occurrence whose window has opened, both
                     branches, kept for 26 weeks
  fill_stats.json    per weekly slot (class + weekday + start + branch), over the
                     last 12 weeks: how often it filled, median/fastest fill,
                     how often within a minute, typical waitlist — read by the
                     iOS app's Stats screen

Set FILL_HISTORY_DRY_RUN=1 to print the stats and write nothing.
"""

from __future__ import annotations

import json
import os
import statistics
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import fisikal, private_store       # noqa: E402
from src.http_context import HttpContext     # noqa: E402
from src.login import login                   # noqa: E402
from src.main import load_config              # noqa: E402

HISTORY_PATH = "fill_history.json"
STATS_PATH = "fill_stats.json"
BRANCHES = {1392: "Southwest", 1388: "Northwest"}
KEEP_WEEKS = 26
STATS_WEEKS = 12
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def _utc(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc)


def _iso(d: datetime) -> str:
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def record(occ: dict, branch: int, tz: ZoneInfo) -> dict | None:
    """A history row for a group class whose booking window has opened, else None."""
    hours = occ.get("restrict_to_book_in_advance_time_in_hours") or 0
    minutes = occ.get("restrict_to_book_in_advance_time_in_minutes") or 0
    if (occ.get("service_group_size") or 0) < 5 or not (hours or minutes):
        return None  # personal training and the like: no booking window to race
    at = _utc(occ["occurs_at"])
    opened = at - timedelta(hours=hours, minutes=minutes)
    if opened > datetime.now(timezone.utc):
        return None
    local = at.astimezone(tz)
    return {
        "id": occ["id"],
        "name": (occ.get("service_title") or "").strip(),
        "weekday": DAYS[local.weekday()],
        "start": local.strftime("%H:%M"),
        "branch_id": branch,
        "occurs_at": _iso(at),
        "open_at": _iso(opened),
        "capacity": occ.get("service_group_size") or 0,
        "full_group_at": _iso(_utc(occ["full_group_at"])) if occ.get("full_group_at") else None,
        "waitlist": occ.get("total_on_waiting_list") or 0,
    }


def fill_seconds(r: dict) -> float | None:
    if not r.get("full_group_at"):
        return None
    s = (_utc(r["full_group_at"]) - _utc(r["open_at"])).total_seconds()
    return s if s >= 0 else None


def slot_stats(history: list[dict], now: datetime) -> list[dict]:
    cutoff = now - timedelta(weeks=STATS_WEEKS)
    slots: dict[str, list[dict]] = {}
    for r in history:
        if _utc(r["occurs_at"]) >= cutoff:
            key = f"{r['name'].lower()}|{r['weekday']}|{r['start']}|{r['branch_id']}"
            slots.setdefault(key, []).append(r)
    out = []
    for key, rows in slots.items():
        fills = [f for f in (fill_seconds(r) for r in rows) if f is not None]
        r0 = rows[0]
        out.append({
            "key": key,
            "name": r0["name"],
            "weekday": r0["weekday"],
            "start": r0["start"],
            "branch_id": r0["branch_id"],
            "branch": BRANCHES.get(r0["branch_id"], "?"),
            "capacity": max(r["capacity"] for r in rows),
            "weeks": len(rows),
            "filled": len(fills),
            "median_fill_s": round(statistics.median(fills), 1) if fills else None,
            "fastest_fill_s": round(min(fills), 1) if fills else None,
            "within_60s": sum(1 for f in fills if f <= 60),
            "median_waitlist": round(statistics.median(r["waitlist"] for r in rows)),
        })
    out.sort(key=lambda s: (DAYS.index(s["weekday"]), s["start"], s["name"]))
    return out


def run() -> int:
    cfg = load_config()
    tz = ZoneInfo(cfg.get("timezone", "America/Los_Angeles"))
    dry = os.environ.get("FILL_HISTORY_DRY_RUN") == "1"
    token = os.environ.get("PRIVATE_REPO_TOKEN")
    if not token and not dry:
        raise SystemExit("PRIVATE_REPO_TOKEN required (or set FILL_HISTORY_DRY_RUN=1).")
    user, pw = os.environ.get("EGYM_USERNAME"), os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")

    old_text, sha = (None, None) if dry else private_store.get_file(token, HISTORY_PATH)
    old = json.loads(old_text)["occurrences"] if old_text else []
    by_id = {r["id"]: r for r in old}

    now = datetime.now(timezone.utc)
    # First run: backfill what the API still serves. After that, the last two
    # days catch any class that filled late (and the next 8 cover open windows).
    since = now - (timedelta(days=28) if not old else timedelta(days=2))
    with HttpContext() as context:
        _, csrf = login(context, user, pw)
        print("Logged in; csrf acquired.")
        for branch in BRANCHES:
            for occ in fisikal.list_occurrences(context, csrf, since, now + timedelta(days=8),
                                                location_ids=[branch]):
                row = record(occ, branch, tz)
                if not row:
                    continue
                prev = by_id.get(row["id"])
                if prev:  # keep the highest waitlist seen and the first fill time
                    row["waitlist"] = max(row["waitlist"], prev.get("waitlist", 0))
                    row["full_group_at"] = row["full_group_at"] or prev.get("full_group_at")
                by_id[row["id"]] = row

    keep_after = now - timedelta(weeks=KEEP_WEEKS)
    history = sorted((r for r in by_id.values() if _utc(r["occurs_at"]) >= keep_after),
                     key=lambda r: (r["occurs_at"], r["id"]))
    stats = slot_stats(history, now)
    print(f"{len(history)} occurrences in history; {len(stats)} weekly slots; "
          f"{sum(1 for s in stats if s['filled'])} slots have filled at least once.")

    if dry:
        for s in stats:
            if s["filled"] and s["median_fill_s"] is not None and s["median_fill_s"] < 3600:
                print(f"  {s['name']:<24} {s['weekday']} {s['start']} {s['branch']:<9} "
                      f"filled {s['filled']}/{s['weeks']} wk, median {s['median_fill_s']:.0f}s")
        return 0

    if history == old:
        print("History unchanged; nothing to write.")
        return 0
    stamp = _iso(now)
    private_store.put_file(token, HISTORY_PATH,
                           json.dumps({"updated_at": stamp, "occurrences": history}, indent=1) + "\n",
                           sha, f"fill history: {stamp} — {len(history)} occurrences")
    _, stats_sha = private_store.get_file(token, STATS_PATH)
    # Full regeneration from history, so a concurrent write can simply be retried.
    private_store.put_file(token, STATS_PATH,
                           json.dumps({"updated_at": stamp, "weeks": STATS_WEEKS, "slots": stats}, indent=1) + "\n",
                           stats_sha, f"fill stats: {stamp} — {len(stats)} slots", retry_conflict=True)
    print("Wrote fill_history.json and fill_stats.json.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
