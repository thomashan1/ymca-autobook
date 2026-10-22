#!/usr/bin/env bash
# Build YMCA Booker for iPhone and iPad and upload it to TestFlight:
# scripts/release_ios.sh 1.0 20261020.1
# The build number is the date plus a counter for that day (Apple allows only digits
# and dots), and must be higher than the last upload of that version.
#
# Needs an App Store Connect API key (Admin or App Manager) saved as
# ~/.appstoreconnect/AuthKey_<ASC_KEY_ID>.p8, with ASC_KEY_ID and ASC_ISSUER_ID set.
# The upload lands in App Store Connect → TestFlight; internal testers get it once
# Apple finishes processing (about 10-30 minutes).
set -euo pipefail
VERSION="${1:?usage: release_ios.sh <version> <build>}"
BUILD="${2:?usage: release_ios.sh <version> <build>}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${RELEASE_DIR:-$(mktemp -d)}"
XB="${XCODEBUILD:-xcodebuild}"
"$HERE/scripts/fetch_sparkle.sh"   # the Mac updater, kept out of git
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "== Archive $VERSION ($BUILD) into $OUT"
"$XB" -project "$HERE/app/YmcaAutobook.xcodeproj" -scheme YmcaAutobook -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/dd" -archivePath "$OUT/app.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" archive -quiet
"$HERE/scripts/check_weak_imports.sh" "$OUT/app.xcarchive/Products/Applications/YMCA Booker.app/YMCA Booker" \
  "$HERE/scripts/weak_imports_ios.txt"

echo "== Upload to App Store Connect"
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
"$XB" -exportArchive -archivePath "$OUT/app.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export" "${AUTH[@]}"
echo "Done: $VERSION ($BUILD) uploaded"
