# CLAUDE.md — ymca-autobook

## Before starting any work

Always fetch and pull the latest main first:

```bash
git fetch origin main && git pull origin main
```

This project is worked on from both a local Mac session and a remote web session. Main is the source of truth — always start from ToT.

## Branch policy

- Work on `main` directly for small changes, or create a feature branch and PR for larger ones.
- After merging a PR, reset to `origin/main` before continuing.
- **Never force push** (`--force` or `--force-with-lease`) to any branch.

## Key files

- `classes.yml` — classes to auto-book (name, weekday, start time, location)
- `scripts/weekly_summary.py` — sends HTML email + GitHub Actions summary of booked classes
- `src/fisikal.py` — Fisikal API client (list, book, cancel occurrences)
- `src/main.py` — booking orchestration (pick target, wait, retry)
- `.github/workflows/book.yml` — per-class booking crons + manual dispatch
- `.github/workflows/weekly-summary.yml` — Mon 8am PT + Thu 3pm PT summary email

## Secrets (never commit)

Credentials live only in GitHub Actions secrets and environment variables:
`EGYM_USERNAME`, `EGYM_PASSWORD`, `NOTIFY_EMAIL`, `GMAIL_APP_PASSWORD`

`*.har`, `.env`, `capture/` are git-ignored. Personal away-dates live in the private repo `thomashan1/ymca-private`.
