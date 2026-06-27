"""Persist booked classes into a dedup ledger in the private repo.

Runs every 12h. Logs into Fisikal, lists currently-joined occurrences, and
merges them into bookings.json (in thomashan1/ymca-private), keyed by
occurrence id:

  * new bookings get first_seen
  * already-tracked bookings get last_seen refreshed (and fields re-synced)
  * an upcoming booking that vanishes from Fisikal is flagged
    status="cancelled" (a dropped / gym-cancelled / waitlisted booking)

Git history on the private repo is the audit trail — each run is one commit.
Fail-LOUD: unlike pauses (which fail open so booking never stops), the ledger
raises on a missing token so a silent permissions problem is visible.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import fisikal              # noqa: E402
from src import private_store        # noqa: E402
from src.login import login          # noqa: E402
from src.main import load_config     # noqa: E402

_BOTH_LOCATIONS = [1392, 1388]  # Southwest + Northwest
LEDGER_PATH = os.environ.get("BOOKINGS_PATH", "bookings.json")
HORIZON_DAYS = 30  # how far ahead to query (booking opens ~7d out, so ample)


def run() -> int:
    cfg = load_config()
    tz = ZoneInfo(cfg.get("timezone", "America/Los_Angeles"))

    user = os.environ.get("EGYM_USERNAME")
    pw = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")
    token = os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        raise SystemExit("PRIVATE_REPO_TOKEN required to read/write the ledger.")

    now = datetime.now(timezone.utc)
    horizon_end = now + timedelta(days=HORIZON_DAYS)
    nowiso = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            print("Logged in; csrf acquired.")
            occs = fisikal.list_occurrences(
                context, csrf, now - timedelta(hours=1), horizon_end,
                location_ids=_BOTH_LOCATIONS,
            )
        finally:
            context.close()
            browser.close()

    joined = [o for o in occs if o.get("is_joined")]

    text, sha = private_store.get_file(token, LEDGER_PATH)
    ledger = json.loads(text) if text else {}
    book = ledger.setdefault("bookings", {})

    current_ids = set()
    added = 0
    for o in joined:
        oid = str(o["id"])
        current_ids.add(oid)
        occ_local = datetime.fromisoformat(
            o["occurs_at"].replace("Z", "+00:00")).astimezone(tz)
        entry = book.get(oid)
        if entry is None:
            entry = {"first_seen": nowiso}
            added += 1
        entry.update({
            "occurrence_id": o["id"],
            "name": (o.get("service_title") or "").strip(),
            "occurs_at": o["occurs_at"],
            "local": occ_local.strftime("%a %Y-%m-%d %H:%M"),
            "location": (o.get("location_name") or "").strip(),
            "instructor": (o.get("trainer_name") or "").strip(),
            "status": "booked",
            "last_seen": nowiso,
        })
        book[oid] = entry

    # Drop detection: a still-upcoming booking we previously tracked that is no
    # longer joined in Fisikal — but only within the queried window, so we never
    # mis-flag something that's simply beyond the horizon.
    dropped = []
    for oid, entry in book.items():
        if entry.get("status") != "booked" or oid in current_ids:
            continue
        try:
            occ = datetime.fromisoformat(entry["occurs_at"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if now < occ <= horizon_end:
            entry["status"] = "cancelled"
            entry["cancelled_detected"] = nowiso
            dropped.append(entry)

    ledger["updated_at"] = nowiso
    new_text = json.dumps(ledger, indent=2, sort_keys=True) + "\n"

    if new_text == (text or ""):
        print(f"Ledger unchanged ({len(current_ids)} booked, {len(book)} tracked).")
    else:
        private_store.put_file(
            token, LEDGER_PATH, new_text, sha,
            f"ledger: {nowiso} — {len(current_ids)} booked, +{added} new, "
            f"{len(dropped)} dropped",
        )
        print(f"Ledger written: {len(current_ids)} booked, +{added} new, "
              f"{len(book)} tracked total.")

    if dropped:
        print(f"⚠ {len(dropped)} upcoming booking(s) dropped since last run:")
        for e in dropped:
            print(f"  - {e['name']} {e.get('local', e['occurs_at'])}")
    return 0


if __name__ == "__main__":
    sys.exit(run())
