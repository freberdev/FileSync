#!/bin/bash
# Builds build/FileSync.app from the release binary. With --install, also replaces /Applications/FileSync.app.
# The app used to be called Filsynk; --install also quits and removes /Applications/Filsynk.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Filsynk"

APP=build/FileSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/sv.lproj Resources/en.lproj "$APP/Contents/Resources/"

# Signing identity: $FILSYNK_SIGN_IDENTITY, else the first line of .signing-identity, else ad hoc.
# A certificate keeps macOS permissions (notifications, login item, local network) across rebuilds.
IDENTITY="${FILSYNK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f .signing-identity ]; then
    IDENTITY="$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' .signing-identity)"
fi
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "Built $APP (signed ad hoc)"
else
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Built $APP (signed with a certificate)"
fi

if [ "${1:-}" = "--install" ]; then
    # This app's process, under its new or its old name; another app called FileSync is left alone.
    RUNNING='/Contents/MacOS/(FileSync|Filsynk)$'
    # Only ask a running app to quit; "tell application" would otherwise launch it.
    if pgrep -f "$RUNNING" >/dev/null; then
        osascript -e 'tell application id "com.freberdev.filsynk" to quit' 2>/dev/null || true
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$RUNNING" >/dev/null || break
        sleep 0.5
    done
    pkill -f "$RUNNING" 2>/dev/null || true
    rm -rf /Applications/FileSync.app
    cp -R "$APP" /Applications/FileSync.app
    echo "Installed /Applications/FileSync.app"
    if [ -d /Applications/Filsynk.app ]; then
        rm -rf /Applications/Filsynk.app
        echo "Removed /Applications/Filsynk.app (the same app under its old name)"
        echo "The app has a new name: check in its settings that \"Starta vid inloggning\" is still on."
    fi
fi
