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
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import private_store             # noqa: E402
from src.main import load_config          # noqa: E402
from src.notify_email import send_email   # noqa: E402

_DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri"]
_DOW = {"Mon": 0, "Tue": 1, "Wed": 2, "Thu": 3, "Fri": 4}
SNAPSHOT_PATH = os.environ.get("SCHEDULE_SNAPSHOT_PATH", "schedule_snapshot.json")
BLUE, DBLUE = "#2663c9", "#173f7a"   # header / heading, matching the app's accent
BLOCK_BG = "#e8f0fb"                 # class block fill

# SW / NW chips, mirroring BranchChip in the iOS app: short code, bold, capsule,
# tinted fill with matching text. Two blue shades rather than the app's
# blue/purple, so the pair reads as one family in the mail.
BRANCH_CHIP = {
    "Southwest": ("SW", "#c9dcfa", "#1a44a8"),
    "Northwest": ("NW", "#c2e6f5", "#0a5c82"),
}
# Rows are event bands (see _html), so these only shape proportions — they are
# not what keeps blocks on the hour lines.
PX_PER_MIN = 1.6    # a 5-minute gap reads as 8px, an hour as ~96px
MIN_BAND_PX = 8     # floor, so a tiny band never collapses to nothing


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


def _chip(location: str) -> str:
    """SW / NW capsule, the email twin of BranchChip in the iOS app."""
    short, bg, fg = BRANCH_CHIP.get(location, (location, "#eee", "#666"))
    return (
        f"<span style='display:inline-block;padding:1px 7px;border-radius:9px;"
        f"background:{bg};color:{fg};font-family:sans-serif;font-size:10px;"
        f"font-weight:bold;line-height:1.5'>{short}</span>"
    )


def _html(rows: list[dict]) -> str:
    by_day: dict[int, list[dict]] = {d: [] for d in range(5)}
    for r in rows:
        by_day[r["dow"]].append(r)

    starts = [r["start_min"] for r in rows]
    ends = [r["start_min"] + r["duration"] for r in rows]
    grid_start = (min(starts) // 60) * 60 if rows else 8 * 60
    grid_end = ((max(ends) + 59) // 60) * 60 if rows else 13 * 60

    # Rows are the bands between event boundaries — every class start, every
    # class end, and every hour mark — not fixed-length slots.
    #
    # This is what makes alignment structural rather than arithmetic. A class
    # ending at 11:15 ends on the 11:15 boundary, and 11:00 is its own boundary
    # inside that span, so the block visibly crosses the 11am rule no matter how
    # the client sizes rows. Fixed pixel heights can't promise that: mail
    # clients (Gmail on iOS especially) override font sizes, text grows, rows
    # stretch, and blocks drift off the hour lines.
    bounds = {grid_start, grid_end}
    for r in rows:
        bounds.add(r["start_min"])
        bounds.add(r["start_min"] + r["duration"])
    for m in range(grid_start, grid_end + 1, 60):
        bounds.add(m)
    edges = sorted(b for b in bounds if grid_start <= b <= grid_end)
    n_rows = len(edges) - 1
    at = {b: i for i, b in enumerate(edges)}

    grid: list[list] = [[None] * n_rows for _ in range(5)]
    for dow in range(5):
        for r in by_day[dow]:
            s = at.get(r["start_min"])
            e = at.get(r["start_min"] + r["duration"])
            if s is None or e is None or e <= s:
                continue
            span = e - s
            # Never write over an earlier class's rowspan: an extra <td> in a row
            # breaks the whole table's column alignment. Clip instead, and say so.
            for k in range(s, s + span):
                if grid[dow][k] is not None:
                    print(f"[grid] {r['name']} ({_DAY_NAMES[dow]} {r['start']}) overlaps "
                          f"the previous class; clipping.")
                    span = k - s
                    break
            if span <= 0:
                continue
            grid[dow][s] = (r, span)
            for k in range(s + 1, s + span):
                grid[dow][k] = "skip"

    # Height is only a hint now — it keeps a 5-minute gap from looking like an
    # hour. If a client ignores it, the grid is still correctly ordered.
    heights = [max(MIN_BAND_PX, round((edges[i + 1] - edges[i]) * PX_PER_MIN))
               for i in range(n_rows)]

    day_ths = "".join(
        f"<th style='padding:7px 3px;text-align:center;background:{BLUE};color:#fff;"
        f"font-family:sans-serif;font-size:13px;border-right:1px solid #ddd;"
        f"border-bottom:2px solid {DBLUE}'>{_DAY_NAMES[d]}</th>"
        for d in range(5)
    )
    time_th = (
        "<th style='min-width:52px;padding:4px;background:#f0f0f0;"
        "border-right:1px solid #ccc;border-bottom:2px solid #bbb'></th>"
    )

    body_rows = ""
    for i in range(n_rows):
        minutes = edges[i]
        is_hour = (minutes % 60 == 0)
        h = minutes // 60
        ampm = "am" if h < 12 else "pm"
        label = f"{h % 12 or 12}:00 {ampm}" if is_hour else ""
        if is_hour:
            row_top_border = "border-top:1px solid #ccc"
        elif minutes % 30 == 0:
            row_top_border = "border-top:1px dashed #eee"
        else:
            row_top_border = ""
        time_td = (
            f"<td style='background:#f0f0f0;{row_top_border};border-right:1px solid #ccc;"
            f"padding:0 4px;height:{heights[i]}px;vertical-align:top;"
            f"font-family:sans-serif;font-size:10px;color:#888;text-align:right;"
            f"white-space:nowrap'>{label}</td>"
        )
        day_tds = ""
        for dow in range(5):
            cell = grid[dow][i]
            border = "border-right:1px solid #ddd" if dow < 4 else ""
            if cell == "skip":
                continue
            if cell is None:
                bg = "#f9f9f9" if not is_hour else "#ffffff"
                day_tds += (
                    f"<td style='height:{heights[i]}px;{row_top_border};{border};"
                    f"background:{bg};padding:0'></td>"
                )
            else:
                r, span = cell
                sh, sm = divmod(r["start_min"], 60)
                eh, em = divmod(r["start_min"] + r["duration"], 60)
                start_lbl = f"{sh % 12 or 12}:{sm:02d} {'am' if sh < 12 else 'pm'}"
                end_lbl = f"{eh % 12 or 12}:{em:02d} {'am' if eh < 12 else 'pm'}"
                block_h = max(1, sum(heights[i:i + span]))
                # The colour goes on the <td> itself, not an inner box. A nested
                # div only ever had a min-height, so when a client scaled the
                # table up the cell grew and the box didn't \u2014 the block stopped
                # short of its own end time. Painting the cell makes the coloured
                # area and the time span the same object; they cannot disagree.
                day_tds += (
                    f"<td rowspan='{span}' style='vertical-align:top;{row_top_border};"
                    f"{border};padding:3px 5px;background:{BLOCK_BG};"
                    f"border-left:3px solid {BLUE};height:{block_h}px;"
                    f"font-family:sans-serif;font-size:11px'>"
                    f"<div style='font-size:10px;color:#555;white-space:nowrap'>"
                    f"{start_lbl} \u2013 {end_lbl}</div>"
                    f"<div style='font-weight:bold;color:{DBLUE};margin-top:1px'>{r['name']}</div>"
                    f"<div style='margin-top:2px'>{_chip(r['location'])}</div>"
                    f"</td>"
                )
        body_rows += f"<tr>{time_td}{day_tds}</tr>"

    return (
        "<!DOCTYPE html><html><body style='margin:20px'>"
        f"<h2 style='font-family:sans-serif;color:{BLUE};margin-bottom:2px'>"
        "Standard weekly YMCA schedule</h2>"
        "<p style='font-family:sans-serif;font-size:13px;color:#555;margin:4px 0 10px'>"
        "Your recurring Mon\u2013Fri lineup (not tied to any specific week or booking status).</p>"
        "<table style='border-collapse:collapse;width:100%;min-width:600px'>"
        f"<thead><tr>{time_th}{day_ths}</tr></thead>"
        f"<tbody>{body_rows}</tbody>"
        "</table>"
        "</body></html>"
    )


def _wrong_dst_twin() -> bool:
    """True if this run is the off-DST half of the cron pair (see the workflow).

    Same approach as weekly_summary.py: both crons fire, and we key off WHICH
    cron triggered rather than the wall clock, so a delayed run still resolves
    correctly. Manual dispatches carry no cron and always send.
    """
    cron = os.environ.get("SCHEDULE_CRON", "").strip()
    if not cron:
        return False
    try:
        cron_hour = int(cron.split()[1])
    except (IndexError, ValueError):
        return False
    now_local = datetime.now(ZoneInfo("America/Los_Angeles"))
    correct_utc_hour = now_local.replace(
        hour=17, minute=52, second=0, microsecond=0
    ).astimezone(timezone.utc).hour
    if cron_hour != correct_utc_hour:
        print(f"[skip] cron '{cron}' is the off-DST pair for 17:52 PT "
              f"(correct UTC hour today is {correct_utc_hour:02d}); skipping duplicate.")
        return True
    return False


def run() -> int:
    if _wrong_dst_twin():
        return 0
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
