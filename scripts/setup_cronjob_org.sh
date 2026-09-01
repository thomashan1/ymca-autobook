#!/usr/bin/env bash
# Creates two cron-job.org jobs that call book.yml's workflow_dispatch for
# BODYPUMP Tue/Thu, as a reliability backup layered ON TOP of GitHub's own
# `schedule:` trigger — not a replacement. GitHub's scheduler has been
# severely delayed (observed up to ~11h) since a 2026-08-26 incident; this
# gives BODYPUMP (the tightest-margin classes, filling within ~5h of open) an
# independent, precisely-timed trigger while book.yml's own crons stay in
# place as free, harmless redundancy (a late GH fire just finds "already
# booked" and no-ops).
#
# Run this yourself, locally — it never sends either secret anywhere but
# cron-job.org's API, and neither one is ever pasted into a chat session.
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
set -euo pipefail

: "${CRONJOB_ORG_API_KEY:?Set CRONJOB_ORG_API_KEY (from cron-job.org Console > Settings > API)}"
: "${GITHUB_PAT:?Set GITHUB_PAT (fine-grained token scoped to this repo, Actions: Read and write)}"

REPO="thomashan1/ymca-autobook"
DISPATCH_URL="https://api.github.com/repos/${REPO}/actions/workflows/book.yml/dispatches"

create_job() {
  local title="$1" class_key="$2" wday="$3"
  local body_json
  body_json=$(printf '{"ref":"main","inputs":{"class_key":"%s"}}' "$class_key")

  curl -sS -X PUT https://api.cron-job.org/jobs \
    -H "Authorization: Bearer ${CRONJOB_ORG_API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
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
      "minutes": [30, 50],
      "hours": [9],
      "mdays": [-1],
      "months": [-1],
      "wdays": [${wday}]
    }
  }
}
JSON
  echo
}

echo "Creating BODYPUMP Tue backup trigger (fires 9:30am and 9:50am PT, Tue)..."
create_job "BODYPUMP Tue backup trigger" "bodypump-tue" 2

echo "Creating BODYPUMP Thu backup trigger (fires 9:30am and 9:50am PT, Thu)..."
create_job "BODYPUMP Thu backup trigger" "bodypump-thu" 4

echo
echo "Done — verify both jobs at https://console.cron-job.org"
