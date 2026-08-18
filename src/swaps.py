"""One-off schedule swaps ("skip X that day, book Y instead"), from a PRIVATE repo.

A swap is a single-date exception to classes.yml: on one specific date you want to
miss a recurring class and take a different one instead. Like pauses, the dates
are personal, so the file lives in the private repo (default thomashan1/ymca-private)
as swaps.yml:

    swaps:
      - date: 2026-08-18          # the CLASS date, not the booking-run date
        skip: cycle-tue           # a key from classes.yml
        book:                     # matched exactly like a classes.yml entry
          name: "BODYCOMBAT"
          start: "09:50"
          location_ids: [1388]    # Southwest=1392, Northwest=1388
        note: "trying the Northwest instructor"

`skip` and `book` are each optional, so a swap can also express "just skip this
one" or "just add this one" — but the common case is both.

The replacement is described the same way classes.yml describes a class (name +
start + branch), NOT as an occurrence id. Ids are only discoverable by browsing
the API and change week to week; a name/time/branch triple is stable and can be
written a week ahead, which is the whole point of the file.

WHY THIS EXISTS: the first one-off swap (BODYCOMBAT 2026-08-18) shipped as its
own temporary workflow with its own cron. That cron fired 46 minutes late — a
brand-new, once-a-year schedule gets treated far worse by GitHub than book.yml's
established weekly crons, which over 100 runs have never been more than 19
minutes late. So swaps deliberately carry no schedule of their own: run_due.py
picks them up on the existing book.yml fires. See issue #95.

FAIL-SAFE by design: a missing token, network error or unparseable file yields
"no swaps", so the ordinary classes.yml schedule books as usual. The failure mode
is "you got your normal class" rather than "you got nothing", which is why this
fails differently from a booking error — there is nothing to alert about.
"""

from __future__ import annotations

import os
from datetime import date, datetime, time
from typing import NamedTuple

import httpx
import yaml


class Swap(NamedTuple):
    """A single-date exception: drop `skip_key`, take `book_*` instead."""
    date: date
    skip_key: str | None = None
    book_name: str | None = None
    book_start: str | None = None
    book_location_ids: tuple[int, ...] = ()
    note: str | None = None

    @property
    def start_time(self) -> time | None:
        """Local start time of the replacement, or None for a skip-only swap."""
        if not self.book_start:
            return None
        try:
            return time.fromisoformat(self.book_start)
        except ValueError:   # a typo in swaps.yml must not crash the run
            return None

    @property
    def label(self) -> str:
        """Human-readable summary, for logs and emails."""
        left = self.skip_key or "(nothing)"
        right = (f"{self.book_name} {self.book_start}" if self.book_name else "(nothing)")
        return f"{self.date}: {left} -> {right}"

    def as_class(self) -> dict:
        """The replacement rendered as a classes.yml-shaped dict for main.book().

        `weekday` is derived from the date so find_matches() filters the same way
        it does for a recurring class; the date itself is passed separately as
        on_date, because a swap must hit one specific day rather than "the next
        matching one".
        """
        return {
            "key": f"swap-{self.date:%Y%m%d}",
            "name": self.book_name,
            "weekday": self.date.strftime("%a"),
            "start": self.book_start,
            "location_ids": list(self.book_location_ids),
        }


# The private file's location. Overridable via env (handy for tests).
SWAP_REPO = os.environ.get("SWAP_REPO", os.environ.get("PAUSE_REPO", "thomashan1/ymca-private"))
SWAP_PATH = os.environ.get("SWAP_PATH", "swaps.yml")
SWAP_REF = os.environ.get("SWAP_REF", "main")


def _as_date(v) -> date:
    """Coerce a YAML scalar to a date (PyYAML already parses ISO dates as date)."""
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    return date.fromisoformat(str(v).strip())


def _fetch_yaml(token: str) -> str:
    """Download the raw swaps.yml from the private repo via the contents API."""
    url = f"https://api.github.com/repos/{SWAP_REPO}/contents/{SWAP_PATH}"
    resp = httpx.get(
        url,
        params={"ref": SWAP_REF},
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github.raw+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=15.0,
    )
    # An absent file is normal — most weeks have no swaps at all.
    if resp.status_code == 404:
        return ""
    resp.raise_for_status()
    return resp.text


def parse_swaps(text: str) -> list[Swap]:
    """Parse swaps.yml text into Swaps, newest date last."""
    data = yaml.safe_load(text) or {}
    out = []
    for s in data.get("swaps", []) or []:
        book = s.get("book") or {}
        loc = book.get("location_ids") or []
        if isinstance(loc, int):
            loc = [loc]
        out.append(Swap(
            date=_as_date(s["date"]),
            skip_key=(str(s["skip"]).strip() if s.get("skip") else None),
            book_name=(str(book["name"]).strip() if book.get("name") else None),
            book_start=(str(book["start"]).strip() if book.get("start") else None),
            book_location_ids=tuple(int(x) for x in loc),
            note=(str(s["note"]).strip() if s.get("note") else None),
        ))
    return sorted(out, key=lambda s: s.date)


def load_swaps(token: str | None = None) -> list[Swap]:
    """Fetch + parse swaps from the private repo. Fail-safe -> []."""
    token = token or os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        print("[swap] PRIVATE_REPO_TOKEN not set; skipping swap check.")
        return []
    try:
        return parse_swaps(_fetch_yaml(token))
    except Exception as exc:  # network / auth / parse — fall back to the normal schedule
        print(f"[swap] could not read swaps ({exc!r}); using classes.yml as-is.")
        return []


def upcoming(swaps: list[Swap], now: datetime) -> list[Swap]:
    """Swaps still worth acting on at local time `now`.

    Past dates drop out, and so does a swap on today's date whose replacement has
    already started. That second half matters: once a class is under way Fisikal
    stops listing its occurrence, so re-running a spent swap can only report "No
    upcoming bookable occurrence found" and fail a run whose work was done hours
    earlier. That is exactly what happened on 2026-08-18 — the BODYCOMBAT
    replacement was booked at 09:50 and taken, and every book.yml fire after
    ~12:00 PDT that day emailed a ❌ for a swap that had already succeeded.

    A skip-only swap (no `book:`) has no time of its own — the class it drops is
    just a key into classes.yml — so it stays live for the whole day. It books
    nothing, so it cannot fail this way.

    `now` must be timezone-aware local time, not the runner's UTC: date.today()
    on a UTC runner rolls over at 17:00 PDT and would retire an evening swap on
    the wrong side of midnight.
    """
    out = []
    for s in swaps:
        if s.date > now.date():
            out.append(s)
        elif s.date == now.date():
            start = s.start_time
            if start is None or now.time() < start:
                out.append(s)
    return out
