# ymca-autobook

Automatically books recurring Silicon Valley YMCA classes the moment they open.

The YMCA (Fisikal backend, egym SSO) opens each class for booking exactly **167 hours
before it starts** — that is, the same weekday one hour after the class start time the
previous week. For example, a Thursday 10:15 AM class opens for booking the prior Thursday
at 11:15 AM. The value 167h comes directly from the API (`restrict_to_book_in_advance_time_in_hours`)
and is not hardcoded. This bot logs in, waits for that exact moment, and books next week's
class for you — running unattended on GitHub Actions.

## How it works
1. **Login** (`src/login.py`) — headless Playwright completes the egym SSO flow and reads the
   Fisikal CSRF token. Session cookies are reused for the API calls.
2. **Find** (`src/fisikal.py`) — lists occurrences for the target branch and matches your class
   by **name + weekday + start time** (room and instructor deliberately ignored — they vary
   week to week).
3. **Wait** (`src/schedule.py`) — computes `open = occurs_at − 167h` from the occurrence itself
   and waits for it.
4. **Book** (`src/fisikal.py`) — POSTs the booking; retries up to 3 times (5s apart) to absorb
   clock skew around the open instant. Refreshes `lock_version` on conflicts.
5. **Notify** (`src/notify.py`) — prints result to stdout (visible in Actions job log). The YMCA
   also sends a booking confirmation email from noreply@ymcasv.org automatically.

`scripts/run_due.py` is the scheduled entrypoint: it logs in once and books whichever class is
opening now (others are skipped cheaply). `scripts/gen_workflow.py` regenerates the GitHub
Actions cron schedule from `classes.yml`.

## Configure your classes
Copy [`classes.example.yml`](classes.example.yml) to `classes.yml` (git-ignored, stays local)
and fill in your classes — one entry per recurring class (name, weekday, local start time, and
branch `location_ids`). Then regenerate the workflow and update the `CLASSES_YML` secret:

```bash
.venv/bin/python scripts/gen_workflow.py   # rewrites .github/workflows/book.yml
cat classes.yml | gh secret set CLASSES_YML --repo <your-repo>
```

## Local setup & testing
```bash
/usr/bin/python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m playwright install chromium

# credentials and class schedule (both git-ignored, stay local)
cp .env.example .env               # fill in EGYM_USERNAME / EGYM_PASSWORD
cp classes.example.yml classes.yml # fill in your classes
set -a; . ./.env; set +a
```

Useful commands (run from repo root via `.venv/bin/python -m src.main`):
```bash
--browse                   # Mon–Fri 9:30–15:00 classes at both branches (no dance/fee/swim)
--list [name]              # print upcoming occurrences with open times (verify filters)
--class <key> --dry-run    # find the target + open time, don't book
--class <key> --book-now   # skip the wait and book immediately (testing)
--book-id <occ_id>         # book any occurrence by id (testing with a random class)
--cancel-id <occ_id>       # cancel a booking by occurrence id
python scripts/run_due.py  # what the scheduler runs: book whatever's due now
```

## Deploy to GitHub Actions
1. Push this repo (the `.gitignore` keeps `.env`, `classes.yml`, and `*.har` out).
2. In **Settings → Secrets and variables → Actions**, add:
   - `EGYM_USERNAME`, `EGYM_PASSWORD`
   - `CLASSES_YML` — contents of your local `classes.yml` (keep this secret; it reveals
     your weekly schedule)
3. The workflow runs on the generated cron schedule. Trigger a manual test from the **Actions**
   tab → *Book YMCA classes* → *Run workflow* (pass a `class_key` and check *Skip the wait*
   to book immediately).

### Timing notes
- Booking correctness never depends on cron: the script computes the true open instant in
  Pacific time and waits for it. Cron only needs to fire shortly before.
- The cron fires **25 minutes early** to absorb GitHub's scheduling lag (runs can be delayed
  up to ~15 min under load). The script then busy-waits to the exact second.
- GitHub cron is fixed UTC, so each class has **two cron lines** (PDT = UTC−7, PST = UTC−8).
  The off-season line no-ops via the 60-min "already booked / too far out" guard.
- If a class ever fills in seconds, move to an always-on VPS (same code, swap the trigger).

## Security
- `*.har`, `.env`, `classes.yml`, and `capture/` are git-ignored. Credentials and your class
  schedule live only in env vars / GitHub secrets — never in the repo.
