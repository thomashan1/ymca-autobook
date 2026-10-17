"""The YMCA of Silicon Valley branches, by Fisikal location id.

The YMCA's own list (GET /api/web/locations, no login needed), the same one the
app uses (app/YmcaAutobook/Shared/Branch.swift). Nothing here is anyone's
lineup: a class names its own branch in classes.yml (`location_ids`).
"""

from __future__ import annotations

BRANCHES = {
    1384: "Central",
    1385: "El Camino",
    1386: "Lewis and Joan Platt",
    1387: "East Valley",
    1388: "Northwest",
    1389: "Palo Alto",
    1390: "Sequoia",
    1391: "South Valley",
    1392: "Southwest",
}
ALL = list(BRANCHES)


def name(location_id: int | None) -> str:
    return BRANCHES.get(location_id, f"Branch {location_id}") if location_id else "?"


def names(location_ids: list[int] | None) -> str:
    return ", ".join(name(i) for i in (location_ids or [])) or "?"
