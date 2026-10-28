#!/bin/bash
# Build the tvOS probe and run it in the Apple TV simulator.
#   tvos/probe/build.sh            simulator build, installed and launched
# The simulator shares the Mac's memory and GPU, so it only proves that the
# app builds and runs.  The answers that matter (address space, memory, BC
# textures) come from a real Apple TV: build the same main.m for the device
# from Xcode (a tvOS App target, tvos/probe/Info.plist, your team's signing).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../out/tvos-probe"
APP="$OUT/NFSU2Probe.app"
SDK="$(xcrun --sdk appletvsimulator --show-sdk-path)"
rm -rf "$APP"; mkdir -p "$APP"
clang -target arm64-apple-tvos17.0-simulator -isysroot "$SDK" -fobjc-arc -O1 \
    -framework UIKit -framework Foundation -framework Metal -framework QuartzCore -framework GameController -framework CoreGraphics \
    -o "$APP/NFSU2Probe" "$HERE/main.m"
sed -e "s/\$(EXECUTABLE_NAME)/NFSU2Probe/; s/\$(PRODUCT_BUNDLE_IDENTIFIER)/org.nfsu2.tvprobe/; s/\$(PRODUCT_NAME)/NFSU2Probe/" "$HERE/Info.plist" > "$APP/Info.plist"
codesign -s - --force "$APP"
echo "built $APP"

SIM="$(xcrun simctl list devices available | grep -m1 'Apple TV' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
[ -n "$SIM" ] || { echo "no Apple TV simulator: Xcode > Settings > Components"; exit 1; }
xcrun simctl boot "$SIM" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch --console "$SIM" org.nfsu2.tvprobe
