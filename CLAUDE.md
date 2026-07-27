# CLAUDE.md — ymca-autobook

Standing context + preferences for this project. **Read at the start of each session** and honor these without re-asking.

## Class & schedule preferences
- **Dislikes Restorative Yoga** — never recommend or auto-book it.
- **Likes Monday Les Mills CORE, Vinyasa Yoga, and Lift & H.I.I.T.** — keep booking all three.
- **Three classes are on trial — check in one week after each goes live**, i.e. after its *second* session. Ask about each on/after its date; don't wait to batch them:
  - **Thu 9:00 BODYPUMP** (Southwest) — first live 8/13 → **check in 8/20**
  - **Fri 10:30 TRX for Beginners** (Southwest) — first live 8/14 → **check in 8/21**
  - **Tue 9:00 BODYPUMP** (Southwest) — first live 8/18 → **check in 8/25**

  **The two BODYPUMPs are a straight keep-or-drop.** Either they're liked and join the rotation permanently, or they're removed — which returns Tue and Thu to a single class each (Tue 10:15 Cycle, Thu 10:15 Cycle Sculpt). There's no third option to reshuffle them.

  **The Friday TRX trial is a different question.** It isn't about whether the class is enjoyable — it's testing whether Friday can stay **entirely at Southwest with no branch hop**. Judge it on that: does the all-Southwest morning work, including the 5-min turnaround into Lift & H.I.I.T. at 11:20? If it doesn't, the fallback is Fri 9:45 Les Mills CORE at *Northwest*, which brings the cross-branch hop back.

  Trials came about because kids' school starts 8/13, freeing up earlier mornings; Thu starts right on school-start day, Tue naturally lands later since the pause calendar already covers the Tuesdays before that. _(Mon 8:45 BODYCOMBAT was also being trialed but was removed via the iOS app on 2026-07-24, before its 8/17 first-live.)_
- **No cap on classes per day.** Generally avoid back-to-back high-intensity; at most one HIIT-type class per day.
- **Don't add classes to the light days (Mon / Tue / Thu) unless asked** — currently left as-is on purpose.
- Prefer **same-branch** pairings; minimize cross-branch hops when suggesting additions.
- Branch by day: **Mon / Tue / Thu / Fri = Southwest**, **Wed = Northwest**. IDs: Southwest = 1392, Northwest = 1388.
- **Fri dropped the Northwest CORE hop** — replaced with Southwest TRX for Beginners (10:30–11:15), a tight 5-min gap before Lift & H.I.I.T. (11:20), so Friday is now all-Southwest. First live booking lands 8/14 (pause calendar already covers 7/24, 7/31, 8/7); the already-booked 7/24 CORE occurrence is untouched.

## Current weekly schedule (snapshot 2026-07-24 — see `classes.yml` for the authoritative source)
| Day | Time | Class | Branch | Status |
|---|---|---|---|---|
| Mon | 9:45–10:15 | Les Mills CORE | Southwest | recurring |
| Mon | 10:15–11:15 | Vinyasa Yoga | Southwest | recurring |
| Mon | 11:20–12:00 | Lift & H.I.I.T. | Southwest | recurring |
| Tue | 9:00–10:00 | BODYPUMP | Southwest | trial, first live 8/18 |
| Tue | 10:15–11:15 | Cycle | Southwest | recurring |
| Wed | 9:30–10:20 | RPM | Northwest | recurring |
| Wed | 10:30–11:00 | Les Mills CORE | Northwest | recurring |
| Thu | 9:00–10:00 | BODYPUMP | Southwest | trial, first live 8/13 |
| Thu | 10:15–11:15 | Cycle Sculpt | Southwest | recurring |
| Fri | 10:30–11:15 | TRX for Beginners | Southwest | trial, first live 8/14 |
| Fri | 11:20–12:00 | Lift & H.I.I.T. | Southwest | recurring |

~11 classes/week, ~8h40m total, 5 days/week, no built-in rest day. Monday now
runs Les Mills CORE → Vinyasa → Lift & H.I.I.T. (a single HIIT-type class),
after the Mon 8:45 BODYCOMBAT trial was removed via the iOS app on 2026-07-24 —
which also resolves the old "two HIIT-types on Monday" concern. Update this
table whenever `classes.yml` changes so it doesn't go stale.

## Booking model
- `classes.yml` = recurring classes to auto-book. Booking opens ~7 days ahead, so each class's cron fires ~1 week before and books that future date.
- Away dates live in the **private** repo `thomashan1/ymca-private` (`pauses.yml`); supports an optional per-class `except:` list to keep booking specific classes on a paused day. The summary calendar greys out away days.
- Full Mon-Fri schedule (both branches, 8:30-15:00, no fee/dance/swim/senior/pickleball) is cached in `schedule_snapshot.json` in the private repo, refreshed daily by `.github/workflows/schedule-snapshot.yml` (`scripts/snapshot_schedule.py`). Read it instead of a live browse when just discussing/recommending classes — it has an `updated_at` timestamp; re-browse live only if it looks stale or a one-off dispatch is needed.
- Manual one-off booking: dispatch `book.yml` with `class_key=<key>` (this path ignores pauses).
- `book.yml`'s per-class cron is generated from `classes.yml` by `scripts/gen_workflow.py`. `.github/workflows/regen-book.yml` reruns it automatically on any push to `main` that touches `classes.yml` (e.g. an iOS-app delete) and opens an auto-merging PR — so cron stays in sync without a manual step.

## iOS app
- SwiftUI companion app under `ios/` — a control panel over the GitHub state (Actions stays the booking engine; the app never books directly). Signs in with a fine-grained PAT (Contents + Pull requests + Actions + Workflows) stored in the device Keychain.
- Reads `classes.yml`, `pauses.yml`, and two private-repo snapshots: `schedule_snapshot.json` (class end times/durations) and `bookings.json` (actually-booked classes with room/instructor, published by `scripts/snapshot_bookings.py` via `.github/workflows/bookings-snapshot.yml`, every 6h). The Week view merges the recurring plan with real bookings.
- Editing classes (delete) opens an auto-merging PR against `classes.yml`; away-date edits write directly to `pauses.yml` in the private repo. See `ios/README.md`.

## Summary emails
- **Mon / Wed / Fri ~12:07 AM PT** (early + off-peak to dodge GitHub's cron-queue delay).
- Mon = this week; Wed & Fri = this + next week. Date format M/D. Away days blocked out in the calendar.
- **Standard schedule email — Sun ~6pm PT** (`scripts/standard_schedule_email.py`, `.github/workflows/standard-schedule-email.yml`). A separate, simpler email: the recurring `classes.yml` lineup as a generic Mon–Fri calendar grid, not tied to any specific week's dates or live booking status. No live Fisikal login needed (reads `classes.yml` directly); pulls each class's end time from the cached `schedule_snapshot.json` in the private repo for the grid, falling back to a 60-min default if a class isn't found there.

## Notifications
- Native **GitHub iOS push, failures-only**. Don't add per-run success pings unless asked.
- **Email alert on failed booking attempts** (issue #33 — originally wanted text messages, but AT&T shut down its free email-to-SMS gateway for good on 2025-06-17 with no free replacement, so this alerts by email instead): subject prefixed with ❌, sent via the existing `NOTIFY_EMAIL`/`GMAIL_APP_PASSWORD` creds. Fires for real booking attempts only (scheduled auto-booking, manual `--class`, manual `--book-id`) that fail — not successes (the summary emails already show those) and not cancellations. Fail-open: unset means no alert, everything else unaffected.

## Ground rules
- Always start from latest `main` (`git fetch origin main`). Land changes via **PR** (main is protected). **Never force-push.**
- **Keep `main` clean** — no temporary/debug workflows or scratch scripts on `main`; use throwaway branches for those.
- Credentials live only in GitHub Actions secrets (`EGYM_USERNAME`, `EGYM_PASSWORD`, `NOTIFY_EMAIL`, `GMAIL_APP_PASSWORD`, `PRIVATE_REPO_TOKEN`). Never commit secrets. Personal away-dates stay in the private repo only.
