#!/usr/bin/env bash
# Creates cron-job.org jobs that call book.yml's workflow_dispatch for every
# class in classes.yml, as a reliability backup layered ON TOP of GitHub's own
# `schedule:` trigger — not a replacement. GitHub's scheduler has been
# severely delayed (observed up to ~11h) since a 2026-08-26 incident; this
# gives every class an independent, precisely-timed trigger while book.yml's
# own crons stay in place as free, harmless redundancy (a late GH fire just
# finds "already booked" and no-ops).
#
# One fire per class (-15m before its window opens) by default; two (-30m and
# -10m) for classes carrying `extra_leads` in classes.yml — currently just
# BODYPUMP, the one class where cron-job.org itself having a bad moment could
# actually cost a seat (fills within ~5h; everything else has more slack).
# Reuses `extra_leads` rather than a second parallel config, since it's
# already the same signal gen_workflow.py uses for GitHub-side redundancy.
# One cron-job.org job per (class, lead) — kept as separate jobs rather than
# one job with multiple minute values, since leads can cross an hour boundary
# (e.g. a class whose open is 11:15 has leads at 10:45 and 11:05, in different
# hours — a single job with minutes=[45,5] hours=[10,11] would fire at all
# four combinations, not just the two intended).
#
# Idempotent: re-running SKIPS any existing job with the same title (does not
# delete/recreate — cron-job.org's API proved flaky enough under back-to-back
# calls that a delete-then-recreate pattern risked net-losing a job if the
# create after a successful delete failed). To pick up a changed schedule for
# one class, delete that class's jobs by hand in the console first, then
# re-run. Each create retries a few times on a failed/empty response before
# giving up on that one job and moving on — safe to just re-run the whole
# script afterward to fill in whatever's still missing.
#
# Run this yourself, locally — it never sends either secret anywhere but
# cron-job.org's API, and neither one should be pasted into a chat session.
#
# Prerequisites (you do these yourself, both free, no credit card needed):
#   1. Sign up at https://cron-job.org
#   2. Console -> Settings -> API -> generate an API key
#   3. GitHub -> Settings -> Developer settings -> Fine-grained tokens ->
#      generate one scoped ONLY to thomashan1/ymca-autobook, permission
#      "Actions: Read and write" (nothing else)
#
# Usage:
#   CRONJOB_ORG_API_KEY=... GITHUB_PAT=... ./scripts/setup_cronjob_org.sh
#   CRONJOB_ORG_API_KEY=... GITHUB_PAT=... ./scripts/setup_cronjob_org.sh bodypump-tue   # just one class
set -euo pipefail

: "${CRONJOB_ORG_API_KEY:?Set CRONJOB_ORG_API_KEY (from cron-job.org Console > Settings > API)}"
: "${GITHUB_PAT:?Set GITHUB_PAT (fine-grained token scoped to this repo, Actions: Read and write)}"

REPO="thomashan1/ymca-autobook"
DISPATCH_URL="https://api.github.com/repos/${REPO}/actions/workflows/book.yml/dispatches"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSES_YML="${HERE}/../classes.yml"
CLASS_FILTER="${1:-}"

EXISTING_TITLES=$(curl -sS https://api.cron-job.org/jobs -H "Authorization: Bearer ${CRONJOB_ORG_API_KEY}" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for j in data.get('jobs', []):
    print(j['title'])
")

job_exists() {
  printf '%s\n' "$EXISTING_TITLES" | grep -qxF "$1"
}

# Retries a few times on a failed/empty response — cron-job.org's API proved
# flaky enough under back-to-back calls that a single attempt wasn't reliable.
create_job() {
  local title="$1" class_key="$2" wday="$3" hour="$4" minute="$5"
  local body_json payload attempt resp job_id

  body_json=$(printf '{"ref":"main","inputs":{"class_key":"%s"}}' "$class_key")
  payload=$(cat <<JSON
{
  "job": {
    "title": "${title}",
    "url": "${DISPATCH_URL}",
    "enabled": true,
    "requestMethod": 1,
    "extendedData": {
      "headers": {
        "Authorization": "Bearer ${GITHUB_PAT}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json"
      },
      "body": $(printf '%s' "$body_json" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    },
    "schedule": {
      "timezone": "America/Los_Angeles",
      "minutes": [${minute}],
      "hours": [${hour}],
      "mdays": [-1],
      "months": [-1],
      "wdays": [${wday}]
    }
  }
}
JSON
)

  for attempt in 1 2 3 4; do
    resp=$(curl -sS -X PUT https://api.cron-job.org/jobs \
      -H "Authorization: Bearer ${CRONJOB_ORG_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$payload")
    job_id=$(printf '%s' "$resp" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('jobId',''))
except Exception: print('')" 2>/dev/null || true)
    if [ -n "$job_id" ]; then
      echo "  created job $job_id"
      return 0
    fi
    echo "  attempt $attempt failed (response: ${resp:-<empty>}), retrying..."
    sleep $((attempt * 2))
  done
  echo "  GAVE UP on ${title} after 4 attempts"
  return 1
}

# Emit (class_key, weekday, cron_wday, hour, minute, lead_label) rows — two
# leads (-30m, -10m before open=start+1h) per class — from classes.yml. Written
# to a temp file rather than an inline heredoc: a heredoc nested inside a
# process substitution inside a while-loop is a known bash parsing trap (it
# gets mis-read as the loop repeats), so this sidesteps that entirely.
ROWS_SCRIPT="$(mktemp)"
trap 'rm -f "$ROWS_SCRIPT"' EXIT
cat > "$ROWS_SCRIPT" <<'PYEOF'
import sys
import yaml
from datetime import datetime, timedelta

path, filt = sys.argv[1], sys.argv[2]
cron_dow = {"Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6, "Sun": 0}
cfg = yaml.safe_load(open(path))
for k in cfg["classes"]:
    if filt and k["key"] != filt:
        continue
    h, m = (int(x) for x in k["start"].split(":"))
    open_dt = datetime(2000, 1, 3, h, m) + timedelta(hours=1)
    leads = ((30, "-30m"), (10, "-10m")) if k.get("extra_leads") else ((15, "-15m"),)
    for lead, label in leads:
        fire = open_dt - timedelta(minutes=lead)
        print(f"{k['key']}\t{k['weekday']}\t{cron_dow[k['weekday']]}\t{fire.hour}\t{fire.minute}\t{label}")
PYEOF

ROWS="$(python3 "$ROWS_SCRIPT" "$CLASSES_YML" "$CLASS_FILTER")"

FAILED=()
while IFS=$'\t' read -r class_key weekday wday hour minute lead_label; do
  title="${class_key} (${lead_label})"
  if job_exists "$title"; then
    echo "Skipping ${title} — already exists."
    continue
  fi
  echo "Creating ${title} — ${weekday} $(printf '%02d:%02d' "$hour" "$minute") PT..."
  create_job "$title" "$class_key" "$wday" "$hour" "$minute" || FAILED+=("$title")
  sleep 2  # be gentle on cron-job.org's API — rapid-fire requests got rate-limited
done <<< "$ROWS"

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo
  echo "${#FAILED[@]} job(s) never landed after retries — re-run this script to fill them in:"
  printf '  %s\n' "${FAILED[@]}"
fi
echo "Done — verify jobs at https://console.cron-job.org"
