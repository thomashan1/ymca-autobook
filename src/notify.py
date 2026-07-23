"""Booking run notifications — stdout (visible in the GitHub Actions log),
plus an optional text message on successful bookings (see issue #33).

The YMCA already sends its own confirmation email, so this repo doesn't
duplicate that — but a text is handy for the "did it actually book" moment
when you're not near a computer or checking Actions logs. This uses a
carrier email-to-SMS gateway (e.g. 5551234567@vtext.com) via the same Gmail
SMTP credentials already configured for the summary emails — free, no new
paid service or API.

NOTIFY_SMS_EMAIL (optional): the carrier gateway address to text. Leave
unset to skip SMS entirely — logging and the summary emails still work.
Common US gateways: @vtext.com (Verizon), @txt.att.net (AT&T),
@tmomail.net (T-Mobile), @messaging.sprintpcs.com (Sprint/T-Mobile legacy).
"""

from __future__ import annotations

import os

from .notify_email import send_email


def notify(success: bool, class_label: str, detail: str, sms: bool = False) -> None:
    status = "OK" if success else "FAILED"
    print(f"[notify] {status}: {class_label}")
    print(detail)

    if not (success and sms):
        return

    sms_to = os.environ.get("NOTIFY_SMS_EMAIL")
    login_email = os.environ.get("NOTIFY_EMAIL")
    gmail_app_pw = os.environ.get("GMAIL_APP_PASSWORD")
    if not (sms_to and login_email and gmail_app_pw):
        return

    # Carrier gateways are picky — keep it short and plain, no HTML.
    text = f"YMCA booked: {class_label}"
    try:
        send_email(login_email=login_email, password=gmail_app_pw, to=sms_to,
                   subject="", html=text, text=text)
        print(f"[notify] SMS sent to {sms_to}.")
    except Exception as exc:  # a text failing must never break a successful booking
        print(f"[notify] SMS send failed ({exc!r}); booking itself is unaffected.")
