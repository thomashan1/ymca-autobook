"""egym SSO login via Playwright.

Flow (reverse-engineered from the booking HAR):
    1. GET id.egym.com/login?clientId=...&callbackUrl=.../egym_login  (JS SPA form)
    2. Submit username/password -> egym mints a Firebase JWT and redirects the
       browser to  ymca-silicon-valley.fisikal.com/egym_login?token=<JWT>
    3. Fisikal validates the token, sets its session cookie, and 302s to /
    4. The Fisikal page exposes <meta name="csrf-token" content="..."> which every
       subsequent API call must echo as the X-CSRF-Token header.

We let Playwright drive the real browser so we don't have to replicate egym's
internal token exchange. After login we return the BrowserContext (its cookie jar
is shared by context.request) plus the CSRF token.
"""

from __future__ import annotations

import time
from urllib.parse import quote

from playwright.sync_api import BrowserContext, Page, TimeoutError as PWTimeout

CLIENT_ID = "silicon-valley-ymca-2b6f1d9d-5696-4fc7-a96c-bfc8051c32d1"
FISIKAL_BASE = "https://ymca-silicon-valley.fisikal.com"
CALLBACK_URL = f"{FISIKAL_BASE}/egym_login"
LOGIN_URL = (
    f"https://id.egym.com/login?clientId={CLIENT_ID}"
    f"&callbackUrl={quote(CALLBACK_URL, safe='')}"
)

# Generic selectors — verified/adjusted during the first headed run.
USER_SEL = "input[type=email], input[name=username], input[name=email], input#username"
PASS_SEL = "input[type=password], input[name=password], input#password"
SUBMIT_SEL = (
    "button[type=submit], button:has-text('Log in'), button:has-text('Sign in'), "
    "button:has-text('Continue'), button:has-text('Next')"
)


# Text egym shows when the credentials themselves are wrong. Retrying that is
# pointless and, worse, looks like a flaky network instead of a real problem —
# so we fail fast and say so.
_CREDENTIAL_ERROR_HINTS = (
    "incorrect", "invalid", "wrong password",
    "not recognised", "not recognized", "no account",
)


def _credential_error(page: Page) -> str | None:
    try:
        body = (page.inner_text("body") or "").lower()
    except Exception:
        return None
    return next((h for h in _CREDENTIAL_ERROR_HINTS if h in body), None)


def login(context: BrowserContext, username: str, password: str,
          timeout_ms: int = 45000, attempts: int = 3) -> tuple[Page, str]:
    """Log in through egym SSO; return (fisikal page, csrf_token).

    Retries, because egym's identity provider intermittently just doesn't
    redirect: three runs failed this way across two days while every other run
    that hour logged in fine. A whole booking run died each time and emailed a
    failure that a retry cron then quietly fixed — noise that trains you to
    ignore the alerts that matter.

    Wrong credentials are NOT retried; that's a real failure and should surface
    immediately rather than three times slower.

    Raises RuntimeError if every attempt fails.
    """
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return _login_once(context, username, password, timeout_ms)
        except (RuntimeError, PWTimeout) as exc:
            # PWTimeout too: the page load and the selector waits can time out
            # for the same transient reasons as the redirect.
            last = exc
            if getattr(exc, "fatal", False):
                raise
            if attempt < attempts:
                pause = 5 * attempt
                print(f"[login] attempt {attempt}/{attempts} failed ({exc}); "
                      f"retrying in {pause}s.")
                time.sleep(pause)
    raise RuntimeError(f"Login failed after {attempts} attempts. Last: {last}")


def _login_once(context: BrowserContext, username: str, password: str,
                timeout_ms: int) -> tuple[Page, str]:
    page = context.new_page()
    try:
        return _attempt(page, username, password, timeout_ms)
    except BaseException:
        # Don't leak a page per failed attempt — closing twice is harmless.
        try:
            page.close()
        except Exception:
            pass
        raise


def _attempt(page: Page, username: str, password: str,
             timeout_ms: int) -> tuple[Page, str]:
    page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=timeout_ms)

    # Fill username; the SPA may be email-first (password appears after Continue).
    page.wait_for_selector(USER_SEL, timeout=timeout_ms)
    page.fill(USER_SEL, username)

    if page.locator(PASS_SEL).count() == 0 or not page.locator(PASS_SEL).first.is_visible():
        # Two-step form: advance to the password step.
        page.click(SUBMIT_SEL)
        page.wait_for_selector(PASS_SEL, timeout=timeout_ms)

    page.fill(PASS_SEL, password)
    page.click(SUBMIT_SEL)

    # Wait until we are on the Fisikal domain (after the egym->fisikal redirect).
    try:
        page.wait_for_url(f"{FISIKAL_BASE}/**", timeout=timeout_ms)
    except PWTimeout as exc:
        bad = _credential_error(page)
        url = page.url
        page.close()
        err = RuntimeError(
            f"Login did not redirect to Fisikal (still at {url})."
            + (f" The page says '{bad}' — check EGYM_USERNAME / EGYM_PASSWORD."
               if bad else
               " Transient, or the egym form selectors changed.")
        )
        # Bad credentials won't fix themselves on a retry.
        err.fatal = bool(bad)
        raise err from exc

    # <meta> lives in <head> and is never "visible"; wait for it to be attached.
    page.wait_for_selector("meta[name=csrf-token]", state="attached", timeout=timeout_ms)
    csrf = page.get_attribute("meta[name=csrf-token]", "content")
    if not csrf:
        raise RuntimeError("Logged in but could not read csrf-token meta tag.")
    return page, csrf
