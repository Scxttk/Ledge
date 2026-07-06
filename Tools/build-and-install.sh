#!/bin/sh
# Builds a Release build and installs it as /Applications/NotchMate.app,
# so Cmd+Space always launches the version built by this script.
set -e

cd "$(dirname "$0")/.."

BUILD_DIR="build/install"
rm -rf "$BUILD_DIR"

xcodebuild -project NotchMate.xcodeproj -scheme NotchMate -configuration Release \
  -derivedDataPath "$BUILD_DIR" build

APP="$BUILD_DIR/Build/Products/Release/NotchMate.app"

osascript -e 'quit app "NotchMate"' 2>/dev/null || true
sleep 1

rm -rf /Applications/NotchMate.app
cp -R "$APP" /Applications/NotchMate.app
rm -rf "$BUILD_DIR"

echo "Installed /Applications/NotchMate.app"
