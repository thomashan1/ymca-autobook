# ymca-autobook

Automatically books recurring Silicon Valley YMCA classes the moment they open.

The YMCA (Fisikal backend, egym SSO) opens each class for booking exactly **167 hours
before it starts** — that is 1 week (168h) minus 1 hour, which works out to the same
weekday one hour *after* the class start time the previous week. For example, a Thursday
10:15 AM class opens for booking the prior Thursday at 11:15 AM. The value 167h comes
directly from the API (`restrict_to_book_in_advance_time_in_hours`) and is not hardcoded.
This bot logs in, waits for that exact moment, and books next week's class for you —
running unattended on GitHub Actions.

## How it works
1. **Login** (`src/login.py`) — headless Playwright completes the egym SSO flow and reads
   the Fisikal CSRF token. Session cookies are reused for all API calls.
2. **Find** (`src/fisikal.py`) — lists occurrences for the target branch and matches by
   **name + weekday + start time** (room and instructor ignored — they vary week to week).
3. **Pause check** (`src/pauses.py`) — if the class date falls in an away-range (see
   [Away / pause dates](#away--pause-dates)), skip it silently.
4. **Wait** (`src/schedule.py`) — computes `open = occurs_at − 167h` and waits for it.
5. **Book** (`src/fisikal.py`) — POSTs the booking; retries up to 3 times (5s apart) to
   absorb clock skew. Refreshes `lock_version` on conflicts.
6. **Notify** (`src/notify.py`) — prints result to stdout (visible in Actions job log).
   The YMCA also sends a booking confirmation email from noreply@ymcasv.org automatically.

`scripts/run_due.py` is the scheduled entrypoint: one login, loops all classes, books
whichever is opening now, skips the rest cheaply. `scripts/gen_workflow.py` regenerates
the GitHub Actions cron schedule from `classes.yml`.

## Configure your classes
Edit [`classes.yml`](classes.yml) — one entry per recurring class:

```yaml
timezone: America/Los_Angeles
classes:
  - key: vinyasa-yoga-mon       # unique slug used in CLI and cron comments
    name: "Vinyasa Yoga"        # exact title from the YMCA schedule
    weekday: Mon
    start: "10:15"              # local start time
    location_ids: [1392]        # branch: Southwest=1392, Northwest=1388
```

After editing, regenerate the workflow:
```bash
.venv/bin/python scripts/gen_workflow.py   # rewrites .github/workflows/book.yml
git add classes.yml .github/workflows/book.yml && git commit && git push
```

## Away / pause dates
Away-dates are kept in a **separate private repo** (`thomashan1/ymca-private`) so they
never appear in this public repo. Create a `pauses.yml` there following
[`pauses.example.yml`](pauses.example.yml):

```yaml
pauses:
  - {start: 2026-07-03, end: 2026-07-03}   # single day off
  - {start: 2026-07-07, end: 2026-07-12}   # away week; resume Mon 7/13
```

The bot matches on the **class date** (not the run date) — booking opens ~7 days ahead,
so the run that would book a paused class fires a week earlier. Add `PRIVATE_REPO_TOKEN`
(a GitHub PAT with `contents:read` on the private repo) to your Actions secrets to enable
this. Fail-open: a missing or broken token means "no pauses" so a misconfiguration can
never silently stop bookings.

## Local setup & testing
```bash
/usr/bin/python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m playwright install chromium

cp .env.example .env    # fill in EGYM_USERNAME / EGYM_PASSWORD
set -a; . ./.env; set +a
```

Useful commands (run from repo root via `.venv/bin/python -m src.main`):
```bash
--browse                   # Mon–Fri 9:30–15:00 classes at both branches (no fee/dance/swim)
--list [name]              # print upcoming occurrences with open times
--class <key> --dry-run    # find the target + open time, don't book
--class <key> --book-now   # skip the wait and book immediately (testing)
--book-id <occ_id>         # book any occurrence by id (testing with a random class)
--cancel-id <occ_id>       # cancel a booking by occurrence id
python scripts/run_due.py  # what the scheduler runs: book whatever's due now
python scripts/weekly_summary.py  # preview this week's booked-class digest
```

## Deploy to GitHub Actions
1. Push this repo (`.gitignore` keeps `.env` and `*.har` out).
2. In **Settings → Secrets and variables → Actions**, add:
   - `EGYM_USERNAME`, `EGYM_PASSWORD` — your egym login
   - `PRIVATE_REPO_TOKEN` *(optional)* — PAT for reading `pauses.yml` from the private repo
   - `NOTIFY_EMAIL`, `GMAIL_APP_PASSWORD` *(optional)* — enables the weekly summary email
3. The booking workflow runs on the generated cron schedule. You can also trigger it
   manually from the **Actions** tab → *Book YMCA classes* → *Run workflow*:
   - **Class key**: book a specific class immediately (blank = schedule decides)
   - **Cancel id**: cancel an existing booking by occurrence id
4. The weekly summary workflow (`weekly-summary.yml`) runs automatically Mon 8am + Fri
   3pm PT and writes a class calendar to the Actions job summary. It also emails an HTML
   calendar if `NOTIFY_EMAIL` and `GMAIL_APP_PASSWORD` are set.

### Timing notes
- Booking correctness never depends on cron: the script computes the true open instant in
  Pacific time and waits for it. Cron only needs to fire shortly before.
- Each class has **four cron lines**: two lead times (-25min and -15min) × two UTC offsets
  (PDT = UTC−7, PST = UTC−8). The redundant leads guard against GitHub silently dropping a
  trigger; the off-season DST line no-ops via the 60-min "already booked" guard.
- GitHub-scheduled runs can be delayed several minutes under load. Because these classes
  don't fill instantly, the bot still books if it starts a little late. If a class ever
  fills in seconds, move to an always-on VPS (same code, swap the trigger).

## Security
- `*.har`, `.env`, and `capture/` are git-ignored. Credentials live only in env vars /
  GitHub secrets — never in the repo.
- Away-dates live in a separate private repo (`thomashan1/ymca-private`), not here.
