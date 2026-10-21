#!/usr/bin/env bash
# Build, sign (Developer ID), notarize and package YMCA Booker for the Mac as a .dmg,
# with its Sparkle update feed: scripts/release_mac.sh 1.0 20261020.1. Nothing is published:
# scripts/promote.sh puts a tested build in front of friends.
# The build number is the date plus a counter for that day (Apple allows only digits
# and dots, so 20261020.2 rather than 20261020b).
#
# One-time setup (the account holder): a Developer ID Application certificate in the
# login Keychain (Xcode → Settings → Accounts → Manage Certificates), and an App Store
# Connect API key saved as ~/.appstoreconnect/AuthKey_<ASC_KEY_ID>.p8. Set ASC_KEY_ID
# and ASC_ISSUER_ID in the environment. Nothing secret is stored in this repo.
set -euo pipefail
VERSION="${1:?usage: release_mac.sh <version> <build>}"
BUILD="${2:?usage: release_mac.sh <version> <build>}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${RELEASE_DIR:-$(mktemp -d)}"
XB="${XCODEBUILD:-xcodebuild}"
"$HERE/scripts/fetch_sparkle.sh"   # the Mac updater, kept out of git
BUNDLE=com.thomashan.ymcaautobook
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the Keychain"; exit 1; }
NOTARY=(--key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

echo "== Archive $VERSION ($BUILD) into $OUT"
"$XB" -project "$HERE/app/YmcaAutobook.xcodeproj" -scheme YmcaAutobook -destination 'generic/platform=macOS' \
  -derivedDataPath "$OUT/dd" -archivePath "$OUT/app.xcarchive" MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" archive -quiet

echo "== Developer ID provisioning profile"
# Xcode's automatic Developer ID export needs cloud signing, which only the account
# holder (not an API key) may use; so fetch a profile and sign by hand.
python3 "$HERE/scripts/asc_profile.py" "$KEY" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$BUNDLE" "$OUT/devid.provisionprofile"

echo "== Sign"
APP="$OUT/YMCA Booker.app"
rm -rf "$APP"; ditto "$OUT/app.xcarchive/Products/Applications/YMCA Booker.app" "$APP"
cp "$OUT/devid.provisionprofile" "$APP/Contents/embedded.provisionprofile"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$OUT/ent.plist"
/usr/bin/python3 - "$OUT/ent.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
d.pop("com.apple.security.get-task-allow", None)
d["com.apple.developer.icloud-container-environment"] = "Production"
plistlib.dump(d, open(p, "wb"))
PY
# Sparkle's helpers first, inside out: notarization needs every piece signed
# with the Developer ID, hardened runtime and a timestamp.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
  for part in "$SPK/Versions/B/XPCServices/Installer.xpc" "$SPK/Versions/B/XPCServices/Downloader.xpc" \
              "$SPK/Versions/B/Autoupdate" "$SPK/Versions/B/Updater.app" "$SPK"; do
    [ -e "$part" ] && codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$part"
  done
fi
codesign --force --options runtime --timestamp --entitlements "$OUT/ent.plist" --sign "$IDENTITY" "$APP"

echo "== Notarize the app"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
xcrun notarytool submit "$OUT/app.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"

echo "== Package the .dmg"
DMG="$OUT/YMCA-Booker-$VERSION.dmg"
rm -rf "$OUT/dmgroot"; mkdir "$OUT/dmgroot"; ditto "$APP" "$OUT/dmgroot/YMCA Booker.app"
ln -s /Applications "$OUT/dmgroot/Applications"
hdiutil create -volname "YMCA Booker" -srcfolder "$OUT/dmgroot" -ov -format UDZO "$DMG" -quiet
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

echo "== Update feed (Sparkle)"
# The app reads this from the newest release; its signature is checked against
# the public key built into the app. The private key never enters the repo.
REPO="$(git -C "$HERE" remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
SPARKLE_KEY="${SPARKLE_KEY:-$HOME/.appstoreconnect/sparkle_ed25519_private.txt}"
python3 "$HERE/scripts/appcast.py" "$DMG" "$SPARKLE_KEY" "$VERSION" "$BUILD" \
  "https://github.com/$REPO/releases/download/v$VERSION-$BUILD/$(basename "$DMG")" \
  "$HERE/release-notes/$VERSION.md" > "$OUT/appcast.xml"

echo "Built $DMG. Install it on your own Mac to try it; when it's ready for friends:"
echo "  scripts/promote.sh $VERSION $BUILD $OUT"
echo "Done: $DMG"
