#!/bin/zsh
# Archive EmoDrink and upload it to App Store Connect (TestFlight).
#
# Usage (from the repo root):
#   tools/release.sh <build-number>          archive, export and upload
#   tools/release.sh <build-number> --dry    archive and export only (no upload)
#
# Needs an App Store Connect API key for team FLOWXR (3U4384584Z). Defaults
# to the one in ~/.appstoreconnect/private_keys; override with ASC_KEY_ID,
# ASC_ISSUER_ID and ASC_KEY_PATH. The build number must be higher than every
# build already uploaded for the current MARKETING_VERSION.
set -euo pipefail

BUILD=${1:?usage: tools/release.sh <build-number> [--dry]}
DEST=upload
[[ ${2:-} == --dry ]] && DEST=export

KEY_ID=${ASC_KEY_ID:-F26W9MD3G9}
ISSUER=${ASC_ISSUER_ID:-57b4dae3-2c6d-4cac-ae62-4ad91443fb4b}
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY"
      -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

# A release without the Meta app id cannot link to glasses; without the
# assistant key the recipient would be asked to type one.
grep -qE '^META_APP_ID *= *[0-9]{6,}' Config/Secrets.xcconfig \
  || { echo "Config/Secrets.xcconfig has no real META_APP_ID"; exit 1; }
grep -qE '^BUNDLED_AI_KEY *= *[^ ]' Config/Secrets.xcconfig \
  || echo "warning: no BUNDLED_AI_KEY - the app will ask for a key"

OUT=build/release
rm -rf $OUT
xcodebuild archive -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath $OUT/EmoDrink.xcarchive -derivedDataPath $OUT/dd \
  CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" | grep -E 'error:|\*\* ARCHIVE'

cat > $OUT/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>3U4384584Z</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>$DEST</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

xcodebuild -exportArchive -archivePath $OUT/EmoDrink.xcarchive \
  -exportPath $OUT/export -exportOptionsPlist $OUT/ExportOptions.plist \
  "${AUTH[@]}" | grep -E 'error|\*\* EXPORT|Upload'
echo "done: build $BUILD ($DEST)"
