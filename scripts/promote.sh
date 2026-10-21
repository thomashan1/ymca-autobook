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
[ "$(defaults read "$OUT/YMCA Booker.app/Contents/Info.plist" CFBundleVersion)" = "$BUILD" ] || { echo "$OUT holds a different build"; exit 1; }
REPO="$(git -C "$HERE" remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"

echo "== GitHub release (Mac download + updates)"
gh release create "v$VERSION-$BUILD" "$DMG" "$OUT/appcast.xml" --target "$(git -C "$HERE" rev-parse HEAD)" --repo "$REPO" \
  --title "YMCA Booker $VERSION ($BUILD) for Mac" \
  --notes "Open the .dmg and drag **YMCA Booker** into Applications. Signed with Developer ID and notarized by Apple. Already installed? It offers this update itself."
# One release per version: this build replaces earlier builds of the same version.
for old in $(gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' | grep "^v$VERSION-" | grep -vx "v$VERSION-$BUILD"); do
  gh release delete "$old" --repo "$REPO" --yes --cleanup-tag
done

echo "== TestFlight (friends' group)"
python3 "$HERE/scripts/asc_promote.py" "$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8" "$ASC_KEY_ID" "$ASC_ISSUER_ID" \
  com.thomashan.ymcaautobook "$BUILD"
