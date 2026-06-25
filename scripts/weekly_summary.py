"""Weekly summary: print upcoming booked classes to GitHub Actions job summary.

Runs Monday morning via .github/workflows/weekly-summary.yml. Logs in, finds
all occurrences in the next 7 days where is_joined=True, and writes a markdown
table to $GITHUB_STEP_SUMMARY so it's visible directly in the GitHub Actions run.
GitHub sends a workflow-completion notification (via the app or email) that links
to it.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import fisikal                 # noqa: E402
from src.login import login            # noqa: E402
from src.main import load_config       # noqa: E402

_BOTH_LOCATIONS = [1392, 1388]  # Southwest + Northwest


def run() -> int:
    cfg = load_config()
    tz = ZoneInfo(cfg.get("timezone", "America/Los_Angeles"))

    user = os.environ.get("EGYM_USERNAME")
    pw = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")

    now = datetime.now(timezone.utc)
    week_end = now + timedelta(days=7)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            occs = fisikal.list_occurrences(
                context, csrf, now, week_end,
                location_ids=_BOTH_LOCATIONS,
            )
        finally:
            context.close()
            browser.close()

    booked = [o for o in occs if o.get("is_joined")]
    booked.sort(key=lambda o: o["occurs_at"])

    today = datetime.now(tz).date()
    week_end_local = (today + timedelta(days=7)).strftime("%b %d")

    lines = []
    lines.append(f"## YMCA classes: {today.strftime('%b %d')} – {week_end_local}\n")

    if not booked:
        lines.append("_No classes booked this week._\n")
    else:
        lines.append("| Day | Date | Time | Class | Location |")
        lines.append("|-----|------|------|-------|----------|")
        for o in booked:
            dt = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00")).astimezone(tz)
            day  = dt.strftime("%a")
            date = dt.strftime("%b %d")
            time = dt.strftime("%I:%M %p").lstrip("0")
            name = (o.get("service_title") or "").strip()
            loc  = (o.get("location_name") or "").replace("Silicon Valley YMCA - ", "")
            lines.append(f"| {day} | {date} | {time} | {name} | {loc} |")
        lines.append(f"\n**{len(booked)} class{'es' if len(booked) != 1 else ''} booked.**\n")

    summary = "\n".join(lines)

    # Print to log (always visible)
    print(summary)

    # Write to GitHub step summary (renders as markdown in the Actions UI)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(summary + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(run())
