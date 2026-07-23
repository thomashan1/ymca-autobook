"""Standard weekly schedule email — the recurring classes.yml lineup, shown as
a generic Mon-Fri "what does a normal week look like" view. Not tied to any
specific week's dates or live booking status (see weekly_summary.py for that).

Runs once a week via .github/workflows/standard-schedule-email.yml. Reads
classes.yml only — no live Fisikal login needed. Pulls each class's end time
from the cached schedule_snapshot.json in the private repo (matched by
day/start/name) for a proper calendar-grid look; falls back to a 60-minute
default if a class isn't found there (fail-open, same spirit as pauses.py).
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import private_store             # noqa: E402
from src.main import load_config          # noqa: E402
from src.notify_email import send_email   # noqa: E402

_DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri"]
_DOW = {"Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4}
SNAPSHOT_PATH = os.environ.get("SCHEDULE_SNAPSHOT_PATH", "schedule_snapshot.json")
GREEN, DGREEN = "#2d6a4f", "#1b4332"
SLOT, ROW_H = 30, 28  # minutes per grid row / px per row


def _duration_lookup(token: str | None) -> dict[tuple, int]:
    """(weekday, start, name-lower) -> duration_minutes, from the cached live
    snapshot. Empty dict (-> 60-min default everywhere) if unavailable."""
    if not token:
        return {}
    try:
        text, _ = private_store.get_file(token, SNAPSHOT_PATH)
        if not text:
            return {}
        data = json.loads(text)
    except Exception as exc:
        print(f"[duration] could not read snapshot ({exc!r}); using 60-min default.")
        return {}
    out = {}
    for r in data.get("classes", []):
        try:
            sh, sm = (int(x) for x in r["start"].split(":"))
            eh, em = (int(x) for x in r["end"].split(":"))
        except (KeyError, ValueError):
            continue
        out[(r["day"], r["start"], r["name"].strip().lower())] = (eh * 60 + em) - (sh * 60 + sm)
    return out


def _rows(cfg: dict, durations: dict[tuple, int]) -> list[dict]:
    rows = []
    for c in cfg["classes"]:
        dow = _DOW.get(c["weekday"])
        if dow is None:  # Sat/Sun not shown — this is a Mon-Fri view
            continue
        h, m = (int(x) for x in c["start"].split(":"))
        start_min = h * 60 + m
        loc_ids = c.get("location_ids") or []
        location = "Southwest" if 1392 in loc_ids else ("Northwest" if 1388 in loc_ids else "?")
        key = (c["weekday"], c["start"], c["name"].strip().lower())
        rows.append({
            "dow": dow, "start_min": start_min, "duration": durations.get(key, 60),
            "start": c["start"], "name": c["name"], "location": location,
        })
    rows.sort(key=lambda r: (r["dow"], r["start_min"]))
    return rows


def _markdown(rows: list[dict]) -> str:
    lines = ["## Standard weekly YMCA schedule\n"]
    by_day: dict[int, list[dict]] = {d: [] for d in range(5)}
    for r in rows:
        by_day[r["dow"]].append(r)
    for dow in range(5):
        day_rows = by_day[dow]
        if not day_rows:
            continue
        lines.append(f"**{_DAY_NAMES[dow]}**\n")
        lines.append("| Time | Class | Branch |")
        lines.append("|------|-------|--------|")
        for r in day_rows:
            h, m = divmod(r["start_min"] + r["duration"], 60)
            lines.append(f"| {r['start']}–{h:02d}:{m:02d} | {r['name']} | {r['location']} |")
        lines.append("")
    return "\n".join(lines)


def _html(rows: list[dict]) -> str:
    by_day: dict[int, list[dict]] = {d: [] for d in range(5)}
    for r in rows:
        by_day[r["dow"]].append(r)

    starts = [r["start_min"] for r in rows]
    ends = [r["start_min"] + r["duration"] for r in rows]
    grid_start = (min(starts) // 60) * 60 if rows else 8 * 60
    grid_end = ((max(ends) + 59) // 60) * 60 + SLOT if rows else 13 * 60
    total_slots = (grid_end - grid_start) // SLOT

    grid: list[list] = [[None] * total_slots for _ in range(5)]
    for dow in range(5):
        for r in by_day[dow]:
            start_s = (r["start_min"] - grid_start) // SLOT
            span = max(1, (r["duration"] + SLOT - 1) // SLOT)
            if 0 <= start_s < total_slots:
                grid[dow][start_s] = (r, span)
                for s in range(start_s + 1, min(start_s + span, total_slots)):
                    grid[dow][s] = "skip"

    day_ths = "".join(
        f"<th style='padding:7px 3px;text-align:center;background:{GREEN};color:#fff;"
        f"font-family:sans-serif;font-size:13px;border-right:1px solid #ddd;"
        f"border-bottom:2px solid {DGREEN}'>{_DAY_NAMES[d]}</th>"
        for d in range(5)
    )
    time_th = (
        "<th style='min-width:52px;padding:4px;background:#f0f0f0;"
        "border-right:1px solid #ccc;border-bottom:2px solid #bbb'></th>"
    )

    body_rows = ""
    for slot_idx in range(total_slots):
        minutes = grid_start + slot_idx * SLOT
        is_hour = (minutes % 60 == 0)
        h = minutes // 60
        ampm = "am" if h < 12 else "pm"
        label = f"{h % 12 or 12}:00 {ampm}" if is_hour else ""
        row_top_border = "border-top:1px solid #ccc" if is_hour else "border-top:1px dashed #eee"
        time_td = (
            f"<td style='background:#f0f0f0;{row_top_border};border-right:1px solid #ccc;"
            f"padding:0 4px;height:{ROW_H}px;vertical-align:top;"
            f"font-family:sans-serif;font-size:10px;color:#888;text-align:right;"
            f"white-space:nowrap'>{label}</td>"
        )
        day_tds = ""
        for dow in range(5):
            cell = grid[dow][slot_idx]
            border = "border-right:1px solid #ddd" if dow < 4 else ""
            if cell == "skip":
                continue
            if cell is None:
                bg = "#f9f9f9" if not is_hour else "#ffffff"
                day_tds += (
                    f"<td style='height:{ROW_H}px;{row_top_border};{border};"
                    f"background:{bg};padding:0'></td>"
                )
            else:
                r, span = cell
                sh, sm = divmod(r["start_min"], 60)
                eh, em = divmod(r["start_min"] + r["duration"], 60)
                start_lbl = f"{sh % 12 or 12}:{sm:02d} {'am' if sh < 12 else 'pm'}"
                end_lbl = f"{eh % 12 or 12}:{em:02d} {'am' if eh < 12 else 'pm'}"
                block_h = span * ROW_H - 4
                day_tds += (
                    f"<td rowspan='{span}' style='vertical-align:top;{row_top_border};"
                    f"{border};padding:2px 3px;background:#fff'>"
                    f"<div style='background:#e8f5ee;border-left:3px solid {GREEN};"
                    f"border-radius:3px;padding:3px 5px;min-height:{block_h}px;overflow:hidden;"
                    f"font-family:sans-serif;font-size:11px;box-sizing:border-box'>"
                    f"<div style='font-size:10px;color:#555;white-space:nowrap'>"
                    f"{start_lbl} – {end_lbl}</div>"
                    f"<div style='font-weight:bold;color:{DGREEN};margin-top:1px'>{r['name']}</div>"
                    f"<div style='color:#888;font-size:10px;margin-top:1px'>{r['location']}</div>"
                    f"</div></td>"
                )
        body_rows += f"<tr>{time_td}{day_tds}</tr>"

    return (
        "<!DOCTYPE html><html><body style='margin:20px'>"
        f"<h2 style='font-family:sans-serif;color:{GREEN};margin-bottom:2px'>"
        "Standard weekly YMCA schedule</h2>"
        "<p style='font-family:sans-serif;font-size:13px;color:#555;margin:4px 0 10px'>"
        "Your recurring Mon–Fri lineup (not tied to any specific week or booking status).</p>"
        "<table style='border-collapse:collapse;width:100%;min-width:600px'>"
        f"<thead><tr>{time_th}{day_ths}</tr></thead>"
        f"<tbody>{body_rows}</tbody>"
        "</table>"
        "</body></html>"
    )


def run() -> int:
    cfg = load_config()
    durations = _duration_lookup(os.environ.get("PRIVATE_REPO_TOKEN"))
    rows = _rows(cfg, durations)

    md = _markdown(rows)
    html = _html(rows)
    print(md)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(md + "\n")

    notify_email = os.environ.get("NOTIFY_EMAIL")
    gmail_app_pw = os.environ.get("GMAIL_APP_PASSWORD")
    if notify_email and gmail_app_pw:
        send_email(
            login_email=notify_email,
            password=gmail_app_pw,
            subject="Standard weekly YMCA schedule",
            html=html,
            text=md,
        )
        print(f"Email sent to {notify_email}.")
    else:
        print("[email] NOTIFY_EMAIL or GMAIL_APP_PASSWORD not set; skipping email.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
