"""Booking run notifications — stdout (visible in the GitHub Actions log),
plus an email alert on failed booking attempts.

Successes aren't emailed here — the weekly summary emails already show what
got booked, so a separate success ping would be redundant. Reuses the same
Gmail SMTP creds as the summary emails (NOTIFY_EMAIL / GMAIL_APP_PASSWORD).
Fail-open: unset means no alert email, everything else still works.

(Text-message notifications via carrier email-to-SMS gateways were tried —
see issue #33 — but AT&T shut down its gateway for good on 2025-06-17, and
there's no free replacement, so this alerts by email instead.)
"""

from __future__ import annotations

import os

from .notify_email import send_email


def notify(success: bool, class_label: str, detail: str, alert: bool = False) -> None:
    status = "OK" if success else "FAILED"
    print(f"[notify] {status}: {class_label}")
    print(detail)

    if success or not alert:
        return

    login_email = os.environ.get("NOTIFY_EMAIL")
    gmail_app_pw = os.environ.get("GMAIL_APP_PASSWORD")
    if not (login_email and gmail_app_pw):
        return

    subject = f"❌ YMCA booking failed: {class_label}"
    body = f"{class_label}\n\n{detail}"
    try:
        send_email(login_email=login_email, password=gmail_app_pw,
                   subject=subject, html=body, text=body)
        print(f"[notify] Failure alert emailed to {login_email}.")
    except Exception as exc:  # an alert failing must never break a booking attempt
        print(f"[notify] Failure alert send failed ({exc!r}); booking itself is unaffected.")
