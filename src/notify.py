"""Booking run notifications — printed to stdout (visible in GitHub Actions logs).

The YMCA already sends a confirmation email from noreply@ymcasv.org, so we
don't need to send one ourselves. All output goes to stdout for Actions log.
"""

from __future__ import annotations


def notify(success: bool, class_label: str, detail: str) -> None:
    status = "OK" if success else "FAILED"
    print(f"[notify] {status}: {class_label}")
    print(detail)
