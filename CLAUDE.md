# CLAUDE.md — ymca-autobook

Standing context + preferences for this project. **Read at the start of each session** and honor these without re-asking.

## Class & schedule preferences
- **Dislikes Restorative Yoga** — never recommend or auto-book it.
- **Likes Monday Les Mills CORE, Vinyasa Yoga, and Lift & H.I.I.T.** — keep booking all three.
- **No classes are on trial right now.** The three early-morning trials that followed the 8/13 school-start change were all removed via the iOS app before their first live session: **Mon 8:45 BODYCOMBAT** (2026-07-24), **Thu 9:00 BODYPUMP** (2026-07-30), **Tue 9:00 BODYPUMP** (2026-07-30). Don't re-suggest them unasked — the earlier mornings were tried and dropped.
- **No cap on classes per day.** Generally avoid back-to-back high-intensity; at most one HIIT-type class per day.
- **Don't add classes to the light days (Mon / Tue / Thu) unless asked** — currently left as-is on purpose.
- Prefer **same-branch** pairings; minimize cross-branch hops when suggesting additions.
- Branch by day: **Mon / Tue / Thu = Southwest**, **Wed = Northwest**, **Fri = both** (Northwest first, then Southwest). IDs: Southwest = 1392, Northwest = 1388.
- **Friday keeps the cross-branch hop, deliberately.** Les Mills CORE 9:45–10:15 at *Northwest*, then Lift & H.I.I.T. 11:20–12:00 at *Southwest* — a comfortable hour to cross. This settles the experiment: Southwest TRX for Beginners (10:30) briefly replaced the CORE to test whether Friday could be all-Southwest, and on **2026-07-30** that was reversed in favour of the CORE. Friday is the one day where the same-branch preference above is knowingly overridden, so don't "fix" it. First live booking of the restored CORE lands **8/14** (the pause calendar covers 7/31 and 8/7).

## Current weekly schedule (snapshot 2026-07-30 — see `classes.yml` for the authoritative source)
| Day | Time | Class | Branch | Status |
|---|---|---|---|---|
| Mon | 9:45–10:15 | Les Mills CORE | Southwest | recurring |
| Mon | 10:15–11:15 | Vinyasa Yoga | Southwest | recurring |
| Mon | 11:20–12:00 | Lift & H.I.I.T. | Southwest | recurring |
| Tue | 10:15–11:15 | Cycle | Southwest | recurring |
| Wed | 9:30–10:20 | RPM | Northwest | recurring |
| Wed | 10:30–11:00 | Les Mills CORE | Northwest | recurring |
| Thu | 10:15–11:15 | Cycle Sculpt | Southwest | recurring |
| Fri | 9:45–10:15 | Les Mills CORE | Northwest | recurring, first live 8/14 |
| Fri | 11:20–12:00 | Lift & H.I.I.T. | Southwest | recurring |

9 classes/week, 5 days/week, no built-in rest day. Monday is the heavy day
(Les Mills CORE → Vinyasa → Lift & H.I.I.T., a single HIIT-type class);
Tue and Thu are single-class days (Cycle / Cycle Sculpt); Friday runs
Northwest CORE → Southwest Lift & H.I.I.T. Update this table whenever
`classes.yml` changes so it doesn't go stale.

## Booking model
- `classes.yml` = recurring classes to auto-book. Booking opens ~7 days ahead, so each class's cron fires ~1 week before and books that future date.
- Away dates live in the **private** repo `thomashan1/ymca-private` (`pauses.yml`); supports an optional per-class `except:` list to keep booking specific classes on a paused day. The summary calendar greys out away days.
- **One-off swaps** ("that Tuesday, skip Cycle and take BODYCOMBAT instead") live in the same private repo as `swaps.yml` (`src/swaps.py`, applied by `scripts/run_due.py`; template at `swaps.example.yml`). Each entry is a class `date` plus an optional `skip:` key from `classes.yml` and an optional `book:` block naming the replacement by name/start/location_ids — **never an occurrence id**, since ids change weekly and can't be written ahead of time. **The original is never released until the replacement is actually booked**: if the replacement is full, errors, or its window hasn't opened, the recurring class stays on the roster, and once the replacement lands the original is cancelled automatically. A replacement still unbooked after its window opened fails the run and sends a ❌ email. Deliberately has **no cron of its own** — swaps ride `book.yml`'s existing fires, because the purpose-built one-off cron for 2026-08-18 fired 46 min late while `book.yml`'s established crons have never exceeded 19 min across 100 runs. **Don't build another bespoke one-off workflow; add a swap.**
- Full Mon-Fri schedule (both branches, 8:30-15:00, no fee/dance/swim/senior/pickleball) is cached in `schedule_snapshot.json` in the private repo, refreshed daily by `.github/workflows/schedule-snapshot.yml` (`scripts/snapshot_schedule.py`). Read it instead of a live browse when just discussing/recommending classes — it has an `updated_at` timestamp; re-browse live only if it looks stale or a one-off dispatch is needed.
- Manual one-off booking: dispatch `book.yml` with `class_key=<key>` (this path ignores pauses).
- `book.yml`'s per-class cron is generated from `classes.yml` by `scripts/gen_workflow.py`. `.github/workflows/regen-book.yml` tries to rerun it on any push to `main` touching `classes.yml`, **but cannot push the result**: GITHUB_TOKEN is forbidden from writing files under `.github/workflows`, and no `permissions:` value grants it (only a PAT with `workflow` scope, via a `WORKFLOW_TOKEN` secret that doesn't exist yet). Without that secret it reports the drift and exits 0. **So after any classes.yml change, run `python scripts/gen_workflow.py` and commit.** A stale cron for a *deleted* class is harmless (run_due.py reads classes.yml), but an *added* class won't be booked at all until its cron exists.
- **Lead times and `OPEN_GUARD` are coupled — move them together.** `gen_workflow.FIRE_LEAD_MINS` is `[45, 30, 15]`; each lead emits a PDT and a PST cron line and **both fire all year**, so the out-of-season twin arrives `lead + 60` min before the open and `main.OPEN_GUARD` (60 min) is the only thing making it exit instead of waiting an extra hour. Every lead must therefore stay **under 60**. The earliest lead is the delay budget: a late run still books on time because it waits for the true instant. Measured over 100 scheduled runs, GitHub's queue delay was median 4.3 min / p90 13.4 / max 18.8 — the 45 min lead is ~2.5× the worst seen.
- **Pushing `book.yml` can cost that day's scheduled runs.** GitHub re-registers the schedule when the file changes, and on 2026-07-30 a ~10:03 push was followed by both of that morning's booking crons never firing — Cycle Sculpt for 8/6 had to be booked by hand. Avoid regenerating cron on a day a booking window opens, and verify afterwards.

## iOS app
- SwiftUI companion app under `ios/` — a control panel over the GitHub state (Actions stays the booking engine; the app never books directly). Signs in with a fine-grained PAT (Contents + Pull requests + Actions + Workflows) stored in the device Keychain.
- Reads `classes.yml`, `pauses.yml`, and two private-repo snapshots: `schedule_snapshot.json` (class end times/durations) and `bookings.json` (actually-booked classes with room/instructor, published by `scripts/snapshot_bookings.py` via `.github/workflows/bookings-snapshot.yml`, every 6h). The Week view merges the recurring plan with real bookings.
- Editing classes (delete) opens an auto-merging PR against `classes.yml`; away-date edits write directly to `pauses.yml` in the private repo. See `ios/README.md`.

## Summary emails
- **Mon / Wed / Fri ~12:07 AM PT** (early + off-peak to dodge GitHub's cron-queue delay).
- Mon = this week; Wed & Fri = this + next week. Date format M/D. Away days blocked out in the calendar.
- **Standard schedule email — on every `classes.yml` change** (`scripts/standard_schedule_email.py`, `.github/workflows/standard-schedule-email.yml`). Triggered by a push to `main` touching `classes.yml`, plus manual dispatch — **no cron**. It was a Sunday ~6pm weekly send until 2026-08-09; the lineup is static between edits, so an unchanged week had nothing to report. Regenerating `book.yml` after a classes change touches only `.github/workflows`, so it won't fire a second mail. A separate, simpler email: the recurring `classes.yml` lineup as a generic Mon–Fri calendar grid, not tied to any specific week's dates or live booking status. No live Fisikal login needed (reads `classes.yml` directly); pulls each class's end time from the cached `schedule_snapshot.json` in the private repo for the grid, falling back to a 60-min default if a class isn't found there.

## Notifications
- Native **GitHub iOS push, failures-only**. Don't add per-run success pings unless asked.
- **Email alert on failed booking attempts** (issue #33 — originally wanted text messages, but AT&T shut down its free email-to-SMS gateway for good on 2025-06-17 with no free replacement, so this alerts by email instead): subject prefixed with ❌, sent via the existing `NOTIFY_EMAIL`/`GMAIL_APP_PASSWORD` creds. Fires for real booking attempts only (scheduled auto-booking, manual `--class`, manual `--book-id`) that fail — not successes (the summary emails already show those) and not cancellations. Fail-open: unset means no alert, everything else unaffected.

## Ground rules
- Always start from latest `main` (`git fetch origin main`). Land changes via **PR** (main is protected). **Never force-push.**
- **Keep `main` clean** — no temporary/debug workflows or scratch scripts on `main`; use throwaway branches for those.
- Credentials live only in GitHub Actions secrets (`EGYM_USERNAME`, `EGYM_PASSWORD`, `NOTIFY_EMAIL`, `GMAIL_APP_PASSWORD`, `PRIVATE_REPO_TOKEN`). Never commit secrets. Personal away-dates stay in the private repo only.
