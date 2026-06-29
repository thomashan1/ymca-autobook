# CLAUDE.md — ymca-autobook

Standing context + preferences for this project. Read at the start of each session.

## Class preferences
- **Dislikes Restorative Yoga** — tried it, not a fan. Do **not** recommend or auto-book it.
- **Likes Monday Vinyasa Yoga** — keep booking it.
- When suggesting classes to fill light days, prefer the user's home branch and avoid back-to-back high-intensity stacks. Lighter days currently: Mon / Tue / Thu (one class each).

## Booking model
- `classes.yml` = recurring classes to auto-book. Booking opens ~7 days ahead, so each class's cron fires ~1 week before and books that future date.
- Away dates live in the **private** repo `thomashan1/ymca-private` (`pauses.yml`); supports an optional per-class `except:` list to keep booking specific classes on a paused day. The summary calendar greys out away days.
- Branch IDs: **Southwest = 1392, Northwest = 1388**.

## Schedule (current)
- **Booking:** per-class crons in `.github/workflows/book.yml`.
- **Summary emails:** Mon / Wed / Fri ~12:07am PT (early + off-peak to dodge GitHub's cron-queue delay).
- **Ledger:** `bookings.json` snapshot to the private repo every 12h.
- **Notifications:** native GitHub iOS push on failures only.

## Ground rules
- Always start from latest `main` (`git fetch origin main`); land changes via PR (main is protected). **Never force-push.**
- Credentials live only in GitHub Actions secrets (`EGYM_USERNAME`, `EGYM_PASSWORD`, `NOTIFY_EMAIL`, `GMAIL_APP_PASSWORD`, `PRIVATE_REPO_TOKEN`). Never commit secrets; personal away-dates stay in the private repo.
