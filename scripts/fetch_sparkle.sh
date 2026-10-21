#!/usr/bin/env bash
# Put Sparkle's official framework at app/Vendor/Sparkle/Sparkle.xcframework (git-ignored),
# checked against the checksum Sparkle publishes for Swift Package Manager. Xcode's own
# package download asks the login Keychain for GitHub credentials and stalls on that
# prompt, so the project uses this local copy instead. Runs once; later calls are no-ops.
set -euo pipefail
VERSION=2.10.0
SHA256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/app/Vendor/Sparkle"
[ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ] && [ -d "$DEST/Sparkle.xcframework" ] && exit 0
TMP="$(mktemp -d)"
curl -fsSL -o "$TMP/sparkle.zip" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip"
echo "$SHA256  $TMP/sparkle.zip" | shasum -a 256 -c - >/dev/null
rm -rf "$DEST/Sparkle.xcframework"
ditto -x -k "$TMP/sparkle.zip" "$TMP/x"
mv "$TMP/x/Sparkle.xcframework" "$DEST/"
echo "$VERSION" > "$DEST/.version"
rm -rf "$TMP"
echo "Sparkle $VERSION ready"
