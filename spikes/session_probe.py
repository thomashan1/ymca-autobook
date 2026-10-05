"""Spike 2 (#138): how long does a Fisikal session stay usable with no re-login?

Reuses the cookie + CSRF saved by http_login.py and makes one read-only
occurrences GET at growing gaps, appending each result to session_probe.log.
Never logs in, never books. Stops at the first rejection (or after ~7 days).

Gaps grow so an idle timeout shorter than a gap shows up as the first failure
right after that gap; the wall-clock age of the session is logged each time.
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from http_login import FISIKAL, SESSION_FILE, UA, list_occurrences

LOG = Path(__file__).with_name("session_probe.log")
GAPS_MIN = [30, 60, 120, 240, 480, 960, 1440, 1440, 1440, 1440, 1440, 1440, 1440]


def log(msg: str) -> None:
    line = f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}"
    print(line, flush=True)
    with LOG.open("a") as f:
        f.write(line + "\n")


def check(saved: dict) -> tuple[bool, str]:
    jar = httpx.Cookies()
    for ck in saved["cookies"]:
        jar.set(ck["name"], ck["value"], domain=ck["domain"], path=ck["path"])
    with httpx.Client(cookies=jar, timeout=30, headers={"user-agent": UA},
                      follow_redirects=False) as c:
        try:
            occs = list_occurrences(c, saved["csrf"])
            return True, f"OK {len(occs)} occurrences"
        except httpx.HTTPStatusError as e:
            r = e.response
            return False, f"REJECTED HTTP {r.status_code} -> {r.headers.get('location', '')[:80]}"
        except httpx.HTTPError as e:
            return None, f"NETWORK {type(e).__name__}"  # not a session verdict


def main() -> None:
    saved = json.loads(SESSION_FILE.read_text())
    born = datetime.fromisoformat(saved["created_at"])
    log(f"probe start; session created {born.isoformat(timespec='seconds')}")
    for gap in GAPS_MIN:
        time.sleep(gap * 60)
        age_h = (datetime.now(timezone.utc) - born).total_seconds() / 3600
        ok, detail = check(saved)
        log(f"age={age_h:6.2f}h gap={gap}m {detail}")
        if ok is False:
            log(f"RESULT: session died between the previous check and age {age_h:.2f}h")
            return
    log("RESULT: session still alive at end of probe window")


if __name__ == "__main__":
    main()
