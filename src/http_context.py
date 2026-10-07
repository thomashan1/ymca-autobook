"""A plain-HTTP stand-in for the Playwright BrowserContext the code used to log in with.

Everything after login was already plain web requests made through
`context.request.get/post/delete`, and only `.ok`, `.status`, `.json()` and
`.text()` were ever read off the responses. This keeps exactly that surface on
top of an httpx client, so fisikal.py and the booking logic didn't have to change
— while dropping the ~180 MB Chrome download every run used to need (which hung
on 2026-10-07 when Playwright shipped a new Chrome build, and cost a booking).
"""

from __future__ import annotations

import httpx

# A real browser's user agent: egym and Fisikal only ever saw Chrome before.
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")


class Response:
    """The slice of Playwright's APIResponse the code uses."""

    def __init__(self, r: httpx.Response):
        self._r = r

    @property
    def ok(self) -> bool:
        return 200 <= self._r.status_code < 300

    @property
    def status(self) -> int:
        return self._r.status_code

    @property
    def url(self) -> str:
        return str(self._r.url)

    def json(self):
        return self._r.json()

    def text(self) -> str:
        return self._r.text


class _Requests:
    def __init__(self, client: httpx.Client):
        self._c = client

    def get(self, url: str, params: dict | None = None, headers: dict | None = None) -> Response:
        return Response(self._c.get(url, params=params, headers=headers))

    def post(self, url: str, form: dict | None = None, headers: dict | None = None) -> Response:
        return Response(self._c.post(url, data=form, headers=headers))

    def delete(self, url: str, form: dict | None = None, headers: dict | None = None) -> Response:
        # httpx's delete() takes no body; Fisikal's cancel expects a form body.
        return Response(self._c.request("DELETE", url, data=form, headers=headers))


class HttpContext:
    """Cookie-carrying HTTP session with Playwright's `context.request` shape."""

    def __init__(self, timeout: float = 30.0):
        self.client = httpx.Client(follow_redirects=True, timeout=timeout,
                                   headers={"user-agent": USER_AGENT})
        self.request = _Requests(self.client)

    def close(self) -> None:
        self.client.close()

    def __enter__(self) -> "HttpContext":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
