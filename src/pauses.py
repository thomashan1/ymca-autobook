"""Away-period ("pause") windows, fetched from a PRIVATE repo at runtime.

Personal away-dates must never live in this public repo, so they're kept in a
separate private repo (default: thomashan1/ymca-private) as a small pauses.yml:

    # inclusive start..end, local schedule timezone; resume = day after `end`
    pauses:
      - {start: 2026-07-03, end: 2026-07-03}   # single day
      - {start: 2026-07-07, end: 2026-07-12}   # away, resume 7/13

Each range lists the dates of CLASSES you won't attend. run_due.py loads the
ranges once per scheduled run and skips booking any occurrence whose own date
falls inside one — NOT the run date. Booking opens ~7 days ahead, so the run
that books a paused class fires a week earlier; matching on the class date
(not "today") is what actually keeps you off the roster while you're away.

FAIL-OPEN by design: a missing token, network error, or unparseable file means
"no pauses" so a misconfiguration can never silently stop bookings — the worst
case is booking a class during a week you're away, which you can still cancel.
"""

from __future__ import annotations

import os
from datetime import date, datetime

import httpx
import yaml

# The private file's location. Overridable via env (handy for tests).
PAUSE_REPO = os.environ.get("PAUSE_REPO", "thomashan1/ymca-private")
PAUSE_PATH = os.environ.get("PAUSE_PATH", "pauses.yml")
PAUSE_REF = os.environ.get("PAUSE_REF", "main")


def _as_date(v) -> date:
    """Coerce a YAML scalar to a date (PyYAML already parses ISO dates as date)."""
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    return date.fromisoformat(str(v).strip())


def _fetch_yaml(token: str) -> str:
    """Download the raw pauses.yml from the private repo via the contents API."""
    url = f"https://api.github.com/repos/{PAUSE_REPO}/contents/{PAUSE_PATH}"
    resp = httpx.get(
        url,
        params={"ref": PAUSE_REF},
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github.raw+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp.text


def parse_ranges(text: str) -> list[tuple[date, date]]:
    """Parse pauses.yml text into [(start, end), ...] inclusive ranges."""
    data = yaml.safe_load(text) or {}
    ranges = []
    for p in data.get("pauses", []) or []:
        start = _as_date(p["start"])
        end = _as_date(p.get("end", p["start"]))
        if end < start:
            start, end = end, start
        ranges.append((start, end))
    return ranges


def load_ranges(token: str | None = None) -> list[tuple[date, date]]:
    """Fetch + parse the away-ranges from the private repo. Fail-open -> []."""
    token = token or os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        print("[pause] PRIVATE_REPO_TOKEN not set; skipping pause check.")
        return []
    try:
        return parse_ranges(_fetch_yaml(token))
    except Exception as exc:  # network / auth / parse — never block booking
        print(f"[pause] could not read pauses ({exc!r}); proceeding to book.")
        return []


def covering(ranges: list[tuple[date, date]], day: date) -> tuple[date, date] | None:
    """Return the range covering `day`, or None."""
    for start, end in ranges:
        if start <= day <= end:
            return (start, end)
    return None
