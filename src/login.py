"""egym SSO login over plain HTTP — no browser.

Flow:
    1. GET  id.egym.com/login?clientId=...&callbackUrl=.../egym_login
    2. POST id.egym.com/login (username, password, clientId, callbackUrl) as the
       page's own jQuery form does — the response body is the redirect URL,
       ymca-silicon-valley.fisikal.com/egym_login?token=<JWT>
    3. GET that URL: Fisikal validates the token, sets its session cookie, and
       302s to /, whose <meta name="csrf-token"> every API call must echo as
       X-CSRF-Token.

This used to drive a headless Chrome through the same form. The page turned out
to be a plain form (not a JS app), so the browser only ever added a ~180 MB
download per run — which hung on 2026-10-07 and cost a booking. Verified
end-to-end with plain HTTP in #138 (Spike 1): ~2.4 s, same session and CSRF.
"""

from __future__ import annotations

import re
import time
from urllib.parse import quote

import httpx

from .http_context import HttpContext

CLIENT_ID = "silicon-valley-ymca-2b6f1d9d-5696-4fc7-a96c-bfc8051c32d1"
FISIKAL_BASE = "https://ymca-silicon-valley.fisikal.com"
CALLBACK_URL = f"{FISIKAL_BASE}/egym_login"
EGYM_LOGIN = "https://id.egym.com/login"
LOGIN_URL = f"{EGYM_LOGIN}?clientId={CLIENT_ID}&callbackUrl={quote(CALLBACK_URL, safe='')}"

_CSRF = re.compile(r'<meta name="csrf-token" content="([^"]+)"')


class LoginError(RuntimeError):
    def __init__(self, msg: str, fatal: bool = False):
        super().__init__(msg)
        self.fatal = fatal


def login(context: HttpContext, username: str, password: str,
          attempts: int = 3) -> tuple[None, str]:
    """Log in through egym SSO; return (None, csrf_token).

    The first element used to be the Playwright page; it's kept so every caller's
    `_, csrf = login(...)` still works.

    Retries, because egym's identity provider intermittently fails to redirect
    (three runs died this way across two days while others that hour logged in
    fine). Wrong credentials are NOT retried — that's a real failure and should
    surface immediately rather than three times slower.
    """
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return None, _login_once(context, username, password)
        except (LoginError, httpx.HTTPError) as exc:
            last = exc
            if getattr(exc, "fatal", False):
                raise
            if attempt < attempts:
                pause = 5 * attempt
                print(f"[login] attempt {attempt}/{attempts} failed ({exc}); retrying in {pause}s.")
                time.sleep(pause)
    raise RuntimeError(f"Login failed after {attempts} attempts. Last: {last}")


def _login_once(context: HttpContext, username: str, password: str) -> str:
    c = context.client
    c.cookies.clear()
    c.get(LOGIN_URL)

    r = c.post(EGYM_LOGIN,
               data={"username": username, "password": password,
                     "clientId": CLIENT_ID, "callbackUrl": CALLBACK_URL},
               headers={"x-requested-with": "XMLHttpRequest", "accept": "*/*",
                        "origin": "https://id.egym.com", "referer": LOGIN_URL})
    if r.status_code in (400, 401, 403):
        # egym answers bad credentials with a JSON reason (in German, as it happens).
        try:
            reason = r.json().get("errorReason") or r.text[:200]
        except ValueError:
            reason = r.text[:200]
        raise LoginError(f"egym rejected the login (HTTP {r.status_code}): {reason} "
                         f"— check EGYM_USERNAME / EGYM_PASSWORD.", fatal=r.status_code != 403)
    if r.status_code != 200:
        raise LoginError(f"egym login returned HTTP {r.status_code}")

    redirect = r.text.strip().strip('"')
    if not redirect.startswith(CALLBACK_URL):
        raise LoginError(f"egym did not redirect to Fisikal (got {redirect[:80]!r})")

    page = c.get(redirect)  # sets fisikal_v2_session, 302s to /
    m = _CSRF.search(page.text) or _CSRF.search(c.get(FISIKAL_BASE + "/").text)
    if not m:
        raise LoginError("Reached Fisikal but found no csrf-token meta tag")
    return m.group(1)
