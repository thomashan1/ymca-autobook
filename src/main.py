"""Orchestrate one booking run.

Usage:
    python -m src.main --class <key>            # book the configured class
    python -m src.main --class <key> --dry-run  # do everything except the join
    python -m src.main --class <key> --headed   # show the browser (debug login)
    python -m src.main --class <key> --book-now  # skip the wait (test in an open window)
    python -m src.main --list [name]            # print upcoming occurrences (debug filters)

Credentials & SMTP come from environment variables (see README): EGYM_USERNAME,
EGYM_PASSWORD, SMTP_*, NOTIFY_EMAIL.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import yaml
from playwright.sync_api import sync_playwright

from . import fisikal
from . import pauses
from .login import login
from .notify import notify
from .schedule import open_instant, wait_until

CONFIG_PATH = os.path.join(os.path.dirname(__file__), os.pardir, "classes.yml")
MAX_RETRY_ATTEMPTS = 3        # max booking attempts (avoids hammering the server)
RETRY_SLEEP_SECONDS = 5.0     # seconds between retries
LIST_WINDOW_DAYS = 16         # how far ahead to look for occurrences
# If the next unbooked instance opens more than this far out, this week is
# already booked (or it isn't this class's run) -> exit instead of waiting.
# Sized to proceed on an in-season cron (fires ~25 min early) but skip an
# off-season DST-shifted cron (fires ~85 min early).
OPEN_GUARD = timedelta(minutes=60)


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def get_class(cfg: dict, key: str) -> dict:
    for c in cfg.get("classes", []):
        if c["key"] == key:
            return c
    raise SystemExit(f"No class with key '{key}' in classes.yml")


def _open_dt(occ: dict) -> datetime:
    return open_instant(
        occ["occurs_at"],
        occ.get("restrict_to_book_in_advance_time_in_hours"),
        occ.get("restrict_to_book_in_advance_time_in_minutes"),
    )


def _fmt(dt: datetime, tz: str) -> str:
    return dt.astimezone(ZoneInfo(tz)).strftime("%a %Y-%m-%d %H:%M %Z")


_EXCLUDE_KEYWORDS = {
    "dance", "salsa", "zumba", "hip hop", "cha cha", "cumbia", "jazzercise", "bollyx",  # dance
    "swim", "aqua", "lap ", "pool",                                                       # water
    "senior fitness", "craft club", "gym ventures",                                       # clubs/seniors
    "pickleball",                                                                          # group games
}
_BROWSE_BOTH_LOCATIONS = [1392, 1388]  # Southwest + Northwest
_DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri"]


BROWSE_START_MIN = 8 * 60 + 30   # 8:30
BROWSE_END_MIN = 15 * 60         # 15:00


def collect_schedule(context, csrf, cfg,
                     start_min: int = BROWSE_START_MIN,
                     end_min: int = BROWSE_END_MIN) -> list[dict]:
    """Fetch Mon-Fri occurrences in [start_min, end_min) (local), both branches,
    no fee/dance/swim/senior/pickleball, deduped. Sorted by day then start time.

    Each row: day (Mon..Fri), start/end ("HH:MM"), start_min (int, for sorting),
    name, location, joined (bool).
    """
    zone = ZoneInfo(cfg["timezone"])
    now = datetime.now(timezone.utc)
    occs = fisikal.list_occurrences(
        context, csrf,
        now - timedelta(hours=1),
        now + timedelta(days=LIST_WINDOW_DAYS),
        location_ids=_BROWSE_BOTH_LOCATIONS,
    )

    seen: set = set()
    rows: list[dict] = []

    for o in occs:
        title = (o.get("service_title") or "").strip()
        title_l = title.lower()
        if title_l.startswith("$"):
            continue
        if any(kw in title_l for kw in _EXCLUDE_KEYWORDS):
            continue

        occurs = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00")).astimezone(zone)
        dow = occurs.weekday()
        if dow >= 5:
            continue
        occ_start_min = occurs.hour * 60 + occurs.minute
        if occ_start_min < start_min or occ_start_min >= end_min:
            continue

        location = (o.get("location_name") or "").replace("Silicon Valley YMCA - ", "")
        key = (title_l, dow, occurs.hour, occurs.minute, location)
        if key in seen:
            continue
        seen.add(key)

        # Whole-hour classes report hours=1, minutes=0, so minutes-alone reads 0.
        duration = (int(o.get("duration_in_hours") or 0) * 60
                    + int(o.get("duration_in_minutes") or 0)) or 60
        occ_end_min = occ_start_min + duration

        rows.append({
            "day": _DAY_NAMES[dow],
            "start": f"{occ_start_min // 60:02d}:{occ_start_min % 60:02d}",
            "end": f"{occ_end_min // 60:02d}:{occ_end_min % 60:02d}",
            "start_min": occ_start_min,
            "dow": dow,
            "name": title,
            "location": location,
            "joined": bool(o.get("is_joined")),
        })

    rows.sort(key=lambda r: (r["dow"], r["start_min"]))
    return rows


def run_browse(context, csrf, cfg) -> None:
    """Print Mon-Fri classes 8:30–15:00 (local), grouped by day, no fee/dance/swim."""
    rows = collect_schedule(context, csrf, cfg)

    by_day: dict[int, list[dict]] = {d: [] for d in range(5)}
    for r in rows:
        by_day[r["dow"]].append(r)

    total = 0
    for dow in range(5):
        day_rows = by_day[dow]
        if not day_rows:
            continue
        print(f"\n── {_DAY_NAMES[dow]} ──────────────────────────────────────────────────────────")
        print(f"  {'TIME':<13}  {'CLASS':<34}  {'WHERE':<26}  JOINED")
        for r in day_rows:
            t = f"{r['start']}–{r['end']}"
            joined = "✓" if r["joined"] else ""
            print(f"  {t:<13}  {r['name']:<34}  {r['location']:<26}  {joined}")
            total += 1
    print(f"\n{total} unique classes (Mon–Fri, 8:30–15:00, no fee/dance/swim).")


def run_list(context, csrf, cfg, name_filter: str | None) -> None:
    tz = cfg["timezone"]
    now = datetime.now(timezone.utc)
    occs = fisikal.list_occurrences(context, csrf, now - timedelta(hours=2),
                                    now + timedelta(days=LIST_WINDOW_DAYS),
                                    location_ids=cfg.get("list_location_ids"))
    print(f"{len(occs)} occurrences in the next ~{LIST_WINDOW_DAYS} days\n")
    rows = sorted(occs, key=lambda o: o["occurs_at"])
    for o in rows:
        title = o.get("service_title", "")
        if name_filter and name_filter.lower() not in title.lower():
            continue
        try:
            opens = _fmt(_open_dt(o), tz)
        except Exception:
            opens = "?"
        occurs = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00"))
        print(f"  id={o['id']:>7} lock={o.get('lock_version'):>3} "
              f"{_fmt(occurs, tz)}  "
              f"opens={opens}  joined={o.get('is_joined')} full={o.get('full_group')}  "
              f"{title} / {o.get('sub_location_name')} / {o.get('trainer_name')}")


def pick_target(context, csrf, cfg, klass) -> dict | None:
    """Find the next not-yet-booked occurrence of the configured class."""
    now = datetime.now(timezone.utc)
    occs = fisikal.list_occurrences(
        context, csrf, now - timedelta(hours=2), now + timedelta(days=LIST_WINDOW_DAYS),
        location_ids=klass.get("location_ids"),
    )
    matches = fisikal.find_matches(
        occs, klass["name"], klass["weekday"], klass["start"], cfg["timezone"],
        sub_location=klass.get("sub_location"), trainer=klass.get("trainer"),
    )
    for o in matches:
        occurs = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00"))
        if occurs > now and not o.get("is_joined"):
            return o
    return None


def refresh_lock_version(context, csrf, klass, target_id, target_occurs_at) -> int | None:
    """Re-list a narrow window to read the target occurrence's current lock_version."""
    occurs = datetime.fromisoformat(target_occurs_at.replace("Z", "+00:00"))
    occs = fisikal.list_occurrences(
        context, csrf, occurs - timedelta(days=1), occurs + timedelta(days=1),
        location_ids=klass.get("location_ids"),
    )
    for o in occs:
        if o["id"] == target_id:
            return o.get("lock_version")
    return None


def find_occurrence(context, csrf, occurrence_id: int, horizon_days: int = 40) -> dict | None:
    """Locate a specific occurrence by id, searching both branches."""
    now = datetime.now(timezone.utc)
    occs = fisikal.list_occurrences(
        context, csrf, now - timedelta(hours=2), now + timedelta(days=horizon_days),
        location_ids=_BROWSE_BOTH_LOCATIONS,
    )
    for o in occs:
        if o["id"] == occurrence_id:
            return o
    return None


def book_by_id(context, csrf, occurrence_id: int) -> tuple[bool, str]:
    """Book a specific occurrence by id, independent of classes.yml.

    For one-off exceptions — e.g. a configured class is full/unavailable this
    week and you want to fall back to a specific alternate occurrence instead.
    Uses the same retry/lock-refresh logic as the scheduled path.
    """
    target = find_occurrence(context, csrf, occurrence_id)
    if not target:
        return False, f"Occurrence id={occurrence_id} not found in the next 40 days."
    title = (target.get("service_title") or "?").strip()
    label = f"{title} at {target['occurs_at']} (id={occurrence_id})"

    lock = target.get("lock_version")
    last = "no attempt"
    for attempt in range(1, MAX_RETRY_ATTEMPTS + 1):
        resp = fisikal.join(context, csrf, occurrence_id, lock)
        ok, msg, errors = fisikal.parse_join_result(resp)
        last = f"attempt {attempt}: {msg}"
        print(f"  {last}")
        if ok:
            return True, f"{label}\n{last}"
        types = {e.get("type") for e in errors}
        if types & fisikal.TERMINAL_ERROR_TYPES:
            return False, f"{label}\n{last} (terminal)"
        if types & fisikal.LOCK_CONFLICT_TYPES:
            fresh = find_occurrence(context, csrf, occurrence_id)
            if fresh is not None:
                lock = fresh.get("lock_version")
        if attempt < MAX_RETRY_ATTEMPTS:
            time.sleep(RETRY_SLEEP_SECONDS)

    return False, f"{label}\nGave up after {MAX_RETRY_ATTEMPTS} attempts. Last: {last}"


def book(context, csrf, cfg, klass, dry_run: bool, book_now: bool,
         pause_ranges: list | None = None) -> tuple[bool, str]:
    tz = cfg["timezone"]
    label = f"{klass['name']} {klass['weekday']} {klass['start']}"

    target = pick_target(context, csrf, cfg, klass)
    if not target:
        return False, f"No upcoming bookable occurrence found for {label}."

    # Skip if the class we'd book falls on an away-date. We match on the
    # occurrence's own (local) date, not "today" — booking opens ~7 days ahead,
    # so the run booking a paused class fires the week before.
    if pause_ranges:
        occ_local = datetime.fromisoformat(
            target["occurs_at"].replace("Z", "+00:00")).astimezone(ZoneInfo(tz)).date()
        for rng in pause_ranges:
            if rng.start <= occ_local <= rng.end:
                # An `except` entry keeps this specific class bookable while away.
                if klass["key"] in rng.except_keys:
                    print(f"Paused {rng.start}..{rng.end}, but '{klass['key']}' is "
                          f"an exception — booking {occ_local}.")
                    break
                return True, (f"Paused {rng.start}..{rng.end}: skipping '{label}' on "
                              f"{occ_local} (away).")

    open_dt = _open_dt(target)
    plan = (f"{label}\n  occurrence id={target['id']} at "
            f"{_fmt(datetime.fromisoformat(target['occurs_at'].replace('Z','+00:00')), tz)}\n"
            f"  opens for booking: {_fmt(open_dt, tz)}\n"
            f"  current lock_version={target.get('lock_version')} "
            f"full={target.get('full_group')}")
    print(plan)

    if dry_run:
        return True, "DRY RUN — identified target, did not book.\n" + plan

    if not book_now:
        now = datetime.now(timezone.utc)
        if open_dt - now > OPEN_GUARD:
            # This week's instance is already booked; the next one opens far out.
            # Don't sit waiting for days — exit cleanly.
            return True, (f"Nothing to book now — next '{label}' opens "
                          f"{_fmt(open_dt, tz)} (this week likely already booked).")
        print(f"Waiting until {_fmt(open_dt, tz)} ...")
        wait_until(open_dt)

    # Retry loop: fire at the open instant; keep trying through "too early"
    # (advance_time_restriction) and refresh lock_version only on lock conflicts.
    lock = target.get("lock_version")
    last = "no attempt"
    for attempt in range(1, MAX_RETRY_ATTEMPTS + 1):
        resp = fisikal.join(context, csrf, target["id"], lock)
        ok, msg, errors = fisikal.parse_join_result(resp)
        last = f"attempt {attempt}: {msg}"
        print(f"  {last}")
        if ok:
            return True, f"{label}\n{last}\nopened {_fmt(open_dt, tz)}"
        types = {e.get("type") for e in errors}
        if types & fisikal.TERMINAL_ERROR_TYPES:
            return False, f"{label}\n{last} (terminal)"
        if types & fisikal.LOCK_CONFLICT_TYPES:
            fresh = refresh_lock_version(context, csrf, klass, target["id"], target["occurs_at"])
            if fresh is not None:
                lock = fresh
        if attempt < MAX_RETRY_ATTEMPTS:
            time.sleep(RETRY_SLEEP_SECONDS)

    return False, f"{label}\nGave up after {MAX_RETRY_ATTEMPTS} attempts. Last: {last}"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--class", dest="klass", help="class key from classes.yml")
    ap.add_argument("--browse", action="store_true",
                    help="show all Mon-Fri 9:30–15:00 classes (both branches, no dance/fee)")
    ap.add_argument("--list", nargs="?", const="", help="list upcoming occurrences (optional name filter)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--headed", action="store_true")
    ap.add_argument("--book-now", action="store_true", help="skip the wait; book immediately")
    ap.add_argument("--cancel-id", type=int, help="cancel a booking by occurrence id")
    ap.add_argument("--cancel-class", help="cancel the next booked occurrence of this class key")
    ap.add_argument("--on", help="with --cancel-class: target this class date (YYYY-MM-DD, local)")
    ap.add_argument("--cancel-paused", action="store_true",
                    help="cancel every booked occurrence that now falls in a pause range")
    ap.add_argument("--book-id", type=int,
                    help="book a specific occurrence by id, independent of classes.yml "
                         "(one-off exception, e.g. a configured class is full this week)")
    args = ap.parse_args(argv)

    cfg = load_config()
    username = os.environ.get("EGYM_USERNAME")
    password = os.environ.get("EGYM_PASSWORD")
    if not username or not password:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD environment variables.")

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not args.headed)
        context = browser.new_context()
        try:
            _, csrf = login(context, username, password)
            print("Logged in; csrf acquired.")

            if args.browse:
                run_browse(context, csrf, cfg)
                return 0

            if args.list is not None:
                run_list(context, csrf, cfg, args.list or None)
                return 0

            if args.cancel_id:
                resp = fisikal.cancel(context, csrf, args.cancel_id)
                print(f"cancel {args.cancel_id} -> HTTP {resp.status}: {resp.text()[:200]}")
                return 0 if resp.ok else 1

            if args.cancel_class:
                tz = cfg["timezone"]
                klass = get_class(cfg, args.cancel_class)
                label = f"{klass['name']} {klass['weekday']} {klass['start']}"
                now = datetime.now(timezone.utc)
                occs = fisikal.list_occurrences(
                    context, csrf, now - timedelta(hours=2),
                    now + timedelta(days=LIST_WINDOW_DAYS),
                    location_ids=klass.get("location_ids"),
                )
                matches = fisikal.find_matches(
                    occs, klass["name"], klass["weekday"], klass["start"], tz,
                    sub_location=klass.get("sub_location"), trainer=klass.get("trainer"),
                )
                target = None
                for o in matches:
                    occ = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00"))
                    if occ <= now or not o.get("is_joined"):
                        continue
                    if args.on and occ.astimezone(ZoneInfo(tz)).date().isoformat() != args.on:
                        continue
                    target = o
                    break
                if not target:
                    where = f" on {args.on}" if args.on else ""
                    print(f"No upcoming booked occurrence to cancel for '{label}'{where}.")
                    return 0
                resp = fisikal.cancel(context, csrf, target["id"])
                when = _fmt(datetime.fromisoformat(target["occurs_at"].replace("Z", "+00:00")), tz)
                ok = resp.ok
                detail = f"{label}\ncancelled occ id={target['id']} at {when} -> HTTP {resp.status}"
                notify(ok, f"Cancel {label}", detail)
                print(("OK: " if ok else "FAILED: ") + detail)
                return 0 if ok else 1

            if args.cancel_paused:
                # Reconcile: cancel any upcoming booked occurrence of a configured
                # class whose date now falls in a pause range (respecting `except`).
                tz = cfg["timezone"]
                ranges = pauses.load_ranges()
                if not ranges:
                    print("No pause ranges loaded; nothing to cancel.")
                    return 0
                print("Pause ranges: " + ", ".join(
                    f"{r.start}..{r.end}" + (f" except {sorted(r.except_keys)}"
                                             if r.except_keys else "") for r in ranges))
                now = datetime.now(timezone.utc)
                cancelled, failed = [], []
                for klass in cfg.get("classes", []):
                    occs = fisikal.list_occurrences(
                        context, csrf, now - timedelta(hours=2),
                        now + timedelta(days=LIST_WINDOW_DAYS),
                        location_ids=klass.get("location_ids"),
                    )
                    matches = fisikal.find_matches(
                        occs, klass["name"], klass["weekday"], klass["start"], tz,
                        sub_location=klass.get("sub_location"), trainer=klass.get("trainer"),
                    )
                    for o in matches:
                        occ = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00"))
                        if occ <= now or not o.get("is_joined"):
                            continue
                        occ_date = occ.astimezone(ZoneInfo(tz)).date()
                        rng = pauses.covering(ranges, occ_date)
                        if not rng or klass["key"] in rng.except_keys:
                            continue
                        resp = fisikal.cancel(context, csrf, o["id"])
                        line = f"{klass['key']} {occ_date} occ={o['id']} -> HTTP {resp.status}"
                        print(("  cancelled " if resp.ok else "  FAILED   ") + line)
                        (cancelled if resp.ok else failed).append(line)
                summary = (f"Cancelled {len(cancelled)} paused booking(s)"
                           + (f", {len(failed)} FAILED" if failed else "") + ".")
                print(summary)
                if cancelled or failed:
                    notify(not failed, "Cancel paused bookings",
                           summary + "\n" + "\n".join(cancelled + failed))
                return 0 if not failed else 1

            if args.book_id:
                ok, detail = book_by_id(context, csrf, args.book_id)
                print(detail)
                notify(ok, f"Book occurrence id={args.book_id}", detail)
                if ok:
                    print(f"Booked! Cancel with: --cancel-id {args.book_id}")
                return 0 if ok else 1

            if not args.klass:
                raise SystemExit("Provide --class <key> (or --list).")

            klass = get_class(cfg, args.klass)
            success, detail = book(context, csrf, cfg, klass, args.dry_run, args.book_now)
            if not args.dry_run:
                notify(success, f"{klass['name']} {klass['weekday']} {klass['start']}", detail)
            print(("OK: " if success else "FAILED: ") + detail)
            return 0 if success else 1
        finally:
            context.close()
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
