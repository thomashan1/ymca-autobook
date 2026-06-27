"""TEMP (throwaway branch): verify pause ranges + exceptions against the real
private pauses.yml. Read-only — loads pauses and reports, for each class
occurrence in the next 30 days that falls in a pause, whether it would be
booked (exception) or skipped. No Fisikal login, no booking.
"""

from __future__ import annotations

import os
import sys
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src import main as m      # noqa: E402
from src import pauses         # noqa: E402

_WD = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


def run() -> int:
    cfg = m.load_config()
    ranges = pauses.load_ranges()
    print(f"Parsed {len(ranges)} pause range(s):")
    for r in ranges:
        ex = f"  except={sorted(r.except_keys)}" if r.except_keys else ""
        print(f"  {r.start}..{r.end}{ex}")
    print()

    today = date.today()
    hits = 0
    for klass in cfg.get("classes", []):
        wd = _WD[klass["weekday"].lower()[:3]]
        for i in range(31):
            d = today + timedelta(days=i)
            if d.weekday() != wd:
                continue
            rng = pauses.covering(ranges, d)
            if rng:
                excepted = klass["key"] in rng.except_keys
                verdict = "BOOK (exception)" if excepted else "skip  (paused)"
                print(f"  {d}  {klass['key']:16} {klass['name']:16} -> {verdict}")
                hits += 1
    if not hits:
        print("  (no class occurrences fall in a pause in the next 30 days)")
    return 0


if __name__ == "__main__":
    sys.exit(run())
