#!/usr/bin/env bash
# Installs a release .dmg in a macOS 12 VM and checks it there, since every Mac
# that builds releases runs a newer macOS: scripts/test_macos12.sh <release dir>
# (the folder release_mac.sh made). Passing writes macos12-ok into that folder,
# which promote.sh asks for. Takes about 5 minutes; the VM's window shows it all.
#
# Checks: the app installs and opens; it reports the build in the .dmg; the sample
# data screenshots of Schedule, Classes and Settings come out (in <release
# dir>/macos12/); and after a real restart with "Reopen windows" on, exactly one
# copy runs (macOS 12 once started two, and both would book).
#
# The VM (~/VMs/ymca-macos12, about 18 GB; YB_VM moves it) is macOS 12.6 with
# one account, "tester", password "test". To make it again on an Apple Silicon Mac:
#   swiftc -O scripts/vm/vmrun.swift -o vmrun && codesign -s - --entitlements scripts/vm/vmrun.entitlements vmrun
#   ./vmrun install UniversalMac_12.6_21G115_Restore.ipsw ~/VMs/ymca-macos12   (from updates.cdn-apple.com)
#   ./vmrun run ~/VMs/ymca-macos12, then click through Setup Assistant: skip the
#   Apple ID, account tester/test, Pacific time, then in Terminal allow access to
#   removable volumes the first time it asks.
set -euo pipefail
OUT="$(cd "${1:?usage: test_macos12.sh <release dir>}" && pwd)"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VM="${YB_VM:-$HOME/VMs/ymca-macos12}"
DMG="$(ls "$OUT"/YMCA-Booker-*.dmg | head -1)"
[ -f "$VM/disk.img" ] || { echo "No VM at $VM (see the top of this script to make one)"; exit 1; }
pgrep -x vmrun >/dev/null && { echo "The VM is already running; shut it down first"; exit 1; }

RUN="$VM/vmrun"
if [ ! -x "$RUN" ] || [ "$HERE/scripts/vm/vmrun.swift" -nt "$RUN" ]; then
  echo "== Build the VM runner"
  xcrun swiftc -O "$HERE/scripts/vm/vmrun.swift" -o "$RUN"
  codesign -f -s - --entitlements "$HERE/scripts/vm/vmrun.entitlements" "$RUN"
fi

M="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$M" "$DMG" -quiet
WANT="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$M/YMCA Booker.app/Contents/Info.plist")"
hdiutil detach "$M" -quiet

echo "== Test disk with $(basename "$DMG") ($WANT)"
T="$OUT/macos12"; rm -rf "$T"; mkdir -p "$T"
hdiutil create -size 300m -fs HFS+ -volname YBTEST -type UDIF -layout GPTSPUD "$T/disk.dmg" -quiet
hdiutil attach -nobrowse -mountpoint "$M" "$T/disk.dmg" -quiet
cp "$DMG" "$HERE/scripts/vm/guest.sh" "$M/"
hdiutil detach "$M" -quiet
hdiutil convert "$T/disk.dmg" -format UDTO -o "$T/disk" -quiet && rm "$T/disk.dmg"

# One line per command, as vmrun reads them; returns once it has done them all.
vm() {
  rm -f "$VM/out"; printf '%s\n' "$@" > "$VM/cmd.tmp"; mv "$VM/cmd.tmp" "$VM/cmd"
  for _ in $(seq 600); do [ -s "$VM/out" ] && return 0; sleep 0.2; done
  echo "The VM stopped answering"; exit 1
}
shot() { vm "shot $T/$1.png"; }
login() { sleep "$1"; vm "type test" "key return"; sleep 35; }
# Terminal, in front, through Spotlight.
guest() { vm "click 1069 11"; sleep 2; vm "type terminal" "key return"; sleep 4; vm "type sh /Volumes/YBTEST/guest.sh $1" "key return"; }

echo "== Boot macOS 12"
"$RUN" run "$VM" "rw:$T/disk.cdr" > "$T/vmrun.log" 2>&1 &
PID=$!
login 50
echo "== Install"
guest install; sleep 45; shot welcome
echo "== Schedule, Classes, Settings with sample data"
guest sample; sleep 30
echo "== Restart with Reopen windows on"
vm "click 26 11"; sleep 2; vm "click 47 217"; sleep 3; shot restart; vm "click 795 302"
login 70
guest count; sleep 12; shot after-restart
echo "== Shut down"
guest stop
for _ in $(seq 120); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -0 "$PID" 2>/dev/null && { echo "The VM didn't shut down"; kill "$PID"; exit 1; }

hdiutil attach -nobrowse -imagekey diskimage-class=CRawDiskImage -mountpoint "$M" "$T/disk.cdr" -quiet
cp "$M/results.txt" "$T/" 2>/dev/null || true
cp "$M"/shots/*.png "$T/" 2>/dev/null || true
hdiutil detach "$M" -quiet
rm -f "$T/disk.cdr"

echo "== Results"
cat "$T/results.txt" 2>/dev/null || { echo "No results from the VM"; exit 1; }
r() { sed -n "s/^$1=//p" "$T/results.txt" | tail -1; }
FAIL=""
[ "$(r build)" = "$WANT" ] || FAIL="$FAIL; installed build is $(r build), not $WANT"
[ "$(r copies_after_install)" = 1 ] || FAIL="$FAIL; $(r copies_after_install) copies running after install"
[ "$(r copies_after_restart)" = 1 ] || FAIL="$FAIL; $(r copies_after_restart) copies running after restart"
for tab in schedule classes settings; do [ -f "$T/mac-$tab.png" ] || FAIL="$FAIL; no $tab screenshot"; done
if [ -n "$FAIL" ]; then echo "FAILED${FAIL}"; exit 1; fi
echo "$WANT" > "$OUT/macos12-ok"
echo "Passed on macOS $(r macos). Look over the screenshots in $T before promoting."
