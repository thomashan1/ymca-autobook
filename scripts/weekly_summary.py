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
            "dt":           dt,
            "day":          dt.strftime("%a"),
            "date":         dt.strftime("%b %d"),
            "isodate":      dt.date(),
            "isoweek":      dt.isocalendar()[1],
            "time":         dt.strftime("%I:%M %p").lstrip("0"),
            "name":         (o.get("service_title") or "").strip(),
            "instructor":   (o.get("trainer_name") or "—").strip(),
            "sub_location": (o.get("sub_location_name") or "—").strip(),
            "duration":     int(o.get("duration_in_minutes") or 60),
        })
    return rows


def _markdown(rows: list[dict], title: str, count: int) -> str:
    lines = [f"## {title}\n"]
    if not rows:
        lines.append("_No classes booked this week._\n")
        return "\n".join(lines)

    header = "| Day | Date | Time | Class | Instructor | Studio |"
    sep    = "|-----|------|------|-------|------------|--------|"

    prev_date: date | None = None
    prev_week: int | None = None
    for r in rows:
        if prev_week is not None and r["isoweek"] != prev_week:
            lines.append("\n---\n")
            lines.append(header)
            lines.append(sep)
        elif prev_date is not None and r["isodate"] != prev_date:
            lines.append("")
            lines.append(header)
            lines.append(sep)
        elif prev_date is None:
            lines.append(header)
            lines.append(sep)

        lines.append(
            f"| {r['day']} | {r['date']} | {r['time']} | {r['name']} "
            f"| {r['instructor']} | {r['sub_location']} |"
        )
        prev_date = r["isodate"]
        prev_week = r["isoweek"]

    lines.append(f"\n**{count} class{'es' if count != 1 else ''} booked.**\n")
    return "\n".join(lines)


def _html(rows: list[dict], title: str, count: int, today: date) -> str:
    GREEN   = "#2d6a4f"
    DGREEN  = "#1b4332"
    WKND_BG = "#6a8a7a"  # muted green for weekend header
    SLOT    = 30  # minutes per grid row
    ROW_H   = 28  # px per row (30-min slot)

    days = [today + timedelta(days=i) for i in range(7)]

    if not rows:
        return (
            f"<!DOCTYPE html><html><body style='margin:20px'>"
            f"<h2 style='font-family:sans-serif;color:{GREEN}'>{title}</h2>"
            f"<p style='font-family:sans-serif'><em>No classes booked this week.</em></p>"
            f"</body></html>"
        )

    # Build per-day class list
    day_map: dict[date, list[dict]] = {}
    for r in rows:
        day_map.setdefault(r["isodate"], []).append(r)

    # Group consecutive Sat/Sun into a single "Weekend" column; weekdays stay separate.
    col_groups: list[list[date]] = []
    for d in days:
        if d.weekday() >= 5:  # Sat=5, Sun=6
            if col_groups and col_groups[-1][-1].weekday() >= 5:
                col_groups[-1].append(d)
            else:
                col_groups.append([d])
        else:
            col_groups.append([d])
    num_cols = len(col_groups)

    def _col_header(grp: list[date]) -> tuple[str, str]:
        if len(grp) == 1:
            return grp[0].strftime("%a"), grp[0].strftime("%-m/%-d")
        return "Weekend", f"{grp[0].strftime('%-m/%-d')}–{grp[-1].strftime('%-m/%-d')}"

    # Grid time range: floor earliest start to hour, ceil latest end to hour + padding
    starts = [r["dt"].hour * 60 + r["dt"].minute for r in rows]
    ends   = [r["dt"].hour * 60 + r["dt"].minute + r["duration"] for r in rows]
    grid_start = (min(starts) // 60) * 60
    grid_end   = ((max(ends) + 59) // 60) * 60 + SLOT
    total_slots = (grid_end - grid_start) // SLOT

    # Build occupancy grid: grid[col_idx][slot] = None | (row_dict, rowspan) | "skip"
    grid: list[list] = [[None] * total_slots for _ in range(num_cols)]
    for col_idx, grp in enumerate(col_groups):
        col_rows = sorted(
            [r for d in grp for r in day_map.get(d, [])],
            key=lambda x: x["dt"],
        )
        for r in col_rows:
            start_m = r["dt"].hour * 60 + r["dt"].minute
            start_s = (start_m - grid_start) // SLOT
            end_m   = start_m + r["duration"]
            end_s   = (end_m - grid_start + SLOT - 1) // SLOT  # ceil to next slot
            span    = max(1, end_s - start_s)
            if 0 <= start_s < total_slots:
                grid[col_idx][start_s] = (r, span)
                for s in range(start_s + 1, min(start_s + span, total_slots)):
                    grid[col_idx][s] = "skip"

    # Week boundary: thick right-border between ISO weeks
    week_boundary: int | None = None
    for i in range(num_cols - 1):
        if col_groups[i][-1].isocalendar()[1] != col_groups[i + 1][0].isocalendar()[1]:
            week_boundary = i
            break

    def _col_border(i: int) -> str:
        if i == week_boundary:
            return f"border-right:3px solid {DGREEN}"
        return "border-right:1px solid #ddd" if i < num_cols - 1 else ""

    # Header row
    time_th = (
        f"<th style='min-width:52px;padding:4px;background:#f0f0f0;"
        f"border-right:1px solid #ccc;border-bottom:2px solid #bbb'></th>"
    )
    day_ths = ""
    for i, grp in enumerate(col_groups):
        day_label, date_label = _col_header(grp)
        is_wknd = grp[0].weekday() >= 5
        bg = WKND_BG if is_wknd else GREEN
        day_ths += (
            f"<th style='padding:7px 3px;text-align:center;background:{bg};color:#fff;"
            f"font-family:sans-serif;font-size:13px;{_col_border(i)};border-bottom:2px solid {DGREEN}'>"
            f"{day_label}<br>"
            f"<span style='font-size:11px;font-weight:normal'>{date_label}</span>"
            f"</th>"
        )

    # Time-grid body rows
    body_rows = ""
    for slot_idx in range(total_slots):
        minutes  = grid_start + slot_idx * SLOT
        is_hour  = (minutes % 60 == 0)
        h        = minutes // 60
        ampm     = "am" if h < 12 else "pm"
        label    = f"{h % 12 or 12}:00 {ampm}" if is_hour else ""
        row_top_border = "border-top:1px solid #ccc" if is_hour else "border-top:1px dashed #eee"

        time_td = (
            f"<td style='background:#f0f0f0;{row_top_border};border-right:1px solid #ccc;"
            f"padding:0 4px;height:{ROW_H}px;vertical-align:top;"
            f"font-family:sans-serif;font-size:10px;color:#888;text-align:right;"
            f"white-space:nowrap'>{label}</td>"
        )

        day_tds = ""
        for col_idx in range(num_cols):
            cell = grid[col_idx][slot_idx]
            if cell == "skip":
                continue

            col_border = _col_border(col_idx)
            is_wknd = col_groups[col_idx][0].weekday() >= 5
            bg = "#f4f6f5" if is_wknd else ("#f9f9f9" if not is_hour else "#ffffff")

            if cell is None:
                day_tds += (
                    f"<td style='height:{ROW_H}px;{row_top_border};{col_border};"
                    f"background:{bg};padding:0'></td>"
                )
            else:
                r, span = cell
                end_dt  = r["dt"] + timedelta(minutes=r["duration"])
                end_str = end_dt.strftime("%I:%M %p").lstrip("0").lower()
                block_h = span * ROW_H - 4
                day_tds += (
                    f"<td rowspan='{span}' style='vertical-align:top;{row_top_border};"
                    f"{col_border};padding:2px 3px;background:#fff'>"
                    f"<div style='background:#e8f5ee;border-left:3px solid {GREEN};"
                    f"border-radius:3px;padding:3px 5px;min-height:{block_h}px;overflow:hidden;"
                    f"font-family:sans-serif;font-size:11px;box-sizing:border-box'>"
                    f"<div style='font-size:10px;color:#555;white-space:nowrap'>"
                    f"{r['time'].lower()} – {end_str}</div>"
                    f"<div style='font-weight:bold;color:{DGREEN};margin-top:1px'>{r['name']}</div>"
                    f"<div style='color:#444;margin-top:1px'>{r['instructor']}</div>"
                    f"<div style='color:#888;font-size:10px;margin-top:1px'>{r['sub_location']}</div>"
                    f"</div></td>"
                )

        body_rows += f"<tr>{time_td}{day_tds}</tr>"

    count_line = (
        f"<p style='font-family:sans-serif;font-size:13px;color:#555;margin:4px 0 10px'>"
        f"{count} class{'es' if count != 1 else ''} booked.</p>"
    )
    # Return a fragment (no html/body wrapper) so callers can combine sections.
    return (
        f"<h2 style='font-family:sans-serif;color:{GREEN};margin-bottom:2px'>{title}</h2>"
        f"{count_line}"
        f"<table style='border-collapse:collapse;width:100%;min-width:600px'>"
        f"<thead><tr>{time_th}{day_ths}</tr></thead>"
        f"<tbody>{body_rows}</tbody>"
        f"</table>"
    )


def _wrap_html(*sections: str) -> str:
    divider = "<hr style='border:none;border-top:2px solid #ddd;margin:28px 0'>"
    body = divider.join(sections)
    return f"<!DOCTYPE html><html><body style='margin:20px'>{body}</body></html>"


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

    today        = datetime.now(tz).date()
    dow          = today.weekday()  # 0=Mon … 4=Fri … 6=Sun
    this_mon     = today - timedelta(days=dow)
    next_mon     = this_mon + timedelta(days=7)
    # Always fetch 14 days; per-week filtering happens below.
    win_start    = datetime(this_mon.year, this_mon.month, this_mon.day, tzinfo=tz)
    win_end      = win_start + timedelta(days=14)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        try:
            _, csrf = login(context, user, pw)
            occs = fisikal.list_occurrences(
                context, csrf, win_start, win_end,
                location_ids=_BOTH_LOCATIONS,
            )
        finally:
            context.close()
            browser.close()

    all_booked = sorted([o for o in occs if o.get("is_joined")], key=lambda o: o["occurs_at"])

    import json as _json
    print("=== RAW BOOKED OCCURRENCES ===")
    for o in all_booked:
        print(_json.dumps(o, indent=2))
    print("=== END RAW ===")

    def _rows_for(mon: date) -> list[dict]:
        sun = mon + timedelta(days=6)
        return _build_rows(
            [o for o in all_booked
             if mon <= datetime.fromisoformat(o["occurs_at"].replace("Z", "+00:00"))
                                .astimezone(tz).date() <= sun],
            tz,
        )

    this_rows  = _rows_for(this_mon)
    next_rows  = _rows_for(next_mon)
    this_fri   = this_mon + timedelta(days=4)
    next_fri   = next_mon + timedelta(days=4)
    this_title = f"YMCA classes: {this_mon.strftime('%a %-m/%-d')} – {this_fri.strftime('%a %-m/%-d')}"
    next_title = f"YMCA classes: {next_mon.strftime('%a %-m/%-d')} – {next_fri.strftime('%a %-m/%-d')}"

    if dow == 0:  # Monday: this week only
        count = len(this_rows)
        md    = _markdown(this_rows, this_title, count)
        html  = _wrap_html(_html(this_rows, this_title, count, this_mon))
        title = this_title
    elif dow <= 3:  # Tue–Thu: this week + next week
        count = len(this_rows) + len(next_rows)
        md    = _markdown(this_rows, this_title, len(this_rows)) + "\n" + _markdown(next_rows, next_title, len(next_rows))
        html  = _wrap_html(_html(this_rows, this_title, len(this_rows), this_mon),
                           _html(next_rows, next_title, len(next_rows), next_mon))
        title = f"{this_title} + next week"
    else:  # Fri–Sun: next week only (classes not yet open for booking)
        count = len(next_rows)
        md    = _markdown(next_rows, next_title, count)
        html  = _wrap_html(_html(next_rows, next_title, count, next_mon))
        title = next_title

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
