"""Read/write small files in the PRIVATE repo via the GitHub Contents API.

Uses the same repo/ref/token as the pause config (see pauses.py). Used to
persist the bookings ledger. Reads need PRIVATE_REPO_TOKEN with contents:read;
writes need contents:write.
"""

from __future__ import annotations

import base64
import os

import httpx

REPO = os.environ.get("PAUSE_REPO", "thomashan1/ymca-private")
REF = os.environ.get("PAUSE_REF", "main")
_API = "https://api.github.com"


def _headers(token: str) -> dict:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def get_file(token: str, path: str) -> tuple[str | None, str | None]:
    """Return (text, sha) for a file in the private repo, or (None, None) if absent."""
    resp = httpx.get(
        f"{_API}/repos/{REPO}/contents/{path}",
        params={"ref": REF},
        headers=_headers(token),
        timeout=15.0,
    )
    if resp.status_code == 404:
        return None, None
    resp.raise_for_status()
    data = resp.json()
    text = base64.b64decode(data["content"]).decode("utf-8")
    return text, data["sha"]


def put_file(token: str, path: str, text: str, sha: str | None, message: str) -> dict:
    """Create or update a file. Pass the current sha to update; None to create."""
    body = {
        "message": message,
        "content": base64.b64encode(text.encode("utf-8")).decode("ascii"),
        "branch": REF,
    }
    if sha:
        body["sha"] = sha
    resp = httpx.put(
        f"{_API}/repos/{REPO}/contents/{path}",
        json=body,
        headers=_headers(token),
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp.json()
