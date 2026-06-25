"""Away-period ("pause") windows, fetched from a PRIVATE repo at runtime.

Personal away-dates must never live in this public repo, so they're kept in a
separate private repo (default: thomashan1/ymca-private) as a small pauses.yml:

    # inclusive start..end, local schedule timezone; resume = day after `end`
    pauses:
      - {start: 2026-07-03, end: 2026-07-03}   # single day
      - {start: 2026-07-07, end: 2026-07-12}   # away, resume 7/13

run_due.py calls active_pause(today) at the start of a scheduled run and skips
all booking if today falls inside any range.

FAIL-OPEN by design: a missing token, network error, or unparseable file means
"not paused" so a misconfiguration can never silently stop bookings — the worst
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


def active_pause(today: date, token: str | None = None) -> tuple[date, date] | None:
    """Return the pause range covering `today`, or None. Fail-open on any error."""
    token = token or os.environ.get("PRIVATE_REPO_TOKEN")
    if not token:
        print("[pause] PRIVATE_REPO_TOKEN not set; skipping pause check.")
        return None
    try:
        ranges = parse_ranges(_fetch_yaml(token))
    except Exception as exc:  # network / auth / parse — never block booking
        print(f"[pause] could not read pauses ({exc!r}); proceeding to book.")
        return None
    for start, end in ranges:
        if start <= today <= end:
            return (start, end)
    return None
