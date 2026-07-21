# CLAUDE.md — ymca-autobook

Standing context + preferences for this project. **Read at the start of each session** and honor these without re-asking.

## Class & schedule preferences
- **Dislikes Restorative Yoga** — never recommend or auto-book it.
- **Likes Monday Les Mills CORE, Vinyasa Yoga, and Lift & H.I.I.T.** — keep booking all three.
- **Trial early-morning classes (kids' school starts 8/13, freeing up earlier mornings):** Mon 8:45 BODYCOMBAT, Tue 9:00 BODYPUMP, Thu 9:00 BODYPUMP — all Southwest. Thu is fine starting right on 8/13 (school-start day); Mon/Tue naturally start a bit later (8/17/8/18) since the pause calendar already covers the Mondays/Tuesdays before that. Check in after a few weeks on whether to keep them.
- **No cap on classes per day.** Generally avoid back-to-back high-intensity; at most one HIIT-type class per day.
- **Don't add classes to the light days (Mon / Tue / Thu) unless asked** — currently left as-is on purpose.
- Prefer **same-branch** pairings; minimize cross-branch hops when suggesting additions.
- Branch by day: **Mon / Tue / Thu / Fri = Southwest**, **Wed = Northwest**. IDs: Southwest = 1392, Northwest = 1388.
- **Fri dropped the Northwest CORE hop** — replaced with Southwest TRX for Beginners (10:30–11:15), a tight 5-min gap before Lift & H.I.I.T. (11:20), so Friday is now all-Southwest. First live booking lands 8/14 (pause calendar already covers 7/24, 7/31, 8/7); the already-booked 7/24 CORE occurrence is untouched.

## Current weekly schedule (snapshot 2026-07-21 — see `classes.yml` for the authoritative source)
| Day | Time | Class | Branch | Status |
|---|---|---|---|---|
| Mon | 8:45–9:45 | BODYCOMBAT | Southwest | trial, first live 8/17 |
| Mon | 9:45–10:15 | Les Mills CORE | Southwest | recurring |
| Mon | 10:15–11:15 | Vinyasa Yoga | Southwest | recurring |
| Mon | 11:20–12:00 | Lift & H.I.I.T. | Southwest | recurring |
| Tue | 9:00–10:00 | BODYPUMP | Southwest | trial, first live 8/18 |
| Tue | 10:15–11:15 | Cycle | Southwest | recurring |
| Wed | 9:30–10:20 | RPM | Northwest | recurring |
| Wed | 10:30–11:00 | Les Mills CORE | Northwest | recurring |
| Thu | 9:00–10:00 | BODYPUMP | Southwest | trial, first live 8/13 |
| Thu | 10:15–11:15 | Cycle Sculpt | Southwest | recurring |
| Fri | 10:30–11:15 | TRX for Beginners | Southwest | recurring, first live 8/14 |
| Fri | 11:20–12:00 | Lift & H.I.I.T. | Southwest | recurring |

~12 classes/week, ~9h40m total, 5 days/week, no built-in rest day. **Monday is
the heaviest day** and currently stacks two HIIT-type classes (BODYCOMBAT +
Lift & H.I.I.T.) bookending CORE and Vinyasa — this conflicts with the "at
most one HIIT-type per day" preference above and was flagged as a possible
future trim, not yet acted on. Update this table whenever `classes.yml`
changes so it doesn't go stale.

## Booking model
- `classes.yml` = recurring classes to auto-book. Booking opens ~7 days ahead, so each class's cron fires ~1 week before and books that future date.
- Away dates live in the **private** repo `thomashan1/ymca-private` (`pauses.yml`); supports an optional per-class `except:` list to keep booking specific classes on a paused day. The summary calendar greys out away days.
- Full Mon-Fri schedule (both branches, 8:30-15:00, no fee/dance/swim/senior/pickleball) is cached in `schedule_snapshot.json` in the private repo, refreshed daily by `.github/workflows/schedule-snapshot.yml` (`scripts/snapshot_schedule.py`). Read it instead of a live browse when just discussing/recommending classes — it has an `updated_at` timestamp; re-browse live only if it looks stale or a one-off dispatch is needed.
- Manual one-off booking: dispatch `book.yml` with `class_key=<key>` (this path ignores pauses).

## Summary emails
- **Mon / Wed / Fri ~12:07 AM PT** (early + off-peak to dodge GitHub's cron-queue delay).
- Mon = this week; Wed & Fri = this + next week. Date format M/D. Away days blocked out in the calendar.

## Notifications
- Native **GitHub iOS push, failures-only**. Don't add per-run success pings unless asked.

## Ground rules
- Always start from latest `main` (`git fetch origin main`). Land changes via **PR** (main is protected). **Never force-push.**
- **Keep `main` clean** — no temporary/debug workflows or scratch scripts on `main`; use throwaway branches for those.
- Credentials live only in GitHub Actions secrets (`EGYM_USERNAME`, `EGYM_PASSWORD`, `NOTIFY_EMAIL`, `GMAIL_APP_PASSWORD`, `PRIVATE_REPO_TOKEN`). Never commit secrets. Personal away-dates stay in the private repo only.
