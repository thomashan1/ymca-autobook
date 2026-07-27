"""Record of scheduled classes that filled up before we could book them.

Kept in the PRIVATE repo as full.json, alongside pauses.yml and the snapshots,
because it names the classes and dates you personally planned to attend.

    {
      "updated_at": "2026-07-27T20:00:00Z",
      "full": {
        "316049": {"class_key": "trx-beginners-fri", "name": "TRX for Beginners",
                   "date": "2026-07-31", "start": "10:30",
                   "location": "Southwest", "first_seen": "2026-07-27T19:35:02Z"}
      }
    }

Two jobs:

1. **Alert once.** A full class stays full; re-reporting it on every cron fire
   is noise, and noise is how a real failure gets missed. The first detection
   is a failure (red run -> GitHub push -> email); after that it's a quiet skip.

2. **Show it in the app.** "Not booked" and "not bookable" look identical in the
   Week view otherwise, which is the wrong thing to be ambiguous about.

Entries clear themselves: if a spot frees up and the occurrence is no longer
full, the record is dropped and normal booking resumes. We never stop *checking*
a class — only stop hammering a door that is currently shut.

FAIL-OPEN, like pauses.py: no token, network error, or unparseable file means
"nothing known to be full", which at worst costs one extra booking attempt.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone

from . import private_store

FULL_PATH = os.environ.get("FULL_PATH", "full.json")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _token() -> str | None:
    return os.environ.get("PRIVATE_REPO_TOKEN")


def load() -> dict:
    """{occurrence_id(str): info} — empty on any problem (fail-open)."""
    token = _token()
    if not token:
        return {}
    try:
        text, _ = private_store.get_file(token, FULL_PATH)
        if not text:
            return {}
        data = json.loads(text)
        full = data.get("full")
        return full if isinstance(full, dict) else {}
    except Exception as exc:
        print(f"[full] could not read {FULL_PATH} ({exc!r}); assuming none.")
        return {}


def _write(full: dict, message: str) -> None:
    token = _token()
    if not token:
        return
    try:
        _, sha = private_store.get_file(token, FULL_PATH)
        body = json.dumps({"updated_at": _now(), "full": full},
                          indent=2, sort_keys=True) + "\n"
        private_store.put_file(token, FULL_PATH, body, sha, message)
    except Exception as exc:
        # Never let bookkeeping break a booking run.
        print(f"[full] could not write {FULL_PATH} ({exc!r}); continuing.")


def record(occurrence_id: int, info: dict) -> bool:
    """Note an occurrence as full. Returns True only the FIRST time — that's
    what makes this alert once rather than on every cron fire."""
    key = str(occurrence_id)
    full = load()
    if key in full:
        return False
    entry = dict(info)
    entry["first_seen"] = _now()
    full[key] = entry
    _write(full, f"full: {info.get('name','?')} {info.get('date','?')} filled up")
    return True


def clear(occurrence_id: int) -> None:
    """Drop an occurrence — a spot freed up, so it's bookable again."""
    key = str(occurrence_id)
    full = load()
    if key not in full:
        return
    name = full[key].get("name", "?")
    date_s = full[key].get("date", "?")
    del full[key]
    _write(full, f"full: {name} {date_s} has space again")
