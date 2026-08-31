"""Generate .github/workflows/book.yml from classes.yml.

Booking opens 167h before a class = same weekday, (start time + 1 hour). We fire
each job at several FIRE_LEAD_MINS minutes before that. GitHub cron is best-effort
and silently drops/delays triggers under load, so we emit a redundant trigger at
each lead — if one is skipped, another still fires before the open, waits for the
true instant, and books. GitHub cron is also fixed UTC and ignores Pacific DST, so
each lead emits two cron lines (PDT = UTC-7, PST = UTC-8); the script computes the
true open instant and waits, and any redundant run no-ops via the OPEN_GUARD (the
booking API is idempotent, so a duplicate just sees "already booked"). Run:
  python scripts/gen_workflow.py

Split into 5 weekday files + manual.yml on 2026-08-28, then reverted back to this
single file on 2026-08-31: the split didn't fix anything — a brand-new, 18-line
weekday file still fired zero times, and a same-afternoon test on a completely
fresh throwaway workflow (created minutes before its own cron) also fired zero
times, ruling out "cron volume in one file" and "stuck state tied to an old
workflow file's history" alike. GitHub's status history shows a Critical Actions
incident on 2026-08-26 15:02-15:45 UTC ("Actions jobs failed to start", database
saturation, jobs stuck in queued state) right when reliability started degrading;
best working theory is this repo got left in a stuck scheduler state that incident's
"resolved" status never individually cleared, which no amount of restructuring our
own workflow files can fix. So: back to the simpler single-file structure that
was previously reliable (100 runs, median 4.3 min delay) rather than carrying the
extra complexity of 6 files for a problem they didn't solve. See CLAUDE.md.

NATIVE_TIMEZONE_DAYS (2026-08-28): GitHub Actions added a native `timezone:` field
on schedule entries in March 2026 (GA) — the cron's h/m fields are read as *local*
time in that zone and GitHub itself handles the DST switch, so a class needs only
ONE line per lead instead of two (no more hand-written PDT/PST twins). Piloted on
Wed classes only; unrelated to the file-split question above, so it stays.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

import yaml

# Fire a trigger at each of these minutes before booking opens. Multiple leads give
# redundancy against GitHub dropping a scheduled trigger; all fire before the open
# so whichever runs waits for the precise instant and books on the first attempt.
#
# The earliest lead is the delay budget: a run that starts late still books on time
# as long as it starts before the open, because it waits. Measured over 100
# scheduled runs the queue delay was a 4.3 min median, 13.4 at p90 and 18.8 at
# worst — so the old 25 min lead had ~6 min of headroom. 45 roughly triples that.
# Runner minutes spent waiting are free on a public repo, so the lead costs nothing
# but idle time.
#
# CEILING: every lead must stay UNDER main.OPEN_GUARD (60 min). GitHub cron is
# fixed UTC, so each lead emits both a PDT and a PST line and both fire all year;
# the out-of-season twin arrives lead+60 min before the open, and OPEN_GUARD is
# what makes it exit instead of waiting an extra hour. A lead of 60+ would stop
# that twin being filtered and start booking from the wrong-season trigger.
FIRE_LEAD_MINS = [45, 30, 15]
CRON_DOW = {"Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6, "Sun": 0}
LOCAL_TZ = "America/Los_Angeles"
# Pilot scope for the native `timezone:` cron field — see module docstring.
NATIVE_TIMEZONE_DAYS = {"Wed"}
HERE = os.path.dirname(__file__)
CONFIG = os.path.join(HERE, os.pardir, "classes.yml")
OUT = os.path.join(HERE, os.pardir, ".github", "workflows", "book.yml")


def cron_lines(klass) -> list[tuple[str, str, str | None]]:
    """Return [(cron_expr, comment, timezone), ...] for a class.

    `timezone` is None for the default (UTC, PDT+PST twin) path, or LOCAL_TZ for
    a class on a NATIVE_TIMEZONE_DAYS weekday — see module docstring for both.

    `extra_leads` (optional, in classes.yml) adds more redundant fires beyond
    FIRE_LEAD_MINS for a class worth extra insurance — e.g. BODYPUMP, which has
    been observed to fill within ~5h of its window opening. Same CEILING as
    FIRE_LEAD_MINS applies: every lead must stay under main.OPEN_GUARD (60).
    """
    dow = klass["weekday"]
    h, m = (int(x) for x in klass["start"].split(":"))
    leads = sorted(set(FIRE_LEAD_MINS) | set(klass.get("extra_leads", [])), reverse=True)
    assert all(0 < lead < 60 for lead in leads), \
        f"{klass['key']}: every lead must be in (0, 60) minutes"
    native = dow in NATIVE_TIMEZONE_DAYS
    out = []
    for i, lead in enumerate(leads):
        # First lead is the primary trigger; the rest are redundant retries in case
        # GitHub drops/delays the earlier one.
        role = "primary" if i == 0 else f"retry {i}"
        # open = start + 1h; fire = open - lead, as a same-day local time.
        fire = datetime(2000, 1, 3, h, m) + timedelta(hours=1) - timedelta(minutes=lead)
        if native:
            # GitHub reads h/m as LOCAL time in `timezone` and handles DST itself
            # — one line does the work of the PDT+PST pair below.
            out.append((f"{fire.minute} {fire.hour} * * {CRON_DOW[dow]}",
                        f"{klass['key']} — opens {dow} {h+1:02d}:{m:02d} PT "
                        f"({role}, fire -{lead}m)", LOCAL_TZ))
            continue
        for off, season in ((7, "PDT"), (8, "PST")):
            ut = fire + timedelta(hours=off)            # local -> UTC
            # day-of-week only shifts if the +offset crosses midnight; our fire times
            # are late morning/midday Pacific so UTC stays the same calendar weekday.
            assert ut.day == fire.day, "offset crossed midnight; handle DOW shift"
            out.append((f"{ut.minute} {ut.hour} * * {CRON_DOW[dow]}",
                        f"{klass['key']} — opens {dow} {h+1:02d}:{m:02d} PT "
                        f"({season}, {role}, fire -{lead}m)", None))
    return out


def _sched_line(expr: str, comment: str, tz: str | None) -> str:
    if tz is None:
        return f"    - cron: \"{expr}\"  # {comment}"
    return f"    - cron: \"{expr}\"  # {comment}\n      timezone: \"{tz}\""


def main():
    cfg = yaml.safe_load(open(CONFIG))
    crons = []
    for k in cfg["classes"]:
        crons.extend(cron_lines(k))

    sched = "\n".join(_sched_line(expr, c, tz) for expr, c, tz in crons)
    keys = [k["key"] for k in cfg["classes"]]
    body = f"""# AUTO-GENERATED by scripts/gen_workflow.py — edit classes.yml then regenerate.
name: Book YMCA classes

on:
  schedule:
{sched}
  workflow_dispatch:
    inputs:
      class_key:
        description: "Class key to book now (see classes.yml). Blank = decide from schedule."
        required: false
        default: ""
      cancel_id:
        description: "Occurrence id to CANCEL an existing booking. Takes priority over class_key."
        required: false
        default: ""
      cancel_class:
        description: "Class key to CANCEL its next booked occurrence (optionally set cancel_on date)."
        required: false
        default: ""
      cancel_on:
        description: "With cancel_class: target class date YYYY-MM-DD (blank = next booked)."
        required: false
        default: ""
      cancel_paused:
        description: "Cancel ALL booked classes that now fall in a pause range (set to 'true')."
        required: false
        default: ""
      book_id:
        description: "Occurrence id to BOOK directly, independent of classes.yml (one-off exception)."
        required: false
        default: ""
      browse:
        description: "Books NOTHING: lists upcoming occurrences with full/joined so you can see what is still open. Use 'all' or a name filter, e.g. 'RPM'."
        required: false
        default: ""

concurrency:
  group: book-${{{{ github.run_id }}}}

jobs:
  book:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: pip install -r requirements.txt
      - run: python -m playwright install --with-deps chromium
      - name: Book
        env:
          EGYM_USERNAME: ${{{{ secrets.EGYM_USERNAME }}}}
          EGYM_PASSWORD: ${{{{ secrets.EGYM_PASSWORD }}}}
          PRIVATE_REPO_TOKEN: ${{{{ secrets.PRIVATE_REPO_TOKEN }}}}
          NOTIFY_EMAIL: ${{{{ secrets.NOTIFY_EMAIL }}}}
          GMAIL_APP_PASSWORD: ${{{{ secrets.GMAIL_APP_PASSWORD }}}}
          GITHUB_EVENT_SCHEDULE: ${{{{ github.event.schedule }}}}
        run: |
          if [ -n "${{{{ github.event.inputs.browse }}}}" ]; then
            # Read-only. Checked first so a stray value in another field can
            # never turn an availability check into a booking or cancellation.
            FILTER="${{{{ github.event.inputs.browse }}}}"
            [ "$FILTER" = "all" ] && FILTER=""
            python -m src.main --list "$FILTER"
          elif [ -n "${{{{ github.event.inputs.cancel_id }}}}" ]; then
            python -m src.main --cancel-id "${{{{ github.event.inputs.cancel_id }}}}"
          elif [ -n "${{{{ github.event.inputs.cancel_class }}}}" ]; then
            python -m src.main --cancel-class "${{{{ github.event.inputs.cancel_class }}}}" ${{{{ github.event.inputs.cancel_on && format('--on {{0}}', github.event.inputs.cancel_on) || '' }}}}
          elif [ -n "${{{{ github.event.inputs.cancel_paused }}}}" ]; then
            python -m src.main --cancel-paused
          elif [ -n "${{{{ github.event.inputs.book_id }}}}" ]; then
            python -m src.main --book-id "${{{{ github.event.inputs.book_id }}}}"
          elif [ -n "${{{{ github.event.inputs.class_key }}}}" ]; then
            python -m src.main --class "${{{{ github.event.inputs.class_key }}}}"
          else
            python scripts/run_due.py
          fi
"""
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(body)
    print(f"Wrote {OUT} with {len(crons)} cron lines for {len(keys)} classes.")


if __name__ == "__main__":
    main()
