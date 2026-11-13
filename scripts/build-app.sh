#!/bin/bash
# Builds build/Filsynk.app from the release binary. With --install, also replaces /Applications/Filsynk.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Filsynk"

APP=build/Filsynk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Filsynk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    # Only ask a running app to quit; "tell application" would otherwise launch it.
    if pgrep -x Filsynk >/dev/null; then
        osascript -e 'tell application "Filsynk" to quit' 2>/dev/null || true
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Filsynk >/dev/null || break
        sleep 0.5
    done
    pkill -x Filsynk 2>/dev/null || true
    rm -rf /Applications/Filsynk.app
    cp -R "$APP" /Applications/Filsynk.app
    echo "Installed /Applications/Filsynk.app"
fi
