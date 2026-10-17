"""Which private repo holds classes.yml, away.yml and swaps.yml.

`PRIVATE_REPO` ("owner/name") wins when set. Otherwise it's `ymca-private`
under the same account as this code: GitHub Actions says who that is
(GITHUB_REPOSITORY_OWNER), and a local run reads it from the git remote. So a
copy of this repo under another account finds its own private repo without
editing anything.
"""

from __future__ import annotations

import os
import re
import subprocess

NAME = "ymca-private"


def _origin_owner() -> str | None:
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True,
                             cwd=os.path.dirname(os.path.abspath(__file__)), timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"github\.com[:/]([^/]+)/", url)
    return m.group(1) if m else None


def default() -> str:
    if repo := os.environ.get("PRIVATE_REPO"):
        return repo
    owner = os.environ.get("GITHUB_REPOSITORY_OWNER") or _origin_owner()
    return f"{owner}/{NAME}" if owner else NAME
