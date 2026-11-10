#!/usr/bin/env bash
# Put a build you've tried in front of friends: scripts/promote.sh 1.1 20261021.3 <release dir>
#  - Mac: publish its notarized .dmg and Sparkle feed as the GitHub release (the download
#    link and every Mac's "update available" both read the newest release), replacing
#    earlier builds of the same version.
#  - iPhone/iPad: add the same build number to the TestFlight group with the public link
#    and submit it for Apple's beta review (quick, often automatic, within a version).
# The release dir is what release_mac.sh built into (RELEASE_DIR). Needs ASC_KEY_ID and
# ASC_ISSUER_ID like the other release scripts.
set -euo pipefail
VERSION="${1:?usage: promote.sh <version> <build> <release dir>}"
BUILD="${2:?usage: promote.sh <version> <build> <release dir>}"
OUT="${3:?usage: promote.sh <version> <build> <release dir>}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$OUT/YMCA-Booker-$VERSION.dmg"
[ -f "$DMG" ] && [ -f "$OUT/appcast.xml" ] || { echo "No $DMG and appcast.xml in $OUT"; exit 1; }
# The oldest macOS the app supports, in a VM (scripts/test_macos12.sh); every Mac
# that builds releases runs a newer one. SKIP_MACOS12_TEST=1 only for a reason you'd write down.
if [ "$(cat "$OUT/macos12-ok" 2>/dev/null)" != "$BUILD" ] && [ "${SKIP_MACOS12_TEST:-}" != 1 ]; then
  echo "$BUILD hasn't passed on macOS 12: run scripts/test_macos12.sh $OUT"; exit 1
fi
[ "$(defaults read "$OUT/YMCA Booker.app/Contents/Info.plist" CFBundleVersion)" = "$BUILD" ] || { echo "$OUT holds a different build"; exit 1; }
REPO="$(git -C "$HERE" remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
# What's new in this version (release-notes/<version>.md): the release page, the Mac's
# update window (via the feed) and TestFlight's "What to Test" all show it.
NOTES="$HERE/release-notes/$VERSION.md"
[ -f "$NOTES" ] || { echo "Write $NOTES first (one '- ' line per change)"; exit 1; }

echo "== GitHub release (Mac download + updates)"
# Lines the last release of this version already had go under a fold; the rest lead.
PREV="$(gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' | grep "^v$VERSION-" | head -1 || true)"
SEEN="$( [ -n "$PREV" ] && gh release view "$PREV" --repo "$REPO" --json body --jq .body | grep '^- ' || true)"
ALL="$(grep '^- ' "$NOTES")"
if [ -z "$SEEN" ]; then
  BODY="$(printf "## What's new in %s\n\n%s" "$VERSION" "$ALL")"
else
  FRESH="$(grep -vxF -f <(printf '%s\n' "$SEEN") <<<"$ALL" || true)"
  BODY="$(printf "## New in this build\n\n%s\n\n<details><summary>Everything in %s</summary>\n\n%s\n\n</details>" "${FRESH:-Small fixes.}" "$VERSION" "$ALL")"
fi
gh release create "v$VERSION-$BUILD" "$DMG" "$OUT/appcast.xml" --target "$(git -C "$HERE" rev-parse HEAD)" --repo "$REPO" \
  --title "YMCA Booker $VERSION ($BUILD) for Mac" \
  --notes "$(printf "%s\n\n---\nOpen the .dmg and drag **YMCA Booker** into Applications. Signed with Developer ID and notarized by Apple. Already installed? It offers this update itself." "$BODY")"
# One release per version: this build replaces earlier builds of the same version.
for old in $(gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' | grep "^v$VERSION-" | grep -vx "v$VERSION-$BUILD"); do
  gh release delete "$old" --repo "$REPO" --yes --cleanup-tag
done

echo "== TestFlight (friends' group)"
python3 "$HERE/scripts/asc_promote.py" "$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8" "$ASC_KEY_ID" "$ASC_ISSUER_ID" \
  com.thomashan.ymcaautobook "$BUILD" "$NOTES"
