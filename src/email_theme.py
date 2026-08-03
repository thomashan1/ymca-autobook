"""One palette for every schedule email.

Both the Sunday standard-schedule mail and the Mon/Wed/Fri booked-classes
summary draw the same kind of calendar grid, and they used to carry their own
copies of the colours — which is how one ended up green and the other blue.
They import from here instead so restyling one restyles both.
"""

from __future__ import annotations

BLUE = "#2663c9"        # headers, headings
DBLUE = "#173f7a"       # class names, header underline, week divider
BLOCK_BG = "#e8f0fb"    # class block fill
WKND_BG = "#7d92bb"     # muted blue — weekend column header
AWAY_HDR = "#8a8f8c"    # gray — an away day's header
AWAY_BG = "#e6e6e6"     # blocked-out cell fill
WKND_CELL = "#f5f7fb"   # faint blue tint for weekend cells

# SW / NW chips, mirroring BranchChip in the iOS app: short code, bold, capsule,
# tinted fill with matching text. Two blue shades rather than the app's
# blue/purple, so the pair reads as one family in the mail.
BRANCH_CHIP = {
    "Southwest": ("SW", "#c9dcfa", "#1a44a8"),
    "Northwest": ("NW", "#c2e6f5", "#0a5c82"),
}


def chip(location: str) -> str:
    """SW / NW capsule, the email twin of BranchChip in the iOS app."""
    short, bg, fg = BRANCH_CHIP.get(location, (location, "#eee", "#666"))
    return (
        f"<span style='display:inline-block;padding:1px 7px;border-radius:9px;"
        f"background:{bg};color:{fg};font-family:sans-serif;font-size:10px;"
        f"font-weight:bold;line-height:1.5'>{short}</span>"
    )


def branch_of(text: str) -> str | None:
    """Branch name from a free-text location like 'Southwest - Rec Room'."""
    low = (text or "").lower()
    if "southwest" in low:
        return "Southwest"
    if "northwest" in low:
        return "Northwest"
    return None


def chip_for(text: str) -> str:
    """Chip for a room string, falling back to the raw text off-branch."""
    branch = branch_of(text)
    return chip(branch) if branch else ""
