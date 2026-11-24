#!/bin/bash
# Build Mac Memory Monitor.
#   ./build.sh            build, install to ~/Applications and launch
#   ./build.sh --package  build a universal (Apple Silicon + Intel) zip in dist/ for releases
set -euo pipefail
cd "$(dirname "$0")"
NAME="Mac Memory Monitor"
APP="build/$NAME.app"

if [[ "${1:-}" == "--package" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/MacMonitor"
else
  swift build -c release
  BIN=".build/release/MacMonitor"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--package" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  mkdir -p dist
  ZIP="dist/MacMemoryMonitor-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packaged $ZIP"
  exit 0
fi

pkill -x MacMonitor 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"Mac Monitor.app"   # older name
rm -rf ~/Applications/"$NAME.app"
cp -R "$APP" ~/Applications/
open ~/Applications/"$NAME.app"
echo "Installed ~/Applications/$NAME.app — look for ● NN% in the menu bar."
