"""Weekly summary: email + GitHub Actions job summary of upcoming booked classes.

Runs Mon 08:00 PT and Fri 15:00 PT via .github/workflows/weekly-summary.yml.
Logs in, finds all occurrences in the next 7 days where is_joined=True, sends
an HTML email via Gmail SMTP, and writes the same table to $GITHUB_STEP_SUMMARY.
"""

from __future__ import annotations

import os
import smtplib
import sys
from datetime import date, datetime, timedelta, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from zoneinfo import ZoneInfo

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import fisikal              # noqa: E402
from src.login import login         # noqa: E402
from src.main import load_config    # noqa: E402

_BOTH_LOCATIONS = [1392, 1388]  # Southwest + Northwest


def _build_rows(booked: list[dict], tz: ZoneInfo) -> list[dict]:
    rows = []
    for o in booked:
        dt = datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00")).astimezone(tz)
        rows.append({
            "dt":          dt,
            "day":         dt.strftime("%a"),
            "date":        dt.strftime("%b %d"),
            "isodate":     dt.date(),
            "isoweek":     dt.isocalendar()[1],
            "time":        dt.strftime("%I:%M %p").lstrip("0"),
            "name":        (o.get("service_title") or "").strip(),
            "instructor":  (o.get("trainer_name") or "—").strip(),
            "sub_location":(o.get("sub_location_name") or "—").strip(),
            "location":    (o.get("location_name") or "").replace("Silicon Valley YMCA - ", ""),
        })
    return rows


def _markdown(rows: list[dict], title: str, count: int) -> str:
    lines = [f"## {title}\n"]
    if not rows:
        lines.append("_No classes booked this week._\n")
        return "\n".join(lines)

    header = "| Day | Date | Time | Class | Instructor | Studio | Branch |"
    sep    = "|-----|------|------|-------|------------|--------|--------|"

    prev_date: date | None = None
    prev_week: int | None = None
    for r in rows:
        # Week break (bold horizontal rule before the new week's first class)
        if prev_week is not None and r["isoweek"] != prev_week:
            lines.append("\n---\n")
            lines.append(header)
            lines.append(sep)
        # Day break (blank line + fresh header for each new day)
        elif prev_date is not None and r["isodate"] != prev_date:
            lines.append("")
            lines.append(header)
            lines.append(sep)
        # First row
        elif prev_date is None:
            lines.append(header)
            lines.append(sep)

        lines.append(
            f"| {r['day']} | {r['date']} | {r['time']} | {r['name']} "
            f"| {r['instructor']} | {r['sub_location']} | {r['location']} |"
        )
        prev_date = r["isodate"]
        prev_week = r["isoweek"]

    lines.append(f"\n**{count} class{'es' if count != 1 else ''} booked.**\n")
    return "\n".join(lines)


def _html(rows: list[dict], title: str, count: int) -> str:
    GREEN  = "#2d6a4f"
    DGREEN = "#1b4332"
    COLS   = ["Day", "Date", "Time", "Class", "Instructor", "Studio", "Branch"]

    if not rows:
        body = "<p><em>No classes booked this week.</em></p>"
    else:
        thead = "".join(
            f"<th style='padding:8px 12px;text-align:left'>{h}</th>" for h in COLS
        )
        trs = ""
        prev_date: date | None = None
        prev_week: int | None = None
        stripe = 0

        for r in rows:
            # Week break — bold divider row spanning all columns
            if prev_week is not None and r["isoweek"] != prev_week:
                trs += (
                    f"<tr><td colspan='{len(COLS)}' style='"
                    f"background:{DGREEN};height:4px;padding:0'></td></tr>"
                )
                stripe = 0
            # Day break — spacer row
            elif prev_date is not None and r["isodate"] != prev_date:
                trs += (
                    f"<tr><td colspan='{len(COLS)}' style='"
                    f"background:#e0e0e0;height:2px;padding:0'></td></tr>"
                )
                stripe = 0

            bg = "#f4f9f6" if stripe % 2 else "#ffffff"
            cells = "".join(
                f"<td style='padding:7px 12px'>{v}</td>"
                for v in [r["day"], r["date"], r["time"], r["name"],
                          r["instructor"], r["sub_location"], r["location"]]
            )
            trs += f"<tr style='background:{bg}'>{cells}</tr>"
            stripe += 1
            prev_date = r["isodate"]
            prev_week = r["isoweek"]

        body = f"""
        <table style='border-collapse:collapse;font-family:sans-serif;font-size:14px;width:100%'>
          <thead>
            <tr style='background:{GREEN};color:#fff'>{thead}</tr>
          </thead>
          <tbody>{trs}</tbody>
        </table>
        <p style='font-family:sans-serif;font-size:13px;color:#555;margin-top:8px'>
          {count} class{'es' if count != 1 else ''} booked.
        </p>"""

    return f"""<!DOCTYPE html><html><body style='margin:20px'>
    <h2 style='font-family:sans-serif;color:{GREEN}'>{title}</h2>
    {body}
    </body></html>"""


def send_email(to: str, password: str, subject: str, html: str, text: str) -> None:
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = to
    msg["To"] = to
    msg.attach(MIMEText(text, "plain"))
    msg.attach(MIMEText(html, "html"))
    with smtplib.SMTP("smtp.gmail.com", 587) as smtp:
        smtp.starttls()
        smtp.login(to, password)
        smtp.send_message(msg)


def run() -> int:
    cfg = load_config()
    tz = ZoneInfo(cfg.get("timezone", "America/Los_Angeles"))

    user = os.environ.get("EGYM_USERNAME")
    pw   = os.environ.get("EGYM_PASSWORD")
    if not user or not pw:
        raise SystemExit("Set EGYM_USERNAME and EGYM_PASSWORD.")

    notify_email = os.environ.get("NOTIFY_EMAIL")
    gmail_app_pw = os.environ.get("GMAIL_APP_PASSWORD")

    now      = datetime.now(timezone.utc)
    week_end = now + timedelta(days=7)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            occs = fisikal.list_occurrences(
                context, csrf, now, week_end,
                location_ids=_BOTH_LOCATIONS,
            )
        finally:
            context.close()
            browser.close()

    booked = sorted([o for o in occs if o.get("is_joined")], key=lambda o: o["occurs_at"])
    rows   = _build_rows(booked, tz)
    today  = datetime.now(tz).date()
    title  = f"YMCA classes: {today.strftime('%b %d')} – {(today + timedelta(days=7)).strftime('%b %d')}"
    count  = len(rows)

    md   = _markdown(rows, title, count)
    html = _html(rows, title, count)

    print(md)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(md + "\n")

    if notify_email and gmail_app_pw:
        send_email(
            to=notify_email,
            password=gmail_app_pw,
            subject=f"🏋️ {title}",
            html=html,
            text=md,
        )
        print(f"Email sent to {notify_email}.")
    else:
        print("[email] NOTIFY_EMAIL or GMAIL_APP_PASSWORD not set; skipping email.")

    return 0


if __name__ == "__main__":
    sys.exit(run())
