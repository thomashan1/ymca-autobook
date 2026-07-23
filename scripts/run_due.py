"""Scheduled entrypoint: book whichever configured class is opening now.

GitHub `schedule` triggers can't pass which class to a run, so we log in once and
loop over every class. book() bails out cheaply (OPEN_GUARD) for classes whose
next opening is far off, and waits + books the one whose window is about to open.
Emails are sent only for real booking attempts, not the no-op skips.

Away-periods (vacations) live in a private repo (see src/pauses.py). We load them
once and skip booking any class whose own date falls in a range — matching the
class date, not today, because booking opens ~7 days ahead.
"""

from __future__ import annotations

import os
import sys

from playwright.sync_api import sync_playwright

# Allow running as `python scripts/run_due.py` from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import main as m          # noqa: E402
from src import pauses             # noqa: E402
from src.login import login        # noqa: E402
from src.notify import notify      # noqa: E402


def run() -> int:
    cfg = m.load_config()

    # Away-dates kept in a private repo; skip booking classes that land in one.
    pause_ranges = pauses.load_ranges()
    if pause_ranges:
        print(f"Loaded {len(pause_ranges)} pause range(s): "
              + ", ".join(
                  f"{r.start}..{r.end}"
                  + (f" except {sorted(r.except_keys)}" if r.except_keys else "")
                  for r in pause_ranges))

    user = os.environ.get("EGYM_USERNAME")
    pw = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")

    booked_any = False
    failed_any = False
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            print("Logged in; csrf acquired.")
            for klass in cfg.get("classes", []):
                label = f"{klass['name']} {klass['weekday']} {klass['start']}"
                print(f"\n--- {klass['key']} ---")
                try:
                    ok, detail = m.book(context, csrf, cfg, klass,
                                        dry_run=False, book_now=False,
                                        pause_ranges=pause_ranges)
                except Exception as exc:  # one class failing must not kill the rest
                    ok, detail = False, f"{label}\nException: {exc!r}"
                print(("OK: " if ok else "FAILED: ") + detail)
                # Cheap skips (nothing due, or paused) aren't real attempts — no email.
                if detail.startswith("Nothing to book") or detail.startswith("Paused"):
                    continue
                notify(ok, label, detail, alert=True)
                booked_any = booked_any or ok
                failed_any = failed_any or not ok
        finally:
            context.close()
            browser.close()

    return 1 if failed_any and not booked_any else 0


if __name__ == "__main__":
    sys.exit(run())
