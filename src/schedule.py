"""Timing helpers.

The booking-open rule is read straight from each occurrence's own fields in the
Fisikal API, so we don't hardcode it:

    open_instant = occurs_at - restrict_to_book_in_advance_time

Observed at this club: restrict_to_book_in_advance_time_in_hours = 167 (7 days
minus 1 hour), which is why a class opens "X minutes after last week's session
ends" (X = 60 - class_duration). Reading it from the API keeps us correct even
if the club changes the policy.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone


def parse_utc(iso: str) -> datetime:
    """Parse a Fisikal 'occurs_at' like '2026-06-29T18:20:00Z' as aware UTC."""
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc)


def open_instant(occurs_at_iso: str, restrict_hours: int | None,
                 restrict_minutes: int | None) -> datetime:
    """When booking opens for an occurrence (aware UTC datetime)."""
    occurs = parse_utc(occurs_at_iso)
    delta = timedelta(hours=restrict_hours or 0, minutes=restrict_minutes or 0)
    return occurs - delta


def wait_until(target: datetime, lead_seconds: float = 2.0) -> None:
    """Coarse-sleep until `lead_seconds` before target, then spin to the instant.

    The coarse sleep avoids burning CPU during the long wait; the final tight
    spin keeps the fire time within ~10ms of the open instant.
    """
    while True:
        remaining = (target - datetime.now(timezone.utc)).total_seconds()
        if remaining <= lead_seconds:
            break
        time.sleep(min(remaining - lead_seconds, 30))

    while datetime.now(timezone.utc) < target:
        time.sleep(0.01)
