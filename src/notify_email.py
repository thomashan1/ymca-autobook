"""Send an HTML+text email via Gmail SMTP. Shared by the summary-email scripts."""

from __future__ import annotations

import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


def send_email(login_email: str, password: str, subject: str, html: str, text: str,
               to: str | None = None) -> None:
    """Send via the Gmail account at `login_email`. Defaults to self-send
    (to=login_email) for the summary emails; pass `to` to send elsewhere —
    e.g. a carrier email-to-SMS gateway address for text notifications."""
    to = to or login_email
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = login_email
    msg["To"] = to
    msg.attach(MIMEText(text, "plain"))
    msg.attach(MIMEText(html, "html"))
    with smtplib.SMTP("smtp.gmail.com", 587) as smtp:
        smtp.starttls()
        smtp.login(login_email, password)
        smtp.send_message(msg)
