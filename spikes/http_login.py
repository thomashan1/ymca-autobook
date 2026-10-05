"""Spike 1 (#138): egym SSO -> Fisikal session with plain HTTP, no browser.

Read-only: logs in and lists occurrences. Never joins or cancels anything.
Credentials come from the main checkout's gitignored .env (path via ENV_FILE),
and are never printed. Saves the resulting session to spikes/.session.json
(gitignored) for the session-lifetime probe.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote, urlparse

import httpx

CLIENT_ID = "silicon-valley-ymca-2b6f1d9d-5696-4fc7-a96c-bfc8051c32d1"
FISIKAL = "https://ymca-silicon-valley.fisikal.com"
CALLBACK = f"{FISIKAL}/egym_login"
LOGIN_PAGE = f"https://id.egym.com/login?clientId={CLIENT_ID}&callbackUrl={quote(CALLBACK, safe='')}"
OCCURRENCES = f"{FISIKAL}/api/web/schedule/occurrences"
SESSION_FILE = Path(__file__).with_name(".session.json")
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")


def load_env(path: str) -> dict:
    env = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("'\"")
    return env


def list_occurrences(client: httpx.Client, csrf: str, days: int = 16) -> list[dict]:
    now = datetime.now(timezone.utc)
    flt = {"filter": [
        {"by": "status", "with": ["Rescheduled", "Scheduled", "Reminded", "Completed",
                                  "Requested", "Counted", "Verified"]},
        {"by": "since", "with": (now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")},
        {"by": "till", "with": (now + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")},
    ]}
    r = client.get(OCCURRENCES,
                   params={"json": json.dumps(flt), "all_service_categories": "true"},
                   headers={"x-csrf-token": csrf, "x-requested-with": "XMLHttpRequest",
                            "accept": "*/*", "referer": FISIKAL + "/"})
    r.raise_for_status()
    return r.json().get("data", [])


def login(username: str, password: str) -> tuple[httpx.Client, str, dict]:
    t0 = time.monotonic()
    timings = {}
    c = httpx.Client(follow_redirects=True, timeout=30, headers={"user-agent": UA})

    r = c.get(LOGIN_PAGE)
    r.raise_for_status()
    timings["login_page"] = time.monotonic() - t0

    r = c.post("https://id.egym.com/login",
               data={"username": username, "password": password,
                     "clientId": CLIENT_ID, "callbackUrl": CALLBACK},
               headers={"x-requested-with": "XMLHttpRequest",
                        "origin": "https://id.egym.com", "referer": LOGIN_PAGE,
                        "accept": "*/*"})
    timings["post_credentials"] = time.monotonic() - t0
    if r.status_code != 200:
        body = r.text[:300]
        try:
            j = r.json()
            body = f"{j.get('errorPosition')}: {j.get('errorReason')}"
        except Exception:
            pass
        raise SystemExit(f"egym rejected the login: HTTP {r.status_code} — {body}")

    redirect = r.text.strip().strip('"')
    host = urlparse(redirect).netloc
    print(f"egym returned a redirect to {host}{urlparse(redirect).path} "
          f"(query has token: {'token=' in redirect})")

    r = c.get(redirect)  # Fisikal validates the token, sets its session, 302s to /
    timings["fisikal_callback"] = time.monotonic() - t0
    if urlparse(str(r.url)).netloc != urlparse(FISIKAL).netloc:
        raise SystemExit(f"Did not land on Fisikal (ended at {r.url.host})")

    m = re.search(r'<meta name="csrf-token" content="([^"]+)"', r.text)
    if not m:
        r = c.get(FISIKAL + "/")
        m = re.search(r'<meta name="csrf-token" content="([^"]+)"', r.text)
    if not m:
        raise SystemExit("Landed on Fisikal but found no csrf-token meta tag")
    timings["csrf"] = time.monotonic() - t0
    return c, m.group(1), timings


def main() -> int:
    env = load_env(os.environ.get("ENV_FILE", "../ymca-autobook/.env"))
    c, csrf, timings = login(env["EGYM_USERNAME"], env["EGYM_PASSWORD"])

    t = time.monotonic()
    occs = list_occurrences(c, csrf)
    timings["list_occurrences"] = timings["csrf"] + (time.monotonic() - t)
    joined = [o for o in occs if o.get("is_joined")]

    print(f"\nLOGGED IN WITH PLAIN HTTP — {len(occs)} occurrences visible, "
          f"{len(joined)} booked by us")
    for k, v in timings.items():
        print(f"  {k:<18} {v:5.2f}s (cumulative)")

    print("\nFisikal cookies (names / expiry only):")
    for ck in c.cookies.jar:
        if "fisikal" in ck.domain:
            exp = (datetime.fromtimestamp(ck.expires, timezone.utc).isoformat()
                   if ck.expires else "session (no expiry)")
            print(f"  {ck.name:<28} {exp}")

    SESSION_FILE.write_text(json.dumps({
        "created_at": datetime.now(timezone.utc).isoformat(),
        "csrf": csrf,
        "cookies": [{"name": ck.name, "value": ck.value, "domain": ck.domain,
                     "path": ck.path} for ck in c.cookies.jar if "fisikal" in ck.domain],
    }))
    os.chmod(SESSION_FILE, 0o600)
    print(f"\nSaved session to {SESSION_FILE.name} for the lifetime probe.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
