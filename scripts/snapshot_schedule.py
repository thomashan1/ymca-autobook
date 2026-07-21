"""Persist a live schedule snapshot into schedule_snapshot.json in the private repo.

Runs periodically (see .github/workflows/schedule-snapshot.yml). Logs into
Fisikal, browses Mon-Fri classes 8:30-15:00 at both branches (same filter as
`python -m src.main --browse`: no fee/dance/swim/senior/pickleball), and
overwrites schedule_snapshot.json in thomashan1/ymca-private with the result
plus an `updated_at` timestamp — so the schedule can be read from the repo any
time without a live login.

Lives in the private repo (not this one) because this repo's `main` is
PR-protected; the private repo already accepts automated writes (same pattern
as the bookings ledger).
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import private_store              # noqa: E402
from src.login import login                # noqa: E402
from src.main import collect_schedule, load_config  # noqa: E402

SNAPSHOT_PATH = os.environ.get("SCHEDULE_SNAPSHOT_PATH", "schedule_snapshot.json")


def run() -> int:
    cfg = load_config()

    user = os.environ.get("EGYM_USERNAME")
    pw = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")
    token = os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        raise SystemExit("PRIVATE_REPO_TOKEN required to write the snapshot.")

    nowiso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            print("Logged in; csrf acquired.")
            rows = collect_schedule(context, csrf, cfg)
        finally:
            context.close()
            browser.close()

    # Drop the sort-only helper fields before writing.
    classes = [{k: v for k, v in r.items() if k not in ("start_min", "dow")} for r in rows]

    snapshot = {
        "updated_at": nowiso,
        "timezone": cfg["timezone"],
        "window": {"days": "Mon-Fri", "start": "08:30", "end": "15:00"},
        "classes": classes,
    }
    new_text = json.dumps(snapshot, indent=2) + "\n"

    old_text, sha = private_store.get_file(token, SNAPSHOT_PATH)
    # Compare ignoring updated_at so an unchanged schedule doesn't churn history.
    old_classes = json.loads(old_text).get("classes") if old_text else None
    if old_classes == classes:
        print(f"Snapshot unchanged ({len(classes)} classes).")
        return 0

    private_store.put_file(
        token, SNAPSHOT_PATH, new_text, sha,
        f"schedule snapshot: {nowiso} — {len(classes)} classes",
    )
    print(f"Snapshot written: {len(classes)} classes.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
