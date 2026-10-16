"""Away dates (away ranges), fetched from a PRIVATE repo at runtime.

Personal away-dates must never live in this public repo, so they're kept in a
separate private repo (default: thomashan1/ymca-private) as a small away.yml:

    # inclusive start..end, local schedule timezone; resume = day after `end`
    away:
      - {start: 2026-07-03, end: 2026-07-03}   # single day
      - {start: 2026-07-06, end: 2026-07-06, except: [lift-hiit-mon]}  # keep one class
      - {start: 2026-07-07, end: 2026-07-12}   # away, resume 7/13

`except` (optional) lists class keys (from classes.yml) to keep booking despite
the away range — handy when you're "off" but still want one specific class that day.

Each range lists the dates of CLASSES you won't attend. run_due.py loads the
ranges once per scheduled run and skips booking any occurrence whose own date
falls inside one — NOT the run date. Booking opens ~7 days ahead, so the run
that books a class on an away day fires a week earlier; matching on the class date
(not "today") is what actually keeps you off the roster while you're away.

FAIL-OPEN by design: a missing token, network error, or unparseable file means
"no away dates" so a misconfiguration can never silently stop bookings — the worst
case is booking a class during a week you're away, which you can still cancel.
"""

from __future__ import annotations

import os
from datetime import date, datetime
from typing import NamedTuple

import httpx
import yaml


class AwayRange(NamedTuple):
    """An inclusive away-window. `except_keys` are class keys still booked anyway."""
    start: date
    end: date
    except_keys: frozenset[str] = frozenset()

# The private file's location. Overridable via env (handy for tests).
PRIVATE_REPO = os.environ.get("PRIVATE_REPO", "thomashan1/ymca-private")
AWAY_PATH = os.environ.get("AWAY_PATH", "away.yml")
PRIVATE_REF = os.environ.get("PRIVATE_REF", "main")


def _as_date(v) -> date:
    """Coerce a YAML scalar to a date (PyYAML already parses ISO dates as date)."""
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    return date.fromisoformat(str(v).strip())


def _fetch_yaml(token: str) -> str:
    """Download the raw away.yml from the private repo via the contents API."""
    url = f"https://api.github.com/repos/{PRIVATE_REPO}/contents/{AWAY_PATH}"
    resp = httpx.get(
        url,
        params={"ref": PRIVATE_REF},
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github.raw+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp.text


def parse_ranges(text: str) -> list[AwayRange]:
    """Parse away.yml text into inclusive AwayRanges (with any exceptions)."""
    data = yaml.safe_load(text) or {}
    ranges = []
    for p in data.get("away", []) or []:
        start = _as_date(p["start"])
        end = _as_date(p.get("end", p["start"]))
        if end < start:
            start, end = end, start
        # `except` (optional): class key(s) to keep booking despite the away range.
        raw = p.get("except") or []
        if isinstance(raw, str):
            raw = [raw]
        except_keys = frozenset(str(k).strip() for k in raw)
        ranges.append(AwayRange(start, end, except_keys))
    return ranges


def load_ranges(token: str | None = None) -> list[AwayRange]:
    """Fetch + parse the away-ranges from the private repo. Fail-open -> []."""
    token = token or os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        print("[away] PRIVATE_REPO_TOKEN not set; skipping away check.")
        return []
    try:
        return parse_ranges(_fetch_yaml(token))
    except Exception as exc:  # network / auth / parse — never block booking
        print(f"[away] could not read away dates ({exc!r}); proceeding to book.")
        return []


def covering(ranges: list[AwayRange], day: date) -> AwayRange | None:
    """Return the range covering `day`, or None."""
    for r in ranges:
        if r.start <= day <= r.end:
            return r
    return None
