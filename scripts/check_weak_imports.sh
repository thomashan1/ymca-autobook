#!/usr/bin/env bash
# Fails when the app weak-links an OS symbol that isn't in the reviewed list.
# A new SDK can make the app call functions only the newest OS has, guarded by
# an OS version check; betas of that OS can pass the check without having the
# function, and the app crashes (Date >= in the 27.2 SDK, 10/21). A new entry
# here means: check which OS added it, then avoid it or add it to the list.
#   check_weak_imports.sh <binary> <list>      (--update rewrites the list)
set -euo pipefail
BIN="$1"; LIST="$2"
current() { dyld_info -fixups -arch arm64 "$BIN" | awk '/weak-import/ {print $(NF-1)}' | sort -u; }
if [ "${3:-}" = "--update" ]; then current > "$LIST"; exit 0; fi
NEW="$(comm -13 "$LIST" <(current))"
[ -z "$NEW" ] && exit 0
echo "New weak-linked OS symbols (see scripts/check_weak_imports.sh):"
echo "$NEW" | while read -r s; do echo "  $s  ($(echo "${s#*/_}" | xcrun swift-demangle --simplified))"; done
exit 1
