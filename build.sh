#!/bin/bash
# Build Mac Monitor, install it to ~/Applications and (re)start it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/Mac Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacMonitor "$APP/Contents/MacOS/MacMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
pkill -x MacMonitor 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"Mac Monitor.app"
cp -R "$APP" ~/Applications/
open ~/Applications/"Mac Monitor.app"
echo "Installed ~/Applications/Mac Monitor.app — look for ● NN% in the menu bar."
