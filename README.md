# ymca-autobook

Automatically books recurring Silicon Valley YMCA classes the moment they open.

The YMCA (Fisikal backend, egym SSO) opens each class for booking exactly **167 hours
before it starts** — i.e. right after the previous week's session. This bot logs in, waits
for that moment, and books next week's class for you, running unattended on GitHub Actions
with email notifications.

## How it works
1. **Login** (`src/login.py`) — headless Playwright completes the egym SSO flow and reads the
   Fisikal CSRF token. Session cookies are reused for the API calls.
2. **Find** (`src/fisikal.py`) — lists occurrences for the target branch and matches your class
   by **name + weekday + start time** (room and instructor deliberately ignored — they vary).
3. **Wait** (`src/schedule.py`) — computes `open = occurs_at − 167h` from the occurrence itself
   and waits for it.
4. **Book** (`src/fisikal.py`) — POSTs the booking, retrying through the "too early"
   (`advance_time_restriction`) window and lock-version conflicts for up to 60s.
5. **Notify** (`src/notify.py`) — emails the result.

`scripts/run_due.py` is the scheduled entrypoint: it logs in once and books whichever class is
opening now (others are skipped cheaply). `scripts/gen_workflow.py` regenerates the GitHub
Actions cron schedule from `classes.yml`.

## Configure your classes
Edit [`classes.yml`](classes.yml) — one entry per recurring class (name, weekday, local start
time, and branch `location_ids`: Southwest=1392, Northwest=1388). Then regenerate the workflow:

```bash
.venv/bin/python scripts/gen_workflow.py   # rewrites .github/workflows/book.yml
```

## Local setup & testing
```bash
/usr/bin/python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m playwright install chromium

# credentials for local runs (these become GitHub secrets in the cloud)
cp .env.example .env   # then fill in EGYM_USERNAME / EGYM_PASSWORD / SMTP_*
set -a; . ./.env; set +a
```

Useful commands (run from repo root via `.venv/bin/python -m src.main`):
```bash
--browse                   # Mon–Fri 9:30–15:00 classes at both branches (no dance/fee)
--list [name]              # print upcoming occurrences (verify filters)
--class <key> --dry-run    # find the target + open time, don't book
--class <key> --book-now   # attempt the booking immediately (testing)
--cancel-id <occ_id>       # cancel a booking by occurrence id
python scripts/run_due.py  # what the scheduler runs: book whatever's due now
```

## Deploy to GitHub Actions (private repo)
1. **Create a _private_ repo** (the config reveals your weekly whereabouts — keep it private).
2. Push this directory (the `.gitignore` keeps `.env` and `*.har` out).
3. In **Settings → Secrets and variables → Actions**, add:
   - `EGYM_USERNAME`, `EGYM_PASSWORD`
   - (The YMCA already sends a booking confirmation email from noreply@ymcasv.org, so
     no SMTP secrets needed. Run results appear in the Actions job log.)
4. The workflow runs on the generated cron schedule. Trigger a manual test from the **Actions**
   tab → *Book YMCA classes* → *Run workflow* (optionally pass a `class_key`).

### Timing notes
- Booking correctness never depends on cron: the script computes the true open instant in
  Pacific time and waits for it. Cron only needs to fire shortly before.
- GitHub cron is fixed UTC, so each class has **two cron lines** (PDT and PST). The off-season
  one no-ops via the 60-min "already booked / too far out" guard.
- GitHub-scheduled runs can be delayed several minutes under load. Because these classes don't
  fill instantly, the bot still books if it starts a little late. If a class ever fills in
  seconds, move to an always-on VPS (same code, swap the trigger).

## Security
- `*.har`, `.env`, and `capture/` are git-ignored. Credentials live only in env vars / GitHub
  secrets — never in the repo.
- Keep the repo **private**.
