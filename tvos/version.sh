#!/bin/bash
# The app's version (the number TestFlight and the App Store show): 0.<merges + 1>.  Every merge commit
# on main (a sync with the original repo, a pull request) raises it by one; the build number (BUILD in
# testflight.sh) is the date and time and rises with every build.  VERSION=x.y overrides.
cd "$(dirname "$0")/.."
[ -n "$VERSION" ] && { echo "$VERSION"; exit 0; }
echo "0.$(( $(git rev-list --first-parent --merges --count HEAD) + 1 ))"
