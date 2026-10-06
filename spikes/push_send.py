"""Spike 3 (#138): send test pushes to Y Booker via APNs (sandbox).

Config lives in spikes/push.env (gitignored):
    APNS_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
    APNS_KEY_ID=XXXXXXXXXX
    APNS_TEAM_ID=GYW462KLR5
    DEVICE_TOKEN=<hex from the app's Settings tab>

Usage:
    push_send.py silent              one silent (content-available) push now
    push_send.py alert               one visible time-sensitive push now (the fallback)
    push_send.py schedule TIMES DAYS silent pushes at local HH:MM TIMES for DAYS days,
                                     e.g.  schedule 07:10,15:40,22:05 4

Every send is logged to push_send.log with the timestamp embedded in the payload,
so the app's wake log can compute delivery latency. Pushes due inside the weekday
9:00–13:30 PT booking window are skipped.
"""

from __future__ import annotations

import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
import jwt

HERE = Path(__file__).parent
TOPIC = "com.thomashan.ybooker"
HOST = "https://api.sandbox.push.apple.com"
PT = ZoneInfo("America/Los_Angeles")
LOG = HERE / "push_send.log"


def config() -> dict:
    cfg = {}
    for line in (HERE / "push.env").read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def log(msg: str) -> None:
    line = f"{datetime.now(PT).isoformat(timespec='seconds')} {msg}"
    print(line, flush=True)
    with LOG.open("a") as f:
        f.write(line + "\n")


def in_quiet_window(t: datetime) -> bool:
    t = t.astimezone(PT)
    mins = t.hour * 60 + t.minute
    return t.weekday() < 5 and 9 * 60 <= mins < 13 * 60 + 30


class APNs:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.key = Path(cfg["APNS_KEY_PATH"]).expanduser().read_text()
        self.client = httpx.Client(http2=True, timeout=20)
        self._token, self._minted = "", 0.0

    def _jwt(self) -> str:
        if time.time() - self._minted > 40 * 60:  # APNs wants tokens refreshed 20-60 min
            self._token = jwt.encode({"iss": self.cfg["APNS_TEAM_ID"], "iat": int(time.time())},
                                     self.key, algorithm="ES256",
                                     headers={"kid": self.cfg["APNS_KEY_ID"]})
            self._minted = time.time()
        return self._token

    def send(self, kind: str) -> None:
        sent = time.time()
        if kind == "silent":
            payload = {"aps": {"content-available": 1}, "sent": sent}
            headers = {"apns-push-type": "background", "apns-priority": "5"}
        else:
            payload = {"aps": {"alert": {"title": "Y Booker test",
                                         "body": "Tap to run the wake-up (fallback path)."},
                               "sound": "default", "interruption-level": "time-sensitive"},
                       "sent": sent}
            headers = {"apns-push-type": "alert", "apns-priority": "10"}
        r = self.client.post(f"{HOST}/3/device/{self.cfg['DEVICE_TOKEN']}", json=payload,
                             headers={**headers, "apns-topic": TOPIC,
                                      "authorization": f"bearer {self._jwt()}"})
        apns_id = r.headers.get("apns-id", "")
        detail = "accepted" if r.status_code == 200 else f"REJECTED {r.status_code} {r.text}"
        log(f"{kind} sent={sent:.3f} -> {detail} apns-id={apns_id}")


def schedule(times: list[str], days: int, apns: APNs) -> None:
    now = datetime.now(PT)
    slots = []
    for d in range(days + 1):
        for hhmm in times:
            h, m = map(int, hhmm.split(":"))
            t = (now + timedelta(days=d)).replace(hour=h, minute=m, second=0, microsecond=0)
            if now < t <= now + timedelta(days=days):
                slots.append(t)
    log(f"schedule: {len(slots)} silent pushes over {days} day(s) at {','.join(times)} PT")
    for t in sorted(slots):
        time.sleep(max(0, (t - datetime.now(PT)).total_seconds()))
        if in_quiet_window(t):
            log(f"skip {t:%a %H:%M} (weekday booking window)")
            continue
        try:
            apns.send("silent")
        except httpx.HTTPError as e:
            log(f"silent send failed: {type(e).__name__}: {e}")
    log("schedule done")


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "silent"
    apns = APNs(config())
    if cmd in ("silent", "alert"):
        if in_quiet_window(datetime.now(PT)):
            print("Inside the weekday 9:00–13:30 PT booking window — not sending.")
            return 1
        apns.send(cmd)
    elif cmd == "schedule":
        schedule(sys.argv[2].split(","), int(sys.argv[3]), apns)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
