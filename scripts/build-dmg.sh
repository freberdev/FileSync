#!/bin/bash
# Builds build/Filsynk-<version>.dmg with the app and a link to /Applications.
# With a name as argument the file is called build/<name>.dmg instead.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

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
