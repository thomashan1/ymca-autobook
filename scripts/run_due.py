"""Scheduled entrypoint: book whichever configured class is opening now.

GitHub `schedule` triggers can't pass which class to a run, so we log in once and
loop over every class. book() bails out cheaply (OPEN_GUARD) for classes whose
next opening is far off, and waits + books the one whose window is about to open.
Emails are sent only for real booking attempts, not the no-op skips.

Away-periods (vacations) live in a private repo (see src/pauses.py). We load them
once and skip booking any class whose own date falls in a range — matching the
class date, not today, because booking opens ~7 days ahead.

One-off swaps ("this Tuesday, skip Cycle and take BODYCOMBAT instead") live in
the same private repo (see src/swaps.py) and are handled here rather than in a
workflow of their own, deliberately: a purpose-built one-off cron fired 46
minutes late, while book.yml's established crons have never been more than 19
minutes late over 100 runs. Riding the existing fires is simply more reliable.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

from playwright.sync_api import sync_playwright

# Allow running as `python scripts/run_due.py` from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import fisikal            # noqa: E402
from src import main as m          # noqa: E402
from src import pauses             # noqa: E402
from src import swaps              # noqa: E402
from src.login import login        # noqa: E402
from src.notify import notify      # noqa: E402

# Booking opens 167h (~6.96 days) ahead, so once a class date is this close its
# window has definitely opened. A replacement still unbooked by then wasn't
# "not due yet" — it was missed, and that's worth an email.
OPEN_BY_DAYS = 6


def _secured(ok: bool, detail: str) -> bool:
    """True only for a real booking — book() also returns ok for cheap no-ops."""
    return ok and not detail.startswith(("Nothing to book", "Full:", "Paused"))


def _release_original(context, csrf, cfg, sw) -> str | None:
    """Cancel the swapped-out class, now that its replacement is secured.

    The original may be on the roster for either of two reasons: the swap was
    written after it had already been booked, or an earlier run reached its
    window before the replacement's and deliberately booked it rather than leave
    the day empty. Both end the same way — release it once, and only once the
    replacement is genuinely in hand.
    """
    # Deliberately not m.get_class(): that raises SystemExit on an unknown key,
    # and one typo in swaps.yml must not take down the whole booking run.
    orig = next((c for c in cfg.get("classes", []) if c["key"] == sw.skip_key), None)
    if orig is None:
        return f"\nSwap names skip: '{sw.skip_key}', which is not in classes.yml."
    booked = m.booked_on(context, csrf, cfg, orig, sw.date)
    if not booked:
        return None
    resp = fisikal.cancel(context, csrf, booked["id"])
    line = (f"\nReleased '{sw.skip_key}' on {sw.date} "
            f"(occurrence {booked['id']}) -> HTTP {resp.status}")
    print(line.strip())
    return line


def _run_swap(context, csrf, cfg, sw) -> tuple[bool, str | None]:
    """Secure a swap's replacement, then release the class it displaces.

    Returns (secured, detail). `detail` is None when nothing happened worth an
    email — the replacement was already booked, or its window isn't open yet.
    """
    # A swap with no `book:` is just a one-day skip; there is nothing to secure,
    # so it takes effect immediately.
    if not sw.book_name:
        return True, None

    repl = sw.as_class()
    detail = None
    already = m.booked_on(context, csrf, cfg, repl, sw.date)
    if already:
        print(f"Replacement already booked (occurrence {already['id']}).")
        secured = True
    else:
        try:
            ok, detail = m.book(context, csrf, cfg, repl, dry_run=False,
                                book_now=False, on_date=sw.date)
        except Exception as exc:  # a bad swap must not kill the recurring classes
            ok, detail = False, f"Exception booking replacement: {exc!r}"
        print(("OK: " if ok else "FAILED: ") + detail)
        secured = _secured(ok, detail)
        if ok and not secured:
            detail = None  # window not open yet — a no-op, not news

    if secured and sw.skip_key:
        released = _release_original(context, csrf, cfg, sw)
        if released:
            detail = (detail or "") + released
    return secured, detail


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

    # One-off swaps that haven't happened yet. Local time, not the runner's UTC:
    # a swap is retired the moment its class starts, and UTC's midnight lands at
    # 17:00 PT — mid-afternoon, with booking fires still to come.
    now_local = datetime.now(ZoneInfo(cfg.get("timezone", "America/Los_Angeles")))
    swap_list = swaps.upcoming(swaps.load_swaps(), now_local)
    if swap_list:
        print(f"Loaded {len(swap_list)} upcoming swap(s): "
              + "; ".join(s.label for s in swap_list))

    user = os.environ.get("EGYM_USERNAME")
    pw = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")

    booked_any = False
    failed_any = False
    swap_missed = False
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            print("Logged in; csrf acquired.")

            # Swaps run BEFORE the regular classes, so that by the time we decide
            # whether to skip a class we already know if its replacement landed.
            # class key -> dates to skip; only ever populated for a secured swap.
            skip_dates: dict[str, set] = {}
            for sw in swap_list:
                print(f"\n--- swap {sw.label} ---")
                secured, detail = _run_swap(context, csrf, cfg, sw)
                if secured:
                    if sw.skip_key:
                        skip_dates.setdefault(sw.skip_key, set()).add(sw.date)
                    booked_any = booked_any or detail is not None
                elif (sw.date - now_local.date()).days <= OPEN_BY_DAYS:
                    # Window has opened and the replacement still isn't booked.
                    # The original stays booked (we never added it to skip_dates),
                    # so nothing is lost — but this needs to be seen. Synthesise a
                    # detail when the attempt itself was silent, so the alert email
                    # goes out either way: a swap that quietly never runs is the
                    # exact failure this mechanism exists to make visible.
                    swap_missed = True
                    detail = detail or (
                        f"Replacement '{sw.book_name} {sw.book_start}' for {sw.date} "
                        f"is still unbooked and its window has already opened. "
                        f"'{sw.skip_key}' was kept, so the slot is not empty.")
                if detail:
                    notify(secured, f"swap {sw.label}", detail, alert=True)

            for klass in cfg.get("classes", []):
                label = f"{klass['name']} {klass['weekday']} {klass['start']}"
                print(f"\n--- {klass['key']} ---")
                try:
                    ok, detail = m.book(context, csrf, cfg, klass,
                                        dry_run=False, book_now=False,
                                        pause_ranges=pause_ranges,
                                        skip_dates=skip_dates.get(klass["key"]))
                except Exception as exc:  # one class failing must not kill the rest
                    ok, detail = False, f"{label}\nException: {exc!r}"
                print(("OK: " if ok else "FAILED: ") + detail)
                # Cheap skips aren't real attempts — no email. "Full:" (without
                # "(new)") is a class we've already reported as full: re-sending
                # it every cron fire is the noise that buries real failures.
                # "Already booked" is a redundant trigger finding the class taken
                # by one of its own siblings — the winner already reported it, so
                # a second mail would just be an echo.
                if (detail.startswith("Nothing to book") or detail.startswith("Paused")
                        or detail.startswith("Full:") or detail.startswith("Swapped out:")
                        or detail.startswith("Already booked")):
                    continue
                # First time we see it full: report once, loudly (red run -> push
                # -> email), but don't treat it as a booking failure to retry.
                if detail.startswith("FULL (new)"):
                    notify(False, label, detail, alert=True)
                    failed_any = True
                    continue
                notify(ok, label, detail, alert=True)
                booked_any = booked_any or ok
                failed_any = failed_any or not ok
        finally:
            context.close()
            browser.close()

    # A missed swap always fails the run, even alongside successful bookings: a
    # recurring class that doesn't book shows up in the weekly summary, but a
    # replacement that silently never books looks exactly like a normal week.
    if swap_missed:
        return 1
    return 1 if failed_any and not booked_any else 0


if __name__ == "__main__":
    sys.exit(run())
