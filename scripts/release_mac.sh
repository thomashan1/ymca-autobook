#!/usr/bin/env bash
# Build, sign (Developer ID), notarize and package YMCA Booker for the Mac as a .dmg,
# then publish it as a GitHub release: scripts/release_mac.sh 1.0 20261020.1
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

if [ "${PUBLISH:-1}" = 1 ]; then
  gh release create "v$VERSION-$BUILD" "$DMG" --target "$(git -C "$HERE" rev-parse HEAD)" --repo "$(git -C "$HERE" remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')" \
    --title "YMCA Booker $VERSION ($BUILD) for Mac" \
    --notes "Open the .dmg and drag **YMCA Booker** into Applications. Signed with Developer ID and notarized by Apple."
fi
echo "Done: $DMG"
