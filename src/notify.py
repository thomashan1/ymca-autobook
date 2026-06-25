"""Email notifications for booking runs.

Reads SMTP config from environment variables (set as GitHub Actions secrets):
    SMTP_HOST     e.g. smtp.gmail.com
    SMTP_PORT     e.g. 587 (defaults to 587)
    SMTP_USER     SMTP login (usually the sending Gmail address)
    SMTP_PASS     Gmail App Password (not your normal password)
    NOTIFY_EMAIL  where to send results (e.g. thomashan@gmail.com)

If SMTP is not configured, notify() just logs to stdout so local runs don't fail.
"""

from __future__ import annotations

import os
import smtplib
import ssl
from email.message import EmailMessage


def notify(success: bool, class_label: str, detail: str) -> None:
    """Send a success/failure email about a booking attempt.

    Falls back to printing if SMTP env vars are absent (e.g. local dry-runs).
    """
    status = "✅ Booked" if success else "❌ Failed"
    subject = f"{status}: {class_label}"
    body = f"{subject}\n\n{detail}\n"

    host = os.environ.get("SMTP_HOST")
    user = os.environ.get("SMTP_USER")
    password = os.environ.get("SMTP_PASS")
    to_addr = os.environ.get("NOTIFY_EMAIL")

    if not all([host, user, password, to_addr]):
        print(f"[notify] SMTP not configured; would have sent:\n{body}")
        return

    port = int(os.environ.get("SMTP_PORT", "587"))

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = to_addr
    msg.set_content(body)

    context = ssl.create_default_context()
    with smtplib.SMTP(host, port) as server:
        server.starttls(context=context)
        server.login(user, password)
        server.send_message(msg)
    print(f"[notify] sent '{subject}' to {to_addr}")
