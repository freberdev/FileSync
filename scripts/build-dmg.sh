#!/bin/bash
# Builds build/Filsynk-<version>.dmg with the app and a link to /Applications.
# With a name as argument the file is called build/<name>.dmg instead.
# With --no-build first, build/Filsynk.app is used as it is instead of being built and signed again.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--no-build" ]; then
    shift
    [ -d build/Filsynk.app ] || { echo "build/Filsynk.app is missing" >&2; exit 1; }
else
    scripts/build-app.sh
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
NAME="${1:-Filsynk-$VERSION}"
DMG="build/$NAME.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Filsynk.app "$STAGE/Filsynk.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname Filsynk -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
echo "Built $DMG"
