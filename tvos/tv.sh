#!/bin/bash
# The Apple TV build, in one place.
#   tvos/tv.sh run        build, install on the Apple TV and start it with the log in the terminal
#   tvos/tv.sh build      build only, the same build as run (nothing is installed or started)
#   tvos/tv.sh install    install the last build on the Apple TV
#   tvos/tv.sh launch     start the installed game with its log in the terminal
#   tvos/tv.sh upload     archive and upload to TestFlight (testflight.sh with UPLOAD=1)
#   tvos/tv.sh project    (re)make tvos/NFSU2.xcodeproj
# The Xcode project is made on the first use: BUNDLE_ID=com.you.nfsu2 TEAM=YOURTEAMID tvos/tv.sh project
# DEVICE=<id> picks the Apple TV (default: the connected one); BUILD=<n> sets the TestFlight build number.
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
PROJ=tvos/NFSU2.xcodeproj
DD=out/tvos-dd

project(){
    : "${BUNDLE_ID:?set BUNDLE_ID (and TEAM) to make the project}" "${TEAM:?set TEAM to make the project}"
    ruby tvos/make_project.rb 2>&1 | grep -v "^Ignoring "
}
[ -d "$PROJ" ] || project

bundle_id(){ grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [^;]*' "$PROJ/project.pbxproj" | head -1 | awk '{print $3}'; }

# the connected Apple TV's identifier
device(){
    [ -n "$DEVICE" ] && { echo "$DEVICE"; return; }
    local j; j="$(mktemp)"
    xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1
    python3 - "$j" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "tvOS" and d["connectionProperties"].get("tunnelState") == "connected":
        print(d["hardwareProperties"]["udid"]); break
PY
    rm -f "$j"
}

build(){
    local dest="$1"
    xcodebuild -project "$PROJ" -scheme NFSU2 -destination "$dest" -allowProvisioningUpdates \
        MARKETING_VERSION="$(tvos/version.sh)" -derivedDataPath "$DD" build 2>&1 | grep -E "error:|BUILD (SUCC|FAIL)"
}

tv(){ DEV="$(device)"; [ -n "$DEV" ] || { echo "no connected Apple TV (wake it up, or set DEVICE=<id>)"; exit 1; }; echo "Apple TV: $DEV"; }
install(){ xcrun devicectl device install app --device "$DEV" "$DD/Build/Products/Debug-appletvos/NFSU2.app" | grep -E "installed|rror"; }
launch(){ exec xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$(bundle_id)"; }

case "${1:-run}" in
  project) project ;;
  build)   tv; build "id=$DEV" ;;
  install) tv; install ;;
  launch)  tv; launch ;;
  run)     tv; build "id=$DEV"; install; launch ;;
  upload)  UPLOAD=1 exec tvos/testflight.sh ;;
  *) sed -n 2,10p "$0"; exit 1 ;;
esac
