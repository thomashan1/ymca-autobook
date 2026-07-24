"""Persist a snapshot of *actually booked* classes into bookings.json in the
private repo.

Runs periodically (see .github/workflows/bookings-snapshot.yml). Logs into
Fisikal, lists occurrences for the next 14 days at both branches, keeps the ones
the member has actually joined (is_joined=True), and overwrites bookings.json in
thomashan1/ymca-private with a dated list plus an `updated_at` timestamp.

This is the real "what I booked" source the iOS app reads — classes.yml only
knows the recurring would-book schedule, and the schedule snapshot's join state
is unreliable. Same write pattern as scripts/snapshot_schedule.py: the JSON lives
in the private repo (which accepts automated writes); this repo's main is
PR-protected.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import fisikal                    # noqa: E402
from src import private_store              # noqa: E402
from src.login import login                # noqa: E402
from src.main import load_config           # noqa: E402

SNAPSHOT_PATH = os.environ.get("BOOKINGS_SNAPSHOT_PATH", "bookings.json")
BOTH_LOCATIONS = [1392, 1388]  # Southwest + Northwest
WINDOW_DAYS = 14


def _booking_rows(occs: list[dict], tz: ZoneInfo) -> list[dict]:
    """Dated rows for occurrences the member has joined, sorted by time."""
    rows: list[dict] = []
    for o in occs:
        if not o.get("is_joined"):
            continue
        start = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00")).astimezone(tz)
        minutes = (int(o.get("duration_in_hours") or 0) * 60
                   + int(o.get("duration_in_minutes") or 0)) or 60
        end = start + timedelta(minutes=minutes)
        rows.append({
            "date":        start.strftime("%Y-%m-%d"),
            "start":       start.strftime("%H:%M"),
            "end":         end.strftime("%H:%M"),
            "name":        (o.get("service_title") or "").strip(),
            "location_id": o.get("location_id"),
            "room":        (o.get("sub_location_name") or "").strip() or None,
            "instructor":  (o.get("trainer_name") or "").strip() or None,
        })
    rows.sort(key=lambda r: (r["date"], r["start"], r["name"]))
    return rows


def run() -> int:
    cfg = load_config()
    tz = ZoneInfo(cfg.get("timezone", "America/Los_Angeles"))

    user = os.environ.get("EGYM_USERNAME")
    pw = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")
    token = os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        raise SystemExit("PRIVATE_REPO_TOKEN required to write the snapshot.")

    # Start at the beginning of the current week so classes already taken this
    # week are captured (not just future ones), through two weeks ahead.
    now_local = datetime.now(tz)
    this_mon = now_local.date() - timedelta(days=now_local.weekday())
    win_start = datetime(this_mon.year, this_mon.month, this_mon.day, tzinfo=tz)
    win_end = win_start + timedelta(days=WINDOW_DAYS + 7)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            occs = fisikal.list_occurrences(
                context, csrf, win_start, win_end, location_ids=BOTH_LOCATIONS,
            )
        finally:
            context.close()
            browser.close()

    bookings = _booking_rows(occs, tz)

    snapshot = {
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timezone": cfg.get("timezone", "America/Los_Angeles"),
        "window": {"days": WINDOW_DAYS, "from": win_start.strftime("%Y-%m-%d")},
        "bookings": bookings,
    }
    new_text = json.dumps(snapshot, indent=2) + "\n"

    old_text, sha = private_store.get_file(token, SNAPSHOT_PATH)
    old_bookings = json.loads(old_text).get("bookings") if old_text else None
    if old_bookings == bookings:
        print(f"Bookings unchanged ({len(bookings)} booked).")
        return 0

    private_store.put_file(
        token, SNAPSHOT_PATH, new_text, sha,
        f"bookings snapshot: {snapshot['updated_at']} — {len(bookings)} booked",
    )
    print(f"Bookings written: {len(bookings)} booked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
