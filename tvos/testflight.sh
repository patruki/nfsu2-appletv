#!/bin/bash
# Archive the app for TestFlight, and upload it.
#   tvos/testflight.sh              archive only (out/tvos-archive/NFSU2.xcarchive)
#   UPLOAD=1 tvos/testflight.sh     archive, then upload to App Store Connect
# BUILD=<n> sets the build number (default: the date and time, always higher than the last one).
# Before the first upload the app must exist in App Store Connect (tvOS, bundle ID as in the project).
# The upload sends everything in the app: the game folder too (1.7 GB).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BUILD="${BUILD:-$(date +%y%m%d%H%M)}"
VERSION="$(tvos/version.sh)"
OUT=out/tvos-archive
TEAM="$(grep -o 'DEVELOPMENT_TEAM = [A-Z0-9]*' tvos/NFSU2.xcodeproj/project.pbxproj | head -1 | awk '{print $3}')"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodebuild archive -project tvos/NFSU2.xcodeproj -scheme NFSU2 -configuration Release \
    -destination 'generic/platform=tvOS' -archivePath "$OUT/NFSU2.xcarchive" \
    -allowProvisioningUpdates MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" 2>&1 | grep -E "error:|warning: .*(icon|asset)|ARCHIVE (SUCC|FAIL)"
echo "archive: $OUT/NFSU2.xcarchive (version $VERSION, build $BUILD)"
[ "${UPLOAD:-0}" = 1 ] || { echo "not uploaded (UPLOAD=1 uploads)"; exit 0; }
cat > "$OUT/ExportOptions.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PL
xcodebuild -exportArchive -archivePath "$OUT/NFSU2.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates 2>&1 | tail -15
